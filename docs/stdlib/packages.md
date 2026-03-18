# Standard Library Packages

This document defines the complete set of standard library packages for Run, their purpose, key types/functions, dependencies, and implementation priority.

## Design Principles

- **Batteries-included** — Ship everything needed to build servers, CLI tools, and systems software
- **Return errors, don't panic** — Use `!T` for fallible operations, sum types for error categories
- **Small interfaces** — Many small interfaces (`Reader`, `Writer`, `Closer`) over few large ones
- **Explicit cleanup** — `defer` for resource cleanup, no implicit finalization
- **No generics** — Built-in collections (`[]T`, `map[K]V`, `chan[T]`) are the polymorphic containers
- **Go-familiar** — A Go developer should feel at home, but leverage Run's error unions, sum types, and generational references where they improve the API
- **Minimal surface** — Start with the 80% use case per package, extend later

## Priority Tiers

| Tier | Meaning | Milestone |
|------|---------|-----------|
| **P0** | Core — everything depends on these | M4 |
| **P1** | Essential utilities — needed by most programs | M4 |
| **P2** | Important ecosystem — needed for real applications | M4 |
| **P3** | Advanced/specialized — systems programming power | M7–M9 |

---

## P0 — Core Packages

### `fmt` — Formatting and Printing

**Purpose:** String formatting, printing to stdout/stderr, and the `Stringer` interface.

**Key types and functions:**
```
Stringer          interface    — types that can format themselves as strings
println(args)                 — print with spaces and newline to stdout
print(args)                   — print without separator or newline
printf(format, args)          — formatted print with verbs (%d, %s, %v, %f, %x, %o, %b)
eprintln(args)                — print to stderr
sprintf(format, args) string  — format to string
sprint(args) string           — concatenate to string
sprintln(args) string         — concatenate with spaces and newline
```

**Dependencies:** `io` (for Writer interface)
**Status:** Stub exists

---

### `io` — I/O Interfaces and Utilities

**Purpose:** Core I/O interfaces that all I/O types implement. Buffered wrappers. Utility functions for copying, limiting, and composing streams.

**Key types and functions:**
```
Reader            interface    — read(buf []byte) !int
Writer            interface    — write(data []byte) !int
Closer            interface    — close() !void
Seeker            interface    — seek(offset int, whence SeekWhence) !int
ReadWriter        interface    — Reader + Writer
ReadCloser        interface    — Reader + Closer
WriteCloser       interface    — Writer + Closer
ReadWriteCloser   interface    — Reader + Writer + Closer
ReadSeeker        interface    — Reader + Seeker

SeekWhence        sum type     — .start | .current | .end
IoError           sum type     — .unexpectedEof | .brokenPipe | .timeout | .closed

BufferedReader    struct       — wraps Reader with internal buffer
BufferedWriter    struct       — wraps Writer with internal buffer

read_all(Reader) ![]byte                  — read everything until EOF
copy(Writer, Reader) !int                 — stream copy
copy_n(Writer, Reader, int) !int          — copy exactly n bytes
limit_reader(Reader, int) Reader          — reader that stops after n bytes
discard                       Writer      — writer that discards all data
```

**Dependencies:** None (leaf package)
**Status:** Stub exists

---

### `os` — Operating System Interface

**Purpose:** File system operations, environment variables, process control, and path manipulation. Path utilities live here (not a separate package).

**Key types and functions:**
```
File              struct       — open file handle (implements io.Reader, io.Writer, io.Closer, io.Seeker)
FileInfo          struct       — file metadata (name, size, is_dir, mode, mod_time)
DirEntry          struct       — directory entry (name, is_dir, type)
FileMode          sum type     — .regular | .directory | .symlink | .socket | .pipe | .device
FileError         sum type     — .notFound | .permissionDenied | .alreadyExists | .isDirectory | .notDirectory | .diskFull | .tooManyOpen

open(path) !File              — open for reading
create(path) !File            — create/truncate for writing
open_file(path, flags, mode) !File — open with full control
stat(path) !FileInfo          — file metadata
lstat(path) !FileInfo         — metadata without following symlinks
read_file(path) ![]byte       — read entire file
write_file(path, data) !void  — write entire file
read_dir(path) ![]DirEntry    — list directory contents
mkdir(path) !void             — create directory
mkdir_all(path) !void         — create directory tree
remove(path) !void            — remove file or empty directory
remove_all(path) !void        — remove tree
rename(old, new) !void        — rename/move
symlink(target, link) !void   — create symlink
read_link(path) !string       — read symlink target
chmod(path, mode) !void       — change permissions
chown(path, uid, gid) !void   — change ownership
temp_dir() string             — OS temp directory
temp_file(prefix) !File       — create temp file

// Path utilities (no separate path package)
join_path(parts []string) string   — join path components
base(path) string                  — last element of path
dir(path) string                   — all but last element
ext(path) string                   — file extension
clean(path) string                 — clean/normalize path
abs(path) !string                  — absolute path
is_abs(path) bool                  — is path absolute
split_path(path) (string, string)  — split into dir and file
glob(pattern) ![]string            — match file pattern

// Process and environment
args() []string               — command-line arguments
getenv(key) string?            — get environment variable
setenv(key, value) !void       — set environment variable
unsetenv(key) !void            — remove environment variable
environ() []string             — all environment variables as KEY=VALUE
exit(code)                     — terminate process
getpid() int                   — current process ID
hostname() !string             — machine hostname
cwd() !string                  — current working directory
chdir(path) !void              — change working directory
user_home_dir() !string        — user home directory

// stdin, stdout, stderr as package-level File values
```

**Dependencies:** `io`
**Status:** Stub exists

---

## P1 — Essential Utility Packages

### `strings` — String Manipulation

**Purpose:** Functions for searching, splitting, joining, trimming, and transforming strings.

**Key types and functions:**
```
Builder           struct       — efficient string concatenation

contains(s, substr) bool
has_prefix(s, prefix) bool
has_suffix(s, suffix) bool
index_of(s, substr) int?
last_index_of(s, substr) int?
count(s, substr) int
split(s, sep) []string
split_n(s, sep, n) []string
fields(s) []string             — split on whitespace
join(parts, sep) string
replace(s, old, new) string
replace_n(s, old, new, n) string
trim(s) string
trim_left(s) string
trim_right(s) string
trim_prefix(s, prefix) string
trim_suffix(s, suffix) string
trim_chars(s, cutset) string
to_upper(s) string
to_lower(s) string
to_title(s) string
repeat(s, count) string
equal_fold(a, b) bool          — case-insensitive comparison
```

**Dependencies:** None
**Status:** Stub exists

---

### `bytes` — Byte Slice Utilities

**Purpose:** Functions that operate on `[]byte`, mirroring `strings` where applicable. Includes a `Buffer` type for growable byte buffers.

**Key types and functions:**
```
Buffer            struct       — growable byte buffer (implements io.Reader, io.Writer)
  write_string(s string) !int
  write_byte(b byte) !void
  bytes() []byte
  string() string
  reset()
  len() int
  cap() int

contains(b, sub []byte) bool
index(b, sub []byte) int?
split(b, sep []byte) [][]byte
join(parts [][]byte, sep []byte) []byte
trim(b []byte) []byte
equal(a, b []byte) bool
has_prefix(b, prefix []byte) bool
has_suffix(b, suffix []byte) bool
repeat(b []byte, count int) []byte
to_lower(b []byte) []byte
to_upper(b []byte) []byte
```

**Dependencies:** `io`

---

### `math` — Mathematical Functions

**Purpose:** Math constants, floating-point and integer arithmetic functions.

