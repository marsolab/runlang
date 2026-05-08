// run_xev_bridge.zig — Zig bridge exposing libxev fd polling via C-callable functions.
//
// libxev's C API does not expose fd polling, only the Zig API does. This bridge
// wraps the Zig API and exports C functions for the runtime's poller adapter.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");

// ── Types ──────────────────────────────────────────────────────────

const Loop = xev.Loop;
const Completion = xev.Completion;
const File = xev.File;
const Async = xev.Async;
const Timer = xev.Timer;
const CallbackAction = xev.CallbackAction;

// Opaque pointer to a C-side run_g_t (green thread).
const GPtr = ?*anyopaque;

// Callback the C adapter provides — called when an fd becomes ready.
// Arguments: fd, events (bitmask: 1=read, 2=write), the G pointers.
const ReadyCb = *const fn (c_int, u32, GPtr, GPtr) callconv(.c) void;

extern "c" fn _get_osfhandle(fd: c_int) isize;

// ── Per-fd tracking ────────────────────────────────────────────────

const MaxFds = 4096;

const FdSlot = struct {
    generation: u64 = 0,
    read_g: GPtr = null,
    write_g: GPtr = null,
    read_completion: Completion = .{},
    write_completion: Completion = .{},
    read_cancel: Completion = .{},
    write_cancel: Completion = .{},
    read_ctx: CompletionContext = .{},
    write_ctx: CompletionContext = .{},
    read_armed: bool = false,
    write_armed: bool = false,
    active: bool = false,
};

const CompletionContext = struct {
    slot: ?*FdSlot = null,
    generation: u64 = 0,
};

// ── Global state ───────────────────────────────────────────────────

var loop: Loop = undefined;
var loop_initialized: bool = false;
var async_wakeup: Async = undefined;
var async_completion: Completion = .{};
var async_initialized: bool = false;

// Fixed-size fd table. Keeps things simple and allocation-free.
var fd_slots: [MaxFds]FdSlot = [_]FdSlot{.{}} ** MaxFds;
var registered_count: i32 = 0;
var callbacks_fired: u32 = 0;

// The callback set by the C adapter.
var ready_callback: ?ReadyCb = null;

fn fileHandleFromFd(fd: c_int) ?std.Io.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = _get_osfhandle(fd);
        if (handle == -1) return null;
        return @ptrFromInt(@as(usize, @intCast(handle)));
    }
    return @intCast(fd);
}

// ── C exports ──────────────────────────────────────────────────────

/// Initialize the libxev event loop. Called once from run_poller_init().
export fn run_xev_init(cb: ReadyCb) c_int {
    ready_callback = cb;
    loop = Loop.init(.{}) catch return -1;
    loop_initialized = true;
    return 0;
}

/// Shut down the event loop.
export fn run_xev_close() void {
    if (async_initialized) {
        async_wakeup.deinit();
        async_initialized = false;
    }
    if (loop_initialized) {
        loop.deinit();
        loop_initialized = false;
    }
    registered_count = 0;
    fd_slots = [_]FdSlot{.{}} ** MaxFds;
}

/// Register an fd. Currently a no-op bookkeeping call.
export fn run_xev_open(fd: c_int) c_int {
    if (fd < 0 or fd >= MaxFds) return -1;
    const idx: u32 = @intCast(@as(u32, @bitCast(fd)));
    const slot = &fd_slots[idx];

    if (!slot.active) registered_count += 1;
    const next_generation = slot.generation + 1;
    slot.* = .{
        .generation = next_generation,
        .active = true,
    };
    return 0;
}

