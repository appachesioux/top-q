const std = @import("std");
const ctx = @import("ctx.zig");
const linux = @import("procsrc/linux.zig");
const process = @import("process.zig");

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.now(.awake, io).toNanoseconds() & std.math.maxInt(i64));
}

pub fn main(init: std.process.Init) !void {
    ctx.io = init.io;
    ctx.env_map = init.environ_map;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var source = try linux.Linux.init(alloc);
    defer source.deinit();

    try std.Io.File.stdout().writeStreamingAll(init.io, "live /proc enumeration\n");
    for (0..6) |generation| {
        var table = process.ProcessTable.init(alloc);
        const started = nowNs(init.io);
        try source.enumerate(&table);
        const elapsed_us: u64 = @as(u64, @intCast(nowNs(init.io) - started)) / std.time.ns_per_us;

        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  generation {d}: {d} processes in {d} us (dir {d}, read {d}/{d}w, merge {d})\n", .{
            generation + 1,
            table.count(),
            elapsed_us,
            table.collect_dir_us,
            table.collect_read_us,
            table.collect_readers,
            table.collect_merge_us,
        });
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
        table.deinit();
    }
}
