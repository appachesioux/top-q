const std = @import("std");
const process = @import("process.zig");
const view = @import("view.zig");

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.now(.awake, io).toNanoseconds() & std.math.maxInt(i64));
}

fn buildSyntheticTable(alloc: std.mem.Allocator, count: usize, generation: usize) !process.ProcessTable {
    var table = process.ProcessTable.init(alloc);
    errdefer table.deinit();
    try table.procs.ensureTotalCapacity(alloc, count);
    try table.index_by_pid.ensureTotalCapacity(alloc, @intCast(count));
    const arena = table.arena.allocator();

    for (0..count) |i| {
        var comm_buf: [32]u8 = undefined;
        var cmd_buf: [96]u8 = undefined;
        const comm = try std.fmt.bufPrint(&comm_buf, "worker-{d}", .{i % 257});
        const cmd = try std.fmt.bufPrint(&cmd_buf, "/usr/bin/worker-{d} --shard {d} --generation {d}", .{ i % 257, i, generation });
        try table.append(.{
            .pid = @intCast(i + 1),
            .ppid = 1,
            .uid = 1000,
            .user = try arena.dupe(u8, "benchmark"),
            .comm = try arena.dupe(u8, comm),
            .cmdline = try arena.dupe(u8, cmd),
            .state = if (i % 13 == 0) .running else .sleeping,
            .cpu_pct = @floatFromInt((i * 37 + generation) % 800),
            .mem_rss_bytes = (i * 7919 % (16 * 1024)) * 1024,
            .mem_vsz_bytes = 0,
            .nthreads = @intCast(1 + i % 32),
            .io_read_bytes = 0,
            .io_write_bytes = 0,
            .io_available = false,
            .last_jiffies = 0,
            .last_sample_ns = 0,
        });
    }
    return table;
}

fn benchmarkSize(io: std.Io, alloc: std.mem.Allocator, count: usize, iterations: usize) !void {
    var sorted: std.ArrayListUnmanaged(usize) = .empty;
    defer sorted.deinit(alloc);
    try sorted.ensureTotalCapacity(alloc, count);

    const started = nowNs(io);
    for (0..iterations) |generation| {
        var table = try buildSyntheticTable(alloc, count, generation);
        defer table.deinit();

        sorted.clearRetainingCapacity();
        for (0..table.procs.items.len) |i| sorted.appendAssumeCapacity(i);
        const sort_ctx: view.SortCtx = .{ .procs = table.procs.items, .key = .cpu, .dir = .desc };
        std.sort.pdq(usize, sorted.items, sort_ctx, view.SortCtx.lessThan);
    }
    const elapsed_ns: u64 = @intCast(nowNs(io) - started);
    const per_refresh_us = elapsed_ns / (@as(u64, @intCast(iterations)) * std.time.ns_per_us);

    var out: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&out, "{d:>6} processes: {d:>8} us/refresh ({d} iterations)\n", .{ count, per_refresh_us, iterations });
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try std.Io.File.stdout().writeStreamingAll(init.io, "synthetic ProcessTable rebuild + CPU sort\n");
    try benchmarkSize(init.io, alloc, 100, 200);
    try benchmarkSize(init.io, alloc, 1_000, 50);
    try benchmarkSize(init.io, alloc, 10_000, 10);
}