/// Unregister an fd and cancel outstanding completions.
///
/// If the read/write completions are still active in the libxev loop (i.e.,
/// registered with kqueue/epoll but not yet fired), we submit cancel ops so
/// libxev removes them cleanly. Zeroing a still-active completion leaves the
/// loop's internal bookkeeping pointing at dangling memory and produces
/// "invalid state" errors on the next tick.
export fn run_xev_close_fd(fd: c_int) void {
    if (fd < 0 or fd >= MaxFds) return;
    const idx: u32 = @intCast(@as(u32, @bitCast(fd)));
    const slot = &fd_slots[idx];
    if (!slot.active) return;

    slot.active = false;
    slot.generation += 1;
    slot.read_g = null;
    slot.write_g = null;

    if (slot.read_completion.state() == .active) {
        slot.read_cancel = .{ .op = .{ .cancel = .{ .c = &slot.read_completion } } };
        loop.add(&slot.read_cancel);
    }
    if (slot.write_completion.state() == .active) {
        slot.write_cancel = .{ .op = .{ .cancel = .{ .c = &slot.write_completion } } };
        loop.add(&slot.write_cancel);
    }

    // Drain the loop so cancel operations retire before the fd number can be
    // reused by a later test. kqueue may need more than one no-wait pass when
    // cancellation completions enqueue follow-up work. We must also wait for
    // the cancel completions themselves to retire — overwriting their storage
    // while a CQE is still pending in the io_uring ring would later cause
    // libxev to invoke a completion whose op has been reset to .noop, hitting
    // an unreachable in Completion.invoke().
    var drain_count: u8 = 0;
    while (drain_count < 64) : (drain_count += 1) {
        const read_active = slot.read_completion.state() == .active;
        const write_active = slot.write_completion.state() == .active;
        const read_cancel_active = slot.read_cancel.state() == .active;
        const write_cancel_active = slot.write_cancel.state() == .active;
        if (!read_active and !write_active and !read_cancel_active and !write_cancel_active) break;
        loop.run(.no_wait) catch {};
    }

    // kqueue can still report readiness for an event that was deleted in the
    // same tick. Run a few extra no-wait passes before resetting completion
    // storage so those stale events still see a valid callback and userdata.
    var flush_count: u8 = 0;
    while (flush_count < 8) : (flush_count += 1) {
        loop.run(.no_wait) catch {};
    }

    const next_generation = slot.generation;
    // Only reset completion storage that has retired. If a cancel completion
    // is somehow still active (e.g., the kernel hasn't reaped it yet after
    // exhausting our drain budget), leave it alone so its eventual CQE finds
    // a valid op rather than .noop. The slot is marked inactive, so the
    // pollCallback/writePollCallback guards (active/generation checks) will
    // disarm safely.
    if (slot.read_completion.state() != .active) slot.read_completion = .{};
    if (slot.write_completion.state() != .active) slot.write_completion = .{};
    if (slot.read_cancel.state() != .active) slot.read_cancel = .{};
    if (slot.write_cancel.state() != .active) slot.write_cancel = .{};
    slot.read_ctx = .{};
    slot.write_ctx = .{};
    slot.read_armed = false;
    slot.write_armed = false;
    slot.generation = next_generation;
    registered_count -= 1;
}

/// Submit read interest for an fd. The associated G will be woken via the callback.
export fn run_xev_poll_read(fd: c_int, g: GPtr) void {
    if (fd < 0 or fd >= MaxFds) return;
    const handle = fileHandleFromFd(fd) orelse return;
    const idx: u32 = @intCast(@as(u32, @bitCast(fd)));
    const slot = &fd_slots[idx];
    if (!slot.active) return;

    slot.read_g = g;
    if (slot.read_armed and slot.read_completion.state() == .active) return;

    slot.read_completion = .{};
    slot.read_ctx = .{
        .slot = slot,
        .generation = slot.generation,
    };
    slot.read_armed = true;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        slot.read_completion = .{
            .op = .{
                .read = .{
                    .fd = handle,
                    .buffer = .{ .slice = &.{} },
                },
            },
            .userdata = &slot.read_ctx,
            .callback = readPollCallback,
        };
        loop.add(&slot.read_completion);
    } else {
        const file = File.initFd(handle);
        file.poll(&loop, &slot.read_completion, .read, CompletionContext, &slot.read_ctx, &pollCallback);
    }
}

/// Submit write interest for an fd. The associated G will be woken via the
/// callback once the fd is writable. libxev's high-level File.poll only
/// exposes read events, so we construct a completion with a `.write` op and
/// empty buffer manually — on kqueue this registers an EVFILT_WRITE kevent,
/// and on epoll a corresponding EPOLLOUT interest. The completion's perform()
/// will attempt a zero-byte write on fire, which is a no-op on all fd types
/// we care about, and we ignore the returned byte count.
export fn run_xev_poll_write(fd: c_int, g: GPtr) void {
    if (fd < 0 or fd >= MaxFds) return;
    const handle = fileHandleFromFd(fd) orelse return;
    const idx: u32 = @intCast(@as(u32, @bitCast(fd)));
    const slot = &fd_slots[idx];
    if (!slot.active) return;

    slot.write_g = g;
    if (slot.write_armed and slot.write_completion.state() == .active) return;

    slot.write_ctx = .{
        .slot = slot,
        .generation = slot.generation,
    };
    slot.write_completion = .{
        .op = .{
            .write = .{
                .fd = handle,
                .buffer = .{ .slice = &.{} },
            },
        },
        .userdata = &slot.write_ctx,
        .callback = writePollCallback,
    };
    slot.write_armed = true;
    loop.add(&slot.write_completion);
}

fn readPollCallback(
    userdata: ?*anyopaque,
    _: *Loop,
    _: *Completion,
    result: xev.Result,
) CallbackAction {
    const ctx: *CompletionContext = @ptrCast(@alignCast(userdata orelse return .disarm));
    const s = ctx.slot orelse return .disarm;
    if (!s.active or ctx.generation != s.generation) return .disarm;

    if (ready_callback) |cb| {
        const idx = (@intFromPtr(s) - @intFromPtr(&fd_slots[0])) / @sizeOf(FdSlot);
        const fd: c_int = @intCast(idx);
        _ = result.read catch {
            const rg = s.read_g;
            const wg = s.write_g;
            s.read_g = null;
            s.write_g = null;
            if (rg != null or wg != null) callbacks_fired += 1;
            cb(fd, 3, rg, wg);
            return .disarm;
        };
        const rg = s.read_g;
        s.read_g = null;
        if (rg != null) callbacks_fired += 1;
        cb(fd, 1, rg, null);
    }
    return .disarm;
}

