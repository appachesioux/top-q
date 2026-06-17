const std = @import("std");
const utils = @import("utils.zig");
const process = @import("process.zig");

pub const HISTORY_CAPACITY: usize = 120;

/// One sample of the focused process (collected at sub-second cadence).
pub const ProcessSample = struct {
    at_ns: i64,
    cpu_pct: f32,
    mem_rss_bytes: u64,
    io_read_delta_bps: u64,
    io_write_delta_bps: u64,
    nthreads: u32,
};

/// Sliding window of recent samples for the focused process. Sized at
/// compile time. `reset` clears state when the focused PID changes.
pub const ProcessHistory = struct {
    pid: process.Pid,
    cpu: utils.RingBuffer(f32, HISTORY_CAPACITY),
    mem_rss: utils.RingBuffer(u64, HISTORY_CAPACITY),
    io_read: utils.RingBuffer(u64, HISTORY_CAPACITY),
    io_write: utils.RingBuffer(u64, HISTORY_CAPACITY),
    started_at_ns: i64,

    pub fn init(pid: process.Pid) ProcessHistory {
        return .{
            .pid = pid,
            .cpu = .init(),
            .mem_rss = .init(),
            .io_read = .init(),
            .io_write = .init(),
            .started_at_ns = utils.nanoTimestamp(),
        };
    }

    pub fn push(self: *ProcessHistory, s: ProcessSample) void {
        self.cpu.push(s.cpu_pct);
        self.mem_rss.push(s.mem_rss_bytes);
        self.io_read.push(s.io_read_delta_bps);
        self.io_write.push(s.io_write_delta_bps);
    }

    pub fn reset(self: *ProcessHistory, new_pid: process.Pid) void {
        self.pid = new_pid;
        self.cpu.clear();
        self.mem_rss.clear();
        self.io_read.clear();
        self.io_write.clear();
        self.started_at_ns = utils.nanoTimestamp();
    }
};

/// Sliding window of system-wide samples (refreshed at delay_ms cadence,
/// not subsegundo). Drives the mini-sparklines inside each top block.
pub const SystemHistory = struct {
    cpu: utils.RingBuffer(f32, HISTORY_CAPACITY),
    mem_pct: utils.RingBuffer(f32, HISTORY_CAPACITY),
    disk_bps: utils.RingBuffer(u64, HISTORY_CAPACITY),
    net_bps: utils.RingBuffer(u64, HISTORY_CAPACITY),

    pub fn init() SystemHistory {
        return .{
            .cpu = .init(),
            .mem_pct = .init(),
            .disk_bps = .init(),
            .net_bps = .init(),
        };
    }

    pub fn push(self: *SystemHistory, s: *const process.SystemSummary) void {
        self.cpu.push(s.cpu_pct_total);
        const mem_pct: f32 = if (s.mem_total_bytes > 0)
            @floatCast(100.0 * @as(f64, @floatFromInt(s.mem_used_bytes)) / @as(f64, @floatFromInt(s.mem_total_bytes)))
        else
            0;
        self.mem_pct.push(mem_pct);
        self.disk_bps.push(s.disk_read_bps + s.disk_write_bps);
        self.net_bps.push(s.net_rx_bps + s.net_tx_bps);
    }
};