**Key types and functions:**
```
// Constants: pi, e, phi, sqrt2, ln2, ln10, max_f64, min_f64, max_int, min_int, inf, nan

abs(x f64) f64
abs_int(x int) int
min(a, b f64) f64
max(a, b f64) f64
min_int(a, b int) int
max_int(a, b int) int
floor(x f64) f64
ceil(x f64) f64
round(x f64) f64
trunc(x f64) f64
sqrt(x f64) f64
cbrt(x f64) f64
pow(base, exp f64) f64
log(x f64) f64
log2(x f64) f64
log10(x f64) f64
exp(x f64) f64
exp2(x f64) f64
sin(x f64) f64
cos(x f64) f64
tan(x f64) f64
asin(x f64) f64
acos(x f64) f64
atan(x f64) f64
atan2(y, x f64) f64
sinh(x f64) f64
cosh(x f64) f64
tanh(x f64) f64
hypot(x, y f64) f64
fma(x, y, z f64) f64          — fused multiply-add
mod(x, y f64) f64
remainder(x, y f64) f64
is_nan(x f64) bool
is_inf(x f64) bool
is_finite(x f64) bool
clamp(x, lo, hi f64) f64
clamp_int(x, lo, hi int) int
copysign(x, y f64) f64
```

**Dependencies:** None
**Status:** Stub exists

---

### `math/rand` — Pseudo-Random Number Generation

**Purpose:** Fast, non-cryptographic PRNG for simulations, testing, and general use.

**Key types and functions:**
```
Rand              struct       — PRNG state (xoshiro256**)

new(seed int) Rand             — create seeded PRNG
int() int                      — random int
int_n(n int) int               — random int in [0, n)
f64() f64                      — random float in [0.0, 1.0)
bool() bool                    — random boolean
shuffle(s []any)               — in-place shuffle
choice(s []any) any            — random element
```

**Dependencies:** `math`

---

### `testing` — Test Framework

**Purpose:** Test context, assertions, benchmarking support.

**Key types and functions:**
```
T                 struct       — test context
  log(msg)
  logf(format, args)
  fail()
  fail_now()
  error(msg)
  errorf(format, args)
  fatal(msg)
  fatalf(format, args)
  skip(msg)

B                 struct       — benchmark context
  reset_timer()
  start_timer()
  stop_timer()
  report_metric(name, value, unit)
  n int                        — iteration count

TestResult        struct       — test run summary
  passed int
  failed int
  skipped int
  total() int
  ok() bool

// Assertion functions
expect(condition, msg)
expect_eq(expected, actual)
expect_ne(a, b)
expect_true(condition)
expect_false(condition)
expect_error(result)
expect_no_error(result)
expect_nil(value)
```

**Dependencies:** `fmt`, `strings`
**Status:** Stub exists

---

### `time` — Time, Duration, and Timers

**Purpose:** Wall clock time, monotonic time, durations, formatting/parsing, timers, and tickers for periodic events.

**Key types and functions:**
```
Time              struct       — point in time (wall + monotonic)
Duration          struct       — time interval in nanoseconds
Month             sum type     — .january | .february | ... | .december
Weekday           sum type     — .sunday | .monday | ... | .saturday
Location          struct       — timezone

// Duration constants
nanosecond, microsecond, millisecond, second, minute, hour Duration

now() Time                     — current time
since(t Time) Duration         — time elapsed since t
until(t Time) Duration         — time remaining until t
sleep(d Duration)              — pause current green thread

// Time methods
(t @Time) add(d Duration) Time
(t @Time) sub(other Time) Duration
(t @Time) before(other Time) bool
(t @Time) after(other Time) bool
(t @Time) equal(other Time) bool
(t @Time) unix() int           — seconds since epoch
(t @Time) unix_milli() int     — milliseconds since epoch
(t @Time) unix_nano() int      — nanoseconds since epoch
(t @Time) year() int
(t @Time) month() Month
(t @Time) day() int
(t @Time) hour() int
(t @Time) minute() int
(t @Time) second() int
(t @Time) weekday() Weekday
(t @Time) format(layout string) string
parse(layout, value string) !Time

// Timers and Tickers
Timer             struct       — one-shot timer with channel
Ticker            struct       — repeating ticker with channel
new_timer(d Duration) Timer
new_ticker(d Duration) Ticker
(t &Timer) stop()
(t &Timer) reset(d Duration)
(tk &Ticker) stop()
```

**Dependencies:** None (uses compiler builtins for clock)

---

### `log` — Structured Logging

**Purpose:** Leveled, structured logging with configurable output.

**Key types and functions:**
```
Level             sum type     — .debug | .info | .warn | .error
Logger            struct       — configurable logger
Handler           interface    — custom log output backend

new(handler Handler) Logger
default() Logger               — package-level default logger

// Package-level functions (use default logger)
debug(msg, fields...)
info(msg, fields...)
warn(msg, fields...)
error(msg, fields...)

// Logger methods
(l &Logger) debug(msg, fields...)
(l &Logger) info(msg, fields...)
(l &Logger) warn(msg, fields...)
(l &Logger) error(msg, fields...)
(l &Logger) with(fields...) Logger   — create child logger with preset fields
(l &Logger) set_level(level Level)

// Built-in handlers
TextHandler       struct       — human-readable text output
JsonHandler       struct       — structured JSON output
```

**Dependencies:** `io`, `time`, `fmt`

---

## P2 — Application Packages

### `net` — Networking

**Purpose:** TCP/UDP sockets, DNS resolution, IP address types. Foundation for all network protocols.

**Key types and functions:**
```
Addr              interface    — network address
TcpAddr           struct       — TCP address (ip + port)
UdpAddr           struct       — UDP address (ip + port)
Ip                struct       — IP address (v4 or v6)
Listener          struct       — TCP listener (implements io.Closer)
Conn              struct       — network connection (implements io.Reader, io.Writer, io.Closer)
UdpConn           struct       — UDP connection

NetError          sum type     — .connectionRefused | .connectionReset | .timeout
                                | .addressInUse | .hostUnreachable | .networkUnreachable
                                | .dnsNotFound

listen(network, address string) !Listener   — start TCP listener
(l &Listener) accept() !Conn               — accept connection
dial(network, address string) !Conn         — connect to address
dial_timeout(network, address string, timeout Duration) !Conn
resolve_ip(host string) ![]Ip               — DNS lookup

(c &Conn) read(buf []byte) !int
(c &Conn) write(data []byte) !int
(c &Conn) close() !void
(c &Conn) set_deadline(t Time) !void
(c &Conn) set_read_deadline(t Time) !void
(c &Conn) set_write_deadline(t Time) !void
(c @Conn) local_addr() Addr
(c @Conn) remote_addr() Addr
```

**Dependencies:** `io`, `time`, `os`

---

### `net/http` — HTTP Client and Server

**Purpose:** HTTP/1.1 client and server with high-performance routing, middleware, and streaming support. The built-in router uses a **radix tree (Patricia trie)** for O(k) route matching (where k is path length), similar to chi/httprouter. No need for third-party routers.

