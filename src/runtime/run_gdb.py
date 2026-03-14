"""
GDB Python extension for Run green thread stack walking.

Provides custom GDB commands for inspecting the Run language runtime's
green thread (G/M/P) scheduler model. This enables deep debugging of
concurrent Run programs by exposing green thread state and stack frames.

Usage:
    (gdb) source src/runtime/run_gdb.py
    (gdb) info run-goroutines
    (gdb) run-goroutine 3

Auto-loading: Add to your .gdbinit or project .gdb-init file.
"""

import gdb


# --- Status enum mapping (mirrors run_g_status_t in run_scheduler.h) ---

G_STATUS_NAMES = {
    0: "idle",
    1: "runnable",
    2: "running",
    3: "waiting",
    4: "dead",
}


def g_status_name(status_val):
    """Convert numeric G status to human-readable name."""
    return G_STATUS_NAMES.get(int(status_val), f"unknown({status_val})")


# --- Helper: read a run_g_t struct from a pointer ---

def read_g_struct(g_ptr):
    """Read fields from a run_g_t pointer."""
    try:
        g = g_ptr.dereference()
        return {
            "id": int(g["id"]),
            "status": int(g["status"]),
            "status_name": g_status_name(g["status"]),
            "stack_base": g["stack_base"],
            "stack_size": int(g["stack_size"]),
            "entry_fn": g["entry_fn"],
            "context": g["context"],
            "sched_next": g["sched_next"],
            "preempt": bool(g["preempt"]),
            "in_syscall": bool(g["in_syscall"]),
        }
    except gdb.error as e:
        return {"error": str(e)}


def read_context_registers(ctx):
    """Extract saved register values from a run_context_t struct."""
    try:
        return {
            "rsp": ctx["rsp"],
            "rip": ctx["rip"],
            "rbx": ctx["rbx"],
            "rbp": ctx["rbp"],
            "r12": ctx["r12"],
            "r13": ctx["r13"],
            "r14": ctx["r14"],
            "r15": ctx["r15"],
        }
    except gdb.error:
        return None


# --- Walk all Gs by traversing scheduler data structures ---

def walk_all_gs():
    """
    Walk all green threads by calling the runtime's debug helper.
    Uses run_debug_dump_goroutines() which outputs JSON.
    Falls back to manual traversal if the function isn't available.
    """
    gs = []

    try:
        # Try using the runtime debug dump (simpler, always in sync)
        buf_size = 8192
        result = gdb.parse_and_eval(
            f'(void)run_debug_dump_goroutines((char*)malloc({buf_size}), {buf_size})'
        )
        # The function writes to a buffer; we need to read it
        # Fall through to manual traversal for now
    except gdb.error:
        pass

    # Manual traversal: walk the global P array and their local queues
    try:
        # Read GOMAXPROCS equivalent — check each P's local queue
        for p_idx in range(256):  # RUN_MAX_P_COUNT
            try:
                p_ptr = gdb.parse_and_eval(f'(run_p_t*)&run_all_ps[{p_idx}]')
                p = p_ptr.dereference()
                p_status = int(p["status"])
                if p_status == 0 and p_idx > 0:
                    # P_IDLE and not the first P — likely uninitialized
                    break

                # Walk local queue
                g_ptr = p["local_queue"]["head"]
                while g_ptr != 0:
                    g_info = read_g_struct(g_ptr)
                    if "error" not in g_info:
                        gs.append(g_info)
                    g_next = g_ptr.dereference()["sched_next"]
                    g_ptr = g_next
            except gdb.error:
                break

        # Also check M's current_g
        try:
            m_ptr = gdb.parse_and_eval('run_current_m()')
            if m_ptr != 0:
                current_g = m_ptr.dereference()["current_g"]
                if current_g != 0:
                    g_info = read_g_struct(current_g)
                    if "error" not in g_info:
                        # Avoid duplicates
                        if not any(g["id"] == g_info["id"] for g in gs):
                            gs.append(g_info)
        except gdb.error:
            pass

    except gdb.error:
        pass

    return gs


