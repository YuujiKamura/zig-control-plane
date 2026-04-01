const std = @import("std");
const Allocator = std.mem.Allocator;

pub const protocol = @import("protocol.zig");
pub const tab_id = @import("tab_id.zig");
pub const session = @import("session.zig");
pub const utils = @import("utils.zig");

pub const pipe_server = @import("pipe_server.zig");

const log = std.log.scoped(.control_plane);

/// Combined snapshot of tab state, captured in a single UI-thread round-trip.
/// All buffers are stack-allocated; no heap allocation required.
pub const CombinedSnapshot = struct {
    tab_count: usize = 0,
    active_tab: usize = 0,
    pwd: [4096]u8 = undefined,
    pwd_len: usize = 0,
    has_selection: bool = false,
    viewport: [65536]u8 = undefined,
    viewport_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,

    /// Clamp all length fields to their respective buffer sizes.
    /// Call after receiving snapshot data from an external provider to
    /// prevent out-of-bounds slicing even if the provider writes bad lengths.
    pub fn sanitize(self: *CombinedSnapshot) void {
        if (self.viewport_len > self.viewport.len) {
            log.warn("snapshot viewport_len {} exceeds buffer {}, clamping", .{ self.viewport_len, self.viewport.len });
            self.viewport_len = self.viewport.len;
        }
        if (self.pwd_len > self.pwd.len) {
            log.warn("snapshot pwd_len {} exceeds buffer {}, clamping", .{ self.pwd_len, self.pwd.len });
            self.pwd_len = self.pwd.len;
        }
        if (self.title_len > self.title.len) {
            log.warn("snapshot title_len {} exceeds buffer {}, clamping", .{ self.title_len, self.title.len });
            self.title_len = self.title.len;
        }
        if (self.active_tab >= self.tab_count and self.tab_count > 0) {
            log.warn("snapshot active_tab {} >= tab_count {}, clamping to 0", .{ self.active_tab, self.tab_count });
            self.active_tab = 0;
        }
    }
};

pub const Provider = struct {
    ctx: *anyopaque,
    /// Capture all tab state in one UI-thread call (Issue #142).
    /// This is the sole data-read path for STATE, TAIL, and LIST_TABS.
    captureSnapshot: *const fn (ctx: *anyopaque, tab_index: usize, result: *CombinedSnapshot) bool,
    /// Optional: capture full scrollback history. If null, falls back to captureSnapshot.
    captureHistory: ?*const fn (ctx: *anyopaque, tab_index: usize, result: *CombinedSnapshot) bool = null,
    /// Returns cmd_id for ACK tracking. 0 means no ACK needed.
    sendInput: *const fn (ctx: *anyopaque, text: []const u8, raw: bool, tab_index: ?usize) u32,
    /// Check if cmd_id has been drained (processed by UI thread). Returns true if ACKed.
    ackPoll: ?*const fn (ctx: *anyopaque, cmd_id: u32) bool = null,
    newTab: *const fn (ctx: *anyopaque) void,
    closeTab: *const fn (ctx: *anyopaque, index: usize) void,
    switchTab: *const fn (ctx: *anyopaque, index: usize) void,
    focus: *const fn (ctx: *anyopaque) void,
    hwnd: *const fn (ctx: *anyopaque) usize,
};

