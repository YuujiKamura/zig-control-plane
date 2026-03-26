const std = @import("std");
const Allocator = std.mem.Allocator;
const base64 = std.base64.standard;

pub const TabTarget = union(enum) {
    none,
    index: usize,
    id: []const u8,

    pub fn parse(field: []const u8) TabTarget {
        if (field.len == 0) return .none;
        if (field.len > 3 and std.mem.startsWith(u8, field, "id=")) {
            return .{ .id = field[3..] };
        }
        const idx = std.fmt.parseInt(usize, field, 10) catch return .none;
        return .{ .index = idx };
    }
};

pub const Request = union(enum) {
    ping,
    state: TabTarget,
    tail: struct { lines: usize = 20, tab: TabTarget = .none },
    list_tabs,
    input: struct { from: []const u8, payload: []const u8, tab: TabTarget = .none },
    raw_input: struct { from: []const u8, payload: []const u8, tab: TabTarget = .none },
    paste: struct { from: []const u8, payload: []const u8, tab: TabTarget = .none },
    new_tab,
    close_tab: TabTarget,
    switch_tab: TabTarget,
    focus,
    msg: []const u8,
    agent_status,
    set_agent: struct { tab: TabTarget, agent_type: []const u8 },
};

pub const ParseError = error{
    UnknownCommand,
    MissingField,
    InvalidBase64,
    OutOfMemory,
};

/// Decode base64 in-place, returning a slice of the decoded bytes within the
/// provided buffer. The source and destination may alias because base64 output
/// is always shorter than (or equal to) the input.
fn decodeBase64Inplace(encoded: []const u8, buf: []u8) ParseError![]const u8 {
    const decoder = base64.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch return ParseError.InvalidBase64;
    if (len > buf.len) return ParseError.InvalidBase64;
    decoder.decode(buf[0..len], encoded) catch return ParseError.InvalidBase64;
    return buf[0..len];
}

pub fn parse(line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '|');
    const cmd = it.first();

    if (std.mem.eql(u8, cmd, "PING")) return .ping;
    if (std.mem.eql(u8, cmd, "LIST_TABS")) return .list_tabs;
    if (std.mem.eql(u8, cmd, "NEW_TAB")) return .new_tab;
    if (std.mem.eql(u8, cmd, "FOCUS")) return .focus;
    if (std.mem.eql(u8, cmd, "AGENT_STATUS")) return .agent_status;

    if (std.mem.eql(u8, cmd, "STATE")) {
        const field = it.next() orelse return .{ .state = .none };
        return .{ .state = TabTarget.parse(field) };
    }

    if (std.mem.eql(u8, cmd, "TAIL")) {
        const first = it.next() orelse return .{ .tail = .{ .lines = 20, .tab = .none } };
        // first field could be lines count or tab target
        if (std.fmt.parseInt(usize, first, 10)) |lines| {
            const tab_field = it.next() orelse return .{ .tail = .{ .lines = lines, .tab = .none } };
            return .{ .tail = .{ .lines = lines, .tab = TabTarget.parse(tab_field) } };
        } else |_| {
            return .{ .tail = .{ .lines = 20, .tab = TabTarget.parse(first) } };
        }
    }

    if (std.mem.eql(u8, cmd, "INPUT") or std.mem.eql(u8, cmd, "RAW_INPUT") or std.mem.eql(u8, cmd, "PASTE")) {
        const from = it.next() orelse return ParseError.MissingField;
        const encoded = it.next() orelse return ParseError.MissingField;
        const tab_field = it.next();

        // Decode base64 in-place: we reinterpret the encoded slice's memory.
        // This is safe because the encoded data is part of the input line buffer
        // and the decoded output is always <= the encoded length.
        const payload = decodeBase64Inplace(encoded, @constCast(encoded)) catch return ParseError.InvalidBase64;

        const tab = if (tab_field) |f| TabTarget.parse(f) else TabTarget.none;

        if (std.mem.eql(u8, cmd, "INPUT")) {
            return .{ .input = .{ .from = from, .payload = payload, .tab = tab } };
        } else if (std.mem.eql(u8, cmd, "PASTE")) {
            return .{ .paste = .{ .from = from, .payload = payload, .tab = tab } };
        } else {
            return .{ .raw_input = .{ .from = from, .payload = payload, .tab = tab } };
        }
    }

    if (std.mem.eql(u8, cmd, "CLOSE_TAB")) {
        const field = it.next() orelse return ParseError.MissingField;
        return .{ .close_tab = TabTarget.parse(field) };
    }

    if (std.mem.eql(u8, cmd, "SWITCH_TAB")) {
        const field = it.next() orelse return ParseError.MissingField;
        return .{ .switch_tab = TabTarget.parse(field) };
    }

    if (std.mem.eql(u8, cmd, "MSG")) {
        const field = it.next() orelse return ParseError.MissingField;
        return .{ .msg = field };
    }

    if (std.mem.eql(u8, cmd, "SET_AGENT")) {
        const tab_field = it.next() orelse return ParseError.MissingField;
        const agent_type = it.next() orelse return ParseError.MissingField;
        return .{ .set_agent = .{ .tab = TabTarget.parse(tab_field), .agent_type = agent_type } };
    }

    return ParseError.UnknownCommand;
}

