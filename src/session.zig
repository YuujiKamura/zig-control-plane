const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

// Win32 process-liveness probing (used by cleanupStaleSessions).
const HANDLE = *anyopaque;
const DWORD = u32;
const BOOL = i32;
const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
const STILL_ACTIVE: DWORD = 259;
extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

pub const SessionManager = struct {
    session_name: []const u8,
    safe_session_name: []const u8,
    pid: u32,
    pipe_path: []const u8,
    session_file_path: []const u8,
    allocator: Allocator,

    /// Create a new session manager.
    /// app_name: e.g. "ghostty-winui3" — prefix before '-' used as directory name ("ghostty").
    ///           null defaults to "WindowsTerminal".
    pub fn init(allocator: Allocator, session_name: []const u8, pipe_path: []const u8, app_name: ?[]const u8) !SessionManager {
        const safe_name = try sanitizeSessionName(allocator, session_name);
        errdefer allocator.free(safe_name);

        const pid = getCurrentPid();

        const dir_name = if (app_name) |name| blk: {
            if (std.mem.indexOfScalar(u8, name, '-')) |idx| {
                break :blk name[0..idx];
            }
            break :blk name;
        } else "WindowsTerminal";

        const local_app_data = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            else => return err,
        };
        defer allocator.free(local_app_data);

        // Build session file path
        const session_file_path = try std.fmt.allocPrint(
            allocator,
            "{s}\\{s}\\control-plane\\winui3\\sessions\\{s}-{d}.session",
            .{ local_app_data, dir_name, safe_name, pid },
        );
        errdefer allocator.free(session_file_path);

        // Ensure parent directories exist (using forward-slash-normalized path for std.fs)
        ensureParentDirs(session_file_path) catch |err| {
            // If it already exists, that's fine
            if (err != error.PathAlreadyExists) return err;
        };

        const owned_name = try allocator.dupe(u8, session_name);
        errdefer allocator.free(owned_name);
        const owned_pipe = try allocator.dupe(u8, pipe_path);
        errdefer allocator.free(owned_pipe);

        return SessionManager{
            .session_name = owned_name,
            .safe_session_name = safe_name,
            .pid = pid,
            .pipe_path = owned_pipe,
            .session_file_path = session_file_path,
            .allocator = allocator,
        };
    }

    /// Write session file to disk.
    pub fn writeFile(self: *const SessionManager, hwnd: usize) !void {
        // Ensure parent directories exist
        ensureParentDirs(self.session_file_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const content = try std.fmt.allocPrint(
            self.allocator,
            "session_name={s}\nsafe_session_name={s}\npid={d}\nhwnd=0x{X}\npipe_path={s}\n",
            .{ self.session_name, self.safe_session_name, self.pid, hwnd, self.pipe_path },
        );
        defer self.allocator.free(content);

        const file = try createFileFromPath(self.session_file_path);
        defer file.close();
        try file.writeAll(content);
    }

    /// Remove session file from disk (best-effort, ignores errors).
    pub fn removeFile(self: *const SessionManager) void {
        deleteFileFromPath(self.session_file_path) catch {};
    }

    /// Free all owned strings.
    pub fn deinit(self: *SessionManager) void {
        self.allocator.free(self.session_name);
        self.allocator.free(self.safe_session_name);
        self.allocator.free(self.pipe_path);
        self.allocator.free(self.session_file_path);
        self.* = undefined;
    }
};

/// Replace non-alphanumeric (except '-', '_', '.') with '_'.
/// Trim leading/trailing '_'. If empty: return "session".
pub fn sanitizeSessionName(allocator: Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) {
        return try allocator.dupe(u8, "session");
    }

    const buf = try allocator.alloc(u8, name.len);
    defer allocator.free(buf);

    for (name, 0..) |c, i| {
        buf[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') c else '_';
    }

    // Trim leading/trailing underscores
    var start: usize = 0;
    while (start < buf.len and buf[start] == '_') : (start += 1) {}
    var end: usize = buf.len;
    while (end > start and buf[end - 1] == '_') : (end -= 1) {}

    if (start >= end) {
        return try allocator.dupe(u8, "session");
    }

    return try allocator.dupe(u8, buf[start..end]);
}