pub const ControlPlane = struct {
    allocator: Allocator,
    session_name: []const u8,
    pid: u32,
    provider: *const Provider,
    tab_mgr: tab_id.TabIdManager,
    sess_mgr: session.SessionManager,

    pub fn init(
        allocator: Allocator,
        session_name: []const u8,
        pipe_prefix: []const u8,
        app_name: []const u8,
        provider: *const Provider,
    ) !ControlPlane {
        _ = pipe_prefix; // Will be used when pipe_server is integrated
        const pid = getCurrentPid();

        // Build pipe path for session manager
        const safe_name = try session.sanitizeSessionName(allocator, session_name);
        defer allocator.free(safe_name);
        const pipe_path = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\{s}-{s}-{d}", .{ app_name, safe_name, pid });
        defer allocator.free(pipe_path);

        var sess_mgr = try session.SessionManager.init(allocator, session_name, pipe_path, app_name);
        errdefer sess_mgr.deinit();

        var tab_mgr = tab_id.TabIdManager.init(allocator);
        errdefer tab_mgr.deinit();

        // Initial tab sync via snapshot (tab_index=0 is safe; we only need tab_count)
        var snap: CombinedSnapshot = .{};
        _ = provider.captureSnapshot(provider.ctx, 0, &snap);
        snap.sanitize();
        try tab_mgr.syncTabs(snap.tab_count);

        const owned_name = try allocator.dupe(u8, session_name);

        return ControlPlane{
            .allocator = allocator,
            .session_name = owned_name,
            .pid = pid,
            .provider = provider,
            .tab_mgr = tab_mgr,
            .sess_mgr = sess_mgr,
        };
    }

    pub fn start(self: *ControlPlane) !void {
        const hwnd_val = self.provider.hwnd(self.provider.ctx);
        try self.sess_mgr.writeFile(hwnd_val);
    }

    pub fn stop(self: *ControlPlane) void {
        self.sess_mgr.removeFile();
    }

    pub fn deinit(self: *ControlPlane) void {
        self.allocator.free(self.session_name);
        self.tab_mgr.deinit();
        self.sess_mgr.deinit();
        self.* = undefined;
    }

    /// Resolve a TabTarget to a concrete tab index.
    fn resolveTab(self: *ControlPlane, target: protocol.TabTarget) ?usize {
        return switch (target) {
            .none => null,
            .index => |i| i,
            .id => |id| self.tab_mgr.resolve(id),
        };
    }

    /// Resolve tab, falling back to active tab via snapshot.
    /// Returns null if tab_count is 0 (no tabs available).
    fn resolveTabOrActive(self: *ControlPlane, target: protocol.TabTarget) ?usize {
        if (self.resolveTab(target)) |idx| return idx;
        var snap: CombinedSnapshot = .{};
        _ = self.provider.captureSnapshot(self.provider.ctx, 0, &snap);
        snap.sanitize();
        if (snap.tab_count == 0) return null;
        return snap.active_tab;
    }

    /// Core request dispatch -- called by pipe server handler.
    /// Never panics. Returns an ERROR response on OOM or internal errors.
    pub fn handleRequest(self: *ControlPlane, request_line: []const u8) ![]u8 {
        return self.handleRequestInner(request_line) catch |err| {
            log.err("handleRequest failed: {}", .{err});
            return protocol.formatError(self.allocator, self.session_name, "INTERNAL_ERROR");
        };
    }

    fn handleRequestInner(self: *ControlPlane, request_line: []const u8) ![]u8 {
        const alloc = self.allocator;
        const ctx = self.provider.ctx;
        const p = self.provider;

        const request = protocol.parse(request_line) catch {
            log.warn("failed to parse request: {s}", .{request_line});
            return try protocol.formatError(alloc, self.session_name, "PARSE_ERROR");
        };

        switch (request) {
            .ping => {
                return try protocol.formatPong(alloc, self.session_name, self.pid, p.hwnd(ctx));
            },
            .state => |tab_target| {
                const tab_index = self.resolveTabOrActive(tab_target) orelse {
                    log.warn("STATE: no tabs available", .{});
                    return try protocol.formatError(alloc, self.session_name, "NO_TABS");
                };

                var snap: CombinedSnapshot = .{};
                if (!p.captureSnapshot(ctx, tab_index, &snap)) {
                    log.warn("STATE: captureSnapshot returned false for tab {}", .{tab_index});
                    return try protocol.formatError(alloc, self.session_name, "SNAPSHOT_FAILED");
                }
                snap.sanitize();

                const buffer = snap.viewport[0..snap.viewport_len];
                const title = snap.title[0..snap.title_len];
                const pwd = snap.pwd[0..snap.pwd_len];
                const prompt = utils.inferPrompt(buffer, pwd);
                const tab_id_str = self.tab_mgr.getId(tab_index) orelse "?";
                const content_hash = std.hash.Fnv1a_32.hash(buffer);

                const base = try protocol.formatState(
                    alloc,
                    self.session_name,
                    self.pid,
                    p.hwnd(ctx),
                    title,
                    prompt,
                    snap.has_selection,
                    pwd,
                    snap.tab_count,
                    snap.active_tab,
                    tab_id_str,
                );
                defer alloc.free(base);

                const mode_str = if (prompt) "cooked" else "raw";
                const trimmed = std.mem.trimRight(u8, base, "\n");
                return try std.fmt.allocPrint(alloc, "{s}|mode={s}|content_hash={x:0>8}\n", .{ trimmed, mode_str, content_hash });
            },
            .tail => |t| {
                const tab_index = self.resolveTabOrActive(t.tab) orelse {
                    log.warn("TAIL: no tabs available", .{});
                    return try protocol.formatError(alloc, self.session_name, "NO_TABS");
                };

                var snap: CombinedSnapshot = .{};
                if (!p.captureSnapshot(ctx, tab_index, &snap)) {
                    log.warn("TAIL: captureSnapshot returned false for tab {}", .{tab_index});
                    return try protocol.formatError(alloc, self.session_name, "SNAPSHOT_FAILED");
                }
                snap.sanitize();

                const buffer = snap.viewport[0..snap.viewport_len];
                const lines = utils.sliceLastLines(buffer, t.lines);

                var line_count: usize = 0;
                for (lines) |c| {
                    if (c == '\n') line_count += 1;
                }
                if (lines.len > 0 and lines[lines.len - 1] != '\n') {
                    line_count += 1;
                }

                return try protocol.formatTail(alloc, self.session_name, line_count, lines);
            },
            .history => |h| {
                const tab_index = self.resolveTabOrActive(h.tab) orelse {
                    log.warn("HISTORY: no tabs available", .{});
                    return try protocol.formatError(alloc, self.session_name, "NO_TABS");
                };

                var snap: CombinedSnapshot = .{};
                const captured = if (p.captureHistory) |captureHistoryFn|
                    captureHistoryFn(ctx, tab_index, &snap)
                else
                    p.captureSnapshot(ctx, tab_index, &snap);

                if (!captured) {
                    log.warn("HISTORY: capture returned false for tab {}", .{tab_index});
                    return try protocol.formatError(alloc, self.session_name, "SNAPSHOT_FAILED");
                }
                snap.sanitize();

                const buffer = snap.viewport[0..snap.viewport_len];
                const lines = if (h.lines > 0) utils.sliceLastLines(buffer, h.lines) else buffer;

                var line_count: usize = 0;
                for (lines) |c| {
                    if (c == '\n') line_count += 1;
                }
                if (lines.len > 0 and lines[lines.len - 1] != '\n') {
                    line_count += 1;
                }

                return try protocol.formatHistory(alloc, self.session_name, line_count, lines);
            },
            .list_tabs => {
                var meta_snap: CombinedSnapshot = .{};
                _ = p.captureSnapshot(ctx, 0, &meta_snap);
                meta_snap.sanitize();
                const tab_count = meta_snap.tab_count;
                const active = meta_snap.active_tab;

                try self.tab_mgr.syncTabs(tab_count);

                var result = std.ArrayListUnmanaged(u8){};
                errdefer result.deinit(alloc);

                const header = try protocol.formatListTabsHeader(alloc, tab_count, active);
                defer alloc.free(header);
                try result.appendSlice(alloc, header);

                var i: usize = 0;
                while (i < tab_count) : (i += 1) {
                    var tab_snap: CombinedSnapshot = .{};
                    _ = p.captureSnapshot(ctx, i, &tab_snap);
                    tab_snap.sanitize();

                    const title = tab_snap.title[0..tab_snap.title_len];
                    const pwd = tab_snap.pwd[0..tab_snap.pwd_len];
                    const has_selection = tab_snap.has_selection;
                    const tab_id_str = self.tab_mgr.getId(i) orelse "?";

                    var prompt = false;
                    if (i == active) {
                        const viewport = tab_snap.viewport[0..tab_snap.viewport_len];
                        prompt = utils.inferPrompt(viewport, pwd);
                    }

                    const line = try protocol.formatTabLine(alloc, i, tab_id_str, title, pwd, prompt, has_selection);
                    defer alloc.free(line);
                    try result.appendSlice(alloc, line);
                }

                return try result.toOwnedSlice(alloc);
            },
            .input => |inp| {
                const tab_index = self.resolveTab(inp.tab);
                const cmd_id = p.sendInput(ctx, inp.payload, false, tab_index);
                return try std.fmt.allocPrint(alloc, "QUEUED|{s}|INPUT|{d}\n", .{ self.session_name, cmd_id });
            },
            .raw_input => |inp| {
                const tab_index = self.resolveTab(inp.tab);
                const cmd_id = p.sendInput(ctx, inp.payload, true, tab_index);
                return try std.fmt.allocPrint(alloc, "QUEUED|{s}|RAW_INPUT|{d}\n", .{ self.session_name, cmd_id });
            },
            .paste => |inp| {
                const tab_index = self.resolveTab(inp.tab);
                const prefix = "\x1b[200~";
                const suffix = "\x1b[201~";
                var buf: [64 * 1024]u8 = undefined;
                const total = prefix.len + inp.payload.len + suffix.len;
                if (total > buf.len) return try protocol.formatError(alloc, self.session_name, "PASTE_TOO_LARGE");
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..][0..inp.payload.len], inp.payload);
                @memcpy(buf[prefix.len + inp.payload.len ..][0..suffix.len], suffix);
                const cmd_id = p.sendInput(ctx, buf[0..total], true, tab_index);
                return try std.fmt.allocPrint(alloc, "QUEUED|{s}|PASTE|{d}\n", .{ self.session_name, cmd_id });
            },
            .new_tab => {
                p.newTab(ctx);
                return try std.fmt.allocPrint(alloc, "OK|{s}|NEW_TAB\n", .{self.session_name});
            },
            .close_tab => |tab_target| {
                const tab_index = self.resolveTabOrActive(tab_target) orelse {
                    log.warn("CLOSE_TAB: no tabs available", .{});
                    return try protocol.formatError(alloc, self.session_name, "NO_TABS");
                };
                self.tab_mgr.removeTabAtIndex(tab_index);
                p.closeTab(ctx, tab_index);
                return try std.fmt.allocPrint(alloc, "ACK|{s}|CLOSE_TAB|{d}\n", .{ self.session_name, tab_index });
            },
            .switch_tab => |tab_target| {
                const tab_index = self.resolveTabOrActive(tab_target) orelse {
                    log.warn("SWITCH_TAB: no tabs available", .{});
                    return try protocol.formatError(alloc, self.session_name, "NO_TABS");
                };
                p.switchTab(ctx, tab_index);
                return try std.fmt.allocPrint(alloc, "ACK|{s}|SWITCH_TAB|{d}\n", .{ self.session_name, tab_index });
            },
            .focus => {
                p.focus(ctx);
                return try std.fmt.allocPrint(alloc, "ACK|{s}|FOCUS\n", .{self.session_name});
            },
            .msg => {
                return try protocol.formatAck(alloc, self.session_name, self.pid);
            },
            .agent_status, .set_agent => {
                return try protocol.formatError(alloc, self.session_name, "deprecated");
            },
            .subscribe => {
                return try std.fmt.allocPrint(alloc, "SUBSCRIBE_OK|status\n", .{});
            },
            .unsubscribe => {
                return try std.fmt.allocPrint(alloc, "UNSUBSCRIBE_OK\n", .{});
            },
            .ack_poll => |cmd_id| {
                if (p.ackPoll) |poll_fn| {
                    const acked = poll_fn(ctx, cmd_id);
                    if (acked) {
                        return try std.fmt.allocPrint(alloc, "ACK|{s}|{d}\n", .{ self.session_name, cmd_id });
                    } else {
                        return try std.fmt.allocPrint(alloc, "NACK|{s}|{d}\n", .{ self.session_name, cmd_id });
                    }
                } else {
                    return try protocol.formatError(alloc, self.session_name, "ACK_POLL not supported");
                }
            },
        }
    }
};

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn getCurrentPid() u32 {
    if (@import("builtin").os.tag == .windows) {
        return GetCurrentProcessId();
    } else {
        return @intCast(std.posix.getpid());
    }
}