// ── Response formatting ──

pub fn escapeField(input: []const u8, buf: []u8) usize {
    var i: usize = 0;
    for (input) |c| {
        if (i >= buf.len) break;
        buf[i] = switch (c) {
            '|', '\n', '\r' => ' ',
            else => c,
        };
        i += 1;
    }
    return i;
}

pub fn formatPong(alloc: Allocator, session_name: []const u8, pid: u32, hwnd: usize) ![]u8 {
    return std.fmt.allocPrint(alloc, "PONG|{s}|{d}|0x{X}\n", .{ session_name, pid, hwnd });
}

pub fn formatAck(alloc: Allocator, session_name: []const u8, pid: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "ACK|{s}|{d}\n", .{ session_name, pid });
}

pub fn formatError(alloc: Allocator, session_name: []const u8, code: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "ERR|{s}|{s}\n", .{ session_name, code });
}

pub fn formatTail(alloc: Allocator, session_name: []const u8, lines_count: usize, buffer: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "TAIL|{s}|{d}\n{s}", .{ session_name, lines_count, buffer });
}

pub fn formatListTabsHeader(alloc: Allocator, tab_count: usize, active_tab: usize) ![]u8 {
    return std.fmt.allocPrint(alloc, "LIST_TABS|{d}|{d}\n", .{ tab_count, active_tab });
}

pub fn formatTabLine(
    alloc: Allocator,
    index: usize,
    tab_id: []const u8,
    title: []const u8,
    pwd: []const u8,
    prompt: bool,
    selection: bool,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "TAB|{d}|{s}|{s}|pwd={s}|prompt={d}|selection={d}\n", .{
        index,
        tab_id,
        title,
        pwd,
        @as(u8, if (prompt) 1 else 0),
        @as(u8, if (selection) 1 else 0),
    });
}

pub fn formatState(
    alloc: Allocator,
    session_name: []const u8,
    pid: u32,
    hwnd: usize,
    title: []const u8,
    prompt: bool,
    selection: bool,
    pwd: []const u8,
    tab_count: usize,
    active_tab: usize,
    tab_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "STATE|{s}|{d}|0x{X}|{s}|prompt={d}|selection={d}|pwd={s}|tab_count={d}|active_tab={d}|tab_id={s}\n", .{
        session_name,
        pid,
        hwnd,
        title,
        @as(u8, if (prompt) 1 else 0),
        @as(u8, if (selection) 1 else 0),
        pwd,
        tab_count,
        active_tab,
        tab_id,
    });
}

// ── Tests ──

test "parse PING" {
    const req = try parse("PING");
    try std.testing.expect(req == .ping);
}

