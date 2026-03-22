const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TabIdManager = struct {
    next_id: u64,
    id_to_index: std.StringHashMap(usize),
    index_to_id: std.AutoHashMap(usize, []const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TabIdManager {
        return .{
            .next_id = 0,
            .id_to_index = std.StringHashMap(usize).init(allocator),
            .index_to_id = std.AutoHashMap(usize, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabIdManager) void {
        // Free all stored ID strings. Only need to iterate one map since both
        // point to the same allocations.
        var it = self.index_to_id.valueIterator();
        while (it.next()) |v| {
            self.allocator.free(v.*);
        }
        self.id_to_index.deinit();
        self.index_to_id.deinit();
    }

    /// Assign a new tab ID to the given index. Returns the ID string (owned by manager).
    pub fn registerNewTab(self: *TabIdManager, index: usize) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "t_{d:0>3}", .{self.next_id});
        errdefer self.allocator.free(id);
        self.next_id += 1;

        try self.id_to_index.put(id, index);
        try self.index_to_id.put(index, id);
        return id;
    }

    /// Look up index by tab ID. Returns null if not found.
    pub fn resolve(self: *const TabIdManager, id: []const u8) ?usize {
        return self.id_to_index.get(id);
    }

    /// Look up tab ID by index. Returns null if not found.
    pub fn getId(self: *const TabIdManager, index: usize) ?[]const u8 {
        return self.index_to_id.get(index);
    }

    /// Sync with actual tab count. If count > known, register new tabs.
    /// If count < known, drop extras.
    pub fn syncTabs(self: *TabIdManager, tab_count: usize) !void {
        const current = self.index_to_id.count();
        if (tab_count > current) {
            // Grow: register new tabs for missing indices.
            var idx = current;
            while (idx < tab_count) : (idx += 1) {
                _ = try self.registerNewTab(idx);
            }
        } else if (tab_count < current) {
            // Shrink: remove from highest index down to tab_count.
            var idx = current;
            while (idx > tab_count) {
                idx -= 1;
                self.removeTabAtIndex(idx);
            }
        }
    }

    /// Remove tab by ID. Shifts indices down for tabs after it.
    pub fn removeTab(self: *TabIdManager, id: []const u8) void {
        const index = self.id_to_index.get(id) orelse return;
        self.removeTabAtIndex(index);
    }

    /// Remove tab at index. Shifts indices down.
    pub fn removeTabAtIndex(self: *TabIdManager, index: usize) void {
        // Find the ID at this index.
        const id = self.index_to_id.get(index) orelse return;

        // Remove from both maps.
        _ = self.id_to_index.remove(id);
        _ = self.index_to_id.remove(index);

        // Free the string.
        self.allocator.free(id);

        // Shift indices down: collect entries with idx > index, sorted descending.
        // We rebuild by removing old entries and re-inserting with idx-1.
        const count = self.index_to_id.count();
        if (count == 0) return;

        const Entry = struct { idx: usize, tab_id: []const u8 };

        // Count entries that need shifting.
        var shift_count: usize = 0;
        {
            var it2 = self.index_to_id.iterator();
            while (it2.next()) |entry| {
                if (entry.key_ptr.* > index) shift_count += 1;
            }
        }
        if (shift_count == 0) return;

        // Allocate temporary buffer for entries to shift.
        const to_shift = self.allocator.alloc(Entry, shift_count) catch return;
        defer self.allocator.free(to_shift);

        var i: usize = 0;
        var it = self.index_to_id.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > index) {
                to_shift[i] = .{ .idx = entry.key_ptr.*, .tab_id = entry.value_ptr.* };
                i += 1;
            }
        }

        // Sort descending by index to avoid clobber when shifting down.
        std.mem.sort(Entry, to_shift, {}, struct {
            fn f(_: void, a: Entry, b: Entry) bool {
                return a.idx > b.idx;
            }
        }.f);

        // Remove old entries (descending order is safe).
        for (to_shift) |entry| {
            _ = self.index_to_id.remove(entry.idx);
        }

        // Re-insert with shifted indices.
        for (to_shift) |entry| {
            const new_idx = entry.idx - 1;
            self.index_to_id.put(new_idx, entry.tab_id) catch return;
            self.id_to_index.put(entry.tab_id, new_idx) catch return;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "register and resolve" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.registerNewTab(0);
    try std.testing.expectEqualStrings("t_000", id);
    try std.testing.expectEqual(@as(?usize, 0), mgr.resolve("t_000"));
}

test "register multiple" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id0 = try mgr.registerNewTab(0);
    const id1 = try mgr.registerNewTab(1);
    const id2 = try mgr.registerNewTab(2);

    try std.testing.expectEqualStrings("t_000", id0);
    try std.testing.expectEqualStrings("t_001", id1);
    try std.testing.expectEqualStrings("t_002", id2);

    try std.testing.expectEqual(@as(?usize, 0), mgr.resolve("t_000"));
    try std.testing.expectEqual(@as(?usize, 1), mgr.resolve("t_001"));
    try std.testing.expectEqual(@as(?usize, 2), mgr.resolve("t_002"));
}