// ── Tests ──

test {
    _ = protocol;
    _ = tab_id;
    _ = session;
    _ = pipe_server;
    _ = utils;
}

// ── Mock Provider for testing ──

const MockState = struct {
    buffer: []const u8 = "user@host:~$ ",
    title: []const u8 = "bash",
    pwd: []const u8 = "/home/user",
    tab_count: usize = 2,
    active_tab: usize = 0,
    has_selection: bool = false,
    hwnd_val: usize = 0xCAFE,
    last_input: ?[]const u8 = null,
    last_input_raw: bool = false,
    new_tab_called: bool = false,
    close_tab_called: ?usize = null,
    switch_tab_called: ?usize = null,
    focus_called: bool = false,
    snapshot_fail: bool = false,
};

var mock_state = MockState{};
var mock_input_buf: [64 * 1024]u8 = undefined;

fn mockSendInput(_: *anyopaque, text: []const u8, raw: bool, _: ?usize) u32 {
    @memcpy(mock_input_buf[0..text.len], text);
    mock_state.last_input = mock_input_buf[0..text.len];
    mock_state.last_input_raw = raw;
    return 1; // mock cmd_id
}

fn mockCaptureSnapshot(_: *anyopaque, _: usize, result: *CombinedSnapshot) bool {
    if (mock_state.snapshot_fail) return false;

    const src_buf = mock_state.buffer;
    const buf_len = @min(src_buf.len, result.viewport.len);
    @memcpy(result.viewport[0..buf_len], src_buf[0..buf_len]);
    result.viewport_len = buf_len;

    const src_title = mock_state.title;
    const title_len = @min(src_title.len, result.title.len);
    @memcpy(result.title[0..title_len], src_title[0..title_len]);
    result.title_len = title_len;

    const src_pwd = mock_state.pwd;
    const pwd_len = @min(src_pwd.len, result.pwd.len);
    @memcpy(result.pwd[0..pwd_len], src_pwd[0..pwd_len]);
    result.pwd_len = pwd_len;

    result.has_selection = mock_state.has_selection;
    result.tab_count = mock_state.tab_count;
    result.active_tab = mock_state.active_tab;
    return true;
}

