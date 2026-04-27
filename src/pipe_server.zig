const std = @import("std");
const Allocator = std.mem.Allocator;
const w = std.os.windows;
const k32 = w.kernel32;

const log = std.log.scoped(.pipe_server);

const HANDLE = w.HANDLE;
const DWORD = w.DWORD;
const BOOL = w.BOOL;
const LPCWSTR = [*:0]const u16;
const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;
const OVERLAPPED = w.OVERLAPPED;
const SECURITY_ATTRIBUTES = w.SECURITY_ATTRIBUTES;

// ── Win32 externs not in std ──

extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: LPCWSTR,
    StringSDRevision: DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*DWORD,
) callconv(.winapi) BOOL;

// ── Constants ──

const PIPE_ACCESS_DUPLEX = w.PIPE_ACCESS_DUPLEX;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const PIPE_TYPE_BYTE = w.PIPE_TYPE_BYTE;
const PIPE_WAIT = w.PIPE_WAIT;
const WAIT_OBJECT_0 = w.WAIT_OBJECT_0;
const WAIT_TIMEOUT = w.WAIT_TIMEOUT;
const CREATE_EVENT_MANUAL_RESET = w.CREATE_EVENT_MANUAL_RESET;
const EVENT_ALL_ACCESS = w.EVENT_ALL_ACCESS;
const SDDL_REVISION_1: DWORD = 1;

// SDDL: owner has full access
const SDDL_STRING = std.unicode.utf8ToUtf16LeStringLiteral("D:(A;;GA;;;OW)");

pub const HandlerFn = *const fn (request: []const u8, ctx: *anyopaque, allocator: Allocator) []const u8;

const CANCEL_DRAIN_TIMEOUT_MS: DWORD = 500;
const ERROR_OPERATION_ABORTED = 995;
const ERROR_BROKEN_PIPE = 109;
const ERROR_NO_DATA = 232;
const ERROR_PIPE_CONNECTED = 535;

/// Maximum time `writeAll` will wait for a slow/non-draining client before
/// cancelling the pending WriteFile and returning `error.WriteTimeout`.
/// Without this bound a client that opens the pipe but never calls ReadFile
/// (e.g. a stalled deckpilot) wedges the server's clientThread forever and
/// eventually exhausts `nMaxInstances=255` (issue #222).
const WRITE_TIMEOUT_MS: DWORD = 5000;

// ── Rate limit (issue #211) ──
//
// Per-client token-bucket on *write* commands (INPUT/RAW_INPUT/PASTE/SEND_KEYS).
// Read commands (PING, STATE, TAIL, etc.) do not consume backend queue capacity
// and are intentionally not gated.
//
// Defaults are tuned so that legitimate operators (e.g. deckpilot
// auto-approvals at 0.5 req/s) sit far below the sustained rate, while a
// runaway client gets back-pressure feedback (`ERR|RATE_LIMITED|<retry_ms>\n`)
// instead of silent enqueueInput drops at the apprt layer.
//
// All knobs are overridable via environment variables read once at startup:
//   KS_CP_RATE_BURST           — bucket capacity (default 10)
//   KS_CP_RATE_SUSTAINED_PER_SEC — refill rate (default 2)
//   KS_CP_RATE_DISABLE=1       — bypass rate limiting (debug)
const DEFAULT_RATE_BURST: f64 = 10.0;
const DEFAULT_RATE_SUSTAINED_PER_SEC: f64 = 2.0;

const RateLimitConfig = struct {
    burst: f64,
    sustained_per_sec: f64,
    disabled: bool,
};

fn readEnvF64(name: []const u8, default_v: f64) f64 {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return default_v;
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return default_v;
    return std.fmt.parseFloat(f64, value) catch default_v;
}

