const std = @import("std");
const Allocator = std.mem.Allocator;

pub const protocol = @import("protocol.zig");
pub const tab_id = @import("tab_id.zig");
pub const session = @import("session.zig");
pub const utils = @import("utils.zig");

pub const pipe_server = @import("pipe_server.zig");

pub const Provider = struct {
    ctx: *anyopaque,
    readBuffer: *const fn (ctx: *anyopaque, tab_index: ?usize, buf: []u8) usize,
    sendInput: *const fn (ctx: *anyopaque, text: []const u8, raw: bool, tab_index: ?usize) void,
    tabCount: *const fn (ctx: *anyopaque) usize,
    activeTab: *const fn (ctx: *anyopaque) usize,
    tabTitle: *const fn (ctx: *anyopaque, index: usize, buf: []u8) usize,
    tabWorkingDir: *const fn (ctx: *anyopaque, index: usize, buf: []u8) usize,
    tabHasSelection: *const fn (ctx: *anyopaque, index: usize) bool,
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

        // Initial tab sync
        const count = provider.tabCount(provider.ctx);
        try tab_mgr.syncTabs(count);

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
        // pipe_server.start() will be added when Task 4 is merged
    }

    pub fn stop(self: *ControlPlane) void {
        // pipe_server.stop() will be added when Task 4 is merged
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

    /// Resolve tab, falling back to active tab if target is .none.
    fn resolveTabOrActive(self: *ControlPlane, target: protocol.TabTarget) usize {
        return self.resolveTab(target) orelse self.provider.activeTab(self.provider.ctx);
    }

    /// Core request dispatch — called by pipe server handler.
    pub fn handleRequest(self: *ControlPlane, request_line: []const u8) ![]u8 {
        const alloc = self.allocator;
        const ctx = self.provider.ctx;
        const p = self.provider;

        const request = protocol.parse(request_line) catch {
            return try protocol.formatError(alloc, self.session_name, "PARSE_ERROR");
        };

        switch (request) {
            .ping => {
                return try protocol.formatPong(alloc, self.session_name, self.pid, p.hwnd(ctx));
            },
            .state => |tab_target| {
                const tab_index = self.resolveTabOrActive(tab_target);
                var buf: [64 * 1024]u8 = undefined;
                const buf_len = p.readBuffer(ctx, tab_index, &buf);
                const buffer = buf[0..buf_len];

                var title_buf: [256]u8 = undefined;
                const title_len = p.tabTitle(ctx, tab_index, &title_buf);
                const title = title_buf[0..title_len];

                var pwd_buf: [1024]u8 = undefined;
                const pwd_len = p.tabWorkingDir(ctx, tab_index, &pwd_buf);
                const pwd = pwd_buf[0..pwd_len];

                const has_selection = p.tabHasSelection(ctx, tab_index);
                const prompt = utils.inferPrompt(buffer, pwd);
                const tab_count = p.tabCount(ctx);
                const active = p.activeTab(ctx);

                const tab_id_str = self.tab_mgr.getId(tab_index) orelse "?";

                // Compute content hash (FNV-1a 32-bit) of visible buffer
                const content_hash = std.hash.Fnv1a_32.hash(buffer);

                const base = try protocol.formatState(
                    alloc,
                    self.session_name,
                    self.pid,
                    p.hwnd(ctx),
                    title,
                    prompt,
                    has_selection,
                    pwd,
                    tab_count,
                    active,
                    tab_id_str,
                );
                defer alloc.free(base);

                // Heuristic terminal mode detection (Issue #13):
                // If inferPrompt detects a shell prompt, the terminal is likely in
                // cooked/canonical mode (normal shell). Otherwise, a TUI app is
                // probably running in raw mode (e.g., vim, Claude Code).
                const mode_str = if (prompt) "cooked" else "raw";

                // Append mode and content_hash fields.
                // base ends with "\n", strip it, append new fields, re-add "\n".
                const trimmed = std.mem.trimRight(u8, base, "\n");
                return try std.fmt.allocPrint(alloc, "{s}|mode={s}|content_hash={x:0>8}\n", .{ trimmed, mode_str, content_hash });
            },
            .tail => |t| {
                const tab_index = self.resolveTabOrActive(t.tab);
                var buf: [64 * 1024]u8 = undefined;
                const buf_len = p.readBuffer(ctx, tab_index, &buf);
                const buffer = buf[0..buf_len];
                const lines = utils.sliceLastLines(buffer, t.lines);

                // Count actual line count in the result
                var line_count: usize = 0;
                for (lines) |c| {
                    if (c == '\n') line_count += 1;
                }
                // If there's content without a trailing newline, that's also a line
                if (lines.len > 0 and lines[lines.len - 1] != '\n') {
                    line_count += 1;
                }

                return try protocol.formatTail(alloc, self.session_name, line_count, lines);
            },
            .list_tabs => {
                const tab_count = p.tabCount(ctx);
                try self.tab_mgr.syncTabs(tab_count);
                const active = p.activeTab(ctx);

                var result = std.ArrayListUnmanaged(u8){};
                errdefer result.deinit(alloc);

                const header = try protocol.formatListTabsHeader(alloc, tab_count, active);
                defer alloc.free(header);
                try result.appendSlice(alloc, header);

                var i: usize = 0;
                while (i < tab_count) : (i += 1) {
                    var title_buf: [256]u8 = undefined;
                    const title_len = p.tabTitle(ctx, i, &title_buf);
                    const title = title_buf[0..title_len];

                    var pwd_buf: [1024]u8 = undefined;
                    const pwd_len = p.tabWorkingDir(ctx, i, &pwd_buf);
                    const pwd = pwd_buf[0..pwd_len];

                    const has_selection = p.tabHasSelection(ctx, i);
                    const tab_id_str = self.tab_mgr.getId(i) orelse "?";

                    // Infer prompt for the active tab
                    var prompt = false;
                    if (i == active) {
                        var buf: [64 * 1024]u8 = undefined;
                        const buf_len = p.readBuffer(ctx, i, &buf);
                        prompt = utils.inferPrompt(buf[0..buf_len], pwd);
                    }

                    const line = try protocol.formatTabLine(alloc, i, tab_id_str, title, pwd, prompt, has_selection);
                    defer alloc.free(line);
                    try result.appendSlice(alloc, line);
                }

                return try result.toOwnedSlice(alloc);
            },
            .input => |inp| {
                const tab_index = self.resolveTab(inp.tab);
                p.sendInput(ctx, inp.payload, false, tab_index);
                // sendInput uses PostMessageW (fire-and-forget), so delivery is not confirmed.
                return try std.fmt.allocPrint(alloc, "QUEUED|{s}|INPUT\n", .{self.session_name});
            },
            .raw_input => |inp| {
                const tab_index = self.resolveTab(inp.tab);
                p.sendInput(ctx, inp.payload, true, tab_index);
                // sendInput uses PostMessageW (fire-and-forget), so delivery is not confirmed.
                return try std.fmt.allocPrint(alloc, "QUEUED|{s}|RAW_INPUT\n", .{self.session_name});
            },
            .paste => |inp| {
                const tab_index = self.resolveTab(inp.tab);
                // Wrap payload in bracketed paste mode: ESC[200~ + payload + ESC[201~ + CR
                const prefix = "\x1b[200~";
                const suffix = "\x1b[201~";
                var buf: [64 * 1024]u8 = undefined;
                const total = prefix.len + inp.payload.len + suffix.len;
                if (total > buf.len) return try protocol.formatError(alloc, self.session_name, "PASTE_TOO_LARGE");
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..][0..inp.payload.len], inp.payload);
                @memcpy(buf[prefix.len + inp.payload.len ..][0..suffix.len], suffix);
                p.sendInput(ctx, buf[0..total], true, tab_index);
                return try std.fmt.allocPrint(alloc, "QUEUED|{s}|PASTE\n", .{self.session_name});
            },
            .new_tab => {
                p.newTab(ctx);
                // newTab posts asynchronously (PostMessageW) so tabCount is stale here.
                // Return acknowledgement without claiming a specific tab ID.
                return try std.fmt.allocPrint(alloc, "OK|{s}|NEW_TAB\n", .{self.session_name});
            },
            .close_tab => |tab_target| {
                const tab_index = self.resolveTabOrActive(tab_target);
                self.tab_mgr.removeTabAtIndex(tab_index);
                p.closeTab(ctx, tab_index);
                return try std.fmt.allocPrint(alloc, "ACK|{s}|CLOSE_TAB|{d}\n", .{ self.session_name, tab_index });
            },
            .switch_tab => |tab_target| {
                const tab_index = self.resolveTabOrActive(tab_target);
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
            .subscribe, .unsubscribe => {
                // SUBSCRIBE/UNSUBSCRIBE are handled at the pipe_server level
                // (intercepted before reaching handleRequest). If we get here,
                // the client sent them outside a PERSIST connection.
                return try protocol.formatError(alloc, self.session_name, "subscribe_requires_persist");
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
};

var mock_state = MockState{};

fn mockReadBuffer(_: *anyopaque, _: ?usize, buf: []u8) usize {
    const src = mock_state.buffer;
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    return len;
}

var mock_input_buf: [64 * 1024]u8 = undefined;

fn mockSendInput(_: *anyopaque, text: []const u8, raw: bool, _: ?usize) void {
    @memcpy(mock_input_buf[0..text.len], text);
    mock_state.last_input = mock_input_buf[0..text.len];
    mock_state.last_input_raw = raw;
}

fn mockTabCount(_: *anyopaque) usize {
    return mock_state.tab_count;
}

fn mockActiveTab(_: *anyopaque) usize {
    return mock_state.active_tab;
}

fn mockTabTitle(_: *anyopaque, _: usize, buf: []u8) usize {
    const src = mock_state.title;
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    return len;
}

fn mockTabWorkingDir(_: *anyopaque, _: usize, buf: []u8) usize {
    const src = mock_state.pwd;
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    return len;
}

fn mockTabHasSelection(_: *anyopaque, _: usize) bool {
    return mock_state.has_selection;
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
    .readBuffer = &mockReadBuffer,
    .sendInput = &mockSendInput,
    .tabCount = &mockTabCount,
    .activeTab = &mockActiveTab,
    .tabTitle = &mockTabTitle,
    .tabWorkingDir = &mockTabWorkingDir,
    .tabHasSelection = &mockTabHasSelection,
    .newTab = &mockNewTab,
    .closeTab = &mockCloseTab,
    .switchTab = &mockSwitchTab,
    .focus = &mockFocus,
    .hwnd = &mockHwnd,
};

fn getMockProvider() *const Provider {
    // ctx can be anything since mock functions use the global mock_state
    mock_state = MockState{};
    var dummy: u8 = 0;
    mock_provider_storage.ctx = @ptrCast(&dummy);
    return &mock_provider_storage;
}

fn initTestCp() !ControlPlane {
    const prov = getMockProvider();
    // Bypass session manager by constructing directly
    var tab_mgr = tab_id.TabIdManager.init(std.testing.allocator);
    try tab_mgr.syncTabs(mock_state.tab_count);

    const owned_name = try std.testing.allocator.dupe(u8, "test-session");

    // Create a minimal SessionManager for testing
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
    // Should contain prompt=1 since mock buffer ends with "$ "
    try std.testing.expect(std.mem.indexOf(u8, resp, "prompt=1") != null);
    // Should contain mode=cooked (mock buffer ends with "$ " → prompt detected)
    try std.testing.expect(std.mem.indexOf(u8, resp, "|mode=cooked|") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "|content_hash=") != null);
    // content_hash should be 8 hex chars before the trailing newline
    const hash_start = std.mem.indexOf(u8, resp, "content_hash=").? + "content_hash=".len;
    const hash_end = std.mem.indexOfPos(u8, resp, hash_start, "\n") orelse resp.len;
    try std.testing.expectEqual(@as(usize, 8), hash_end - hash_start);
}

test "handleRequest TAIL" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("TAIL|5");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "TAIL|test-session|"));
}

test "handleRequest LIST_TABS" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("LIST_TABS");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.startsWith(u8, resp, "LIST_TABS|2|0"));
    // Should contain TAB lines
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

test "handleRequest PASTE" {
    var cp = try initTestCp();
    defer cp.deinit();
    // "aGVsbG8=" is base64 for "hello"
    var line = "PASTE|agent|aGVsbG8=".*;
    const resp = try cp.handleRequest(&line);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("QUEUED|test-session|PASTE\n", resp);
    // Verify the payload was wrapped in bracketed paste mode
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

test "handleRequest unknown command" {
    var cp = try initTestCp();
    defer cp.deinit();
    const resp = try cp.handleRequest("FOOBAR");
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "PARSE_ERROR") != null);
}