fn mockNewTab(_: *anyopaque) void {
    mock_state.new_tab_called = true;
    mock_state.tab_count += 1;
}

fn mockCloseTab(_: *anyopaque, index: usize) void {
    mock_state.close_tab_called = index;
    if (mock_state.tab_count > 0) mock_state.tab_count -= 1;
}

fn mockSwitchTab(_: *anyopaque, index: usize) void {
    mock_state.switch_tab_called = index;
}

fn mockFocus(_: *anyopaque) void {
    mock_state.focus_called = true;
}

fn mockHwnd(_: *anyopaque) usize {
    return mock_state.hwnd_val;
}

var mock_provider_storage = Provider{
    .ctx = undefined,
    .captureSnapshot = &mockCaptureSnapshot,
    .sendInput = &mockSendInput,
    .newTab = &mockNewTab,
    .closeTab = &mockCloseTab,
    .switchTab = &mockSwitchTab,
    .focus = &mockFocus,
    .hwnd = &mockHwnd,
};

fn getMockProvider() *const Provider {
    mock_state = MockState{};
    var dummy: u8 = 0;
    mock_provider_storage.ctx = @ptrCast(&dummy);
    return &mock_provider_storage;
}

fn initTestCp() !ControlPlane {
    const prov = getMockProvider();
    var tab_mgr = tab_id.TabIdManager.init(std.testing.allocator);
    try tab_mgr.syncTabs(mock_state.tab_count);

    const owned_name = try std.testing.allocator.dupe(u8, "test-session");

    var tmp_dir = std.testing.tmpDir(.{});
    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const session_file = try std.fmt.allocPrint(std.testing.allocator, "{s}/test-{d}.session", .{ tmp_path, @as(u32, 0) });
    tmp_dir.cleanup();

    const sess_mgr = session.SessionManager{
        .session_name = try std.testing.allocator.dupe(u8, "test-session"),
        .safe_session_name = try std.testing.allocator.dupe(u8, "test-session"),
        .pid = 0,
        .pipe_path = try std.testing.allocator.dupe(u8, "\\\\.\\pipe\\test"),
        .session_file_path = session_file,
        .allocator = std.testing.allocator,
    };

    return ControlPlane{
        .allocator = std.testing.allocator,
        .session_name = owned_name,
        .pid = 12345,
        .provider = prov,
        .tab_mgr = tab_mgr,
        .sess_mgr = sess_mgr,
    };
}

