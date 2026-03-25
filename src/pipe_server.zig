const std = @import("std");
const Allocator = std.mem.Allocator;
const w = std.os.windows;
const k32 = w.kernel32;

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

pub const PipeServer = struct {
    pipe_path_w: [:0]const u16,
    stop_flag: std.atomic.Value(bool),
    thread: ?std.Thread = null,
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
        self.thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    pub fn stop(self: *PipeServer) void {
        self.stop_flag.store(true, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
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
            self.serverIteration(&sa);
        }
    }

    /// Context passed to each client-handler thread.
    const ClientThreadCtx = struct {
        server: *PipeServer,
        pipe: HANDLE,
    };

    fn serverIteration(self: *PipeServer, sa: *SECURITY_ATTRIBUTES) void {
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
        if (pipe == INVALID_HANDLE_VALUE) return;

        // Create manual-reset event for overlapped I/O
        const event = w.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) catch {
            w.CloseHandle(pipe);
            return;
        };
        defer w.CloseHandle(event);

        var overlapped = std.mem.zeroes(OVERLAPPED);
        overlapped.hEvent = event;

        _ = ConnectNamedPipe(pipe, &overlapped);

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

        // Stopping — cancel pending connect
        _ = k32.CancelIoEx(pipe, &overlapped);
        _ = DisconnectNamedPipe(pipe);
        w.CloseHandle(pipe);
    }

    /// Runs on a dedicated thread per client. Owns the pipe handle.
    /// active_clients was already incremented before spawn.
    fn clientThread(ctx: *ClientThreadCtx) void {
        const self = ctx.server;
        const pipe = ctx.pipe;
        self.allocator.destroy(ctx);
        defer _ = self.active_clients.fetchSub(1, .acq_rel);
        defer {
            _ = DisconnectNamedPipe(pipe);
            w.CloseHandle(pipe);
        }
        self.handleClient(pipe);
    }

    fn handleClient(self: *PipeServer, pipe: HANDLE) void {
        const event = w.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) catch return;
        defer w.CloseHandle(event);

        var buf: [65536]u8 = undefined;
        var carry: [65536]u8 = undefined;
        var carry_len: usize = 0;
        var persistent = false;

        while (!self.stop_flag.load(.monotonic)) {
            // 1) Try to get a complete request line
            const request = self.readRequestLine(pipe, event, &buf, &carry, &carry_len, persistent) orelse {
                // null means disconnect, timeout (1-shot), or fatal error
                return;
            };

            // Empty line: in persistent mode just skip, in 1-shot mode we're done
            if (request.len == 0) {
                if (persistent) continue;
                return;
            }

            // 2) Check for PERSIST handshake
            if (std.mem.eql(u8, request, "PERSIST")) {
                persistent = true;
                writeAll(pipe, "OK|PERSIST\n");
                continue;
            }

            // 3) Dispatch to handler
            const response = self.handler(request, self.ctx, self.allocator);
            defer self.allocator.free(response);
            writeAll(pipe, response);

            if (!persistent) break; // legacy 1-shot mode
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
            _ = k32.ReadFile(pipe, buf, @intCast(space), null, &overlapped);

            const timeout: DWORD = if (persistent) 200 else 2000;
            const wait_result = k32.WaitForSingleObject(event, timeout);

            if (wait_result == WAIT_TIMEOUT) {
                _ = k32.CancelIoEx(pipe, &overlapped);
                if (persistent) {
                    // No data yet — return empty slice so caller can check stop_flag
                    return carry[0..0];
                }
                // 1-shot mode: for backward compat, treat buffered data as request
                if (carry_len.* > 0) {
                    const trimmed = std.mem.trimRight(u8, carry[0..carry_len.*], &[_]u8{ '\r', '\n', ' ', '\t' });
                    carry_len.* = 0;
                    return trimmed;
                }
                return null;
            }
            if (wait_result != WAIT_OBJECT_0) return null;

            const bytes_read = w.GetOverlappedResult(pipe, &overlapped, false) catch return null;
            if (bytes_read == 0) return null; // client disconnected

            // Append to carry buffer
            const new_total = carry_len.* + bytes_read;
            if (new_total > carry.len) return null; // overflow
            @memcpy(carry[carry_len.*..new_total], buf[0..bytes_read]);
            carry_len.* = new_total;

            // Loop back to try extractLine again
        }
    }

    /// Write all bytes to the pipe (synchronous).
    fn writeAll(pipe: HANDLE, data: []const u8) void {
        var written: DWORD = 0;
        _ = k32.WriteFile(pipe, data.ptr, @intCast(data.len), &written, null);
        _ = k32.FlushFileBuffers(pipe);
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