fn getCurrentPid() u32 {
    if (@import("builtin").os.tag == .windows) {
        return GetCurrentProcessId();
    } else {
        // For testing on non-Windows, use a placeholder
        return @intCast(std.os.linux.getpid());
    }
}

/// Ensure all parent directories of `path` exist. Path uses backslash separators.
fn ensureParentDirs(path: []const u8) !void {
    // Find the last backslash to get parent dir
    var last_sep: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '\\' or c == '/') last_sep = i;
    }
    const parent = if (last_sep) |s| path[0..s] else return;
    // Use std.fs to create the directory tree
    // We need to handle Windows paths — std.fs.makeDirAbsolute works iteratively
    makeDirsRecursive(parent) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
}

fn makeDirsRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        if (err == error.FileNotFound) {
            // Parent doesn't exist, recurse
            var last_sep: ?usize = null;
            for (path, 0..) |c, i| {
                if (c == '\\' or c == '/') last_sep = i;
            }
            if (last_sep) |s| {
                if (s == 0) return err;
                try makeDirsRecursive(path[0..s]);
                // Now create this directory
                std.fs.makeDirAbsolute(path) catch |e| {
                    if (e == error.PathAlreadyExists) return;
                    return e;
                };
            } else {
                return err;
            }
        } else {
            return err;
        }
    };
}

fn createFileFromPath(path: []const u8) !std.fs.File {
    // On Windows, paths are absolute with backslashes. Use cwd-relative open with the full path.
    // std.fs.createFileAbsolute handles Windows absolute paths.
    return std.fs.createFileAbsolute(path, .{});
}

fn deleteFileFromPath(path: []const u8) !void {
    std.fs.deleteFileAbsolute(path) catch |err| {
        return err;
    };
}

/// Predicate signature for liveness checks. Returns true iff `pid` is still alive.
/// Hoisted to a public type so `cleanupStaleSessionsIn` can be tested without
/// relying on real OS processes.
pub const IsAliveFn = *const fn (pid: u32) bool;

/// Default Win32-backed liveness probe. On non-Windows targets this conservatively
/// returns true so stale-session cleanup never deletes a peer session by accident.
pub fn defaultIsAlive(pid: u32) bool {
    if (builtin.os.tag != .windows) return true;
    if (pid == 0) return false;
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = CloseHandle(handle);
    var code: DWORD = 0;
    if (GetExitCodeProcess(handle, &code) == 0) return false;
    return code == STILL_ACTIVE;
}

fn parsePidFromSessionFile(content: []const u8) ?u32 {
    // Session files contain `key=value` lines; we want the `pid=` line.
    var iter = std.mem.tokenizeAny(u8, content, "\r\n");
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pid=")) continue;
        const value = std.mem.trim(u8, trimmed["pid=".len..], " \t");
        if (value.len == 0) continue;
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

/// Counts of stale-session sweep results.
pub const CleanupStats = struct {
    scanned: usize = 0,
    removed: usize = 0,
    skipped_alive: usize = 0,
    skipped_unparsable: usize = 0,
    errors: usize = 0,
};

/// Sweep `dir_path` for `*.session` files whose `pid=` line points at a dead
/// process and delete them. Pure I/O over `dir_path`; safe to call from `init()`
/// before this process has written its own session file (the current PID will be
/// reported alive by `is_alive_fn` so we never wipe ourselves).
pub fn cleanupStaleSessionsIn(
    allocator: Allocator,
    dir_path: []const u8,
    is_alive_fn: IsAliveFn,
) !CleanupStats {
    var stats: CleanupStats = .{};

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        // No directory yet => no stale files; treat as a clean sweep.
        error.FileNotFound => return stats,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".session")) continue;
        stats.scanned += 1;

        const file = dir.openFile(entry.name, .{}) catch {
            stats.errors += 1;
            continue;
        };
        const content = file.readToEndAlloc(allocator, 64 * 1024) catch {
            file.close();
            stats.errors += 1;
            continue;
        };
        file.close();
        defer allocator.free(content);

        const pid = parsePidFromSessionFile(content) orelse {
            stats.skipped_unparsable += 1;
            continue;
        };

        if (is_alive_fn(pid)) {
            stats.skipped_alive += 1;
            continue;
        }

        dir.deleteFile(entry.name) catch {
            stats.errors += 1;
            continue;
        };
        stats.removed += 1;
    }

    return stats;
}