**Key types and functions:**
```
// Server
Server            struct       — HTTP server
Handler           interface    — fun serve_http(w &ResponseWriter, r @Request)
Middleware        type         — fun(next Handler) Handler
ResponseWriter    struct       — write HTTP responses (implements io.Writer)

listen_and_serve(addr string, handler Handler) !void
listen_and_serve_tls(addr, cert_file, key_file string, handler Handler) !void

// Router — Patricia trie based, chi-style
Router            struct       — radix tree request router
new_router() Router

// Route registration — supports path parameters and wildcards
(r &Router) get(pattern string, handler Handler)
(r &Router) post(pattern string, handler Handler)
(r &Router) put(pattern string, handler Handler)
(r &Router) delete(pattern string, handler Handler)
(r &Router) patch(pattern string, handler Handler)
(r &Router) head(pattern string, handler Handler)
(r &Router) options(pattern string, handler Handler)
(r &Router) handle(pattern string, handler Handler)           — any method
(r &Router) handle_func(pattern string, fun(&ResponseWriter, @Request))
(r &Router) method(method, pattern string, handler Handler)   — custom method

// Route groups and middleware (chi-style)
(r &Router) group(fn fun(sub &Router))              — inline group
(r &Router) route(prefix string, sub Handler)       — mount sub-router at prefix
(r &Router) use(middlewares ...Middleware)            — apply middleware to group
(r &Router) with(middlewares ...Middleware) Router    — return new router with middleware

// Path parameters — extracted from {name} segments
//   Pattern: "/users/{id}/posts/{post_id}"
//   Pattern: "/files/{path...}"  (wildcard catch-all)
url_param(r @Request, name string) string

// Request/Response
Request           struct       — HTTP request
  method string
  url    Url
  header Header
  body   io.ReadCloser
Response          struct       — HTTP response
  status      int
  status_text string
  header      Header
  body        io.ReadCloser
Header            struct       — HTTP headers (wraps map[string][]string)
Url               struct       — parsed URL
Cookie            struct       — HTTP cookie

// ResponseWriter helpers
(w &ResponseWriter) write_header(status_code int)
(w &ResponseWriter) set_header(key, value string)
(w &ResponseWriter) write_json(status int, value any) !void
(w &ResponseWriter) redirect(url string, code int)

// Client
Client            struct       — HTTP client with timeouts and redirects
get(url string) !Response
post(url, content_type string, body io.Reader) !Response
head(url string) !Response
(c &Client) do(req @Request) !Response

// Built-in middleware
log_middleware() Middleware            — request logging
recover_middleware() Middleware        — panic recovery
timeout_middleware(d Duration) Middleware
cors_middleware(opts CorsOptions) Middleware
metrics_middleware(opts MetricsOptions) Middleware  — Prometheus metrics per route

// MetricsOptions for metrics middleware
type MetricsOptions struct {
    set               &metrics.Set?   — custom Set, nil = default set
    request_counter   string          — counter name (default: "http_requests_total")
    duration_histogram string         — histogram name (default: "http_request_duration_seconds")
    in_flight_gauge   string          — gauge name (default: "http_requests_in_flight")
    response_size     string          — counter name (default: "http_response_bytes_total")
}
// Labels added automatically: method, path, status

// Status codes as constants
status_ok, status_created, status_not_found, status_internal_server_error, ...
```

**Router design notes:**
- Patricia trie stores compressed path segments for memory efficiency
- Route conflicts are detected at registration time, not at request time
- `{param}` matches a single path segment, `{param...}` matches the rest of the path
- Method-specific trees — each HTTP method has its own trie for zero-allocation matching
- Middleware stacks are chi-style: `Use()` for group-level, `With()` for inline

**Example:**
```run
package main

use "net/http"

pub fun main() {
    r := http.new_router()

    // Middleware
    r.use(http.log_middleware())
    r.use(http.recover_middleware())

    // Routes
    r.get("/", index_handler)
    r.route("/api", fun(api &http.Router) {
        api.use(auth_middleware())
        api.get("/users/{id}", get_user)
        api.post("/users", create_user)
        api.get("/files/{path...}", serve_file)
    })

    http.listen_and_serve(":8080", r)
}

fun get_user(w &http.ResponseWriter, r @http.Request) {
    id := http.url_param(r, "id")
    // ...
}
```

**Dependencies:** `net`, `io`, `fmt`, `strings`, `time`, `context`, `metrics`

---

### `net/http2` — HTTP/2 Protocol

**Purpose:** HTTP/2 framing, multiplexed streams, flow control, and HPACK header compression. Used directly by `net/http` for h2 connections and as the transport layer for gRPC.

**Key types and functions:**
```
Transport         struct       — HTTP/2 client transport (implements http round-tripper)
Server            struct       — HTTP/2 server (used automatically by net/http when TLS is configured)

Frame             sum type     — .data | .headers | .priority | .rst_stream | .settings
                                | .push_promise | .ping | .goaway | .window_update | .continuation
Stream            struct       — single HTTP/2 stream within a connection

// Most users don't interact with net/http2 directly.
// net/http uses it automatically for HTTP/2 connections.
// grpc uses it as its transport layer.

configure_server(srv &http.Server) !void   — enable HTTP/2 on existing HTTP server
configure_transport(t &http.Transport) !void
```

**Dependencies:** `net`, `net/http`, `io`, `sync`, `crypto/tls`

---

### `net/grpc` — gRPC Client and Server

**Purpose:** Full gRPC support — unary RPCs, server streaming, client streaming, and bidirectional streaming. Integrates with Run's green threads for natural concurrency and channels for streaming patterns.

**Key types and functions:**
```
// Server
Server            struct       — gRPC server
ServiceDesc       struct       — service descriptor (generated from .proto)
MethodDesc        struct       — method descriptor
StreamDesc        struct       — streaming method descriptor

new_server(opts ...ServerOption) Server
(s &Server) register_service(desc @ServiceDesc, impl any)
(s &Server) serve(listener net.Listener) !void
(s &Server) graceful_stop()
(s &Server) stop()

ServerOption      sum type     — .max_recv_msg_size(int) | .max_send_msg_size(int)
                                | .max_concurrent_streams(int)
                                | .keepalive(KeepaliveParams)
                                | .creds(Credentials)
                                | .interceptor(UnaryServerInterceptor)
                                | .stream_interceptor(StreamServerInterceptor)

// Client
ClientConn        struct       — gRPC client connection
dial(target string, opts ...DialOption) !ClientConn
(cc &ClientConn) close() !void

DialOption        sum type     — .insecure | .block | .timeout(Duration)
                                | .creds(Credentials)
                                | .keepalive(KeepaliveParams)
                                | .interceptor(UnaryClientInterceptor)
                                | .stream_interceptor(StreamClientInterceptor)
                                | .default_service_config(string)

// RPC invocation (used by generated code)
invoke(cc &ClientConn, method string, req any, reply &any, opts ...CallOption) !void
new_stream(cc &ClientConn, desc @StreamDesc, method string, opts ...CallOption) !ClientStream

// Streaming interfaces
type ServerStream interface {
    send(msg any) !void
    recv(msg &any) !void
    send_header(Metadata) !void
    set_trailer(Metadata)
}
type ClientStream interface {
    send(msg any) !void
    recv(msg &any) !void
    close_send() !void
    header() !Metadata
    trailer() Metadata
}

// Status and errors
Status            struct       — gRPC status (code + message + details)
Code              sum type     — .ok | .cancelled | .unknown | .invalid_argument
                                | .deadline_exceeded | .not_found | .already_exists
                                | .permission_denied | .resource_exhausted
                                | .failed_precondition | .aborted | .out_of_range
                                | .unimplemented | .internal | .unavailable
                                | .data_loss | .unauthenticated

new_status(code Code, msg string) Status
(s @Status) err() error
(s @Status) code() Code
(s @Status) message() string
from_error(err error) Status

// Metadata (request/response headers)
Metadata          struct       — key-value pairs attached to RPCs
new_metadata(pairs ...string) Metadata
(md &Metadata) get(key string) []string
(md &Metadata) set(key string, values ...string)
(md &Metadata) append(key string, values ...string)

// Interceptors
UnaryServerInterceptor    type — fun(ctx Context, req any, info @UnaryServerInfo, handler UnaryHandler) !any
StreamServerInterceptor   type — fun(srv any, stream ServerStream, info @StreamServerInfo, handler StreamHandler) !void
UnaryClientInterceptor    type — fun(ctx Context, method string, req any, reply &any, cc &ClientConn, invoker UnaryInvoker, opts ...CallOption) !void
StreamClientInterceptor   type — fun(ctx Context, desc @StreamDesc, cc &ClientConn, method string, streamer Streamer, opts ...CallOption) !ClientStream

// Credentials
type Credentials interface {
    require_transport_security() bool
}
insecure_credentials() Credentials
tls_credentials(config @tls.Config) Credentials

// Keepalive
type KeepaliveParams struct {
    time              Duration   — ping interval when idle
    timeout           Duration   — wait for ping ack
    permit_without_stream bool   — ping even with no active RPCs
}

// Health checking
HealthServer      struct       — standard gRPC health check service (grpc.health.v1)
(hs &HealthServer) set_status(service string, status ServingStatus)
ServingStatus     sum type     — .unknown | .serving | .not_serving
```