test "handleRequest PING" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("PING");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "PONG|test-session|"));
}

test "handleRequest STATE" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("STATE");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "STATE|test-session|"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "prompt=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "|mode=cooked|") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "|content_hash=") != null);
    const hash_start = std.mem.indexOf(u8, resp, "content_hash=").? + "content_hash=".len;
    const hash_end = std.mem.indexOfPos(u8, resp, hash_start, "\n") orelse resp.len;
    try std.testing.expectEqual(@as(usize, 8), hash_end - hash_start);
}

test "handleRequest STATE snapshot_fail returns SNAPSHOT_FAILED" {
    var cp = try initTestCp();
    defer cp.deinit();
    mock_state.snapshot_fail = true;
    // Use explicit tab index to bypass resolveTabOrActive (which also calls captureSnapshot)
    const resp = try cp.handleRequest("STATE|0");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "SNAPSHOT_FAILED") != null);
}

test "handleRequest STATE zero tabs returns NO_TABS" {
    var cp = try initTestCp();
    defer cp.deinit();
    mock_state.tab_count = 0;
    const resp = try cp.handleRequest("STATE");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "NO_TABS") != null);
}

test "handleRequest TAIL" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("TAIL|5");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "TAIL|test-session|"));
}

test "handleRequest TAIL snapshot_fail returns SNAPSHOT_FAILED" {
    var cp = try initTestCp();
    defer cp.deinit();
    mock_state.snapshot_fail = true;
    // Use explicit tab index to bypass resolveTabOrActive
    const resp = try cp.handleRequest("TAIL|5|0");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "SNAPSHOT_FAILED") != null);
}