fn readEnvBool(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn loadRateLimitConfig() RateLimitConfig {
    return .{
        .burst = @max(1.0, readEnvF64("KS_CP_RATE_BURST", DEFAULT_RATE_BURST)),
        .sustained_per_sec = @max(0.1, readEnvF64("KS_CP_RATE_SUSTAINED_PER_SEC", DEFAULT_RATE_SUSTAINED_PER_SEC)),
        .disabled = readEnvBool("KS_CP_RATE_DISABLE"),
    };
}

/// Per-client token bucket. Created on the clientThread stack — no lock
/// needed because mutation is single-threaded per client.
const TokenBucket = struct {
    tokens: f64,
    last_refill_ns: i128,
    cfg: RateLimitConfig,
    /// Squelches per-bucket "rate-limited" log spam: at most one warn per
    /// LOG_SQUELCH_NS interval per client (rate-limit-on-rate-limit-log).
    last_warn_ns: i128 = 0,

    const LOG_SQUELCH_NS: i128 = 1 * std.time.ns_per_s;

    fn init(cfg: RateLimitConfig) TokenBucket {
        return .{
            .tokens = cfg.burst,
            .last_refill_ns = std.time.nanoTimestamp(),
            .cfg = cfg,
        };
    }

    fn refill(self: *TokenBucket, now_ns: i128) void {
        const dt_ns = now_ns - self.last_refill_ns;
        if (dt_ns <= 0) return;
        const dt_s: f64 = @as(f64, @floatFromInt(dt_ns)) / @as(f64, std.time.ns_per_s);
        self.tokens = @min(self.cfg.burst, self.tokens + dt_s * self.cfg.sustained_per_sec);
        self.last_refill_ns = now_ns;
    }

    /// Try to consume one token. Returns null on success, or the suggested
    /// retry-after duration in milliseconds when the bucket is empty.
    fn tryConsume(self: *TokenBucket) ?u32 {
        if (self.cfg.disabled) return null;
        const now_ns = std.time.nanoTimestamp();
        self.refill(now_ns);
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return null;
        }
        const need = 1.0 - self.tokens;
        const wait_s = need / self.cfg.sustained_per_sec;
        const wait_ms_f = @ceil(wait_s * 1000.0);
        const wait_ms: u32 = if (wait_ms_f < 1.0) 1 else if (wait_ms_f > @as(f64, @floatFromInt(std.math.maxInt(u32)))) std.math.maxInt(u32) else @intFromFloat(wait_ms_f);
        return wait_ms;
    }

    fn maybeWarn(self: *TokenBucket, retry_ms: u32) void {
        const now_ns = std.time.nanoTimestamp();
        if (now_ns - self.last_warn_ns < LOG_SQUELCH_NS) return;
        self.last_warn_ns = now_ns;
        log.warn("rate limit triggered: retry_after_ms={d} burst={d:.1} rate={d:.2}/s (issue #211)", .{
            retry_ms,
            self.cfg.burst,
            self.cfg.sustained_per_sec,
        });
    }
};

/// Returns true when a request line carries a write command that should
/// consume one token. Read-only commands are unbounded.
fn isRateLimitedRequest(request: []const u8) bool {
    // The protocol uses `|` as separator, so command is everything before
    // the first `|` (or the whole line if none).
    const sep = std.mem.indexOfScalar(u8, request, '|') orelse request.len;
    const cmd = request[0..sep];
    return std.mem.eql(u8, cmd, "INPUT") or
        std.mem.eql(u8, cmd, "RAW_INPUT") or
        std.mem.eql(u8, cmd, "PASTE") or
        std.mem.eql(u8, cmd, "SEND_KEYS");
}

/// Build the wire response sent when a request is rejected by the bucket.
/// Same format family as `ERR|BUSY|...` (#207): `ERR|RATE_LIMITED|<retry_ms>\n`.
fn formatRateLimited(buf: []u8, retry_ms: u32) []const u8 {
    return std.fmt.bufPrint(buf, "ERR|RATE_LIMITED|{d}\n", .{retry_ms}) catch "ERR|RATE_LIMITED|1000\n";
}