/// Convenience wrapper: derive the sessions directory from `app_name` (same
/// scheme as `SessionManager.init`) and sweep stale files using `defaultIsAlive`.
pub fn cleanupStaleSessions(allocator: Allocator, app_name: []const u8) !CleanupStats {
    const dir_name = if (std.mem.indexOfScalar(u8, app_name, '-')) |idx|
        app_name[0..idx]
    else
        app_name;

    const local_app_data = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return CleanupStats{},
        else => return err,
    };
    defer allocator.free(local_app_data);

    const sessions_dir = try std.fmt.allocPrint(
        allocator,
        "{s}\\{s}\\control-plane\\winui3\\sessions",
        .{ local_app_data, dir_name },
    );
    defer allocator.free(sessions_dir);

    return cleanupStaleSessionsIn(allocator, sessions_dir, defaultIsAlive);
}

// ============ Tests ============

test "sanitize session name" {
    const allocator = std.testing.allocator;

    const r1 = try sanitizeSessionName(allocator, "hello world!");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("hello_world", r1);

    const r2 = try sanitizeSessionName(allocator, "---");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("---", r2);

    const r3 = try sanitizeSessionName(allocator, "");
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("session", r3);

    const r4 = try sanitizeSessionName(allocator, "abc");
    defer allocator.free(r4);
    try std.testing.expectEqualStrings("abc", r4);
}

test "sanitize trims underscores" {
    const allocator = std.testing.allocator;

    const r1 = try sanitizeSessionName(allocator, "!!abc!!");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("abc", r1);
}

test "write and read session file" {
    const allocator = std.testing.allocator;

    // Create a temp directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build a session file path inside the temp dir
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const session_file = try std.fmt.allocPrint(allocator, "{s}\\test-session-123.session", .{tmp_path});
    defer allocator.free(session_file);

    // Manually construct a SessionManager pointing to our temp dir
    var mgr = SessionManager{
        .session_name = try allocator.dupe(u8, "my session"),
        .safe_session_name = try allocator.dupe(u8, "my_session"),
        .pid = 12345,
        .pipe_path = try allocator.dupe(u8, "\\\\.\\pipe\\test-pipe"),
        .session_file_path = try allocator.dupe(u8, session_file),
        .allocator = allocator,
    };
    defer mgr.deinit();

    try mgr.writeFile(0xDEAD);

    // Read back and verify
    const file = try std.fs.openFileAbsolute(session_file, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "session_name=my session") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "safe_session_name=my_session") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "pid=12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "hwnd=0xDEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "pipe_path=\\\\.\\pipe\\test-pipe") != null);
}

test "remove file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const session_file = try std.fmt.allocPrint(allocator, "{s}\\remove-test.session", .{tmp_path});
    defer allocator.free(session_file);

    var mgr = SessionManager{
        .session_name = try allocator.dupe(u8, "test"),
        .safe_session_name = try allocator.dupe(u8, "test"),
        .pid = 999,
        .pipe_path = try allocator.dupe(u8, "\\\\.\\pipe\\p"),
        .session_file_path = try allocator.dupe(u8, session_file),
        .allocator = allocator,
    };
    defer mgr.deinit();

    try mgr.writeFile(0x1234);

    // File should exist
    _ = try std.fs.openFileAbsolute(session_file, .{});

    mgr.removeFile();

    // File should be gone
    const result = std.fs.openFileAbsolute(session_file, .{});
    try std.testing.expect(if (result) |_| false else |_| true);
}