fn writePollCallback(
    userdata: ?*anyopaque,
    _: *Loop,
    _: *Completion,
    result: xev.Result,
) CallbackAction {
    const ctx: *CompletionContext = @ptrCast(@alignCast(userdata orelse return .disarm));
    const s = ctx.slot orelse return .disarm;
    if (!s.active or ctx.generation != s.generation) return .disarm;

    if (ready_callback) |cb| {
        const idx = (@intFromPtr(s) - @intFromPtr(&fd_slots[0])) / @sizeOf(FdSlot);
        const fd: c_int = @intCast(idx);
        _ = result.write catch {
            const rg = s.read_g;
            const wg = s.write_g;
            s.read_g = null;
            s.write_g = null;
            if (rg != null or wg != null) callbacks_fired += 1;
            cb(fd, 3, rg, wg);
            return .rearm;
        };
        const wg = s.write_g;
        s.write_g = null;
        if (wg != null) callbacks_fired += 1;
        cb(fd, 2, null, wg);
    }
    return .rearm;
}

fn pollCallback(
    ctx: ?*CompletionContext,
    _: *Loop,
    _: *Completion,
    _: File,
    result: xev.PollError!xev.PollEvent,
) CallbackAction {
    const c = ctx orelse return .disarm;
    const s = c.slot orelse return .disarm;
    if (!s.active or c.generation != s.generation) return .disarm;

    if (ready_callback) |cb| {
        const idx = (@intFromPtr(s) - @intFromPtr(&fd_slots[0])) / @sizeOf(FdSlot);
        const fd: c_int = @intCast(idx);
        _ = result catch {
            const rg = s.read_g;
            const wg = s.write_g;
            s.read_g = null;
            s.write_g = null;
            if (rg != null or wg != null) callbacks_fired += 1;
            cb(fd, 3, rg, wg);
            return .rearm;
        };
        const rg = s.read_g;
        s.read_g = null;
        if (rg != null) callbacks_fired += 1;
        cb(fd, 1, rg, null);
    }
    return .rearm;
}

/// Run the event loop without blocking (tick once).
export fn run_xev_tick() c_int {
    if (!loop_initialized) return 0;
    if (registered_count <= 0) return 0;

    // Drain all currently-ready completions in this tick. On kqueue, a single
    // no_wait run can report only one completion even when multiple fds are
    // already ready; bounded draining ensures fairness and avoids dropped wakeups.
    callbacks_fired = 0;
    var previous_callbacks: u32 = 0;
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        loop.run(.no_wait) catch return -1;
        if (callbacks_fired == previous_callbacks) break;
        previous_callbacks = callbacks_fired;
    }

    return 0;
}

/// Run the event loop, blocking until at least one event or timeout.
export fn run_xev_tick_blocking(timeout_ms: i64) c_int {
    if (!loop_initialized) return 0;

    if (timeout_ms == 0) {
        return run_xev_tick();
    }

    if (timeout_ms > 0) {
        var timer = Timer.init() catch return -1;
        defer timer.deinit();
        var timer_c: Completion = .{};
        timer.run(&loop, &timer_c, @intCast(@as(u64, @bitCast(timeout_ms))), void, null, &timerNoop);
        loop.run(.once) catch return -1;
    } else {
        loop.run(.once) catch return -1;
    }
    return 0;
}

fn timerNoop(
    _: ?*void,
    _: *Loop,
    _: *Completion,
    _: Timer.RunError!void,
) CallbackAction {
    return .disarm;
}

/// Initialize the async notification handle for cross-thread wakeup.
export fn run_xev_async_init() c_int {
    if (!loop_initialized) return -1;
    async_wakeup = Async.init() catch return -1;
    async_initialized = true;
    return 0;
}

/// Trigger the async notification (safe to call from any thread).
export fn run_xev_async_notify() c_int {
    if (!async_initialized) return -1;
    return if (async_wakeup.notify()) |_| 0 else |_| -1;
}

/// Register a wait on the async notification.
export fn run_xev_async_wait() void {
    if (!async_initialized) return;
    if (async_completion.state() == .active) return;
    async_completion = .{};
    async_wakeup.wait(&loop, &async_completion, void, null, &asyncNoop);
}

fn asyncNoop(
    _: ?*void,
    _: *Loop,
    _: *Completion,
    _: Async.WaitError!void,
) CallbackAction {
    return .rearm;
}

/// Returns true if there are registered fds.
export fn run_xev_has_waiters() bool {
    return registered_count > 0;
}