**Design notes:**
- gRPC streaming maps naturally to Run's channels — a bidirectional stream can be bridged to `chan[Request]` / `chan[Response]` pairs
- Green threads mean each RPC handler runs concurrently without callback complexity
- `context.Context` carries deadlines and cancellation across RPC boundaries
- Interceptors provide middleware for auth, logging, metrics, and tracing
- Protocol Buffers serialization is handled by `encoding/proto`; service stubs are generated by a `protoc-gen-run` tool

**Dependencies:** `net`, `net/http2`, `encoding/proto`, `context`, `time`, `sync`, `crypto/tls`

---

### `encoding/proto` — Protocol Buffers

**Purpose:** Protocol Buffers binary serialization (proto3). Encode and decode protobuf messages. Foundation for gRPC wire format.

**Key types and functions:**
```
Message           interface    — types that can be serialized as protobuf
  proto_marshal() ![]byte
  proto_unmarshal(data []byte) !void

marshal(msg Message) ![]byte           — encode message to wire format
unmarshal(data []byte, msg &Message) !void  — decode wire format into message
size(msg @Message) int                 — encoded size in bytes

// Wire types (used by generated code and reflection)
WireType          sum type     — .varint | .fixed64 | .length_delimited | .fixed32

// Field descriptors (for reflection / dynamic messages)
type FieldDescriptor struct {
    number    int
    name      string
    wire_type WireType
    repeated  bool
}

// Encoding helpers (used by generated code)
encode_varint(buf &bytes.Buffer, v int) !void
encode_bytes(buf &bytes.Buffer, data []byte) !void
encode_fixed32(buf &bytes.Buffer, v u32) !void
encode_fixed64(buf &bytes.Buffer, v u64) !void
decode_varint(data []byte, offset int) !(int, int)
decode_bytes(data []byte, offset int) !([]byte, int)
```

**Design notes:**
- Run structs with field tags (e.g., `@proto(1)`) map to protobuf fields
- `protoc-gen-run` generates Run struct definitions + marshal/unmarshal from `.proto` files
- No reflection-based encoding — generated code is fast and type-safe

**Dependencies:** `bytes`, `io`

---

### `encoding/json` — JSON Encoding/Decoding

**Purpose:** Encode Run values to JSON and decode JSON into Run values. Struct field tags control serialization.

**Key types and functions:**
```
Value             sum type     — .null | .bool(bool) | .int(int) | .float(f64)
                                | .string(string) | .array([]Value) | .object(map[string]Value)
JsonError         sum type     — .syntaxError | .unexpectedToken | .overflow | .missingField

marshal(value any) ![]byte                — encode to JSON bytes
marshal_indent(value any, indent string) ![]byte
unmarshal(data []byte, target &any) !void — decode into target
marshal_string(value any) !string         — encode to JSON string

// Streaming
Encoder           struct       — streaming JSON encoder (wraps io.Writer)
Decoder           struct       — streaming JSON decoder (wraps io.Reader)
new_encoder(w io.Writer) Encoder
new_decoder(r io.Reader) Decoder
(e &Encoder) encode(value any) !void
(d &Decoder) decode(target &any) !void

// Value manipulation
parse(data []byte) !Value      — parse to dynamic Value tree
(v @Value) get(key string) Value?
(v @Value) index(i int) Value?
(v @Value) as_string() string?
(v @Value) as_int() int?
(v @Value) as_float() f64?
(v @Value) as_bool() bool?
```

**Dependencies:** `io`, `strings`, `bytes`, `fmt`

---

### `encoding/csv` — CSV Encoding/Decoding

**Purpose:** Read and write CSV files with configurable delimiters.

**Key types and functions:**
```
Reader            struct       — CSV reader (wraps io.Reader)
Writer            struct       — CSV writer (wraps io.Writer)

new_reader(r io.Reader) Reader
new_writer(w io.Writer) Writer

(r &Reader) read() ![]string           — read one record
(r &Reader) read_all() ![][]string     — read all records
(w &Writer) write(record []string) !void
(w &Writer) write_all(records [][]string) !void
(w &Writer) flush() !void
```

**Dependencies:** `io`, `strings`, `bytes`

---

### `encoding/base64` — Base64 Encoding

**Purpose:** Standard and URL-safe base64 encoding/decoding.

**Key types and functions:**
```
Encoding          struct       — encoding configuration

std_encoding      Encoding     — standard base64 (RFC 4648)
url_encoding      Encoding     — URL-safe base64
raw_std_encoding  Encoding     — no padding
raw_url_encoding  Encoding     — URL-safe, no padding

encode(src []byte) string
decode(s string) ![]byte
(enc @Encoding) encode(src []byte) string
(enc @Encoding) decode(s string) ![]byte
encoded_len(n int) int
decoded_len(n int) int
```

**Dependencies:** None

---

### `encoding/hex` — Hexadecimal Encoding

**Purpose:** Hex encoding/decoding and hex dump utilities.

**Key types and functions:**
```
encode(src []byte) string
decode(s string) ![]byte
dump(data []byte) string       — hex dump with offsets and ASCII
```

**Dependencies:** `bytes`

---

### `crypto` — Cryptographic Primitives

**Purpose:** Cryptographically secure random numbers and the `Hash` interface.

**Key types and functions:**
```
Hash              interface    — write([]byte) !int, sum() []byte, reset(), size() int, block_size() int
rand_bytes(n int) ![]byte     — cryptographically secure random bytes
rand_int() !int               — cryptographically secure random int
```

**Dependencies:** `io`

---

### `crypto/sha256` — SHA-256

**Purpose:** SHA-256 hash function.

**Key types and functions:**
```
Digest            struct       — implements crypto.Hash
new() Digest
sum(data []byte) []byte        — one-shot hash
```

**Dependencies:** `crypto`

---

### `crypto/sha512` — SHA-512

**Purpose:** SHA-512 hash function.

**Key types and functions:**
```
Digest            struct       — implements crypto.Hash
new() Digest
sum(data []byte) []byte
```

**Dependencies:** `crypto`

---

### `crypto/hmac` — HMAC

**Purpose:** Keyed-hash message authentication codes.

**Key types and functions:**
```
new(hash_fn fun() crypto.Hash, key []byte) crypto.Hash
equal(a, b []byte) bool       — constant-time comparison
```

**Dependencies:** `crypto`

---

### `crypto/aes` — AES Encryption

**Purpose:** AES block cipher.

**Key types and functions:**
```
Cipher            struct       — AES cipher block
new(key []byte) !Cipher
(c @Cipher) encrypt(dst, src []byte)
(c @Cipher) decrypt(dst, src []byte)
block_size() int
```

**Dependencies:** `crypto`

---

### `crypto/tls` — TLS

**Purpose:** TLS client and server support for secure connections.

**Key types and functions:**
```
Config            struct       — TLS configuration
Conn              struct       — TLS connection (implements net.Conn, io.ReadWriteCloser)

dial(network, addr string, config @Config) !Conn
listen(network, addr string, config @Config) !net.Listener
```

**Dependencies:** `crypto`, `crypto/sha256`, `crypto/aes`, `net`, `io`

---

### `sync` — Synchronization Primitives

**Purpose:** Mutexes, read-write locks, wait groups, atomics, and once-initialization for shared-memory concurrency.