test "parsePidFromSessionFile extracts pid line" {
    try std.testing.expectEqual(@as(?u32, 12345), parsePidFromSessionFile(
        "session_name=foo\nsafe_session_name=foo\npid=12345\nhwnd=0xDEAD\npipe_path=x\n",
    ));
    try std.testing.expectEqual(@as(?u32, 7), parsePidFromSessionFile("pid=7\n"));
    // Trailing CRLF and whitespace tolerated.
    try std.testing.expectEqual(@as(?u32, 99), parsePidFromSessionFile("pid=99 \r\n"));
    // Missing pid line.
    try std.testing.expectEqual(@as(?u32, null), parsePidFromSessionFile("hwnd=0x1\n"));
    // Non-numeric pid.
    try std.testing.expectEqual(@as(?u32, null), parsePidFromSessionFile("pid=abc\n"));
}

const TestPidPredicate = struct {
    var alive_pid: u32 = 0;
    fn isAlive(pid: u32) bool {
        return pid == alive_pid;
    }
};

test "cleanupStaleSessionsIn removes dead-pid files and keeps live ones" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const sep = std.fs.path.sep;

    // Three session files: one alive, one dead, one with no pid line.
    inline for (.{
        .{ "alive.session", "session_name=a\npid=42\nhwnd=0x1\n" },
        .{ "dead.session", "session_name=b\npid=99999\nhwnd=0x2\n" },
        .{ "broken.session", "session_name=c\nhwnd=0x3\n" },
        // A non-session file must be left untouched.
        .{ "ignore-me.txt", "pid=99999\n" },
    }) |pair| {
        const name, const body = pair;
        const path = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ tmp_path, sep, name });
        defer allocator.free(path);
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll(body);
    }

    TestPidPredicate.alive_pid = 42;

    const stats = try cleanupStaleSessionsIn(allocator, tmp_path, TestPidPredicate.isAlive);
    try std.testing.expectEqual(@as(usize, 3), stats.scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.removed);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_alive);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_unparsable);
    try std.testing.expectEqual(@as(usize, 0), stats.errors);

    // alive.session and broken.session must remain; dead.session must be gone.
    const alive_path = try std.fmt.allocPrint(allocator, "{s}{c}alive.session", .{ tmp_path, sep });
    defer allocator.free(alive_path);
    _ = try std.fs.openFileAbsolute(alive_path, .{});

    const broken_path = try std.fmt.allocPrint(allocator, "{s}{c}broken.session", .{ tmp_path, sep });
    defer allocator.free(broken_path);
    _ = try std.fs.openFileAbsolute(broken_path, .{});

    const dead_path = try std.fmt.allocPrint(allocator, "{s}{c}dead.session", .{ tmp_path, sep });
    defer allocator.free(dead_path);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(dead_path, .{}));

    // The non-session file must also remain.
    const ignore_path = try std.fmt.allocPrint(allocator, "{s}{c}ignore-me.txt", .{ tmp_path, sep });
    defer allocator.free(ignore_path);
    _ = try std.fs.openFileAbsolute(ignore_path, .{});
}

test "cleanupStaleSessionsIn returns zero stats when directory missing" {
    const allocator = std.testing.allocator;

    // Build a path that almost certainly does not exist on either OS.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const missing = try std.fmt.allocPrint(
        allocator,
        "{s}{c}does-not-exist-cp-cleanup",
        .{ tmp_path, std.fs.path.sep },
    );
    defer allocator.free(missing);

    const stats = try cleanupStaleSessionsIn(allocator, missing, TestPidPredicate.isAlive);
    try std.testing.expectEqual(@as(usize, 0), stats.scanned);
    try std.testing.expectEqual(@as(usize, 0), stats.removed);
}