# --- GDB Commands ---

class InfoRunGoroutines(gdb.Command):
    """List all Run green threads with their status.

    Usage: info run-goroutines

    Shows: ID, status, entry function, stack info for each green thread.
    """

    def __init__(self):
        super().__init__("info run-goroutines", gdb.COMMAND_STATUS)

    def invoke(self, arg, from_tty):
        gs = walk_all_gs()

        if not gs:
            print("No green threads found (runtime may not be initialized yet).")
            print("Tip: Set a breakpoint after run_scheduler_init() to inspect threads.")
            return

        # Header
        print(f"{'ID':>4}  {'Status':<10}  {'Preempt':<8}  {'Syscall':<8}  Entry Function")
        print("-" * 60)

        for g in sorted(gs, key=lambda x: x.get("id", 0)):
            gid = g.get("id", "?")
            status = g.get("status_name", "?")
            preempt = "yes" if g.get("preempt", False) else "no"
            in_syscall = "yes" if g.get("in_syscall", False) else "no"
            entry_fn = g.get("entry_fn", "?")
            print(f"{gid:>4}  {status:<10}  {preempt:<8}  {in_syscall:<8}  {entry_fn}")

        print(f"\nTotal: {len(gs)} green thread(s)")


class RunGoroutine(gdb.Command):
    """Switch GDB context to a specific green thread's saved registers.

    Usage: run-goroutine <id>

    Reads the green thread's saved CPU context (run_context_t) and
    sets GDB's register state to allow stack walking of non-running threads.
    """

    def __init__(self):
        super().__init__("run-goroutine", gdb.COMMAND_STACK)

    def invoke(self, arg, from_tty):
        if not arg.strip():
            print("Usage: run-goroutine <green-thread-id>")
            return

        try:
            target_id = int(arg.strip())
        except ValueError:
            print(f"Invalid green thread ID: {arg}")
            return

        gs = walk_all_gs()
        target = None
        for g in gs:
            if g.get("id") == target_id:
                target = g
                break

        if target is None:
            print(f"Green thread {target_id} not found.")
            return

        status = target.get("status_name", "unknown")
        if status == "running":
            print(f"Green thread {target_id} is currently running.")
            print("Its state is in the CPU registers — use regular GDB commands.")
            return

        # Read saved context registers
        ctx = target.get("context")
        if ctx is None:
            print(f"Cannot read context for green thread {target_id}.")
            return

        regs = read_context_registers(ctx)
        if regs is None:
            print(f"Failed to read saved registers for green thread {target_id}.")
            return

        print(f"Switching to green thread {target_id} (status: {status})")
        print(f"Saved registers:")

        for reg_name, reg_val in regs.items():
            print(f"  {reg_name} = {reg_val}")

        # Set GDB's view of registers to the saved context
        # This allows 'bt' to show the green thread's stack
        try:
            for reg_name, reg_val in regs.items():
                gdb.execute(f"set ${reg_name} = {reg_val}", to_string=True)
            print(f"\nContext switched. Use 'bt' to view the stack trace.")
            print(f"Use 'run-goroutine-restore' to restore the original context.")
        except gdb.error as e:
            print(f"Failed to set registers: {e}")


class RunGoroutineRestore(gdb.Command):
    """Restore GDB context after run-goroutine switch.

    Usage: run-goroutine-restore

    Returns GDB to the actual executing context.
    """

    def __init__(self):
        super().__init__("run-goroutine-restore", gdb.COMMAND_STACK)

    def invoke(self, arg, from_tty):
        try:
            # Step 0 bytes to refresh GDB's register state from the inferior
            gdb.execute("flushregs", to_string=True)
            print("Register context restored to current executing thread.")
        except gdb.error as e:
            print(f"Failed to restore registers: {e}")


# --- Register commands ---

InfoRunGoroutines()
RunGoroutine()
RunGoroutineRestore()

print("Run debugger extensions loaded.")
print("  info run-goroutines  — list all green threads")
print("  run-goroutine <id>   — switch to green thread's saved context")
print("  run-goroutine-restore — restore original context")