test "parse STATE with id" {
    const req = try parse("STATE|id=t_001");
    switch (req) {
        .state => |t| {
            switch (t) {
                .id => |id| try std.testing.expectEqualStrings("t_001", id),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse STATE with index" {
    const req = try parse("STATE|2");
    switch (req) {
        .state => |t| {
            switch (t) {
                .index => |idx| try std.testing.expectEqual(@as(usize, 2), idx),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse TAIL with lines and id" {
    const req = try parse("TAIL|50|id=t_001");
    switch (req) {
        .tail => |t| {
            try std.testing.expectEqual(@as(usize, 50), t.lines);
            switch (t.tab) {
                .id => |id| try std.testing.expectEqualStrings("t_001", id),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse TAIL default" {
    const req = try parse("TAIL");
    switch (req) {
        .tail => |t| {
            try std.testing.expectEqual(@as(usize, 20), t.lines);
            try std.testing.expect(t.tab == .none);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse INPUT with base64 decode" {
    // "aGVsbG8=" is base64 for "hello"
    var line = "INPUT|agent|aGVsbG8=|id=t_001".*;
    const req = try parse(&line);
    switch (req) {
        .input => |inp| {
            try std.testing.expectEqualStrings("agent", inp.from);
            try std.testing.expectEqualStrings("hello", inp.payload);
            switch (inp.tab) {
                .id => |id| try std.testing.expectEqualStrings("t_001", id),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse PASTE with base64 decode" {
    // "aGVsbG8=" is base64 for "hello"
    var line = "PASTE|agent|aGVsbG8=|id=t_001".*;
    const req = try parse(&line);
    switch (req) {
        .paste => |p| {
            try std.testing.expectEqualStrings("agent", p.from);
            try std.testing.expectEqualStrings("hello", p.payload);
            switch (p.tab) {
                .id => |id| try std.testing.expectEqualStrings("t_001", id),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse INPUT with CJK base64 decode" {
    // CJK text: "あいうえお" (U+3042..U+304A) is 15 bytes in UTF-8
    // base64 of "あいうえお" = "44GC44GE44GG44GI44GK"
    var line = "INPUT|agent|44GC44GE44GG44GI44GK".*;
    const req = try parse(&line);
    switch (req) {
        .input => |inp| {
            try std.testing.expectEqualStrings("agent", inp.from);
            try std.testing.expectEqualStrings("あいうえお", inp.payload);
            try std.testing.expect(inp.tab == .none);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse INPUT with long CJK base64" {
    // Test with a longer CJK string to verify no truncation
    // "日本語テスト文字列" (9 chars, 27 bytes UTF-8)
    // base64: "5pel5pys6Kqe44OG44K544OI5paH5a2X5YiX"
    var line = "INPUT|agent|5pel5pys6Kqe44OG44K544OI5paH5a2X5YiX".*;
    const req = try parse(&line);
    switch (req) {
        .input => |inp| {
            try std.testing.expectEqualStrings("agent", inp.from);
            try std.testing.expectEqualStrings("日本語テスト文字列", inp.payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse RAW_INPUT with CJK" {
    // base64 of "漢字" = "5ryi5a2X"
    var line = "RAW_INPUT|agent|5ryi5a2X".*;
    const req = try parse(&line);
    switch (req) {
        .raw_input => |inp| {
            try std.testing.expectEqualStrings("agent", inp.from);
            try std.testing.expectEqualStrings("漢字", inp.payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse CLOSE_TAB with id" {
    const req = try parse("CLOSE_TAB|id=t_001");
    switch (req) {
        .close_tab => |t| {
            switch (t) {
                .id => |id| try std.testing.expectEqualStrings("t_001", id),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SWITCH_TAB with index" {
    const req = try parse("SWITCH_TAB|1");
    switch (req) {
        .switch_tab => |t| {
            switch (t) {
                .index => |idx| try std.testing.expectEqual(@as(usize, 1), idx),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "TabTarget.parse" {
    const t1 = TabTarget.parse("id=t_001");
    switch (t1) {
        .id => |id| try std.testing.expectEqualStrings("t_001", id),
        else => return error.TestUnexpectedResult,
    }

    const t2 = TabTarget.parse("2");
    switch (t2) {
        .index => |idx| try std.testing.expectEqual(@as(usize, 2), idx),
        else => return error.TestUnexpectedResult,
    }

    const t3 = TabTarget.parse("");
    try std.testing.expect(t3 == .none);
}

test "escapeField" {
    var buf: [64]u8 = undefined;
    const input = "hello|world\nfoo\rbar";
    const len = escapeField(input, &buf);
    try std.testing.expectEqualStrings("hello world foo bar", buf[0..len]);
}

test "formatPong" {
    const result = try formatPong(std.testing.allocator, "sess1", 1234, 0xABCD);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("PONG|sess1|1234|0xABCD\n", result);
}

test "formatTabLine" {
    const result = try formatTabLine(std.testing.allocator, 0, "t_001", "bash", "/home", true, false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("TAB|0|t_001|bash|pwd=/home|prompt=1|selection=0\n", result);
}