**Key types and functions:**
```
Mutex             struct       — mutual exclusion lock
  lock()
  unlock()
  try_lock() bool

RwMutex           struct       — read-write lock
  read_lock()
  read_unlock()
  write_lock()
  write_unlock()

WaitGroup         struct       — wait for goroutine completion
  add(delta int)
  done()
  wait()

Once              struct       — run initialization exactly once
  do(f fun())

Atomic            struct       — atomic integer operations
  load() int
  store(val int)
  add(delta int) int
  swap(new int) int
  compare_and_swap(old, new int) bool
```

**Dependencies:** None (uses compiler builtins for atomics)

---

### `unsafe` — Low-Level Operations

**Purpose:** Raw pointer manipulation, type layout introspection, and escape hatches from the safety model. Importing `unsafe` signals that a file does low-level operations.

**Key types and functions:**
```
Pointer           struct       — raw untyped pointer

ptr(ref &any) Pointer          — convert typed ref to raw pointer
cast(type, p Pointer) &type    — convert raw pointer to typed ref
sizeof(type) int               — size of type in bytes
alignof(type) int              — alignment of type in bytes
offsetof(type, field) int      — field offset in bytes
slice(ptr Pointer, len int) []byte  — create slice from raw pointer
```

**Dependencies:** None
**Status:** Design exists in `docs/unsafe.md`

---

### `sort` — Sorting

**Purpose:** Sorting slices of concrete types and custom sort via a comparator interface.

**Key types and functions:**
```
Less              interface    — fun less(i, j int) bool

ints(s []int)                  — sort int slice ascending
floats(s []f64)                — sort f64 slice ascending
strings_sort(s []string)       — sort string slice ascending
sort(s []any, cmp fun(a, b any) int)  — sort with comparator
is_sorted(s []any, cmp fun(a, b any) int) bool
reverse(s []any)               — reverse slice in place
search(s []any, target any, cmp fun(a, b any) int) int?  — binary search
```

**Dependencies:** None

---

### `strconv` — String Conversions

**Purpose:** Convert between strings and basic types (int, float, bool).

**Key types and functions:**
```
ParseError        sum type     — .invalidSyntax | .outOfRange

parse_int(s string, base int) !int
parse_float(s string) !f64
parse_bool(s string) !bool
format_int(i int, base int) string
format_float(f f64, fmt byte, prec int) string
format_bool(b bool) string
atoi(s string) !int            — shorthand for parse_int(s, 10)
itoa(i int) string             — shorthand for format_int(i, 10)
quote(s string) string         — add quotes and escape
unquote(s string) !string      — remove quotes and unescape
```

**Dependencies:** `strings`

---

### `regex` — Regular Expressions

**Purpose:** Regular expression matching and replacement.

**Key types and functions:**
```
Regex             struct       — compiled regular expression
Match             struct       — match result with captures

compile(pattern string) !Regex
must_compile(pattern string) Regex    — panics on invalid pattern

(re @Regex) is_match(s string) bool
(re @Regex) find(s string) Match?
(re @Regex) find_all(s string) []Match
(re @Regex) replace(s, replacement string) string
(re @Regex) replace_all(s, replacement string) string
(re @Regex) split(s string) []string

(m @Match) text() string
(m @Match) start() int
(m @Match) end() int
(m @Match) group(n int) string?
```

**Dependencies:** `strings`

---

### `hash` — Hash Function Interfaces

**Purpose:** Non-cryptographic hash functions (FNV, xxhash) for hash maps and checksums.

**Key types and functions:**
```
Hash32            interface    — sum32() u32
Hash64            interface    — sum64() u64

fnv32() Hash32
fnv64() Hash64
xxhash64() Hash64
```

**Dependencies:** None

---

### `compress/gzip` — Gzip Compression

**Purpose:** Gzip compression and decompression (RFC 1952).

**Key types and functions:**
```
Reader            struct       — decompression reader (implements io.Reader)
Writer            struct       — compression writer (implements io.WriteCloser)

new_reader(r io.Reader) !Reader
new_writer(w io.Writer) Writer
new_writer_level(w io.Writer, level int) Writer
```

**Dependencies:** `io`, `compress/flate`

---

### `compress/flate` — DEFLATE Compression

**Purpose:** Raw DEFLATE compression/decompression (RFC 1951). Foundation for gzip and zip.

**Key types and functions:**
```
Reader            struct       — implements io.Reader
Writer            struct       — implements io.WriteCloser

new_reader(r io.Reader) Reader
new_writer(w io.Writer) Writer
new_writer_level(w io.Writer, level int) Writer
```

**Dependencies:** `io`

---

### `compress/zlib` — Zlib Compression

**Purpose:** Zlib format compression/decompression (RFC 1950).

**Key types and functions:**
```
Reader            struct       — implements io.Reader
Writer            struct       — implements io.WriteCloser

new_reader(r io.Reader) !Reader
new_writer(w io.Writer) Writer
```

**Dependencies:** `io`, `compress/flate`

---

### `archive/tar` — Tar Archives

**Purpose:** Read and write tar archives.

**Key types and functions:**
```
Reader            struct       — tar archive reader
Writer            struct       — tar archive writer
Header            struct       — file header (name, size, mode, mod_time)

new_reader(r io.Reader) Reader
new_writer(w io.Writer) Writer
(r &Reader) next() !Header?
(r &Reader) read(buf []byte) !int
(w &Writer) write_header(hdr @Header) !void
(w &Writer) write(data []byte) !int
(w &Writer) close() !void
```

**Dependencies:** `io`, `os`, `time`

---

### `archive/zip` — Zip Archives

**Purpose:** Read and write zip archives.

**Key types and functions:**
```
Reader            struct       — zip archive reader
Writer            struct       — zip archive writer
File              struct       — file within archive

open_reader(path string) !Reader
(r @Reader) files() []File
(f &File) open() !io.ReadCloser
new_writer(w io.Writer) Writer
(w &Writer) create(name string) !io.Writer
(w &Writer) close() !void
```

**Dependencies:** `io`, `os`, `compress/flate`, `time`

---

### `bufio` — Buffered I/O Convenience

**Purpose:** Scanner for line-by-line or token-by-token reading. Higher-level than `io.BufferedReader`.

**Key types and functions:**
```
Scanner           struct       — read input by lines or tokens
SplitFunc         type         — custom tokenizer function

new_scanner(r io.Reader) Scanner
(s &Scanner) scan() bool
(s &Scanner) text() string
(s &Scanner) bytes() []byte
(s &Scanner) err() error?
(s &Scanner) split(f SplitFunc)

scan_lines        SplitFunc    — split by newline (default)
scan_words        SplitFunc    — split by whitespace
scan_bytes        SplitFunc    — split by byte
```

**Dependencies:** `io`, `bytes`

---

### `flag` — Command-Line Flag Parsing

**Purpose:** Parse command-line flags and arguments.

**Key types and functions:**
```
FlagSet           struct       — set of defined flags

new(name string) FlagSet
(fs &FlagSet) string_flag(name, default, usage string) &string
(fs &FlagSet) int_flag(name string, default int, usage string) &int
(fs &FlagSet) bool_flag(name string, default bool, usage string) &bool
(fs &FlagSet) float_flag(name string, default f64, usage string) &f64
(fs &FlagSet) parse(args []string) !void
(fs @FlagSet) args() []string          — non-flag arguments
(fs @FlagSet) usage()                  — print usage

// Package-level (default FlagSet)
string_flag(name, default, usage) &string
int_flag(name, default, usage) &int
bool_flag(name, default, usage) &bool
parse() !void
```

**Dependencies:** `os`, `fmt`, `strconv`

---

### `context` — Cancellation and Deadlines

**Purpose:** Carry deadlines, cancellation signals, and request-scoped values across API boundaries and between green threads.

