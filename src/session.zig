const std = @import("std");
const Allocator = std.mem.Allocator;

extern "kernel32" fn GetCurrentProcessId() callconv(std.os.windows.WINAPI) u32;

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
