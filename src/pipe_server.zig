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

        // Read request (up to 65536 bytes, 10s timeout)
        var buf: [65536]u8 = undefined;
        var overlapped = std.mem.zeroes(OVERLAPPED);
        overlapped.hEvent = event;

        _ = k32.ReadFile(pipe, &buf, 65536, null, &overlapped);

        const wait_result = k32.WaitForSingleObject(event, 10000);
        if (wait_result != WAIT_OBJECT_0) return;

        const bytes_read = w.GetOverlappedResult(pipe, &overlapped, false) catch return;
        if (bytes_read == 0) return;

        // Trim trailing whitespace/newline
        const raw = buf[0..bytes_read];
        const request = std.mem.trimRight(u8, raw, &[_]u8{ '\r', '\n', ' ', '\t' });
        if (request.len == 0) return;

        // Call handler
        const response = self.handler(request, self.ctx, self.allocator);
        defer self.allocator.free(response);

        // Write response (synchronous is fine for small responses)
        var written: DWORD = 0;
        _ = k32.WriteFile(pipe, response.ptr, @intCast(response.len), &written, null);
        _ = k32.FlushFileBuffers(pipe);
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