pub const PipeServer = struct {
    pipe_path_w: [:0]const u16,
    stop_flag: std.atomic.Value(bool),
    command_thread: ?std.Thread = null,
    handler: HandlerFn,
    ctx: *anyopaque,
    allocator: Allocator,
    active_clients: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: Allocator, pipe_name: []const u8, handler: HandlerFn, ctx: *anyopaque) !PipeServer {
        const pipe_path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pipe_name);
        return PipeServer{
            .pipe_path_w = pipe_path_w,
            .stop_flag = std.atomic.Value(bool).init(false),
            .handler = handler,
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn start(self: *PipeServer) !void {
        self.command_thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    pub fn stop(self: *PipeServer) void {
        self.stop_flag.store(true, .monotonic);
        if (self.command_thread) |t| {
            t.join();
            self.command_thread = null;
        }
        // Wait for any in-flight client handler threads to finish
        while (self.active_clients.load(.acquire) > 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    pub fn deinit(self: *PipeServer) void {
        self.stop();
        self.allocator.free(self.pipe_path_w);
        self.* = undefined;
    }

    fn serverThread(self: *PipeServer) void {
        self.runAcceptLoop(commandServerIteration);
    }

    fn runAcceptLoop(self: *PipeServer, comptime iteration_fn: fn (*PipeServer, *SECURITY_ATTRIBUTES) void) void {
        // Build security attributes with SDDL
        var sd: ?*anyopaque = null;
        const sddl_ok = ConvertStringSecurityDescriptorToSecurityDescriptorW(
            SDDL_STRING,
            SDDL_REVISION_1,
            &sd,
            null,
        );
        defer if (sd != null) {
            _ = LocalFree(sd);
        };

        var sa = SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = if (sddl_ok != 0) sd else null,
            .bInheritHandle = 0, // FALSE
        };

        while (!self.stop_flag.load(.monotonic)) {
            iteration_fn(self, &sa);
        }
    }

    /// Context passed to each client-handler thread.
    const ClientThreadCtx = struct {
        server: *PipeServer,
        pipe: HANDLE,
    };

    fn commandServerIteration(self: *PipeServer, sa: *SECURITY_ATTRIBUTES) void {
        log.debug("commandServerIteration: creating pipe...", .{});
        const pipe = k32.CreateNamedPipeW(
            self.pipe_path_w,
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_WAIT,
            255, // nMaxInstances — PIPE_UNLIMITED_INSTANCES
            65536,
            65536,
            0,
            sa,
        );
        if (pipe == INVALID_HANDLE_VALUE) {
            const err = k32.GetLastError();
            log.err("CreateNamedPipeW FAILED err={d}", .{@intFromEnum(err)});
            return;
        }
        log.debug("commandServerIteration: pipe created, waiting for client...", .{});

        // Create manual-reset event for overlapped I/O
        const event = w.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) catch {
            w.CloseHandle(pipe);
            return;
        };
        defer w.CloseHandle(event);

        var overlapped = std.mem.zeroes(OVERLAPPED);
        overlapped.hEvent = event;

        const connect_ok = ConnectNamedPipe(pipe, &overlapped);
        var connected_immediately = false;
        if (connect_ok != 0) {
            connected_immediately = true;
        } else {
            const connect_err = @intFromEnum(k32.GetLastError());
            if (connect_err == ERROR_PIPE_CONNECTED) {
                // Client connected before ConnectNamedPipe completed.
                connected_immediately = true;
            } else if (connect_err != @intFromEnum(w.Win32Error.IO_PENDING)) {
                log.err("ConnectNamedPipe FAILED err={d}", .{connect_err});
                _ = DisconnectNamedPipe(pipe);
                w.CloseHandle(pipe);
                return;
            }
        }

        if (connected_immediately) {
            if (!self.stop_flag.load(.monotonic)) {
                const ctx = self.allocator.create(ClientThreadCtx) catch {
                    _ = DisconnectNamedPipe(pipe);
                    w.CloseHandle(pipe);
                    return;
                };
                ctx.* = .{ .server = self, .pipe = pipe };
                _ = self.active_clients.fetchAdd(1, .acq_rel);
                const t = std.Thread.spawn(.{}, clientThread, .{ctx}) catch {
                    _ = self.active_clients.fetchSub(1, .acq_rel);
                    self.allocator.destroy(ctx);
                    _ = DisconnectNamedPipe(pipe);
                    w.CloseHandle(pipe);
                    return;
                };
                t.detach();
            } else {
                _ = DisconnectNamedPipe(pipe);
                w.CloseHandle(pipe);
            }
            return;
        }

        // Wait with 1s timeout for interruptibility
        while (!self.stop_flag.load(.monotonic)) {
            const result = k32.WaitForSingleObject(event, 1000);
            if (result == WAIT_OBJECT_0) {
                // Client connected — spawn a thread to handle it.
                // The handler thread owns the pipe handle (disconnect + close).
                if (!self.stop_flag.load(.monotonic)) {
                    const ctx = self.allocator.create(ClientThreadCtx) catch {
                        _ = DisconnectNamedPipe(pipe);
                        w.CloseHandle(pipe);
                        return;
                    };
                    ctx.* = .{ .server = self, .pipe = pipe };
                    // Increment before spawn so stop() cannot complete while thread is starting.
                    _ = self.active_clients.fetchAdd(1, .acq_rel);
                    const t = std.Thread.spawn(.{}, clientThread, .{ctx}) catch {
                        _ = self.active_clients.fetchSub(1, .acq_rel);
                        self.allocator.destroy(ctx);
                        _ = DisconnectNamedPipe(pipe);
                        w.CloseHandle(pipe);
                        return;
                    };
                    t.detach();
                    // Pipe ownership transferred to clientThread.
                    // Main loop returns to create the next pipe instance.
                } else {
                    _ = DisconnectNamedPipe(pipe);
                    w.CloseHandle(pipe);
                }
                return;
            } else if (result == WAIT_TIMEOUT) {
                // Loop again to check stop flag
                continue;
            } else {
                // Error
                _ = DisconnectNamedPipe(pipe);
                w.CloseHandle(pipe);
                return;
            }
        }

        // Stopping — cancel pending connect and drain before overlapped goes out of scope
        _ = k32.CancelIoEx(pipe, &overlapped);
        _ = k32.WaitForSingleObject(event, 5000);
        _ = DisconnectNamedPipe(pipe);
        w.CloseHandle(pipe);
    }

    /// Runs on a dedicated thread per client. Owns the pipe handle.
    /// active_clients was already incremented before spawn.
    fn clientThread(ctx: *ClientThreadCtx) void {
        const self = ctx.server;
        const pipe = ctx.pipe;
        self.allocator.destroy(ctx);
        log.debug("clientThread: started", .{});
        defer {
            log.debug("clientThread: exiting", .{});
            _ = self.active_clients.fetchSub(1, .acq_rel);
        }
        defer {
            _ = DisconnectNamedPipe(pipe);
            w.CloseHandle(pipe);
        }
        self.handleClient(pipe);
    }

    fn handleClient(self: *PipeServer, pipe: HANDLE) void {
        log.debug("handleClient: enter", .{});
        const event = w.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) catch return;
        defer w.CloseHandle(event);

        var buf: [65536]u8 = undefined;
        var carry: [65536]u8 = undefined;
        var carry_len: usize = 0;
        var persistent = false;
        // Per-client token bucket — see issue #211.
        var bucket = TokenBucket.init(loadRateLimitConfig());

        while (!self.stop_flag.load(.monotonic)) {
            // 1) Try to get a complete request line
            log.debug("handleClient: reading request...", .{});
            const request = self.readRequestLine(pipe, event, &buf, &carry, &carry_len, persistent) orelse {
                log.debug("handleClient: readRequestLine returned null (disconnect/timeout)", .{});
                return;
            };
            log.debug("handleClient: got request len={d}", .{request.len});
            // Empty line: in persistent mode keep the connection alive, in 1-shot mode we're done.
            if (request.len == 0) {
                if (persistent) continue;
                return;
            }

            // 2) Check for PERSIST handshake
            if (std.mem.eql(u8, request, "PERSIST")) {
                persistent = true;
                writeAll(pipe, "OK|PERSIST\n") catch return;
                continue;
            }

            // 3) SUBSCRIBE/UNSUBSCRIBE: no-op stubs for backward compatibility.
            //    Event push is removed; agent-deck polls via TAIL/STATE instead.
            if (std.mem.startsWith(u8, request, "SUBSCRIBE|")) {
                const topic = request["SUBSCRIBE|".len..];
                if (std.mem.eql(u8, topic, "status")) {
                    writeAll(pipe, "SUBSCRIBE_OK|status\n") catch return;
                } else if (std.mem.eql(u8, topic, "output")) {
                    writeAll(pipe, "SUBSCRIBE_OK|output\n") catch return;
                } else {
                    writeAll(pipe, "ERR|unknown_topic\n") catch return;
                }
                continue;
            }
            if (std.mem.startsWith(u8, request, "UNSUBSCRIBE|")) {
                writeAll(pipe, "UNSUBSCRIBE_OK\n") catch return;
                continue;
            }

            // 4) Rate-limit gate (issue #211): only mutating commands cost a
            //    token. Read-only commands pass through untouched.
            if (isRateLimitedRequest(request)) {
                if (bucket.tryConsume()) |retry_ms| {
                    bucket.maybeWarn(retry_ms);
                    var rl_buf: [64]u8 = undefined;
                    const rl_resp = formatRateLimited(&rl_buf, retry_ms);
                    writeAll(pipe, rl_resp) catch |err| {
                        log.warn("handleClient: rate-limit writeAll failed: {}", .{err});
                        return;
                    };
                    if (!persistent) break;
                    continue;
                }
            }

            // 5) Dispatch to handler
            log.debug("handleClient: dispatching to handler...", .{});
            const response = self.handler(request, self.ctx, self.allocator);
            defer self.allocator.free(response);
            log.debug("handleClient: handler returned {d} bytes, writing response...", .{response.len});
            writeAll(pipe, response) catch |err| {
                // WriteTimeout / BrokenPipe are expected under slow or
                // disconnected clients; treat as warn so the noisy code
                // path does not look like a server-side fault (issue #222).
                log.warn("handleClient: writeAll failed: {}", .{err});
                return;
            };
            log.debug("handleClient: response written OK", .{});

            if (!persistent) {
                // NOTE (issue #222): the previous code called
                // `FlushFileBuffers(pipe)` here. That call blocks
                // unboundedly until the client drains the pipe (same
                // failure mode as the writeAll wedge we just fixed) and
                // is unnecessary for short responses on a byte-mode named
                // pipe — the OS retains buffered bytes until the client
                // reads them or the handle is closed. Dropping the flush
                // closes the residual writeAll-side stall window.
                break;
            }
        }
    }

    /// Read one request line from the pipe. Returns the trimmed line content,
    /// or null on disconnect / timeout (1-shot) / fatal error.
    /// In persistent mode, a read timeout returns an empty slice (not null)
    /// so the caller can loop and check the stop flag.
    fn readRequestLine(
        self: *PipeServer,
        pipe: HANDLE,
        event: HANDLE,
        buf: *[65536]u8,
        carry: *[65536]u8,
        carry_len: *usize,
        persistent: bool,
    ) ?[]const u8 {
        while (true) {
            // Check carry buffer for a complete line
            if (extractLine(carry[0..carry_len.*])) |info| {
                const trimmed = std.mem.trimRight(u8, carry[0..info.line_end], &[_]u8{ '\r', '\n', ' ', '\t' });
                // Shift remainder forward
                const remaining = carry_len.* - info.next_start;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, carry[0..remaining], carry[info.next_start..carry_len.*]);
                }
                carry_len.* = remaining;
                return trimmed;
            }

            // No complete line — read more data from pipe
            if (self.stop_flag.load(.monotonic)) return null;

            var overlapped = std.mem.zeroes(OVERLAPPED);
            overlapped.hEvent = event;
            _ = ResetEvent(event);

            const space = buf.len;
            const read_ok = k32.ReadFile(pipe, buf, @intCast(space), null, &overlapped);
            if (read_ok != 0) {
                const bytes_read = getOverlappedBytes(pipe, &overlapped) catch |err| switch (err) {
                    error.BrokenPipe => return null,
                    error.OperationAborted => return null,
                    else => return null,
                };
                if (bytes_read == 0) return null;

                const new_total = carry_len.* + bytes_read;
                if (new_total > carry.len) return null;
                @memcpy(carry[carry_len.*..new_total], buf[0..bytes_read]);
                carry_len.* = new_total;
                continue;
            }

            const read_err = @intFromEnum(w.kernel32.GetLastError());
            if (read_err == ERROR_BROKEN_PIPE or read_err == ERROR_NO_DATA) return null;
            if (read_err != @intFromEnum(w.Win32Error.IO_PENDING)) return null;

            const timeout: DWORD = if (persistent) 500 else 2000;
            const wait_result = k32.WaitForSingleObject(event, timeout);

            // Cancel the pending read and drain before overlapped goes out of scope.
            const is_read_complete = (wait_result == WAIT_OBJECT_0);

            if (!is_read_complete) {
                _ = k32.CancelIoEx(pipe, &overlapped);
                // Wait for cancellation to fully complete so overlapped stays valid.
                _ = k32.WaitForSingleObject(event, CANCEL_DRAIN_TIMEOUT_MS);

                // Even though we cancelled, some bytes might have been read before
                // the cancellation took effect. Salvage them into carry.
                const cancelled_bytes = getOverlappedBytes(pipe, &overlapped) catch |err| switch (err) {
                    error.OperationAborted => 0,
                    error.BrokenPipe => 0,
                    else => 0,
                };
                if (cancelled_bytes > 0) {
                    const new_total = carry_len.* + cancelled_bytes;
                    if (new_total <= carry.len) {
                        @memcpy(carry[carry_len.*..new_total], buf[0..cancelled_bytes]);
                        carry_len.* = new_total;
                    }
                }

                if (wait_result == WAIT_TIMEOUT) {
                    if (persistent) {
                        return carry[0..0];
                    }
                    if (carry_len.* > 0) {
                        const trimmed = std.mem.trimRight(u8, carry[0..carry_len.*], &[_]u8{ '\r', '\n', ' ', '\t' });
                        carry_len.* = 0;
                        return trimmed;
                    }
                    return null;
                }
                // Other error
                return null;
            }

            const bytes_read = getOverlappedBytes(pipe, &overlapped) catch |err| switch (err) {
                error.BrokenPipe => return null,
                error.OperationAborted => return null,
                else => return null,
            };
            if (bytes_read == 0) return null; // client disconnected

            // Append to carry buffer
            const new_total = carry_len.* + bytes_read;
            if (new_total > carry.len) return null; // overflow
            @memcpy(carry[carry_len.*..new_total], buf[0..bytes_read]);
            carry_len.* = new_total;

            // Loop back to try extractLine again
        }
    }

    /// Write all bytes to the pipe using overlapped I/O.
    /// Uses its own OVERLAPPED to avoid interfering with any other I/O on this handle.
    ///
    /// Bounded by `WRITE_TIMEOUT_MS` (issue #222): a client that does not
    /// drain the pipe used to wedge `GetOverlappedResult(bWait=TRUE)` forever
    /// and leak the clientThread, eventually exhausting `nMaxInstances`.
    /// On timeout we `CancelIoEx` the pending write and return
    /// `error.WriteTimeout`. The defer in `clientThread` then disconnects
    /// and closes the pipe handle so the slot is reclaimed.
    fn writeAll(pipe: HANDLE, data: []const u8) !void {
        const ev = w.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) catch
            return error.Unexpected;
        defer w.CloseHandle(ev);

        var overlapped = std.mem.zeroes(OVERLAPPED);
        overlapped.hEvent = ev;

        const ok = k32.WriteFile(pipe, data.ptr, @intCast(data.len), null, &overlapped);
        if (ok == 0) {
            const write_err = @intFromEnum(w.kernel32.GetLastError());
            if (write_err != @intFromEnum(w.Win32Error.IO_PENDING)) {
                if (write_err == ERROR_NO_DATA or write_err == ERROR_BROKEN_PIPE) return error.BrokenPipe;
                return error.Unexpected;
            }
        }

        // Wait for completion with a hard upper bound rather than the
        // unbounded GetOverlappedResult(bWait=TRUE) used previously.
        const wait = k32.WaitForSingleObject(ev, WRITE_TIMEOUT_MS);
        if (wait != WAIT_OBJECT_0) {
            // Either WAIT_TIMEOUT or a signalling error. Cancel the pending
            // write and drain the cancellation so `overlapped` stays valid
            // until the IO is fully aborted.
            _ = k32.CancelIoEx(pipe, &overlapped);
            _ = k32.WaitForSingleObject(ev, CANCEL_DRAIN_TIMEOUT_MS);
            if (wait == WAIT_TIMEOUT) {
                log.warn("writeAll: WriteFile did not complete within {d}ms; cancelling (issue #222)", .{WRITE_TIMEOUT_MS});
                return error.WriteTimeout;
            }
            return error.Unexpected;
        }

        var bytes_written: DWORD = 0;
        // bWait=FALSE is now safe — the event is already signalled.
        if (GetOverlappedResult(pipe, &overlapped, &bytes_written, 0) == 0) {
            const write_err = @intFromEnum(w.kernel32.GetLastError());
            if (write_err == ERROR_NO_DATA or write_err == ERROR_BROKEN_PIPE) return error.BrokenPipe;
            if (write_err == ERROR_OPERATION_ABORTED) return error.WriteTimeout;
            return error.Unexpected;
        }
        if (bytes_written != data.len) return error.Unexpected;
    }

    const LineInfo = struct {
        line_end: usize, // index of end of line content (before \n or \r\n)
        next_start: usize, // index of start of next line
    };

    /// Scan for the first newline in data. Returns the line boundaries or null.
    fn extractLine(data: []const u8) ?LineInfo {
        for (data, 0..) |c, i| {
            if (c == '\n') {
                const line_end = if (i > 0 and data[i - 1] == '\r') i - 1 else i;
                return LineInfo{ .line_end = line_end, .next_start = i + 1 };
            }
        }
        return null;
    }
};

