const std = @import("std");
const process = @import("../process.zig");
const sample_mod = @import("../sample.zig");

/// Stub macOS backend so the project compiles when targeting macOS during
/// US1/US2 development. Real implementation lands in Phase 7 (T059–T062).
pub const MacOS = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !MacOS {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *MacOS) void {
        _ = self;
    }

    pub fn enumerate(self: *MacOS, table: *process.ProcessTable) !void {
        _ = self;
        _ = table;
        return error.NotImplemented;
    }

    pub fn systemSummary(self: *MacOS, alloc: std.mem.Allocator, out: *process.SystemSummary) !void {
        _ = self;
        _ = alloc;
        _ = out;
        return error.NotImplemented;
    }

    pub fn signal(self: *MacOS, pid: process.Pid, sig: process.Signal) !void {
        _ = self;
        std.posix.kill(@intCast(pid), @enumFromInt(@intFromEnum(sig))) catch |e| switch (e) {
            error.PermissionDenied => return error.PermissionDenied,
            error.ProcessNotFound => return error.NoSuchProcess,
            else => return e,
        };
    }

    pub fn sample(self: *MacOS, pid: process.Pid, out: *sample_mod.ProcessSample) !void {
        _ = self;
        _ = pid;
        _ = out;
        return error.NotImplemented;
    }

    pub fn detail(self: *MacOS, pid: process.Pid, out: *process.ProcessDetail) !void {
        _ = self;
        _ = pid;
        _ = out;
        return error.NotImplemented;
    }

    pub fn cycleNet(self: *MacOS) void {
        _ = self;
    }

    pub fn cycleDisk(self: *MacOS) void {
        _ = self;
    }
};
