const std = @import("std");
const ctx = @import("ctx.zig");

// =============================================================================
// Time
// =============================================================================

/// Wall-clock nanoseconds, truncated to i64 (replaces std.time.nanoTimestamp()
/// which was removed in Zig 0.16). Requires ctx.io initialized.
pub fn nanoTimestamp() i64 {
    return @intCast(std.Io.Clock.now(.real, ctx.io).toNanoseconds() & std.math.maxInt(i64));
}

// =============================================================================
// RingBuffer — fixed-capacity FIFO for time-series samples
// =============================================================================

pub fn RingBuffer(comptime T: type, comptime capacity_: usize) type {
    return struct {
        const Self = @This();
        pub const capacity: usize = capacity_;

        data: [capacity_]T = undefined,
        head: usize = 0, // write index
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, v: T) void {
            self.data[self.head] = v;
            self.head = (self.head + 1) % capacity_;
            if (self.len < capacity_) self.len += 1;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }

        /// Returns the i-th oldest element (0 = oldest, len-1 = newest).
        pub fn at(self: *const Self, i: usize) T {
            const start = if (self.len < capacity_) 0 else self.head;
            return self.data[(start + i) % capacity_];
        }
    };
}

// =============================================================================
// Formatters
// =============================================================================

/// Format bytes as e.g. "1.2M", "456K", "  4G". Result fits in `out` buffer.
pub fn formatBytes(bytes: u64, out: []u8) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var v: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;
    while (v >= 1024.0 and unit_idx + 1 < units.len) : (unit_idx += 1) {
        v /= 1024.0;
    }
    return std.fmt.bufPrint(out, "{d:.1}{s}", .{ v, units[unit_idx] }) catch out[0..0];
}

/// Format duration in seconds as "HH:MM:SS" or "Dd HH:MM" if > 1 day.
pub fn formatDuration(seconds: u64, out: []u8) []const u8 {
    const days = seconds / (24 * 3600);
    const rem = seconds % (24 * 3600);
    const hh = rem / 3600;
    const mm = (rem % 3600) / 60;
    const ss = rem % 60;
    if (days > 0) {
        return std.fmt.bufPrint(out, "{d}d {d:0>2}:{d:0>2}", .{ days, hh, mm }) catch out[0..0];
    }
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch out[0..0];
}

/// Format a percentage 0..100+ as "XX.X" with fixed width 4.
pub fn formatPercent(pct: f32, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{d:.1}", .{pct}) catch out[0..0];
}

// =============================================================================
// UidCache — lazy /etc/passwd backed map of uid -> username
// =============================================================================

pub const UidCache = struct {
    map: std.AutoHashMapUnmanaged(u32, []const u8),
    alloc: std.mem.Allocator,
    passwd_loaded: bool,
    passwd_buf: ?[]const u8,

    pub fn init(alloc: std.mem.Allocator) UidCache {
        return .{
            .map = .{},
            .alloc = alloc,
            .passwd_loaded = false,
            .passwd_buf = null,
        };
    }

    pub fn deinit(self: *UidCache) void {
        self.map.deinit(self.alloc);
        if (self.passwd_buf) |buf| self.alloc.free(buf);
    }

    fn loadPasswd(self: *UidCache) void {
        if (self.passwd_loaded) return;
        self.passwd_loaded = true;

        const file = std.Io.Dir.openFileAbsolute(ctx.io, "/etc/passwd", .{}) catch return;
        defer file.close(ctx.io);

        const max_size: usize = 1024 * 1024;
        const buf = self.alloc.alloc(u8, max_size) catch return;
        const n = file.readPositionalAll(ctx.io, buf, 0) catch {
            self.alloc.free(buf);
            return;
        };
        self.passwd_buf = buf;
        const content = buf[0..n];

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            const name = fields.next() orelse continue;
            _ = fields.next(); // password
            const uid_str = fields.next() orelse continue;
            const uid = std.fmt.parseInt(u32, uid_str, 10) catch continue;
            self.map.put(self.alloc, uid, name) catch continue;
        }
    }

    /// Returns username for uid, or a numeric fallback. Returned slice lives
    /// in the cache's allocator (typically an arena owned by the caller).
    pub fn resolve(self: *UidCache, uid: u32) ![]const u8 {
        self.loadPasswd();
        if (self.map.get(uid)) |name| return name;
        const fallback = try std.fmt.allocPrint(self.alloc, "{d}", .{uid});
        self.map.put(self.alloc, uid, fallback) catch {};
        return fallback;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "RingBuffer wraparound" {
    var rb = RingBuffer(u32, 3).init();
    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4); // wraps; oldest (1) dropped
    try std.testing.expectEqual(@as(usize, 3), rb.len);
    try std.testing.expectEqual(@as(u32, 2), rb.at(0));
    try std.testing.expectEqual(@as(u32, 3), rb.at(1));
    try std.testing.expectEqual(@as(u32, 4), rb.at(2));
}

test "formatBytes" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.0B", formatBytes(0, &buf));
    try std.testing.expectEqualStrings("1.0K", formatBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.5M", formatBytes(1024 * 1024 + 512 * 1024, &buf));
    try std.testing.expectEqualStrings("2.0G", formatBytes(2 * 1024 * 1024 * 1024, &buf));
}

test "formatDuration" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("00:00:42", formatDuration(42, &buf));
    try std.testing.expectEqualStrings("01:02:03", formatDuration(3723, &buf));
    try std.testing.expectEqualStrings("2d 03:04", formatDuration(2 * 24 * 3600 + 3 * 3600 + 4 * 60, &buf));
}