// ── Tests ──

const testing = std.testing;

// ── Rate-limit unit tests (issue #211) ──

test "isRateLimitedRequest classifies write commands" {
    try testing.expect(isRateLimitedRequest("INPUT|agent|aGk="));
    try testing.expect(isRateLimitedRequest("RAW_INPUT|agent|aGk="));
    try testing.expect(isRateLimitedRequest("PASTE|agent|aGk="));
    try testing.expect(isRateLimitedRequest("SEND_KEYS|agent|Enter"));

    try testing.expect(!isRateLimitedRequest("PING"));
    try testing.expect(!isRateLimitedRequest("STATE"));
    try testing.expect(!isRateLimitedRequest("TAIL|10"));
    try testing.expect(!isRateLimitedRequest("CAPABILITIES"));
    try testing.expect(!isRateLimitedRequest("ACK_POLL|7"));
    try testing.expect(!isRateLimitedRequest("WAIT_DRAIN|7|500"));
    try testing.expect(!isRateLimitedRequest("PERSIST"));
    try testing.expect(!isRateLimitedRequest("SUBSCRIBE|status"));
}

test "TokenBucket allows burst then rate-limits" {
    var bucket = TokenBucket.init(.{ .burst = 3, .sustained_per_sec = 1, .disabled = false });
    // First 3 requests succeed (full burst).
    try testing.expect(bucket.tryConsume() == null);
    try testing.expect(bucket.tryConsume() == null);
    try testing.expect(bucket.tryConsume() == null);
    // 4th is rate-limited with a positive retry hint.
    const retry = bucket.tryConsume();
    try testing.expect(retry != null);
    try testing.expect(retry.? >= 1);
    // Suggested retry should be roughly 1/rate seconds (1000ms ± ceiling).
    try testing.expect(retry.? <= 1100);
}

