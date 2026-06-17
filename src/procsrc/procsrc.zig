const std = @import("std");
const builtin = @import("builtin");
const process = @import("../process.zig");
const sample_mod = @import("../sample.zig");

const Linux = @import("linux.zig").Linux;
const MacOS = @import("macos.zig").MacOS;

/// Compile-time picked backend implementation.
pub const Impl = switch (builtin.os.tag) {
    .linux => Linux,
    .macos => MacOS,
    else => @compileError("Unsupported OS for top-q"),
};

/// ProcessSource — the only OS-coupled surface the rest of the app sees.
/// All methods delegate to the comptime-selected backend.
pub const ProcessSource = struct {
    impl: Impl,

    pub fn init(alloc: std.mem.Allocator) !ProcessSource {
        return .{ .impl = try Impl.init(alloc) };
    }

    pub fn deinit(self: *ProcessSource) void {
        self.impl.deinit();
    }

    /// Refresh `table` with all processes visible to the current user.
    /// `table` is cleared first; strings are allocated in `table.arena`.
    /// CPU% is computed using internal jiffies bookkeeping kept in the
    /// backend across calls — no `prev` needs to be passed in.
    pub fn enumerate(self: *ProcessSource, table: *process.ProcessTable) !void {
        try self.impl.enumerate(table);
    }

    /// Read system-wide summary into `out`. The `per_cpu` slice (and any
    /// other owned data on `out`) is allocated from `alloc`.
    pub fn systemSummary(self: *ProcessSource, alloc: std.mem.Allocator, out: *process.SystemSummary) !void {
        try self.impl.systemSummary(alloc, out);
    }

    /// Send a POSIX signal to `pid`. Returns error.PermissionDenied on EPERM,
    /// error.NoSuchProcess on ESRCH.
    pub fn signal(self: *ProcessSource, pid: process.Pid, sig: process.Signal) !void {
        try self.impl.signal(pid, sig);
    }

    /// One sub-second sample of the focused process. Throughputs (io_*_bps)
    /// are computed against the previous sample for the same PID; first call
    /// for a given PID returns zero throughput.
    pub fn sample(self: *ProcessSource, pid: process.Pid, out: *sample_mod.ProcessSample) !void {
        try self.impl.sample(pid, out);
    }

    /// Detail (threads + open file descriptors) for the focused process.
    /// `out` must be freshly init'd; existing items are cleared first.
    pub fn detail(self: *ProcessSource, pid: process.Pid, out: *process.ProcessDetail) !void {
        try self.impl.detail(pid, out);
    }

    /// Request the next sample to advance the network interface (wraps).
    pub fn cycleNet(self: *ProcessSource) void {
        self.impl.cycleNet();
    }

    /// Request the next sample to advance the disk mountpoint (wraps).
    pub fn cycleDisk(self: *ProcessSource) void {
        self.impl.cycleDisk();
    }
};