test "handleRequest LIST_TABS" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("LIST_TABS");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "LIST_TABS|2|0"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "TAB|0|") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "TAB|1|") != null);
}

test "handleRequest FOCUS" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("FOCUS");
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("ACK|test-session|FOCUS\n", resp);
    try std.testing.expect(mock_state.focus_called);
}

test "handleRequest NEW_TAB" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("NEW_TAB");
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("OK|test-session|NEW_TAB\n", resp);
    try std.testing.expect(mock_state.new_tab_called);
}

test "handleRequest SWITCH_TAB" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("SWITCH_TAB|1");
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("ACK|test-session|SWITCH_TAB|1\n", resp);
    try std.testing.expectEqual(@as(?usize, 1), mock_state.switch_tab_called);
}

test "handleRequest CLOSE_TAB" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("CLOSE_TAB|0");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "ACK|test-session|CLOSE_TAB|0"));
    try std.testing.expectEqual(@as(?usize, 0), mock_state.close_tab_called);
}

test "handleRequest CLOSE_TAB zero tabs returns NO_TABS" {
    var cp = try initTestCp();
    defer cp.deinit();
    mock_state.tab_count = 0;
    // Use id=nonexistent so resolveTab returns null, then snapshot shows tab_count=0 -> NO_TABS
    const resp = try cp.handleRequest("CLOSE_TAB|id=nonexistent");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "NO_TABS") != null);
}

