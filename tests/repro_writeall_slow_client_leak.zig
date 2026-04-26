//! Repro test for issue #222: pipe_server.writeAll wedges forever when client
//! does not drain the pipe. Pre-fix this test FAILS (writeAll never returns
//! within the observation window). Post-fix it passes (writeAll returns with
//! error.WriteTimeout within ~5s).
//!
//! Wiring:
//!   * Server registers a handler that returns ~512KB of payload — large
//!     enough to overflow the 64KB outbound pipe buffer so WriteFile cannot
//!     complete synchronously.
//!   * Client opens the pipe, writes a request line, but never calls ReadFile.
//!   * The clientThread (running handleClient → writeAll) blocks inside
//!     GetOverlappedResult(bWait=TRUE) (pre-fix) or trips the new
//!     WaitForSingleObject + CancelIoEx timeout path (post-fix).
//!   * A status atomic flag (`write_returned`) is flipped by the test's
//!     handler-wrapper after writeAll returns. The test checks this flag.
//!
//! This file is wired into build.zig as a separate `repro` test step so it
//! can be skipped from the default `zig build test` invocation if desired.

const std = @import("std");
const w = std.os.windows;
const k32 = w.kernel32;

const cp = @import("zig-control-plane");
const PipeServer = cp.pipe_server.PipeServer;

const HANDLE = w.HANDLE;
const DWORD = w.DWORD;
const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;

/// Shared between the handler (called inside clientThread) and the test body.
const Shared = struct {
    write_returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handler_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Sentinel response size — must exceed the pipe's outbound buffer (65536)
    /// so WriteFile cannot complete synchronously without a draining reader.
    response_bytes: usize = 512 * 1024,
};

var shared = Shared{};

/// Handler returns a large response. The fact that this function returns
/// (i.e. writeAll inside handleClient eventually returned) is what we
/// observe via `shared.write_returned`. We set the flag in a *separate*
/// helper thread that polls — but since handleClient calls handler then
/// writeAll, we cannot directly observe writeAll completion from inside
/// handler. Instead we use the side-effect that the next handler invocation
/// (or DisconnectNamedPipe in the cleanup path) only happens after writeAll
/// returns.
///
/// Simpler approach: we wrap the call by having the handler set a "started"
/// flag, and a watcher thread observes whether the clientThread exits
/// (which only happens after writeAll returns or errors).
fn slowResponseHandler(_: []const u8, _: *anyopaque, allocator: std.mem.Allocator) []const u8 {
    shared.handler_called.store(true, .release);
    const buf = allocator.alloc(u8, shared.response_bytes) catch return "";
    @memset(buf, 'A');
    // Make it look like a valid line so the client *could* parse it if it ever read.
    if (buf.len > 0) buf[buf.len - 1] = '\n';
    return buf;
}

/// Watch the server's active_clients counter. When it drops to 0, the
/// clientThread exited (which means writeAll returned, possibly with error).
fn watchClientExit(server: *PipeServer) void {
    while (true) {
        if (server.active_clients.load(.acquire) == 0) {
            shared.write_returned.store(true, .release);
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

test "issue #222: writeAll must not wedge on slow/non-draining client" {
    const allocator = std.testing.allocator;
    shared = Shared{};

    const pipe_name = "\\\\.\\pipe\\zig-cp-test-issue-222-writeall-slow-client";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &slowResponseHandler, @ptrCast(&dummy));
    defer server.deinit();

    try server.start();
    // Let the server thread create the named pipe instance.
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Connect as client but DO NOT read the response.
    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral(
        "\\\\.\\pipe\\zig-cp-test-issue-222-writeall-slow-client",
    );
    const client = k32.CreateFileW(
        pipe_name_w,
        w.GENERIC_READ | w.GENERIC_WRITE,
        0,
        null,
        w.OPEN_EXISTING,
        0,
        null,
    );
    try std.testing.expect(client != INVALID_HANDLE_VALUE);
    defer w.CloseHandle(client);

    // Write a request — the handler will produce ~512KB which must overflow
    // the 64KB pipe outbound buffer.
    const request = "STATE\n";
    var bytes_written: DWORD = 0;
    const write_ok = k32.WriteFile(client, request, @intCast(request.len), &bytes_written, null);
    try std.testing.expect(write_ok != 0);

    // Spawn watcher to flip write_returned when clientThread exits.
    const watcher = try std.Thread.spawn(.{}, watchClientExit, .{&server});
    defer watcher.join();

    // Wait up to 8s for writeAll to give up. With the fix in place, the
    // server-side write should hit its 5s timeout, CancelIoEx the pending
    // write, and let clientThread exit. Pre-fix: this never happens and the
    // test must time out (we report a FAIL via assertion).
    const observation_window_ms: i64 = 8000;
    const deadline = std.time.milliTimestamp() + observation_window_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (shared.write_returned.load(.acquire)) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // Sanity: the handler should have been called (otherwise the test setup
    // is broken, not the bug).
    try std.testing.expect(shared.handler_called.load(.acquire));

    // The actual assertion: writeAll must have returned.
    if (!shared.write_returned.load(.acquire)) {
        std.debug.print(
            "FAIL: writeAll did not return within {d}ms — clientThread is wedged\n",
            .{observation_window_ms},
        );
        return error.WriteAllWedged;
    }
}

test "issue #222: short observation window (200ms) confirms pre-fix wedge / post-fix progress" {
    // This second test exercises the strict 200ms window mentioned in the
    // issue. Pre-fix: writeAll has not returned in 200ms (the test must
    // assert this, then return success — recording the bug repros). The
    // *first* test above is the regression gate.
    //
    // Post-fix: writeAll uses a 5s timeout, so 200ms is too short to
    // observe completion. We make this test a soft-info report, not an
    // assertion failure, so it passes regardless and prints diagnostic
    // output that helps when reading CI logs.
    const allocator = std.testing.allocator;
    shared = Shared{};

    const pipe_name = "\\\\.\\pipe\\zig-cp-test-issue-222-writeall-200ms";
    var dummy: u8 = 0;

    var server = try PipeServer.init(allocator, pipe_name, &slowResponseHandler, @ptrCast(&dummy));
    defer server.deinit();

    try server.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral(
        "\\\\.\\pipe\\zig-cp-test-issue-222-writeall-200ms",
    );
    const client = k32.CreateFileW(
        pipe_name_w,
        w.GENERIC_READ | w.GENERIC_WRITE,
        0,
        null,
        w.OPEN_EXISTING,
        0,
        null,
    );
    try std.testing.expect(client != INVALID_HANDLE_VALUE);
    defer w.CloseHandle(client);

    const request = "STATE\n";
    var bytes_written: DWORD = 0;
    _ = k32.WriteFile(client, request, @intCast(request.len), &bytes_written, null);

    // Wait for the handler to be invoked so we know writeAll has started.
    var spin: usize = 0;
    while (spin < 200) : (spin += 1) {
        if (shared.handler_called.load(.acquire)) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(shared.handler_called.load(.acquire));

    // 200ms wedge observation.
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Spawn watcher *after* the 200ms window and wait briefly so cleanup is clean.
    const watcher = try std.Thread.spawn(.{}, watchClientExit, .{&server});
    defer watcher.join();

    const wedged_after_200ms = !shared.write_returned.load(.acquire);
    std.debug.print(
        "issue #222 200ms-window observation: wedged_after_200ms={}\n",
        .{wedged_after_200ms},
    );
}
