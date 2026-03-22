const std = @import("std");

/// Return the last `n` lines of a buffer.
/// If the buffer has fewer than `n` lines, the entire buffer is returned.
pub fn sliceLastLines(buf: []const u8, n: usize) []const u8 {
    if (buf.len == 0 or n == 0) return buf[buf.len..];

    // Count newlines from the end to find the start of the last N lines.
    var count: usize = 0;
    var pos: usize = buf.len;

    // If buffer ends with '\n', skip it so we don't count an empty trailing line.
    if (pos > 0 and buf[pos - 1] == '\n') {
        pos -= 1;
    }

    while (pos > 0) : (pos -= 1) {
        if (buf[pos - 1] == '\n') {
            count += 1;
            if (count == n) {
                return buf[pos..];
            }
        }
    }

    // Fewer than n lines — return entire buffer.
    return buf;
}

/// Infer if terminal is at a shell prompt.
/// Returns true if the last non-empty line ends with '>', '$', '#',
/// or starts with the provided working directory path.
pub fn inferPrompt(buffer: []const u8, pwd: []const u8) bool {
    const line = lastNonEmptyLine(buffer);
    if (line.len == 0) return false;

    // Check if line ends with a prompt character (possibly followed by a space).
    const trimmed = std.mem.trimRight(u8, line, " ");
    if (trimmed.len > 0) {
        const last_char = trimmed[trimmed.len - 1];
        if (last_char == '>' or last_char == '$' or last_char == '#') {
            return true;
        }
    }

    // Check if line starts with the working directory.
    if (pwd.len > 0 and std.mem.startsWith(u8, line, pwd)) {
        return true;
    }

    return false;
}

/// Find the last non-empty line in a buffer.
fn lastNonEmptyLine(buf: []const u8) []const u8 {
    var end = buf.len;
    // Skip trailing whitespace/newlines
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r' or buf[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) return "";

    // Find start of this line
    var start = end;
    while (start > 0 and buf[start - 1] != '\n') {
        start -= 1;
    }
    return buf[start..end];
}

// ── Tests ──

test "sliceLastLines empty" {
    const result = sliceLastLines("", 5);
    try std.testing.expectEqualStrings("", result);
}

test "sliceLastLines fewer lines" {
    const buf = "line1\nline2\nline3\n";
    const result = sliceLastLines(buf, 10);
    try std.testing.expectEqualStrings(buf, result);
}

test "sliceLastLines exact" {
    const buf = "line1\nline2\nline3\n";
    const result = sliceLastLines(buf, 3);
    try std.testing.expectEqualStrings("line1\nline2\nline3\n", result);
}

test "sliceLastLines subset" {
    const buf = "line1\nline2\nline3\nline4\n";
    const result = sliceLastLines(buf, 2);
    try std.testing.expectEqualStrings("line3\nline4\n", result);
}

test "sliceLastLines no trailing newline" {
    const buf = "line1\nline2\nline3";
    const result = sliceLastLines(buf, 2);
    try std.testing.expectEqualStrings("line2\nline3", result);
}

test "sliceLastLines single line" {
    const buf = "hello\n";
    const result = sliceLastLines(buf, 1);
    try std.testing.expectEqualStrings("hello\n", result);
}

test "sliceLastLines zero lines" {
    const buf = "hello\nworld\n";
    const result = sliceLastLines(buf, 0);
    try std.testing.expectEqualStrings("", result);
}

test "inferPrompt dollar sign" {
    try std.testing.expect(inferPrompt("some output\nuser@host:~$ ", ""));
}

test "inferPrompt angle bracket" {
    try std.testing.expect(inferPrompt("PS C:\\Users> ", ""));
}

test "inferPrompt hash" {
    try std.testing.expect(inferPrompt("root@host:/# ", ""));
}

test "inferPrompt pwd match" {
    try std.testing.expect(inferPrompt("output\n/home/user something", "/home/user"));
}

test "inferPrompt not a prompt" {
    try std.testing.expect(!inferPrompt("hello world\nthis is output", ""));
}

test "inferPrompt empty buffer" {
    try std.testing.expect(!inferPrompt("", ""));
}

test "inferPrompt trailing newlines" {
    try std.testing.expect(inferPrompt("output\nuser@host:~$\n\n", ""));
}