test "handleRequest PASTE" {
    var cp = try initTestCp();
    defer cp.deinit();
    var line = "PASTE|agent|aGVsbG8=".*;
    const resp = try cp.handleRequest(&line);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("QUEUED|test-session|PASTE|1\n", resp);
    const expected = "\x1b[200~hello\x1b[201~";
    try std.testing.expectEqualStrings(expected, mock_state.last_input.?);
    try std.testing.expect(mock_state.last_input_raw);
}

test "handleRequest deprecated commands" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp1 = try cp.handleRequest("AGENT_STATUS");
    defer std.testing.allocator.free(resp1);
    try std.testing.expect(std.mem.indexOf(u8, resp1, "deprecated") != null);

    const resp2 = try cp.handleRequest("SET_AGENT|0|claude");
    defer std.testing.allocator.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "deprecated") != null);
}

test "handleRequest HISTORY falls back to captureSnapshot" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("HISTORY");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HISTORY|test-session|"));
}

test "handleRequest HISTORY with lines" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("HISTORY|5");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HISTORY|test-session|"));
}

test "handleRequest HISTORY snapshot_fail returns SNAPSHOT_FAILED" {
    var cp = try initTestCp();
    defer cp.deinit();
    mock_state.snapshot_fail = true;
    const resp = try cp.handleRequest("HISTORY|0|0");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "SNAPSHOT_FAILED") != null);
}

test "handleRequest HISTORY zero tabs returns NO_TABS" {
    var cp = try initTestCp();
    defer cp.deinit();
    mock_state.tab_count = 0;
    const resp = try cp.handleRequest("HISTORY");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "NO_TABS") != null);
}

test "handleRequest unknown command" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("FOOBAR");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "PARSE_ERROR") != null);
}

test "CombinedSnapshot sanitize clamps overflow" {
    var snap: CombinedSnapshot = .{};
    snap.viewport_len = 999999;
    snap.pwd_len = 99999;
    snap.title_len = 99999;
    snap.tab_count = 3;
    snap.active_tab = 5;
    snap.sanitize();
    try std.testing.expectEqual(snap.viewport.len, snap.viewport_len);
    try std.testing.expectEqual(snap.pwd.len, snap.pwd_len);
    try std.testing.expectEqual(snap.title.len, snap.title_len);
    try std.testing.expectEqual(@as(usize, 0), snap.active_tab);
}

test "CombinedSnapshot sanitize no-op when valid" {
    var snap: CombinedSnapshot = .{};
    snap.viewport_len = 100;
    snap.pwd_len = 10;
    snap.title_len = 5;
    snap.tab_count = 2;
    snap.active_tab = 1;
    snap.sanitize();
    try std.testing.expectEqual(@as(usize, 100), snap.viewport_len);
    try std.testing.expectEqual(@as(usize, 10), snap.pwd_len);
    try std.testing.expectEqual(@as(usize, 5), snap.title_len);
    try std.testing.expectEqual(@as(usize, 1), snap.active_tab);
}