test "TokenBucket disabled bypasses limit" {
    var bucket = TokenBucket.init(.{ .burst = 1, .sustained_per_sec = 1, .disabled = true });
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(bucket.tryConsume() == null);
    }
}

test "TokenBucket refills over time" {
    var bucket = TokenBucket.init(.{ .burst = 2, .sustained_per_sec = 100, .disabled = false });
    try testing.expect(bucket.tryConsume() == null);
    try testing.expect(bucket.tryConsume() == null);
    try testing.expect(bucket.tryConsume() != null);
    // 50ms at 100/s → ~5 tokens, capped at burst (2). After sleep, two should pass.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try testing.expect(bucket.tryConsume() == null);
    try testing.expect(bucket.tryConsume() == null);
}

test "formatRateLimited emits expected wire shape" {
    var buf: [64]u8 = undefined;
    const out = formatRateLimited(&buf, 250);
    try testing.expectEqualStrings("ERR|RATE_LIMITED|250\n", out);
}

fn testHandler(request: []const u8, _: *anyopaque, allocator: Allocator) []const u8 {
    _ = request;
    return allocator.dupe(u8, "PONG|test\n") catch return "";
}

test "pipe server smoke test" {
    const allocator = testing.allocator;

    // Unique pipe name for this test
    const pipe_name = "\\\\.\\pipe\\zig-cp-test-smoke";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &testHandler, @ptrCast(&dummy));
    defer server.deinit();

    try server.start();

    // Give the server thread a moment to set up the pipe
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Connect as client
    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-smoke");
    const client = k32.CreateFileW(
        pipe_name_w,
        w.GENERIC_READ | w.GENERIC_WRITE,
        0,
        null,
        w.OPEN_EXISTING,
        0,
        null,
    );
    try testing.expect(client != INVALID_HANDLE_VALUE);
    defer w.CloseHandle(client);

    // Write request
    const msg = "PING\n";
    var bytes_written: DWORD = 0;
    const write_ok = k32.WriteFile(client, msg, @intCast(msg.len), &bytes_written, null);
    try testing.expect(write_ok != 0);

    // Read response
    var resp_buf: [4096]u8 = undefined;
    var bytes_read: DWORD = 0;
    const read_ok = k32.ReadFile(client, &resp_buf, 4096, &bytes_read, null);
    try testing.expect(read_ok != 0);
    try testing.expect(bytes_read > 0);

    const resp = resp_buf[0..bytes_read];
    try testing.expect(std.mem.startsWith(u8, resp, "PONG"));
}

