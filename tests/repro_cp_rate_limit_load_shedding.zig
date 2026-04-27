//! Repro test for issue #211: CP input has no rate limit, allowing a runaway
//! client to silently swamp `enqueueInput` until the apprt's bounded queue
//! drops bytes mid-string. Pre-fix, **all** burst writes pass through and the
//! server returns `QUEUED|...` for each. Post-fix, write commands beyond the
//! per-client burst budget receive `ERR|RATE_LIMITED|<retry_ms>\n`, and a
//! second client gets an independent token bucket.
//!
//! Wire contract under test:
//!   * Burst of 20 INPUT requests on one persistent client must produce
//!     ≥ N successes (where N = configured burst, default 10) followed by
//!     ≥ 1 RATE_LIMITED responses.
//!   * After ~1s of idle, the bucket has refilled to ~2 tokens (sustained
//!     rate), so 2 more INPUT requests succeed.
//!   * A separate client opened after the first one is throttled still
//!     gets a fresh full burst (per-client identity = pipe instance).
//!
//! Wired into build.zig as `zig build repro-rate-limit`.

const std = @import("std");
const w = std.os.windows;
const k32 = w.kernel32;

const cp = @import("zig-control-plane");
const PipeServer = cp.pipe_server.PipeServer;

const HANDLE = w.HANDLE;
const DWORD = w.DWORD;
const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;

/// Echo handler: returns `QUEUED|test|INPUT|1\n` for any request so the
/// client can distinguish success from rate-limited responses.
fn echoQueuedHandler(_: []const u8, _: *anyopaque, allocator: std.mem.Allocator) []const u8 {
    return allocator.dupe(u8, "QUEUED|test|INPUT|1\n") catch return "";
}

const ERROR_BROKEN_PIPE: DWORD = 109;
const ERROR_NO_DATA: DWORD = 232;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) w.BOOL;

fn connect(pipe_name_w: [*:0]const u16) !HANDLE {
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
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        var avail: DWORD = 0;
        _ = PeekNamedPipe(pipe, null, 0, null, &avail, null);
        if (avail == 0) {
            const peek_err = @intFromEnum(w.kernel32.GetLastError());
            if (peek_err == ERROR_BROKEN_PIPE or peek_err == ERROR_NO_DATA) return error.BrokenPipe;
            std.Thread.sleep(2 * std.time.ns_per_ms);
            continue;
        }
        var bytes_read: DWORD = 0;
        const to_read: DWORD = @intCast(@min(buf.len - total, avail));
        const ok = k32.ReadFile(pipe, @ptrCast(buf.ptr + total), to_read, &bytes_read, null);
        if (ok == 0) return error.ReadFailed;
        if (bytes_read == 0) return error.BrokenPipe;
        total += bytes_read;
        if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |_| {
            return buf[0..total];
        }
    }
    if (total > 0) return buf[0..total];
    return error.Timeout;
}

fn sendAndClassify(pipe: HANDLE) !enum { ok, rate_limited } {
    try pipeSend(pipe, "INPUT|agent|aGk=\n");
    var buf: [256]u8 = undefined;
    const resp = try pipeRecvLine(pipe, &buf);
    if (std.mem.startsWith(u8, resp, "QUEUED")) return .ok;
    if (std.mem.startsWith(u8, resp, "ERR|RATE_LIMITED|")) return .rate_limited;
    std.debug.print("unexpected response: {s}\n", .{resp});
    return error.UnexpectedResponse;
}

// NOTE: do not factor server-startup into a helper that returns PipeServer
// by value — `serverThread` is spawned with a `*PipeServer` pointing into
// the helper's stack frame, which dangles after return-by-value. Each test
// inlines init/start to keep the address stable for the spawned thread.

var dummy_ctx: u8 = 0;

test "issue #211: per-client token bucket throttles burst of write commands" {
    const allocator = std.testing.allocator;

    // Defaults: burst=10, sustained=2/s. We send 20 INPUTs as fast as
    // possible on one client and require that ≥ 10 succeed and ≥ 1 trip
    // RATE_LIMITED. Pre-fix this is impossible (everything succeeds).
    const pipe_name = "\\\\.\\pipe\\zig-cp-test-issue-211-burst";
    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-issue-211-burst");
    var server = try PipeServer.init(allocator, pipe_name, &echoQueuedHandler, @ptrCast(&dummy_ctx));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const client = try connect(pipe_name_w);
    defer w.CloseHandle(client);

    try pipeSend(client, "PERSIST\n");
    var hs_buf: [128]u8 = undefined;
    _ = try pipeRecvLine(client, &hs_buf);

    var ok_count: usize = 0;
    var rl_count: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        switch (try sendAndClassify(client)) {
            .ok => ok_count += 1,
            .rate_limited => rl_count += 1,
        }
    }

    std.debug.print(
        "issue #211 burst result: ok={d} rate_limited={d}\n",
        .{ ok_count, rl_count },
    );
    try std.testing.expect(ok_count >= 10);
    try std.testing.expect(rl_count >= 1);
    try std.testing.expectEqual(@as(usize, 20), ok_count + rl_count);
}

test "issue #211: bucket refills to sustained rate after idle" {
    const allocator = std.testing.allocator;

    const pipe_name = "\\\\.\\pipe\\zig-cp-test-issue-211-refill";
    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-issue-211-refill");
    var server = try PipeServer.init(allocator, pipe_name, &echoQueuedHandler, @ptrCast(&dummy_ctx));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const client = try connect(pipe_name_w);
    defer w.CloseHandle(client);

    try pipeSend(client, "PERSIST\n");
    var hs_buf: [128]u8 = undefined;
    _ = try pipeRecvLine(client, &hs_buf);

    // Drain the burst.
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        _ = try sendAndClassify(client);
    }

    // Sleep ~1.2s — at 2 tokens/s that refills ≥ 2 tokens.
    std.Thread.sleep(1200 * std.time.ns_per_ms);

    var post_ok: usize = 0;
    i = 0;
    while (i < 2) : (i += 1) {
        if ((try sendAndClassify(client)) == .ok) post_ok += 1;
    }
    std.debug.print("issue #211 refill result: post_ok={d}/2\n", .{post_ok});
    try std.testing.expect(post_ok >= 2);
}

test "issue #211: independent token buckets per client" {
    const allocator = std.testing.allocator;

    const pipe_name = "\\\\.\\pipe\\zig-cp-test-issue-211-independent";
    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zig-cp-test-issue-211-independent");
    var server = try PipeServer.init(allocator, pipe_name, &echoQueuedHandler, @ptrCast(&dummy_ctx));
    defer server.deinit();
    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Client A drains its burst.
    const client_a = try connect(pipe_name_w);
    defer w.CloseHandle(client_a);
    try pipeSend(client_a, "PERSIST\n");
    var buf_a: [128]u8 = undefined;
    _ = try pipeRecvLine(client_a, &buf_a);
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        _ = try sendAndClassify(client_a);
    }

    // Client B opens after A is throttled. It should see a fresh full burst.
    const client_b = try connect(pipe_name_w);
    defer w.CloseHandle(client_b);
    try pipeSend(client_b, "PERSIST\n");
    var buf_b: [128]u8 = undefined;
    _ = try pipeRecvLine(client_b, &buf_b);

    var b_ok: usize = 0;
    i = 0;
    while (i < 5) : (i += 1) {
        if ((try sendAndClassify(client_b)) == .ok) b_ok += 1;
    }
    std.debug.print("issue #211 independent-bucket result: client_b ok={d}/5\n", .{b_ok});
    try std.testing.expectEqual(@as(usize, 5), b_ok);
}