test "remove tab shifts indices" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.registerNewTab(0);
    _ = try mgr.registerNewTab(1);
    _ = try mgr.registerNewTab(2);

    mgr.removeTab("t_001");

    // t_000 stays at 0.
    try std.testing.expectEqual(@as(?usize, 0), mgr.resolve("t_000"));
    // t_002 shifted from 2 to 1.
    try std.testing.expectEqual(@as(?usize, 1), mgr.resolve("t_002"));
    // t_001 is gone.
    try std.testing.expectEqual(@as(?usize, null), mgr.resolve("t_001"));
}

test "remove tab at index" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.registerNewTab(0);
    _ = try mgr.registerNewTab(1);
    _ = try mgr.registerNewTab(2);

    mgr.removeTabAtIndex(0);

    // t_000 is gone.
    try std.testing.expectEqual(@as(?usize, null), mgr.resolve("t_000"));
    // t_001 shifted from 1 to 0.
    try std.testing.expectEqual(@as(?usize, 0), mgr.resolve("t_001"));
    // t_002 shifted from 2 to 1.
    try std.testing.expectEqual(@as(?usize, 1), mgr.resolve("t_002"));
}

test "sync tabs grow" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.syncTabs(3);

    try std.testing.expectEqual(@as(usize, 3), mgr.index_to_id.count());
    try std.testing.expectEqualStrings("t_000", mgr.getId(0).?);
    try std.testing.expectEqualStrings("t_001", mgr.getId(1).?);
    try std.testing.expectEqualStrings("t_002", mgr.getId(2).?);
}

test "sync tabs shrink" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.registerNewTab(0);
    _ = try mgr.registerNewTab(1);
    _ = try mgr.registerNewTab(2);

    try mgr.syncTabs(1);

    try std.testing.expectEqual(@as(usize, 1), mgr.index_to_id.count());
    try std.testing.expectEqualStrings("t_000", mgr.getId(0).?);
    try std.testing.expectEqual(@as(?usize, null), mgr.resolve("t_001"));
    try std.testing.expectEqual(@as(?usize, null), mgr.resolve("t_002"));
}

test "sync tabs no change" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.registerNewTab(0);
    _ = try mgr.registerNewTab(1);

    try mgr.syncTabs(2);

    try std.testing.expectEqual(@as(usize, 2), mgr.index_to_id.count());
    try std.testing.expectEqualStrings("t_000", mgr.getId(0).?);
    try std.testing.expectEqualStrings("t_001", mgr.getId(1).?);
}

test "get id" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.registerNewTab(0);

    const id = mgr.getId(0);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("t_000", id.?);

    // Non-existent index returns null.
    try std.testing.expectEqual(@as(?[]const u8, null), mgr.getId(99));
}