// ── Helper: connect a persistent client and subscribe ──

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

fn connectPersistClient(pipe_name_w: [*:0]const u16) !HANDLE {
    const client = k32.CreateFileW(
        pipe_name_w,
        w.GENERIC_READ | w.GENERIC_WRITE,
        0,
        null,
        w.OPEN_EXISTING,
        0,
        null,
    );
    if (client == INVALID_HANDLE_VALUE) return error.ConnectFailed;
    return client;
}

fn pipeSend(pipe: HANDLE, msg: []const u8) !void {
    var written: DWORD = 0;
    const ok = k32.WriteFile(pipe, msg.ptr, @intCast(msg.len), &written, null);
    if (ok == 0) return error.WriteFailed;
}

fn pipeRecvLine(pipe: HANDLE, buf: []u8) ![]const u8 {
    var total: usize = 0;
    const deadline = std.time.milliTimestamp() + 8000; // 8s timeout
    while (std.time.milliTimestamp() < deadline) {
        var avail: DWORD = 0;
        _ = PeekNamedPipe(pipe, null, 0, null, &avail, null);
        if (avail == 0) {
            const peek_err = @intFromEnum(w.kernel32.GetLastError());
            if (peek_err == ERROR_BROKEN_PIPE or peek_err == ERROR_NO_DATA) return error.BrokenPipe;
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        var bytes_read: DWORD = 0;
        const to_read: DWORD = @intCast(@min(buf.len - total, avail));
        const ok = k32.ReadFile(pipe, @ptrCast(buf.ptr + total), to_read, &bytes_read, null);
        if (ok == 0) {
            const read_err = @intFromEnum(w.kernel32.GetLastError());
            if (read_err == ERROR_BROKEN_PIPE or read_err == ERROR_NO_DATA) return error.BrokenPipe;
            return error.ReadFailed;
        }
        if (bytes_read == 0) return error.BrokenPipe;
        total += bytes_read;
        if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |_| {
            return buf[0..total];
        }
    }
    if (total > 0) return buf[0..total];
    return error.Timeout;
}

fn getOverlappedBytes(pipe: HANDLE, overlapped: *OVERLAPPED) !DWORD {
    var bytes: DWORD = 0;
    if (GetOverlappedResult(pipe, overlapped, &bytes, 0) != 0) return bytes;

    const err = @intFromEnum(w.kernel32.GetLastError());
    if (err == ERROR_OPERATION_ABORTED) return error.OperationAborted;
    if (err == ERROR_BROKEN_PIPE or err == ERROR_NO_DATA) {
        return error.BrokenPipe;
    }
    return error.Unexpected;
}

// ── SUBSCRIBE/UNSUBSCRIBE no-op stub tests ──

test "SUBSCRIBE returns SUBSCRIBE_OK for known topics" {
    const allocator = testing.allocator;
    const pipe_name = "\\\\.\\pipe\\zig-cp-test-subscribe-noop";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &testHandler, @ptrCast(&dummy));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-subscribe-noop");
    const client = try connectPersistClient(pipe_name_w);
    defer w.CloseHandle(client);

    var buf: [4096]u8 = undefined;

    try pipeSend(client, "PERSIST\n");
    _ = try pipeRecvLine(client, &buf);

    try pipeSend(client, "SUBSCRIBE|status\n");
    const resp = try pipeRecvLine(client, &buf);
    try testing.expectEqualStrings("SUBSCRIBE_OK|status\n", resp);
}