**Key types and functions:**
```
Context           interface    — deadline() Time?, done() chan[void], err() error?, value(key string) any?

background() Context           — empty, never-cancelled root context
todo() Context                 — placeholder for undecided contexts
with_cancel(parent Context) (Context, CancelFunc)
with_timeout(parent Context, timeout Duration) (Context, CancelFunc)
with_deadline(parent Context, deadline Time) (Context, CancelFunc)
with_value(parent Context, key string, val any) Context

CancelFunc        type         — fun()
```

**Dependencies:** `time`

---

### `metrics` — Application Metrics (VictoriaMetrics-style)

**Purpose:** Lightweight, high-performance application metrics with Prometheus exposition format. Ported from [VictoriaMetrics/metrics](https://github.com/VictoriaMetrics/metrics) — the same zero-allocation, lock-free design philosophy. Counters, gauges, histograms, and summaries with automatic Prometheus-compatible output. No separate exposition library needed.

**Key types and functions:**
```
// ─── Set (metric registry) ───────────────────────────────────────

Set               struct       — collection of named metrics (concurrent-safe)

new_set() Set
default_set() &Set             — package-level default registry

(s &Set) write_prometheus(w io.Writer) !void      — write all metrics in Prometheus exposition format
(s &Set) unregister(name string) bool
(s &Set) unregister_all()
(s &Set) list_metric_names() []string
(s &Set) register_metrics_writer(f fun(w io.Writer))  — custom metrics callback

// Register a Set for inclusion in global write_prometheus output
register_set(s &Set)
unregister_set(s &Set)

// ─── Counter ─────────────────────────────────────────────────────

Counter           struct       — monotonically increasing integer counter (atomic)

// Create via Set or package-level (default set)
(s &Set) new_counter(name string) &Counter
(s &Set) get_or_create_counter(name string) &Counter
new_counter(name string) &Counter
get_or_create_counter(name string) &Counter

(c &Counter) inc()
(c &Counter) dec()
(c &Counter) add(n int)
(c &Counter) set(n int)
(c @Counter) get() int

// ─── FloatCounter ────────────────────────────────────────────────

FloatCounter      struct       — monotonically increasing float counter (atomic)

(s &Set) new_float_counter(name string) &FloatCounter
(s &Set) get_or_create_float_counter(name string) &FloatCounter
new_float_counter(name string) &FloatCounter
get_or_create_float_counter(name string) &FloatCounter

(c &FloatCounter) add(n f64)
(c @FloatCounter) get() f64

// ─── Gauge ───────────────────────────────────────────────────────

Gauge             struct       — float64 value that can go up and down (atomic)

// Optional callback: if provided, gauge value comes from calling f()
(s &Set) new_gauge(name string, f fun() f64) &Gauge
(s &Set) get_or_create_gauge(name string, f fun() f64) &Gauge
new_gauge(name string, f fun() f64) &Gauge
get_or_create_gauge(name string, f fun() f64) &Gauge

(g &Gauge) set(v f64)
(g &Gauge) inc()
(g &Gauge) dec()
(g &Gauge) add(v f64)
(g @Gauge) get() f64

// ─── Histogram ───────────────────────────────────────────────────

Histogram         struct       — value distribution with auto-generated log-scale buckets
                                 (VictoriaMetrics vmrange-style, better compression than cumulative)

(s &Set) new_histogram(name string) &Histogram
(s &Set) get_or_create_histogram(name string) &Histogram
new_histogram(name string) &Histogram
get_or_create_histogram(name string) &Histogram

(h &Histogram) update(v f64)
(h &Histogram) update_duration(start time.Time)   — record elapsed time since start
(h &Histogram) reset()
(h &Histogram) merge(src @Histogram)
(h @Histogram) visit_non_zero_buckets(f fun(vmrange string, count int))

// Standard Prometheus histogram (cumulative buckets) when needed
PrometheusHistogram  struct    — traditional cumulative bucket histogram

(s &Set) new_prometheus_histogram(name string) &PrometheusHistogram
(s &Set) new_prometheus_histogram_ext(name string, upper_bounds []f64) &PrometheusHistogram
(s &Set) get_or_create_prometheus_histogram(name string) &PrometheusHistogram

(ph &PrometheusHistogram) update(v f64)
(ph &PrometheusHistogram) update_duration(start time.Time)

// ─── Summary ─────────────────────────────────────────────────────

Summary           struct       — streaming quantile estimation over a time window

(s &Set) new_summary(name string) &Summary
(s &Set) new_summary_ext(name string, window time.Duration, quantiles []f64) &Summary
(s &Set) get_or_create_summary(name string) &Summary
(s &Set) get_or_create_summary_ext(name string, window time.Duration, quantiles []f64) &Summary
new_summary(name string) &Summary
new_summary_ext(name string, window time.Duration, quantiles []f64) &Summary
get_or_create_summary(name string) &Summary
get_or_create_summary_ext(name string, window time.Duration, quantiles []f64) &Summary

(sm &Summary) update(v f64)
(sm &Summary) update_duration(start time.Time)

// Default quantiles: 0.5, 0.9, 0.97, 0.99, 1.0
// Default window: 5 minutes

// ─── Global exposition ───────────────────────────────────────────

write_prometheus(w io.Writer, expose_process_metrics bool) !void
write_process_metrics(w io.Writer) !void    — memory, CPU, FDs, green thread count

// Metric names follow Prometheus conventions:
//   "http_requests_total"
//   "http_request_duration_seconds{method=\"GET\",path=\"/api\"}"
//   Labels are embedded in the metric name string, not as separate args

// ─── Push gateway support ────────────────────────────────────────

type PushOptions struct {
    extra_labels  string         — "key=value,key2=value2" appended to all metrics
    headers       map[string]string  — custom HTTP headers
    disable_compression bool
}

init_push(url string, interval time.Duration, extra_labels string) !void
init_push_with_options(ctx context.Context, url string, interval time.Duration, opts @PushOptions) !void
push_metrics(url string, extra_labels string) !void

(s &Set) init_push(url string, interval time.Duration, extra_labels string) !void
(s &Set) push_metrics(url string, extra_labels string) !void

// ─── Metadata control ────────────────────────────────────────────

expose_metadata(enabled bool)  — toggle TYPE/HELP lines in Prometheus output

// ─── Write helpers (for custom metrics writers) ──────────────────

write_counter_int(w io.Writer, name string, value int) !void
write_counter_float(w io.Writer, name string, value f64) !void
write_gauge_int(w io.Writer, name string, value int) !void
write_gauge_float(w io.Writer, name string, value f64) !void
```

**Design notes:**
- Ported from VictoriaMetrics/metrics — same philosophy: metric names are strings with embedded labels, no label-builder API, zero-allocation hot paths
- All metric types are concurrent-safe using atomic operations (no mutexes on the hot path)
- Histogram uses VictoriaMetrics vmrange-style log-scale buckets by default (better compression, no cumulative overhead), with traditional Prometheus cumulative histogram available via `PrometheusHistogram`
- Summary uses a sliding time window for quantile estimation
- `get_or_create_*` is the primary API — idempotent, safe to call from any green thread
- Labels embedded in name strings: `get_or_create_counter("http_requests_total{method=\"GET\"}")` — simple, no type-level label machinery needed
- Process metrics include: memory allocation stats (from generational allocator), green thread count, OS thread count, FD count, CPU time

**Example:**
```run
package main

use "metrics"
use "time"
use "net/http"

pub fun main() {
    // Counters
    requests := metrics.get_or_create_counter("http_requests_total")
    errors := metrics.get_or_create_counter("http_errors_total")

    // Histogram for latency
    duration := metrics.get_or_create_histogram("http_request_duration_seconds")

    // Gauge with callback
    metrics.get_or_create_gauge("goroutines_count", fun() f64 {
        return f64(runtime.num_goroutine())
    })

    r := http.new_router()

    // Expose /metrics endpoint
    r.get("/metrics", fun(w &http.ResponseWriter, req @http.Request) {
        metrics.write_prometheus(w, true)
    })

    r.get("/api/data", fun(w &http.ResponseWriter, req @http.Request) {
        start := time.now()
        defer duration.update_duration(start)

        requests.inc()
        // ... handle request ...
    })

    http.listen_and_serve(":8080", r)
}
```

**Dependencies:** `io`, `time`, `sync`, `context`, `net/http` (for push only)

---

### `url` — URL Parsing

**Purpose:** Parse, construct, and escape URLs.

**Key types and functions:**
```
Url               struct       — parsed URL
  scheme, host, port, path, raw_query, fragment string
  user UserInfo?

parse(raw string) !Url
(u @Url) string() string
(u @Url) query() map[string][]string
path_escape(s string) string
path_unescape(s string) !string
query_escape(s string) string
query_unescape(s string) !string
```

**Dependencies:** `strings`, `strconv`

---

### `mime` — MIME Types

**Purpose:** MIME type detection and file extension mapping.

**Key types and functions:**
```
type_by_extension(ext string) string
extension_by_type(mime_type string) string?
parse_media_type(s string) !(string, map[string]string)
format_media_type(mime_type string, params map[string]string) string
```

**Dependencies:** `strings`

---

### `unicode` — Unicode Tables and Properties

**Purpose:** Unicode character classification and properties.

**Key types and functions:**
```
is_letter(r rune) bool
is_digit(r rune) bool
is_upper(r rune) bool
is_lower(r rune) bool
is_space(r rune) bool
is_punct(r rune) bool
is_control(r rune) bool
is_graphic(r rune) bool
is_print(r rune) bool
to_upper(r rune) rune
to_lower(r rune) rune
to_title(r rune) rune
```

**Dependencies:** None

---

### `unicode/utf8` — UTF-8 Encoding

**Purpose:** UTF-8 encoding/decoding, validation, and rune manipulation.

**Key types and functions:**
```
encode(r rune) []byte
decode(b []byte) (rune, int)
decode_string(s string, pos int) (rune, int)
valid(b []byte) bool
valid_string(s string) bool
rune_count(b []byte) int
rune_count_string(s string) int
rune_len(r rune) int
full_rune(b []byte) bool
```

**Dependencies:** None

---

### `os/exec` — Running External Processes

**Purpose:** Run external commands and capture their output.

**Key types and functions:**
```
Cmd               struct       — external command configuration
ProcessError      sum type     — .notFound | .permissionDenied | .exitError(int)

command(name string, args ...string) Cmd
(c &Cmd) run() !void
(c &Cmd) output() ![]byte
(c &Cmd) combined_output() ![]byte
(c &Cmd) start() !void
(c &Cmd) wait() !void
(c &Cmd) stdin_pipe() !io.WriteCloser
(c &Cmd) stdout_pipe() !io.ReadCloser
(c &Cmd) stderr_pipe() !io.ReadCloser
```

**Dependencies:** `os`, `io`, `bytes`

---

### `os/signal` — OS Signal Handling

**Purpose:** Receive and handle OS signals (SIGINT, SIGTERM, etc.) via channels.

**Key types and functions:**
```
Signal            sum type     — .interrupt | .terminate | .hangup | .usr1 | .usr2 | .pipe

notify(c chan[Signal], signals ...Signal)   — relay signals to channel
stop(c chan[Signal])                        — stop relaying
ignore(signals ...Signal)                  — ignore signals
reset(signals ...Signal)                   — reset to default behavior
```

**Dependencies:** `os`

---

## P3 — Advanced/Specialized Packages

### `simd` — SIMD Vector Operations

**Purpose:** Compiler-recognized operations on Run's first-class SIMD vector and
mask primitives. The `simd` namespace maps to runtime helpers and target
intrinsics, with scalar fallbacks when no fast path is available.

**Key scalar and vector types:**
```
// Scalar lane types used by SIMD indexing
i8, i16, i32, f32, f64

// Built-in vector primitives
v4f32, v2f64, v4i32, v8i16, v16i8
v8f32, v4f64, v8i32, v16i16, v32i8

// Built-in mask primitives
v2bool, v4bool, v8bool, v16bool, v32bool
```

**Key operations:**
```
// Element-wise operators on matching vector types
v + w
v - w
v * w
v / w

// Comparisons return the matching mask type
v < w
v <= w
v > w
v >= w
v == w
v != w

// Lane access
lane := v[i]
v[i] = lane_value        // mutable local/parameter only

// SIMD literal syntax
v4f32{ 1.0, 2.0, 3.0, 4.0 }
```

**Compiler-recognized `simd.*` builtins:**
```
hadd(v) scalar
dot(a, b) scalar
shuffle(v, idx0, ..., idxN) vector     — one literal index per lane, all indices in range
min(a, b) vector
max(a, b) vector
select(mask, a, b) vector              — mask lane count must match vector lane count
load(ptr) vector                       — aligned load from @Vector or &Vector
load_unaligned(ptr) vector             — unaligned load from @Vector or &Vector
store(ptr, v)                          — aligned store through &Vector
width() int                            — 256 with AVX, 128 with SSE/NEON, otherwise 0
```

**Notes:**
- `simd` is currently a compiler-recognized pseudo-package; it does not rely on
  ordinary package loading.
- `unsafe.alignof(T)` returns the natural SIMD alignment (`16` for 128-bit
  vectors, `32` for 256-bit vectors).
- Older per-type helper names such as `sum_f32` and `blend_f32` are not part of
  the current API.

**Dependencies:** None (compiler-recognized namespace lowered to runtime helpers/intrinsics)

---

### `numa` — NUMA-Aware Memory and Scheduling

**Purpose:** Topology discovery, NUMA-aware allocation, and thread/green-thread affinity. Allows programs to optimize for memory locality on multi-socket systems.

**Key types and functions:**
```
Node              struct       — NUMA node
  id int
  cpus []int
  memory_total int
  memory_free int

Topology          struct       — system NUMA topology
  nodes []Node
  distances [][]int

topology() Topology            — discover system NUMA topology
available() bool               — is NUMA actually present?
node_count() int               — number of NUMA nodes
current_node() int             — NUMA node of calling thread
preferred_node() int           — preferred allocation node

// Memory placement
Allocator         struct       — NUMA-aware allocator
local_alloc(size int) &byte              — allocate on current node
node_alloc(node int, size int) &byte     — allocate on specific node
interleave_alloc(size int) &byte         — interleave across nodes

// Affinity
bind_thread(node int) !void              — bind current OS thread to node
bind_green_thread(node int) !void        — prefer scheduling on node
set_memory_policy(policy Policy) !void

Policy            sum type     — .local | .bind(node int) | .interleave | .preferred(node int)
```

**Dependencies:** `os`, `unsafe`

---

### `asm` — Inline Assembly Utilities

**Purpose:** Helpers for working with Run's inline assembly blocks. Register constants, constraint helpers, and platform detection.

**Key types and functions:**
```
Arch              sum type     — .x86_64 | .aarch64 | .riscv64 | .wasm32
arch() Arch                    — current target architecture

// Platform detection (compile-time constants)
is_x86_64    bool
is_aarch64   bool
is_riscv64   bool
is_wasm32    bool

// CPU feature detection (runtime)
has_avx() bool
has_avx2() bool
has_avx512() bool
has_sse42() bool
has_neon() bool
has_sve() bool

// Memory barriers
fence()                        — full memory fence
load_fence()                   — load-acquire fence
store_fence()                  — store-release fence

// Cache control
prefetch(addr &byte)
cache_line_size() int
flush_cache_line(addr &byte)
```

**Dependencies:** `unsafe`

---

### `embed` — Embed Files at Compile Time

**Purpose:** Embed file contents into the binary at compile time.

**Key types and functions:**
```
// Used via compiler directive
// @embed("path/to/file") produces a []byte or string at compile time

File              struct       — embedded file
  name string
  data []byte

Dir               struct       — embedded directory tree
  (d @Dir) open(name string) !File
  (d @Dir) read_dir() []string
```

**Dependencies:** None (compiler feature)

---

### `debug` — Debugging Utilities

**Purpose:** Stack traces, assertions, and diagnostic tools for development.

**Key types and functions:**
```
StackFrame        struct       — function, file, line
stack_trace() []StackFrame     — capture current stack
print_stack()                  — print stack to stderr
assert(condition bool, msg string)  — panic with message if false
unreachable(msg string)        — panic with "unreachable" message
todo(msg string)               — panic with "not implemented" message
breakpoint()                   — trigger debugger breakpoint
```

**Dependencies:** `fmt`, `os`

---

### `runtime` — Runtime Introspection

**Purpose:** Query and control the Run runtime: green thread count, memory stats, GC-free allocation stats, scheduler info.

**Key types and functions:**
```
MemStats          struct       — allocator statistics
  alloc_count int
  free_count int
  bytes_allocated int
  bytes_freed int
  generation_checks int
  generation_failures int

num_cpu() int                  — number of logical CPUs
num_goroutine() int            — number of active green threads
gomaxprocs(n int) int          — set/get OS thread count for scheduler
mem_stats() MemStats           — memory allocator statistics
version() string               — Run version string
gc_disable()                   — disable generation checks (unsafe, for benchmarks)
gc_enable()                    — re-enable generation checks
yield()                        — yield current green thread to scheduler
```

**Dependencies:** None (compiler builtins)

---

## Package Dependency Graph

```
                    ┌──────────┐
                    │ unsafe   │
                    └──────────┘
                         │
    ┌────────────────────┼────────────────────┐
    │                    │                    │
┌───▼──┐           ┌────▼───┐           ┌────▼──┐
│  io  │           │  sync  │           │ numa  │
└───┬──┘           └────────┘           └───────┘
    │
    ├──────────────┬──────────────┐
    │              │              │
┌───▼──┐      ┌───▼───┐     ┌───▼────┐
│  os  │      │ bytes │     │  fmt   │
└───┬──┘      └───┬───┘     └───┬────┘
    │             │             │
    ├─────────────┼─────────────┤
    │             │             │
┌───▼─────┐  ┌───▼────┐  ┌────▼───┐
│strings  │  │strconv │  │  time  │
└─────────┘  └────────┘  └────┬───┘
                              │
    ┌─────────────────────────┤
    │                         │
┌───▼──┐                 ┌───▼──────┐
│ log  │                 │ context  │
└──────┘                 └──────────┘

┌─────────┐    ┌────────┐    ┌──────────┐    ┌───────────────┐
│  net    │───▶│net/http│───▶│net/http2 │───▶│   net/grpc    │
└─────────┘    └───┬────┘    └──────────┘    └───────┬───────┘
                   │  │                              │
                   │  ▼                              ▼
                   │ ┌────────────┐        ┌────────────────┐
                   │ │encoding/*  │        │ encoding/proto  │
                   │ └────────────┘        └────────────────┘
                   ▼
              ┌─────────┐
              │ metrics │◀── Prometheus exposition, push gateway
              └─────────┘

┌────────┐    ┌──────┐    ┌──────┐
│  math  │    │ simd │    │ asm  │
└───┬────┘    └──────┘    └──────┘
    │
┌───▼───────┐
│ math/rand │
└───────────┘
```

## Complete Package List

| Package | Purpose | Priority | Dependencies |
|---------|---------|----------|-------------|
| `io` | I/O interfaces, buffered I/O, utilities | P0 | — |
| `fmt` | Formatting and printing | P0 | `io` |
| `os` | Files, processes, env, paths | P0 | `io` |
| `strings` | String manipulation | P1 | — |
| `bytes` | Byte slice utilities, Buffer | P1 | `io` |
| `math` | Math functions and constants | P1 | — |
| `math/rand` | Pseudo-random numbers | P1 | `math` |
| `testing` | Test framework and assertions | P1 | `fmt`, `strings` |
| `time` | Time, duration, timers | P1 | — |
| `log` | Structured logging | P1 | `io`, `time`, `fmt` |
| `strconv` | String/number conversions | P1 | `strings` |
| `unicode` | Unicode character properties | P1 | — |
| `unicode/utf8` | UTF-8 encoding/decoding | P1 | — |
| `sort` | Sorting algorithms | P1 | — |
| `bufio` | Scanner, line-by-line reading | P1 | `io`, `bytes` |
| `net` | TCP/UDP, DNS | P2 | `io`, `time`, `os` |
| `net/http` | HTTP client and server | P2 | `net`, `io`, `fmt`, `strings`, `time`, `context`, `metrics` |
| `net/http2` | HTTP/2 protocol | P2 | `net`, `net/http`, `io`, `sync`, `crypto/tls` |
| `net/grpc` | gRPC client and server | P2 | `net`, `net/http2`, `encoding/proto`, `context`, `time`, `sync`, `crypto/tls` |
| `encoding/proto` | Protocol Buffers | P2 | `bytes`, `io` |
| `encoding/json` | JSON encode/decode | P2 | `io`, `strings`, `bytes`, `fmt` |
| `encoding/csv` | CSV read/write | P2 | `io`, `strings`, `bytes` |
| `encoding/base64` | Base64 encode/decode | P2 | — |
| `encoding/hex` | Hex encode/decode | P2 | `bytes` |
| `crypto` | Hash interface, secure random | P2 | `io` |
| `crypto/sha256` | SHA-256 | P2 | `crypto` |
| `crypto/sha512` | SHA-512 | P2 | `crypto` |
| `crypto/hmac` | HMAC | P2 | `crypto` |
| `crypto/aes` | AES block cipher | P2 | `crypto` |
| `crypto/tls` | TLS connections | P2 | `crypto/*`, `net`, `io` |
| `sync` | Mutex, RwMutex, WaitGroup, Atomic | P2 | — |
| `unsafe` | Raw pointers, type layout | P2 | — |
| `context` | Cancellation and deadlines | P2 | `time` |
| `metrics` | Application metrics, Prometheus exposition | P2 | `io`, `time`, `sync`, `context` |
| `url` | URL parsing and escaping | P2 | `strings`, `strconv` |
| `mime` | MIME types | P2 | `strings` |
| `flag` | CLI flag parsing | P2 | `os`, `fmt`, `strconv` |
| `os/exec` | Run external commands | P2 | `os`, `io`, `bytes` |
| `os/signal` | OS signal handling | P2 | `os` |
| `regex` | Regular expressions | P2 | `strings` |
| `hash` | Non-crypto hash functions | P2 | — |
| `compress/flate` | DEFLATE compression | P2 | `io` |
| `compress/gzip` | Gzip compression | P2 | `io`, `compress/flate` |
| `compress/zlib` | Zlib compression | P2 | `io`, `compress/flate` |
| `archive/tar` | Tar archives | P2 | `io`, `os`, `time` |
| `archive/zip` | Zip archives | P2 | `io`, `os`, `compress/flate`, `time` |
| `simd` | SIMD vector operations | P3 | — |
| `numa` | NUMA topology and allocation | P3 | `os`, `unsafe` |
| `asm` | Assembly utilities, CPU features | P3 | `unsafe` |
| `embed` | Compile-time file embedding | P3 | — |
| `debug` | Stack traces, assertions | P3 | `fmt`, `os` |
| `runtime` | Runtime introspection | P3 | — |

**Total: 50 packages** (6 exist as stubs)