test "SUBSCRIBE with unknown topic returns error" {
    const allocator = testing.allocator;
    const pipe_name = "\\\\.\\pipe\\zig-cp-test-unknown-topic";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &testHandler, @ptrCast(&dummy));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-unknown-topic");
    const client = try connectPersistClient(pipe_name_w);
    defer w.CloseHandle(client);

    var buf: [4096]u8 = undefined;

    try pipeSend(client, "PERSIST\n");
    _ = try pipeRecvLine(client, &buf);

    try pipeSend(client, "SUBSCRIBE|foobar\n");
    const resp = try pipeRecvLine(client, &buf);
    const trimmed = std.mem.trimRight(u8, resp, &[_]u8{ '\r', '\n' });
    try testing.expect(std.mem.startsWith(u8, trimmed, "ERR|unknown_topic"));
}

test "UNSUBSCRIBE returns UNSUBSCRIBE_OK" {
    const allocator = testing.allocator;
    const pipe_name = "\\\\.\\pipe\\zig-cp-test-unsubscribe-noop";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &testHandler, @ptrCast(&dummy));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-unsubscribe-noop");
    const client = try connectPersistClient(pipe_name_w);
    defer w.CloseHandle(client);

    var buf: [4096]u8 = undefined;

    try pipeSend(client, "PERSIST\n");
    _ = try pipeRecvLine(client, &buf);

    try pipeSend(client, "UNSUBSCRIBE|status\n");
    const resp = try pipeRecvLine(client, &buf);
    try testing.expectEqualStrings("UNSUBSCRIBE_OK\n", resp);
}

// ── Persistent connection lifecycle ──

test "persistent connection stays alive across multiple commands" {
    const allocator = testing.allocator;
    const pipe_name = "\\\\.\\pipe\\zig-cp-test-persist-multi-cmd";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &testHandler, @ptrCast(&dummy));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-persist-multi-cmd");
    const client = try connectPersistClient(pipe_name_w);
    defer w.CloseHandle(client);

    var buf: [4096]u8 = undefined;

    try pipeSend(client, "PERSIST\n");
    const persist_resp = try pipeRecvLine(client, &buf);
    try testing.expect(std.mem.startsWith(u8, persist_resp, "OK|PERSIST"));

    try pipeSend(client, "PING\n");
    const ping_resp = try pipeRecvLine(client, &buf);
    try testing.expect(std.mem.startsWith(u8, ping_resp, "PONG"));

    try pipeSend(client, "PING\n");
    const ping_resp2 = try pipeRecvLine(client, &buf);
    try testing.expect(std.mem.startsWith(u8, ping_resp2, "PONG"));

    // SUBSCRIBE is a no-op stub but still works in persistent mode
    try pipeSend(client, "SUBSCRIBE|status\n");
    const sub_resp = try pipeRecvLine(client, &buf);
    try testing.expectEqualStrings("SUBSCRIBE_OK|status\n", sub_resp);
}
