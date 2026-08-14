const std = @import("std");
const process = @import("../process.zig");
const utils = @import("../utils.zig");
const sample_mod = @import("../sample.zig");
const ctx = @import("../ctx.zig");

const Pid = process.Pid;
const Process = process.Process;
const ProcessTable = process.ProcessTable;
const ProcessState = process.ProcessState;
const SystemSummary = process.SystemSummary;
const Signal = process.Signal;
const ProcessSample = sample_mod.ProcessSample;
const ProcessDetail = process.ProcessDetail;
const ThreadInfo = process.ThreadInfo;
const FdInfo = process.FdInfo;
const FdKind = process.FdKind;

// ============================================================================
// Pure parsers — exported for unit tests
// ============================================================================

/// Parsed fields from /proc/<pid>/stat. All numeric fields after `comm`.
pub const PidStat = struct {
    pid: Pid,
    comm: []const u8, // borrows from input buffer (between parens)
    state: ProcessState,
    ppid: Pid,
    utime: u64, // jiffies user mode
    stime: u64, // jiffies kernel mode
    num_threads: u32,
    starttime: u64,
    vsize: u64, // bytes
    rss_pages: u64, // pages (multiply by page_size for bytes)
};

/// Parses one /proc/<pid>/stat line. The `comm` field can contain ')'; we use
/// the standard trick of finding the LAST ')' to delimit it.
pub fn parsePidStat(buf: []const u8) !PidStat {
    // First field is PID up to the first space
    const sp1 = std.mem.indexOfScalar(u8, buf, ' ') orelse return error.MalformedStat;
    const pid = try std.fmt.parseInt(Pid, buf[0..sp1], 10);

    // comm is between '(' and the LAST ')'
    const lp = std.mem.indexOfScalarPos(u8, buf, sp1, '(') orelse return error.MalformedStat;
    const rp = std.mem.lastIndexOfScalar(u8, buf, ')') orelse return error.MalformedStat;
    if (rp <= lp) return error.MalformedStat;
    const comm = buf[lp + 1 .. rp];

    // After ") " come space-separated fields. Field index 0 = state.
    var rest = buf[rp + 1 ..];
    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var idx: usize = 0;

    var state: ProcessState = .unknown;
    var ppid: Pid = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var num_threads: u32 = 0;
    var starttime: u64 = 0;
    var vsize: u64 = 0;
    var rss_pages: u64 = 0;

    while (it.next()) |tok| : (idx += 1) {
        switch (idx) {
            0 => state = ProcessState.fromChar(if (tok.len > 0) tok[0] else '?'),
            1 => ppid = std.fmt.parseInt(Pid, tok, 10) catch 0,
            11 => utime = std.fmt.parseInt(u64, tok, 10) catch 0, // utime  (field 14 overall - we already consumed pid, comm, state, ppid → idx after state=0; so utime is at index 11 from rest start because: 0=state,1=ppid,2=pgrp,3=session,4=tty_nr,5=tpgid,6=flags,7=minflt,8=cminflt,9=majflt,10=cmajflt,11=utime,12=stime)
            12 => stime = std.fmt.parseInt(u64, tok, 10) catch 0,
            17 => num_threads = std.fmt.parseInt(u32, tok, 10) catch 0,
            19 => starttime = std.fmt.parseInt(u64, tok, 10) catch 0,
            20 => vsize = std.fmt.parseInt(u64, tok, 10) catch 0,
            21 => rss_pages = std.fmt.parseInt(u64, tok, 10) catch 0,
            else => {},
        }
        if (idx > 22) break;
    }

    return .{
        .pid = pid,
        .comm = comm,
        .state = state,
        .ppid = ppid,
        .utime = utime,
        .stime = stime,
        .num_threads = num_threads,
        .starttime = starttime,
        .vsize = vsize,
        .rss_pages = rss_pages,
    };
}

/// /proc/<pid>/io — bytes counters. Returns null on parse failure.
pub const PidIo = struct {
    read_bytes: u64,
    write_bytes: u64,
};

pub fn parsePidIo(buf: []const u8) ?PidIo {
    var read_bytes: ?u64 = null;
    var write_bytes: ?u64 = null;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const val_str = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const v = std.fmt.parseInt(u64, val_str, 10) catch continue;
        if (std.mem.eql(u8, key, "read_bytes")) read_bytes = v;
        if (std.mem.eql(u8, key, "write_bytes")) write_bytes = v;
    }
    if (read_bytes == null or write_bytes == null) return null;
    return .{ .read_bytes = read_bytes.?, .write_bytes = write_bytes.? };
}

/// Parsed totals from /proc/stat first line (cpu  ...).
pub const ProcStatCpu = struct {
    total_jiffies: u64,
    idle_jiffies: u64,
};

pub fn parseProcStat(buf: []const u8) !ProcStatCpu {
    // First line: "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
    // Match htop/btop accounting: treat iowait as idle (the CPU is waiting on
    // I/O, not doing work), and skip guest/guest_nice because the kernel
    // already counts those inside user/nice (post-2.6.24).
    const eol = std.mem.indexOfScalar(u8, buf, '\n') orelse return error.MalformedStat;
    const line = buf[0..eol];
    if (!std.mem.startsWith(u8, line, "cpu ")) return error.MalformedStat;

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // "cpu"

    var total: u64 = 0;
    var idle: u64 = 0;
    var idx: usize = 0;
    while (it.next()) |tok| : (idx += 1) {
        if (idx >= 8) break; // guest (8) and guest_nice (9) are double-counted
        const v = std.fmt.parseInt(u64, tok, 10) catch 0;
        total += v;
        if (idx == 3) idle = v; // idle
        if (idx == 4) idle += v; // iowait counted as idle
    }
    return .{ .total_jiffies = total, .idle_jiffies = idle };
}

/// Per-core stats parsed from `cpuN ...` lines of /proc/stat.
/// `total` and `idle` are jiffies (cumulative, monotonically increasing).
pub const PerCpuJiffies = struct {
    total: u64,
    idle: u64,
};

/// Parses ALL `cpuN ...` lines (skipping the aggregate `cpu  ...`) into
/// `out`. Returns the number of cores actually written. `out` must be sized
/// to at least the expected core count.
pub fn parsePerCpuStat(buf: []const u8, out: []PerCpuJiffies) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (n >= out.len) break;
        // Match "cpuN " where N is a digit
        if (line.len < 5) continue;
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        if (!std.ascii.isDigit(line[3])) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // "cpuN"
        var total: u64 = 0;
        var idle: u64 = 0;
        var idx: usize = 0;
        while (it.next()) |tok| : (idx += 1) {
            if (idx >= 8) break;
            const v = std.fmt.parseInt(u64, tok, 10) catch 0;
            total += v;
            if (idx == 3) idle = v;
            if (idx == 4) idle += v;
        }
        out[n] = .{ .total = total, .idle = idle };
        n += 1;
    }
    return n;
}

/// Aggregated /proc/diskstats sectors over physical-only devices.
pub const Diskstats = struct {
    read_sectors: u64 = 0,
    write_sectors: u64 = 0,
};

pub fn isPhysicalDisk(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "loop")) return false;
    if (std.mem.startsWith(u8, name, "ram")) return false;
    if (std.mem.startsWith(u8, name, "dm-")) return false;
    if (std.mem.startsWith(u8, name, "zram")) return false;
    if (std.mem.startsWith(u8, name, "md")) return false;

    // sd*/vd*/hd* without trailing digits = whole disk; with digits = partition
    if (std.mem.startsWith(u8, name, "sd") or
        std.mem.startsWith(u8, name, "vd") or
        std.mem.startsWith(u8, name, "hd"))
    {
        return name.len >= 3 and !std.ascii.isDigit(name[name.len - 1]);
    }
    // nvme<X>n<Y> = whole disk; nvme<X>n<Y>p<Z> = partition
    if (std.mem.startsWith(u8, name, "nvme")) {
        return std.mem.indexOfScalar(u8, name, 'p') == null;
    }
    // mmcblk<X> = whole disk; mmcblk<X>p<Y> = partition
    if (std.mem.startsWith(u8, name, "mmcblk")) {
        return std.mem.indexOfScalar(u8, name, 'p') == null;
    }
    return false;
}

pub fn parseDiskstats(buf: []const u8) Diskstats {
    var out: Diskstats = .{};
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next() orelse continue; // major
        _ = it.next() orelse continue; // minor
        const name = it.next() orelse continue;
        if (!isPhysicalDisk(name)) continue;
        // Field 4 (index 3) = reads_completed; we want sectors_read (index 5)
        // and sectors_written (index 9). Skip 2 fields, then take 1, skip 3, take 1.
        _ = it.next() orelse continue; // reads_completed
        _ = it.next() orelse continue; // reads_merged
        const rs = it.next() orelse continue; // sectors_read
        _ = it.next() orelse continue; // time_reading
        _ = it.next() orelse continue; // writes_completed
        _ = it.next() orelse continue; // writes_merged
        const ws = it.next() orelse continue; // sectors_written
        const r = std.fmt.parseInt(u64, rs, 10) catch 0;
        const w = std.fmt.parseInt(u64, ws, 10) catch 0;
        out.read_sectors += r;
        out.write_sectors += w;
    }
    return out;
}

// ============================================================================
// /proc/mounts — interesting mountpoints (cyclable in the disk block)
// ============================================================================

/// Filesystem types that are pseudo / virtual / not interesting to show in
/// the disk block. Anything not in this list is kept (real disks, fuse,
/// nfs, sshfs, etc.).
const SKIP_FSTYPES = [_][]const u8{
    "proc",        "sysfs",    "devpts",     "devtmpfs",        "tmpfs",
    "cgroup",      "cgroup2",  "securityfs", "debugfs",         "tracefs",
    "fusectl",     "configfs", "mqueue",     "hugetlbfs",       "autofs",
    "binfmt_misc", "pstore",   "bpf",        "rpc_pipefs",      "nsfs",
    "efivarfs",    "ramfs",    "selinuxfs",  "fuse.gvfsd-fuse", "fuse.portal",
    "squashfs",    "overlay",
};

pub const MountEntry = struct {
    path_buf: [256]u8 = undefined,
    path_len: u8 = 0,
    dev_buf: [256]u8 = undefined,
    dev_len: u8 = 0,

    pub fn path(self: *const MountEntry) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn device(self: *const MountEntry) []const u8 {
        return self.dev_buf[0..self.dev_len];
    }
};

/// Parse `/proc/mounts` into `out`, skipping pseudo filesystems, duplicate device
/// subvolumes (e.g. Btrfs @tmp/@log), and EFI boot partitions. Returns the
/// number of entries written. Caller-provided buffer caps the count.
pub fn enumerateMounts(buf: []const u8, out: []MountEntry) u8 {
    var n: u8 = 0;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (n >= out.len) break;
        if (line.len == 0) continue;
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const device = parts.next() orelse continue;
        const mountpoint = parts.next() orelse continue;
        const fstype = parts.next() orelse continue;

        var skip = false;
        for (SKIP_FSTYPES) |s| {
            if (std.mem.eql(u8, fstype, s)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        // Skip EFI system partitions and boot loaders
        if (std.mem.eql(u8, mountpoint, "/boot/efi") or
            std.mem.eql(u8, mountpoint, "/efi") or
            std.mem.eql(u8, mountpoint, "/boot"))
        {
            continue;
        }

        // Must be a real block device or real network filesystem
        if (!std.mem.startsWith(u8, device, "/dev/")) {
            if (!std.mem.eql(u8, fstype, "nfs") and
                !std.mem.eql(u8, fstype, "nfs4") and
                !std.mem.eql(u8, fstype, "cifs") and
                !std.mem.eql(u8, fstype, "smb3") and
                !std.mem.eql(u8, fstype, "fuse.sshfs"))
            {
                continue;
            }
        }

        if (mountpoint.len == 0 or mountpoint.len > 255) continue;
        if (device.len == 0 or device.len > 255) continue;

        // Deduplicate by device and mountpoint:
        // If the same physical device is mounted at multiple locations (e.g. Btrfs subvolumes),
        // keep only one entry (preferring "/" if present).
        var dup_idx: ?usize = null;
        for (out[0..n], 0..) |existing, i| {
            if (std.mem.eql(u8, existing.device(), device) or std.mem.eql(u8, existing.path(), mountpoint)) {
                dup_idx = i;
                break;
            }
        }

        if (dup_idx) |di| {
            if (std.mem.eql(u8, mountpoint, "/") and !std.mem.eql(u8, out[di].path(), "/")) {
                @memcpy(out[di].path_buf[0..mountpoint.len], mountpoint);
                out[di].path_len = @intCast(mountpoint.len);
            }
            continue;
        }

        @memcpy(out[n].path_buf[0..mountpoint.len], mountpoint);
        out[n].path_len = @intCast(mountpoint.len);
        @memcpy(out[n].dev_buf[0..device.len], device);
        out[n].dev_len = @intCast(device.len);
        n += 1;
    }

    // Ensure "/" is at index 0 if present
    var root_idx: ?usize = null;
    for (out[0..n], 0..) |m, i| {
        if (std.mem.eql(u8, m.path(), "/")) {
            root_idx = i;
            break;
        }
    }
    if (root_idx) |ri| {
        if (ri > 0) {
            const root_entry = out[ri];
            var k: usize = ri;
            while (k > 0) : (k -= 1) {
                out[k] = out[k - 1];
            }
            out[0] = root_entry;
        }
    }

    return n;
}

// ============================================================================
// /proc/net/dev — per-interface byte counters
// ============================================================================

/// Reject loopback, bridges, docker/veth/virtual tunnels.
pub fn isPhysicalIface(name: []const u8) bool {
    if (std.mem.eql(u8, name, "lo")) return false;
    if (std.mem.startsWith(u8, name, "docker")) return false;
    if (std.mem.startsWith(u8, name, "veth")) return false;
    if (std.mem.startsWith(u8, name, "br-")) return false;
    if (std.mem.startsWith(u8, name, "virbr")) return false;
    if (std.mem.startsWith(u8, name, "tun")) return false;
    if (std.mem.startsWith(u8, name, "tap")) return false;
    if (std.mem.startsWith(u8, name, "wg")) return false;
    return true;
}

pub const IfaceStats = struct {
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
};

pub const IfaceEntry = struct {
    name_buf: [16]u8 = undefined,
    name_len: u8 = 0,
    stats: IfaceStats = .{},

    pub fn name(self: *const IfaceEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Parse /proc/net/dev into up to `out.len` physical-interface entries.
/// Returns number of entries filled. Headers (first 2 lines) are skipped.
pub fn parseNetDev(buf: []const u8, out: []IfaceEntry) u8 {
    var count: u8 = 0;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    _ = lines.next(); // "Inter-|   Receive..."
    _ = lines.next(); // " face |bytes..."
    while (lines.next()) |line| {
        if (count >= out.len) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const iface_name = std.mem.trim(u8, line[0..colon], " \t");
        if (!isPhysicalIface(iface_name)) continue;
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const rx_s = it.next() orelse continue;
        // skip packets, errs, drop, fifo, frame, compressed, multicast (7 fields)
        var skipped: usize = 0;
        while (skipped < 7) : (skipped += 1) {
            _ = it.next() orelse break;
        }
        const tx_s = it.next() orelse continue;
        const rx = std.fmt.parseInt(u64, rx_s, 10) catch continue;
        const tx = std.fmt.parseInt(u64, tx_s, 10) catch continue;

        const n = @min(iface_name.len, out[count].name_buf.len);
        @memcpy(out[count].name_buf[0..n], iface_name[0..n]);
        out[count].name_len = @intCast(n);
        out[count].stats = .{ .rx_bytes = rx, .tx_bytes = tx };
        count += 1;
    }
    return count;
}

/// Parsed values from /proc/meminfo (in bytes).
pub const Meminfo = struct {
    mem_total_bytes: u64 = 0,
    mem_available_bytes: u64 = 0,
    mem_buffers_bytes: u64 = 0,
    mem_cached_bytes: u64 = 0,
    mem_sreclaimable_bytes: u64 = 0,
    mem_shmem_bytes: u64 = 0,
    swap_total_bytes: u64 = 0,
    swap_free_bytes: u64 = 0,
    swap_cached_bytes: u64 = 0,
};

pub fn parseMeminfo(buf: []const u8) Meminfo {
    var out: Meminfo = .{};
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const val_str = std.mem.trim(u8, line[colon + 1 ..], " \tkB");
        const v_kb = std.fmt.parseInt(u64, val_str, 10) catch continue;
        const bytes = v_kb * 1024;
        if (std.mem.eql(u8, key, "MemTotal")) out.mem_total_bytes = bytes;
        if (std.mem.eql(u8, key, "MemAvailable")) out.mem_available_bytes = bytes;
        if (std.mem.eql(u8, key, "Buffers")) out.mem_buffers_bytes = bytes;
        if (std.mem.eql(u8, key, "Cached")) out.mem_cached_bytes = bytes;
        if (std.mem.eql(u8, key, "SReclaimable")) out.mem_sreclaimable_bytes = bytes;
        if (std.mem.eql(u8, key, "Shmem")) out.mem_shmem_bytes = bytes;
        if (std.mem.eql(u8, key, "SwapTotal")) out.swap_total_bytes = bytes;
        if (std.mem.eql(u8, key, "SwapFree")) out.swap_free_bytes = bytes;
        if (std.mem.eql(u8, key, "SwapCached")) out.swap_cached_bytes = bytes;
    }
    return out;
}

pub fn parseLoadavg(buf: []const u8) [3]f32 {
    var out: [3]f32 = .{ 0, 0, 0 };
    var it = std.mem.tokenizeAny(u8, buf, " \t\n");
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i >= 3) break;
        out[i] = std.fmt.parseFloat(f32, tok) catch 0;
    }
    return out;
}

pub fn parseUptime(buf: []const u8) u64 {
    const sp = std.mem.indexOfScalar(u8, buf, ' ') orelse buf.len;
    const dot = std.mem.indexOfScalar(u8, buf[0..sp], '.') orelse sp;
    return std.fmt.parseInt(u64, buf[0..dot], 10) catch 0;
}

// ============================================================================
// Parallel /proc process snapshot
// ============================================================================

const ProcessMeta = struct {
    starttime: u64,
    uid: u32,
    cmdline: []const u8,
};

/// Reading one process requires multiple procfs operations.  Keep those
/// operations outside ProcessTable so workers only write to their own slot;
/// all allocator/hash-map work is still merged by the collector thread.
const RawProcess = struct {
    valid: bool = false,
    meta_cached: bool = false,
    pid: Pid = 0,
    ppid: Pid = 0,
    uid: u32 = 0,
    state: ProcessState = .unknown,
    utime: u64 = 0,
    stime: u64 = 0,
    num_threads: u32 = 0,
    starttime: u64 = 0,
    vsize: u64 = 0,
    rss_pages: u64 = 0,
    comm_buf: [256]u8 = undefined,
    comm_len: u16 = 0,

    fn comm(self: *const RawProcess) []const u8 {
        return self.comm_buf[0..self.comm_len];
    }
};

const ProcReadWork = struct {
    dir: std.Io.Dir,
    pids: []const Pid,
    out: []RawProcess,
    meta_cache: *const std.AutoHashMapUnmanaged(Pid, ProcessMeta),
    next: std.atomic.Value(usize),
};

/// Eight readers are enough to overlap procfs lookup latency without creating
/// dozens of short-lived threads on large NUMA servers.
const MAX_PROC_READERS: usize = 8;

fn elapsedUs(start_ns: i64, end_ns: i64) u64 {
    if (end_ns <= start_ns) return 0;
    return @as(u64, @intCast(end_ns - start_ns)) / std.time.ns_per_us;
}

fn procReadWorker(work: *ProcReadWork) void {
    while (true) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.pids.len) return;

        const pid = work.pids[index];
        var relative_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&relative_buf, "{d}/stat", .{pid}) catch continue;
        var stat_buf: [4096]u8 = undefined;
        const n = readSmallFileAt(work.dir, stat_path, &stat_buf) catch continue;
        const ps = parsePidStat(stat_buf[0..n]) catch continue;

        const cached_meta = work.meta_cache.get(pid);
        const meta_cached = cached_meta != null and cached_meta.?.starttime == ps.starttime;
        const uid: u32 = if (meta_cached)
            cached_meta.?.uid
        else blk: {
            // Resolve the owner relative to the already-open /proc directory.
            // Existing processes reuse ProcessMeta, so this syscall normally
            // runs only for newly-created or PID-reused processes.
            const pid_path = std.fmt.bufPrintZ(&relative_buf, "{d}", .{pid}) catch continue;
            var stx: std.os.linux.Statx = undefined;
            break :blk if (std.os.linux.errno(std.os.linux.statx(
                work.dir.handle,
                pid_path,
                std.os.linux.AT.SYMLINK_NOFOLLOW,
                .{ .UID = true },
                &stx,
            )) == .SUCCESS) stx.uid else 0;
        };

        var raw: RawProcess = .{
            .valid = true,
            .meta_cached = meta_cached,
            .pid = ps.pid,
            .ppid = ps.ppid,
            .uid = uid,
            .state = ps.state,
            .utime = ps.utime,
            .stime = ps.stime,
            .num_threads = ps.num_threads,
            .starttime = ps.starttime,
            .vsize = ps.vsize,
            .rss_pages = ps.rss_pages,
        };
        const comm_len = @min(ps.comm.len, raw.comm_buf.len);
        @memcpy(raw.comm_buf[0..comm_len], ps.comm[0..comm_len]);
        raw.comm_len = @intCast(comm_len);
        work.out[index] = raw;
    }
}

fn readProcessesParallel(
    dir: std.Io.Dir,
    pids: []const Pid,
    out: []RawProcess,
    cpu_count: usize,
    meta_cache: *const std.AutoHashMapUnmanaged(Pid, ProcessMeta),
) usize {
    if (pids.len == 0) return 0;

    var work: ProcReadWork = .{
        .dir = dir,
        .pids = pids,
        .out = out,
        .meta_cache = meta_cache,
        .next = std.atomic.Value(usize).init(0),
    };

    const reader_count = @max(@as(usize, 1), @min(MAX_PROC_READERS, @min(cpu_count, pids.len)));
    var threads: [MAX_PROC_READERS - 1]?std.Thread = @splat(null);
    var spawned: usize = 0;
    while (spawned + 1 < reader_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, procReadWorker, .{&work}) catch break;
    }

    // The collector participates too, so even a thread creation failure falls
    // back to a correct serial scan instead of dropping the refresh.
    procReadWorker(&work);
    for (threads[0..spawned]) |thread| thread.?.join();
    return spawned + 1;
}

// ============================================================================
// Linux backend
// ============================================================================

pub const Linux = struct {
    const CPU_FREQ_INTERVAL_NS: i64 = std.time.ns_per_s;

    const StaticSystemInfo = struct {
        os_name: []const u8,
        kernel_release: []const u8,
        host_model: []const u8,
        hostname: []const u8,
        cpu_model: []const u8,
        gpus: []const []const u8,

        fn init(alloc: std.mem.Allocator) StaticSystemInfo {
            return .{
                .os_name = parseOsName(alloc),
                .kernel_release = parseKernelRelease(alloc),
                .host_model = parseHostModel(alloc),
                .hostname = parseHostname(alloc),
                .cpu_model = parseCpuModel(alloc),
                .gpus = detectGpus(alloc),
            };
        }

        fn deinit(self: *StaticSystemInfo, alloc: std.mem.Allocator) void {
            alloc.free(self.os_name);
            alloc.free(self.kernel_release);
            alloc.free(self.host_model);
            alloc.free(self.hostname);
            alloc.free(self.cpu_model);
            for (self.gpus) |gpu| alloc.free(gpu);
            if (self.gpus.len > 0) alloc.free(self.gpus);
        }
    };

    alloc: std.mem.Allocator,
    page_size: u64,
    nproc: u32,
    last_total_jiffies: u64, // for global CPU% (header) — owned by systemSummary
    enum_last_total_jiffies: u64, // total-jiffies baseline for per-process CPU% — owned by enumerate
    last_idle_jiffies: u64,
    prev_jiffies: std.AutoHashMapUnmanaged(Pid, u64), // per-process bookkeeping for enumerate cpu%
    process_meta: std.AutoHashMapUnmanaged(Pid, ProcessMeta), // stable PID identity, uid and cmdline
    uid_cache: utils.UidCache, // /etc/passwd is loaded once, not once per refresh

    // Sub-second sample state — tracks one PID at a time.
    sample_pid: Pid,
    sample_last_jiffies: u64,
    sample_last_total: u64,
    sample_last_io_read: u64,
    sample_last_io_write: u64,
    sample_last_ns: i64,

    // ----- US5: per-core CPU + disk throughput state -----
    last_per_cpu: []PerCpuJiffies, // owned, sized = nproc
    last_disk: Diskstats,
    last_disk_ns: i64,
    static_info: StaticSystemInfo,
    cpu_freq_mhz: u32,
    cpu_freq_sampled_ns: i64,

    // ----- Network: primary physical interface bytes counter state -----
    /// Name of the interface we're tracking across calls. Empty on first call
    /// or after the previously chosen iface disappeared. Max 15 (IFNAMSIZ-1).
    net_iface_buf: [16]u8 = undefined,
    net_iface_len: u8 = 0,
    last_net: IfaceStats = .{},
    last_net_ns: i64 = 0,
    net_ip: []const u8 = &.{},
    net_ip_iface_buf: [16]u8 = undefined,
    net_ip_iface_len: u8 = 0,

    // ----- Disk: sticky mountpoint shown in the disk block -----
    /// Mount path currently shown. "/" by default; cycled by app via cycleDisk().
    disk_mount_buf: [256]u8 = undefined,
    disk_mount_len: u8 = 1,

    // ----- Cycle requests posted from main thread, drained on next sample -----
    net_cycle_pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    disk_cycle_pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(alloc: std.mem.Allocator) !Linux {
        const nproc = std.Thread.getCpuCount() catch 1;
        const last_per_cpu = try alloc.alloc(PerCpuJiffies, nproc);
        errdefer alloc.free(last_per_cpu);
        @memset(last_per_cpu, .{ .total = 0, .idle = 0 });
        const static_info = StaticSystemInfo.init(alloc);
        var disk_mount_buf: [256]u8 = undefined;
        disk_mount_buf[0] = '/';
        return .{
            .alloc = alloc,
            .page_size = std.heap.pageSize(),
            .nproc = @intCast(nproc),
            .last_total_jiffies = 0,
            .enum_last_total_jiffies = 0,
            .last_idle_jiffies = 0,
            .prev_jiffies = .{},
            .process_meta = .{},
            .uid_cache = utils.UidCache.init(alloc),
            .sample_pid = 0,
            .sample_last_jiffies = 0,
            .sample_last_total = 0,
            .sample_last_io_read = 0,
            .sample_last_io_write = 0,
            .sample_last_ns = 0,
            .last_per_cpu = last_per_cpu,
            .last_disk = .{},
            .last_disk_ns = 0,
            .static_info = static_info,
            .cpu_freq_mhz = 0,
            .cpu_freq_sampled_ns = 0,
            .net_iface_buf = undefined,
            .net_iface_len = 0,
            .last_net = .{},
            .last_net_ns = 0,
            .net_ip = &.{},
            .net_ip_iface_buf = undefined,
            .net_ip_iface_len = 0,
            .disk_mount_buf = disk_mount_buf,
            .disk_mount_len = 1,
            .net_cycle_pending = std.atomic.Value(u32).init(0),
            .disk_cycle_pending = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Linux) void {
        self.prev_jiffies.deinit(self.alloc);
        var it = self.process_meta.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.value_ptr.cmdline);
        }
        self.process_meta.deinit(self.alloc);
        self.uid_cache.deinit();
        self.alloc.free(self.last_per_cpu);
        self.static_info.deinit(self.alloc);
        if (self.net_ip.len > 0) self.alloc.free(self.net_ip);
    }

    /// Request the next sample to advance the network interface to the next
    /// detected physical iface (wraps around). Atomic, thread-safe.
    pub fn cycleNet(self: *Linux) void {
        _ = self.net_cycle_pending.fetchAdd(1, .seq_cst);
    }

    /// Request the next sample to advance the disk to the next mountpoint.
    pub fn cycleDisk(self: *Linux) void {
        _ = self.disk_cycle_pending.fetchAdd(1, .seq_cst);
    }

    pub fn enumerate(self: *Linux, table: *ProcessTable) !void {
        const collect_started_ns = utils.nanoTimestamp();
        table.clear();
        const arena = table.arena.allocator();

        // Read /proc/stat to compute global jiffies delta for CPU% scaling
        var stat_buf: [4096]u8 = undefined;
        const stat_n = readSmallFile("/proc/stat", &stat_buf) catch 0;
        const cur_cpu = parseProcStat(stat_buf[0..stat_n]) catch ProcStatCpu{ .total_jiffies = 0, .idle_jiffies = 0 };

        // Per-process CPU% scales against enumerate's OWN jiffies baseline,
        // independent of systemSummary's last_total_jiffies. The collector
        // posts summary and table as separate events, so the two run in
        // arbitrary order — sharing the baseline would let whichever runs first
        // zero out the other's delta (→ absurd per-process %). The very first
        // enumerate has an empty prev_jiffies, so CPU% is 0 (btop-style) and
        // becomes real on the next tick.
        const total_delta: u64 = if (cur_cpu.total_jiffies > self.enum_last_total_jiffies)
            cur_cpu.total_jiffies - self.enum_last_total_jiffies
        else
            0;

        var dir = std.Io.Dir.openDirAbsolute(ctx.io, "/proc", .{ .iterate = true }) catch return error.ProcUnavailable;
        defer dir.close(ctx.io);

        // getdents itself is serial, but the expensive per-PID open/read/statx
        // work is independent. Snapshot the numeric entries first, then let a
        // bounded group of readers fill disjoint RawProcess slots.
        var pids: std.ArrayList(Pid) = .empty;
        defer pids.deinit(self.alloc);
        var iter = dir.iterate();
        while (iter.next(ctx.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const pid = std.fmt.parseInt(Pid, entry.name, 10) catch continue;
            pids.append(self.alloc, pid) catch return error.OutOfMemory;
        }
        const dir_finished_ns = utils.nanoTimestamp();

        const raw_procs = try self.alloc.alloc(RawProcess, pids.items.len);
        defer self.alloc.free(raw_procs);
        for (raw_procs) |*raw| raw.* = .{};
        const reader_count = readProcessesParallel(dir, pids.items, raw_procs, self.nproc, &self.process_meta);
        const read_finished_ns = utils.nanoTimestamp();

        // Use one timestamp for the generation. Calling the clock once per PID
        // added thousands of unnecessary vDSO calls on process-heavy hosts.
        const sampled_at_ns = utils.nanoTimestamp();
        for (raw_procs) |*raw| {
            if (!raw.valid) continue; // process exited while /proc was scanned

            // CPU% delta vs previous generation
            const cur_jiffies = raw.utime + raw.stime;
            var cpu_pct: f32 = 0;
            if (raw.meta_cached and self.prev_jiffies.get(raw.pid) != null) {
                const prev_j = self.prev_jiffies.get(raw.pid).?;
                if (cur_jiffies >= prev_j and total_delta > 0) {
                    const proc_delta: u64 = cur_jiffies - prev_j;
                    const num: f64 = @floatFromInt(proc_delta);
                    const den: f64 = @floatFromInt(total_delta);
                    cpu_pct = @floatCast(num / den * @as(f64, @floatFromInt(self.nproc)) * 100.0);
                }
            }
            try self.prev_jiffies.put(self.alloc, raw.pid, cur_jiffies);

            // UidCache is source-owned and its strings are stable for the
            // collector lifetime, so /etc/passwd no longer needs to be read and
            // copied into every ProcessTable generation.
            const user = self.uid_cache.resolve(raw.uid) catch "";
            const comm_dup = arena.dupe(u8, raw.comm()) catch continue;

            const cached_cmdline = if (raw.meta_cached)
                self.process_meta.get(raw.pid).?.cmdline
            else blk: {
                const c = if (raw.ppid == 2)
                    // Kernel threads (children of kthreadd) always have an empty
                    // cmdline — skip the wasted open+read and show "[comm]"
                    // directly. Speeds up the cold enumerate ~2x on typical
                    // systems where kernel threads are most of /proc.
                    try std.fmt.allocPrint(self.alloc, "[{s}]", .{raw.comm()})
                else
                    readCmdlineAt(dir, self.alloc, raw.pid, raw.comm()) catch try self.alloc.dupe(u8, raw.comm());

                const old_meta = self.process_meta.fetchPut(self.alloc, raw.pid, .{
                    .starttime = raw.starttime,
                    .uid = raw.uid,
                    .cmdline = c,
                }) catch |err| {
                    self.alloc.free(c);
                    return err;
                };
                if (old_meta) |old| {
                    // Same numeric PID, different starttime: replace stale
                    // identity. The baseline was overwritten above after the
                    // stale value was deliberately ignored for this sample.
                    self.alloc.free(old.value.cmdline);
                }
                break :blk c;
            };
            const cmdline_dup = arena.dupe(u8, cached_cmdline) catch comm_dup;

            try table.append(.{
                .pid = raw.pid,
                .ppid = raw.ppid,
                .uid = raw.uid,
                .user = user,
                .comm = comm_dup,
                .cmdline = cmdline_dup,
                .state = raw.state,
                .cpu_pct = cpu_pct,
                .mem_rss_bytes = raw.rss_pages * self.page_size,
                .mem_vsz_bytes = raw.vsize,
                .nthreads = raw.num_threads,
                .io_read_bytes = 0,
                .io_write_bytes = 0,
                .io_available = false, // US2 will populate from /proc/<pid>/io
                .last_jiffies = cur_jiffies,
                .last_sample_ns = sampled_at_ns,
            });
        }

        // Garbage collect dead PIDs from caches
        var dead_pids: std.ArrayList(Pid) = .empty;
        defer dead_pids.deinit(arena);

        var it = self.process_meta.iterator();
        while (it.next()) |entry| {
            const pid = entry.key_ptr.*;
            if (table.lookup(pid) == null) {
                dead_pids.append(arena, pid) catch {};
            }
        }
        for (dead_pids.items) |pid| {
            if (self.process_meta.fetchRemove(pid)) |kv| {
                self.alloc.free(kv.value.cmdline);
            }
            _ = self.prev_jiffies.remove(pid);
        }

        self.enum_last_total_jiffies = cur_cpu.total_jiffies;
        table.sampled_at_ns = sampled_at_ns;
        const collect_finished_ns = utils.nanoTimestamp();
        table.collect_dir_us = elapsedUs(collect_started_ns, dir_finished_ns);
        table.collect_read_us = elapsedUs(dir_finished_ns, read_finished_ns);
        table.collect_merge_us = elapsedUs(read_finished_ns, collect_finished_ns);
        table.collect_total_us = elapsedUs(collect_started_ns, collect_finished_ns);
        table.collect_readers = @intCast(reader_count);
    }

    pub fn systemSummary(self: *Linux, alloc: std.mem.Allocator, out: *SystemSummary) !void {
        // -------- /proc/stat: aggregate + per-core --------
        var stat_buf: [16384]u8 = undefined;
        const stat_n = readSmallFile("/proc/stat", &stat_buf) catch 0;
        const cur_cpu = parseProcStat(stat_buf[0..stat_n]) catch ProcStatCpu{ .total_jiffies = 0, .idle_jiffies = 0 };

        const total_delta: u64 = if (cur_cpu.total_jiffies > self.last_total_jiffies and self.last_total_jiffies != 0)
            cur_cpu.total_jiffies - self.last_total_jiffies
        else
            0;
        const idle_delta: u64 = if (cur_cpu.idle_jiffies > self.last_idle_jiffies and self.last_idle_jiffies != 0)
            cur_cpu.idle_jiffies - self.last_idle_jiffies
        else
            0;
        const cpu_pct: f32 = if (total_delta > 0)
            100.0 * (1.0 - (@as(f32, @floatFromInt(idle_delta)) / @as(f32, @floatFromInt(total_delta))))
        else
            0;
        self.last_total_jiffies = cur_cpu.total_jiffies;
        self.last_idle_jiffies = cur_cpu.idle_jiffies;

        // Per-core CPU%
        const per_cpu = try alloc.alloc(f32, self.nproc);
        @memset(per_cpu, 0);
        var cur_per_cpu_buf: [256]PerCpuJiffies = undefined;
        const cores_read = parsePerCpuStat(stat_buf[0..stat_n], cur_per_cpu_buf[0..@min(cur_per_cpu_buf.len, self.nproc)]);
        var i: usize = 0;
        while (i < cores_read) : (i += 1) {
            const cur = cur_per_cpu_buf[i];
            const prev = self.last_per_cpu[i];
            if (prev.total != 0 and cur.total > prev.total) {
                const dt = cur.total - prev.total;
                const di = if (cur.idle > prev.idle) cur.idle - prev.idle else 0;
                per_cpu[i] = 100.0 * (1.0 - (@as(f32, @floatFromInt(di)) / @as(f32, @floatFromInt(dt))));
            }
            self.last_per_cpu[i] = cur;
        }

        // -------- /proc/meminfo --------
        var mem_buf: [8192]u8 = undefined;
        const mem_n = readSmallFile("/proc/meminfo", &mem_buf) catch 0;
        const mi = parseMeminfo(mem_buf[0..mem_n]);

        // -------- /proc/loadavg + /proc/uptime --------
        var load_buf: [128]u8 = undefined;
        const load_n = readSmallFile("/proc/loadavg", &load_buf) catch 0;
        const la = parseLoadavg(load_buf[0..load_n]);

        var up_buf: [128]u8 = undefined;
        const up_n = readSmallFile("/proc/uptime", &up_buf) catch 0;
        const up = parseUptime(up_buf[0..up_n]);

        // -------- /proc/diskstats: aggregate physical disks --------
        var ds_buf: [65536]u8 = undefined;
        const ds_n = readSmallFile("/proc/diskstats", &ds_buf) catch 0;
        const cur_disk = parseDiskstats(ds_buf[0..ds_n]);
        const now_ns: i64 = utils.nanoTimestamp();
        var disk_read_bps: u64 = 0;
        var disk_write_bps: u64 = 0;
        if (self.last_disk_ns != 0 and now_ns > self.last_disk_ns) {
            const dt_ns = @as(u64, @intCast(now_ns - self.last_disk_ns));
            const dt_s = @as(f64, @floatFromInt(dt_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
            const dr = if (cur_disk.read_sectors >= self.last_disk.read_sectors) cur_disk.read_sectors - self.last_disk.read_sectors else 0;
            const dw = if (cur_disk.write_sectors >= self.last_disk.write_sectors) cur_disk.write_sectors - self.last_disk.write_sectors else 0;
            // Linux convention: 1 sector = 512 bytes regardless of physical sector size
            disk_read_bps = @intFromFloat(@as(f64, @floatFromInt(dr * 512)) / dt_s);
            disk_write_bps = @intFromFloat(@as(f64, @floatFromInt(dw * 512)) / dt_s);
        }
        self.last_disk = cur_disk;
        self.last_disk_ns = now_ns;

        // -------- /proc/net/dev: pick one physical interface --------
        var net_buf: [8192]u8 = undefined;
        const net_n = readSmallFile("/proc/net/dev", &net_buf) catch 0;
        var ifaces: [16]IfaceEntry = undefined;
        const n_ifaces = parseNetDev(net_buf[0..net_n], ifaces[0..]);

        var chosen_idx: ?usize = null;
        // Prefer sticking with the previously-tracked interface if it's still
        // present; otherwise pick whichever has the most cumulative traffic.
        if (self.net_iface_len > 0) {
            const tracked = self.net_iface_buf[0..self.net_iface_len];
            var k: usize = 0;
            while (k < n_ifaces) : (k += 1) {
                if (std.mem.eql(u8, ifaces[k].name(), tracked)) {
                    chosen_idx = k;
                    break;
                }
            }
        }
        if (chosen_idx == null and n_ifaces > 0) {
            var best: usize = 0;
            var best_sum: u64 = 0;
            var k: usize = 0;
            while (k < n_ifaces) : (k += 1) {
                const sum = ifaces[k].stats.rx_bytes + ifaces[k].stats.tx_bytes;
                if (sum > best_sum) {
                    best = k;
                    best_sum = sum;
                }
            }
            chosen_idx = best;
            const nm = ifaces[best].name();
            @memcpy(self.net_iface_buf[0..nm.len], nm);
            self.net_iface_len = @intCast(nm.len);
            // Interface changed (or first seen) — zero delta state so the next
            // call starts a fresh bps window instead of reporting bogus spike.
            self.last_net = .{};
            self.last_net_ns = 0;
        }

        // Apply pending cycle requests posted from the main thread (one cycle
        // per request). Advancing wraps around the detected iface list.
        const net_cycles = self.net_cycle_pending.swap(0, .seq_cst);
        if (net_cycles > 0 and n_ifaces > 1) {
            var ci = chosen_idx orelse 0;
            ci = (ci + (net_cycles % n_ifaces)) % n_ifaces;
            chosen_idx = ci;
            const nm = ifaces[ci].name();
            @memcpy(self.net_iface_buf[0..nm.len], nm);
            self.net_iface_len = @intCast(nm.len);
            self.last_net = .{};
            self.last_net_ns = 0;
        }

        var net_rx_bps: u64 = 0;
        var net_tx_bps: u64 = 0;
        var iface_name_owned: []const u8 = "";
        if (chosen_idx) |ci| {
            const cur = ifaces[ci].stats;
            if (self.last_net_ns != 0 and now_ns > self.last_net_ns) {
                const dt_ns = @as(u64, @intCast(now_ns - self.last_net_ns));
                const dt_s = @as(f64, @floatFromInt(dt_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
                const drx = if (cur.rx_bytes >= self.last_net.rx_bytes) cur.rx_bytes - self.last_net.rx_bytes else 0;
                const dtx = if (cur.tx_bytes >= self.last_net.tx_bytes) cur.tx_bytes - self.last_net.tx_bytes else 0;
                net_rx_bps = @intFromFloat(@as(f64, @floatFromInt(drx)) / dt_s);
                net_tx_bps = @intFromFloat(@as(f64, @floatFromInt(dtx)) / dt_s);
            }
            self.last_net = cur;
            self.last_net_ns = now_ns;
            iface_name_owned = alloc.dupe(u8, ifaces[ci].name()) catch "";
        }

        // -------- /proc/mounts: enumerate mountpoints + apply cycling --------
        var mounts_buf: [16384]u8 = undefined;
        const mounts_n = readSmallFile("/proc/mounts", &mounts_buf) catch 0;
        var mounts: [32]MountEntry = undefined;
        const n_mounts = enumerateMounts(mounts_buf[0..mounts_n], mounts[0..]);

        // Sample all enumerated mountpoints with statfs
        var sampled_disks_buf: [32]process.DiskMount = undefined;
        var n_sampled_disks: usize = 0;

        for (mounts[0..n_mounts]) |m| {
            if (n_sampled_disks >= sampled_disks_buf.len) break;
            const mpath = m.path();
            var path_z: [257]u8 = undefined;
            if (mpath.len > 256) continue;
            @memcpy(path_z[0..mpath.len], mpath);
            path_z[mpath.len] = 0;

            var sf: Statfs64 = undefined;
            const sf_rc = std.os.linux.syscall2(.statfs, @intFromPtr(@as([*:0]const u8, @ptrCast(&path_z))), @intFromPtr(&sf));
            if (std.os.linux.errno(sf_rc) == .SUCCESS and sf.blocks > 0) {
                const bsize: u64 = @intCast(sf.bsize);
                const d_total = sf.blocks * bsize;
                const d_used = fsUsedBytes(sf.blocks, sf.bfree, bsize);
                const d_avail = sf.bavail * bsize;
                const d_type = fsTypeName(sf.type);
                const d_mount_owned = alloc.dupe(u8, mpath) catch continue;

                sampled_disks_buf[n_sampled_disks] = .{
                    .mount_path = d_mount_owned,
                    .fs_type_name = d_type,
                    .used_bytes = d_used,
                    .total_bytes = d_total,
                    .avail_bytes = d_avail,
                };
                n_sampled_disks += 1;
            }
        }

        const sampled_disks = alloc.dupe(process.DiskMount, sampled_disks_buf[0..n_sampled_disks]) catch &.{};

        // Locate the current sticky mount in the list. If absent (e.g. unmounted),
        // fall back to the first available; if list empty, keep "/" hardcoded.
        const sticky_path = self.disk_mount_buf[0..self.disk_mount_len];
        var mount_idx: ?usize = null;
        var mi_k: usize = 0;
        while (mi_k < sampled_disks.len) : (mi_k += 1) {
            if (std.mem.eql(u8, sampled_disks[mi_k].mount_path, sticky_path)) {
                mount_idx = mi_k;
                break;
            }
        }
        if (mount_idx == null and sampled_disks.len > 0) {
            mount_idx = 0;
            const p = sampled_disks[0].mount_path;
            @memcpy(self.disk_mount_buf[0..p.len], p);
            self.disk_mount_len = @intCast(p.len);
        }

        const disk_cycles = self.disk_cycle_pending.swap(0, .seq_cst);
        if (disk_cycles > 0 and sampled_disks.len > 1) {
            var mi2 = mount_idx orelse 0;
            mi2 = (mi2 + (disk_cycles % sampled_disks.len)) % sampled_disks.len;
            mount_idx = mi2;
            const p = sampled_disks[mi2].mount_path;
            @memcpy(self.disk_mount_buf[0..p.len], p);
            self.disk_mount_len = @intCast(p.len);
        }

        const active_disk: process.DiskMount = if (sampled_disks.len > 0)
            sampled_disks[mount_idx orelse 0]
        else
            .{};

        var bat_pct: ?u8 = null;
        var bat_status: []const u8 = "";
        parseBattery(alloc, &bat_pct, &bat_status);

        if (self.cpu_freq_sampled_ns == 0 or now_ns - self.cpu_freq_sampled_ns >= CPU_FREQ_INTERVAL_NS) {
            self.cpu_freq_mhz = readCpuFreqMhz();
            self.cpu_freq_sampled_ns = now_ns;
        }

        const iface_changed = !std.mem.eql(
            u8,
            self.net_ip_iface_buf[0..self.net_ip_iface_len],
            iface_name_owned,
        );
        if (iface_changed) {
            if (self.net_ip.len > 0) self.alloc.free(self.net_ip);
            self.net_ip = queryIfaceIp(iface_name_owned, self.alloc);
            if (iface_name_owned.len <= self.net_ip_iface_buf.len) {
                @memcpy(self.net_ip_iface_buf[0..iface_name_owned.len], iface_name_owned);
                self.net_ip_iface_len = @intCast(iface_name_owned.len);
            } else {
                self.net_ip_iface_len = 0;
            }
        }

        out.* = .{
            .cpu_pct_total = cpu_pct,
            .per_cpu = per_cpu,
            .mem_used_bytes = if (mi.mem_total_bytes > mi.mem_available_bytes) mi.mem_total_bytes - mi.mem_available_bytes else 0,
            .mem_total_bytes = mi.mem_total_bytes,
            .mem_available_bytes = mi.mem_available_bytes,
            .mem_cache_bytes = mi.mem_cached_bytes - mi.mem_shmem_bytes,
            .swap_used_bytes = if (mi.swap_total_bytes > mi.swap_free_bytes + mi.swap_cached_bytes) mi.swap_total_bytes - mi.swap_free_bytes - mi.swap_cached_bytes else 0,
            .swap_total_bytes = mi.swap_total_bytes,
            .loadavg = la,
            .uptime_seconds = up,
            .nproc = self.nproc,
            .disk_read_bps = disk_read_bps,
            .disk_write_bps = disk_write_bps,
            .disks = sampled_disks,
            .fs_root_used_bytes = active_disk.used_bytes,
            .fs_root_total_bytes = active_disk.total_bytes,
            .fs_root_avail_bytes = active_disk.avail_bytes,
            .fs_mount_path = active_disk.mount_path,
            .fs_type_name = active_disk.fs_type_name,
            .net_iface_name = iface_name_owned,
            .net_rx_bps = net_rx_bps,
            .net_tx_bps = net_tx_bps,
            .net_ip = self.net_ip,
            .hostname = self.static_info.hostname,
            .os_name = self.static_info.os_name,
            .kernel_release = self.static_info.kernel_release,
            .host_model = self.static_info.host_model,
            .cpu_model = self.static_info.cpu_model,
            .cpu_freq_mhz = self.cpu_freq_mhz,
            .gpus = self.static_info.gpus,
            .battery_pct = bat_pct,
            .battery_status = bat_status,
        };
    }

    pub fn signal(self: *Linux, pid: Pid, sig: Signal) !void {
        _ = self;
        std.posix.kill(@intCast(pid), @enumFromInt(@intFromEnum(sig))) catch |e| switch (e) {
            error.PermissionDenied => return error.PermissionDenied,
            error.ProcessNotFound => return error.NoSuchProcess,
            else => return e,
        };
    }

    /// Sub-second sample of the focused process. Resets internal delta state
    /// when the focused PID changes (so first sample for a PID returns 0
    /// throughputs but valid mem/threads).
    pub fn sample(self: *Linux, pid: Pid, out: *ProcessSample) !void {
        // Read /proc/stat for global delta
        var stat_buf: [4096]u8 = undefined;
        const stat_n = readSmallFile("/proc/stat", &stat_buf) catch 0;
        const cur_total = (parseProcStat(stat_buf[0..stat_n]) catch ProcStatCpu{ .total_jiffies = 0, .idle_jiffies = 0 }).total_jiffies;

        // Read /proc/<pid>/stat
        var path_buf: [64]u8 = undefined;
        const ps_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid});
        var pid_stat_buf: [4096]u8 = undefined;
        const psn = try readSmallFile(ps_path, &pid_stat_buf);
        const ps = try parsePidStat(pid_stat_buf[0..psn]);
        const cur_jiffies = ps.utime + ps.stime;

        // Read /proc/<pid>/io (may fail w/ permission denied)
        const io_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/io", .{pid});
        var io_buf: [4096]u8 = undefined;
        const io_n = readSmallFile(io_path, &io_buf) catch 0;
        const cur_io: PidIo = parsePidIo(io_buf[0..io_n]) orelse .{ .read_bytes = self.sample_last_io_read, .write_bytes = self.sample_last_io_write };

        const now_ns: i64 = utils.nanoTimestamp();

        // If focus PID changed, reset deltas to 0 for this tick
        if (self.sample_pid != pid) {
            self.sample_pid = pid;
            self.sample_last_jiffies = cur_jiffies;
            self.sample_last_total = cur_total;
            self.sample_last_io_read = cur_io.read_bytes;
            self.sample_last_io_write = cur_io.write_bytes;
            self.sample_last_ns = now_ns;
            out.* = .{
                .at_ns = now_ns,
                .cpu_pct = 0,
                .mem_rss_bytes = ps.rss_pages * self.page_size,
                .io_read_delta_bps = 0,
                .io_write_delta_bps = 0,
                .nthreads = ps.num_threads,
            };
            return;
        }

        const delta_proc: u64 = if (cur_jiffies >= self.sample_last_jiffies) cur_jiffies - self.sample_last_jiffies else 0;
        const delta_total: u64 = if (cur_total >= self.sample_last_total) cur_total - self.sample_last_total else 0;
        const cpu_pct: f32 = blk: {
            if (delta_total == 0) break :blk 0;
            const num: f64 = @floatFromInt(delta_proc);
            const den: f64 = @floatFromInt(delta_total);
            break :blk @floatCast(num / den * @as(f64, @floatFromInt(self.nproc)) * 100.0);
        };

        const elapsed_ns: i64 = if (now_ns > self.sample_last_ns) now_ns - self.sample_last_ns else 1;
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const dr: u64 = if (cur_io.read_bytes >= self.sample_last_io_read) cur_io.read_bytes - self.sample_last_io_read else 0;
        const dw: u64 = if (cur_io.write_bytes >= self.sample_last_io_write) cur_io.write_bytes - self.sample_last_io_write else 0;
        const rd_bps: u64 = @intFromFloat(@as(f64, @floatFromInt(dr)) / elapsed_s);
        const wr_bps: u64 = @intFromFloat(@as(f64, @floatFromInt(dw)) / elapsed_s);

        self.sample_last_jiffies = cur_jiffies;
        self.sample_last_total = cur_total;
        self.sample_last_io_read = cur_io.read_bytes;
        self.sample_last_io_write = cur_io.write_bytes;
        self.sample_last_ns = now_ns;

        out.* = .{
            .at_ns = now_ns,
            .cpu_pct = cpu_pct,
            .mem_rss_bytes = ps.rss_pages * self.page_size,
            .io_read_delta_bps = rd_bps,
            .io_write_delta_bps = wr_bps,
            .nthreads = ps.num_threads,
        };
    }

    pub fn detail(self: *Linux, pid: Pid, out: *ProcessDetail) !void {
        _ = self;
        out.threads.clearRetainingCapacity();
        out.fds.clearRetainingCapacity();
        out.fds_truncated = false;
        _ = out.arena.reset(.retain_capacity);
        const arena = out.arena.allocator();

        // ----- Threads from /proc/<pid>/task/* -----
        var task_path_buf: [64]u8 = undefined;
        const task_path = try std.fmt.bufPrint(&task_path_buf, "/proc/{d}/task", .{pid});
        if (std.Io.Dir.openDirAbsolute(ctx.io, task_path, .{ .iterate = true })) |task_dir_const| {
            var task_dir = task_dir_const;
            defer task_dir.close(ctx.io);
            var titer = task_dir.iterate();
            const THREAD_CAP: usize = 512;
            while (titer.next(ctx.io) catch null) |e| {
                if (out.threads.items.len >= THREAD_CAP) break;
                if (e.kind != .directory) continue;
                const tid = std.fmt.parseInt(Pid, e.name, 10) catch continue;
                var tstat_buf: [4096]u8 = undefined;
                var tstat_path_buf: [96]u8 = undefined;
                const tstat_path = std.fmt.bufPrint(&tstat_path_buf, "/proc/{d}/task/{d}/stat", .{ pid, tid }) catch continue;
                const tn = readSmallFile(tstat_path, &tstat_buf) catch continue;
                const ts = parsePidStat(tstat_buf[0..tn]) catch continue;
                const name_dup = arena.dupe(u8, ts.comm) catch continue;
                out.threads.append(out.alloc, .{
                    .tid = tid,
                    .state = ts.state,
                    .cpu_pct = 0, // per-thread CPU% needs deltas; deferred
                    .name = name_dup,
                }) catch break;
            }
        } else |_| {
            // fall through with empty threads list
        }

        // ----- File descriptors from /proc/<pid>/fd/* -----
        var fd_path_buf: [64]u8 = undefined;
        const fd_path = try std.fmt.bufPrint(&fd_path_buf, "/proc/{d}/fd", .{pid});
        if (std.Io.Dir.openDirAbsolute(ctx.io, fd_path, .{ .iterate = true })) |fd_dir_const| {
            var fd_dir = fd_dir_const;
            defer fd_dir.close(ctx.io);
            var fditer = fd_dir.iterate();
            const FD_CAP: usize = 256;
            while (fditer.next(ctx.io) catch null) |e| {
                if (e.kind != .sym_link) continue;
                if (out.fds.items.len >= FD_CAP) {
                    out.fds_truncated = true;
                    break;
                }
                const fdnum = std.fmt.parseInt(u32, e.name, 10) catch continue;

                var link_path_buf: [128]u8 = undefined;
                const link_path = std.fmt.bufPrint(&link_path_buf, "/proc/{d}/fd/{d}", .{ pid, fdnum }) catch continue;
                var target_buf: [4096]u8 = undefined;
                const target_n = std.Io.Dir.readLinkAbsolute(ctx.io, link_path, &target_buf) catch continue;
                const target = target_buf[0..target_n];
                const target_dup = arena.dupe(u8, target) catch continue;
                out.fds.append(out.alloc, .{
                    .fd = fdnum,
                    .kind = classifyFd(target),
                    .target = target_dup,
                }) catch break;
            }
        } else |_| {
            // fall through with empty fd list
        }

        out.pid = pid;
    }
};

fn readCmdlineAt(dir: std.Io.Dir, alloc: std.mem.Allocator, pid: Pid, comm: []const u8) ![]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{d}/cmdline", .{pid}) catch return try alloc.dupe(u8, comm);

    var buf: [4096]u8 = undefined;
    const n = readSmallFileAt(dir, path, &buf) catch 0;
    if (n == 0) {
        if (comm.len > 0 and comm[0] == '[') {
            return try alloc.dupe(u8, comm);
        }
        return std.fmt.allocPrint(alloc, "[{s}]", .{comm}) catch try alloc.dupe(u8, comm);
    }

    // NUL → space in place, collapsing consecutive NULs (argv separator);
    // a single dupe at the end avoids the ArrayList + toOwnedSlice copies.
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = buf[i];
        if (c == 0) {
            if (i + 1 < n and buf[i + 1] != 0) {
                buf[out_len] = ' ';
                out_len += 1;
            }
        } else {
            buf[out_len] = c;
            out_len += 1;
        }
    }

    if (out_len == 0) {
        return try alloc.dupe(u8, comm);
    }
    return try alloc.dupe(u8, buf[0..out_len]);
}

fn classifyFd(target: []const u8) FdKind {
    if (std.mem.startsWith(u8, target, "socket:")) return .socket;
    if (std.mem.startsWith(u8, target, "pipe:")) return .pipe;
    if (std.mem.startsWith(u8, target, "anon_inode:")) return .anon;
    if (std.mem.startsWith(u8, target, "/dev/")) return .char;
    if (target.len > 0 and target[0] == '/') return .regular;
    return .unknown;
}

fn readSmallFile(path: []const u8, buf: []u8) !usize {
    const file = try std.Io.Dir.openFileAbsolute(ctx.io, path, .{});
    defer file.close(ctx.io);
    return try file.readPositionalAll(ctx.io, buf, 0);
}

fn readSmallFileAt(dir: std.Io.Dir, path: []const u8, buf: []u8) !usize {
    const file = try dir.openFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    return try file.readPositionalAll(ctx.io, buf, 0);
}

/// Linux statfs syscall layout (matches `struct statfs` from <sys/vfs.h>).
/// Layout is identical on Linux x86_64 and aarch64 (the v1 platforms).
const Statfs64 = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

/// Bytes occupied by filesystem data. `bfree` includes blocks reserved for
/// privileged users; using `bavail` here would incorrectly count that reserve
/// as occupied space and inflate the displayed usage percentage.
pub fn fsUsedBytes(blocks: u64, bfree: u64, block_size: u64) u64 {
    const used_blocks = if (blocks > bfree) blocks - bfree else 0;
    return used_blocks * block_size;
}

/// Map a statfs `f_type` magic number to a filesystem name. Magics from
/// linux/magic.h. Returns "" for unknown types (caller hides the label).
pub fn fsTypeName(magic: i64) []const u8 {
    return switch (magic) {
        0x9123683E => "btrfs",
        0xEF53 => "ext4",
        0x58465342 => "xfs",
        0xF2F52010 => "f2fs",
        0x2FC12FC1 => "zfs",
        0xCA451A4E => "bcachefs",
        0x5346544E => "ntfs",
        0x2011BAB0 => "exfat",
        0x4D44 => "vfat",
        0x01021994 => "tmpfs",
        0x794C7630 => "overlay",
        0x73717368 => "squashfs",
        0x65735546 => "fuse",
        0x6969 => "nfs",
        0xFF534D42, 0xFE534D42 => "smb",
        else => "",
    };
}

fn parseOsName(alloc: std.mem.Allocator) []const u8 {
    var buf: [2048]u8 = undefined;
    const n = readSmallFile("/etc/os-release", &buf) catch return alloc.dupe(u8, "Linux") catch &.{};
    const content = buf[0..n];
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
            const val = line["PRETTY_NAME=".len..];
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                return alloc.dupe(u8, val[1 .. val.len - 1]) catch "Linux";
            }
            return alloc.dupe(u8, val) catch "Linux";
        }
    }
    return alloc.dupe(u8, "Linux") catch &.{};
}

fn parseKernelRelease(alloc: std.mem.Allocator) []const u8 {
    var buf: [256]u8 = undefined;
    const n = readSmallFile("/proc/sys/kernel/osrelease", &buf) catch return alloc.dupe(u8, "Unknown") catch &.{};
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return alloc.dupe(u8, trimmed) catch alloc.dupe(u8, "Unknown") catch &.{};
}

fn parseHostModel(alloc: std.mem.Allocator) []const u8 {
    var buf: [256]u8 = undefined;
    const n = readSmallFile("/sys/class/dmi/id/product_name", &buf) catch {
        const n2 = readSmallFile("/sys/devices/virtual/dmi/id/product_name", &buf) catch {
            return alloc.dupe(u8, "Desktop") catch &.{};
        };
        const trimmed = std.mem.trim(u8, buf[0..n2], " \t\r\n");
        return alloc.dupe(u8, trimmed) catch alloc.dupe(u8, "Desktop") catch &.{};
    };
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return alloc.dupe(u8, trimmed) catch alloc.dupe(u8, "Desktop") catch &.{};
}

pub fn parseHostname(alloc: std.mem.Allocator) []const u8 {
    var buf: [256]u8 = undefined;
    const n = readSmallFile("/proc/sys/kernel/hostname", &buf) catch {
        const n2 = readSmallFile("/etc/hostname", &buf) catch return alloc.dupe(u8, "") catch &.{};
        const trimmed = std.mem.trim(u8, buf[0..n2], " \t\r\n");
        return alloc.dupe(u8, trimmed) catch alloc.dupe(u8, "") catch &.{};
    };
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return alloc.dupe(u8, trimmed) catch alloc.dupe(u8, "") catch &.{};
}

fn parseCpuModel(alloc: std.mem.Allocator) []const u8 {
    var buf: [8192]u8 = undefined;
    const n = readSmallFile("/proc/cpuinfo", &buf) catch return alloc.dupe(u8, "Unknown CPU") catch &.{};
    const content = buf[0..n];
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_line, "model name")) {
            var parts = std.mem.splitScalar(u8, trimmed_line, ':');
            _ = parts.next();
            if (parts.next()) |val| {
                var model = std.mem.trim(u8, val, " \t\r\n");
                if (std.mem.indexOf(u8, model, " with ")) |idx| {
                    model = model[0..idx];
                }
                return alloc.dupe(u8, model) catch alloc.dupe(u8, "Unknown CPU") catch &.{};
            }
        }
    }
    return alloc.dupe(u8, "Unknown CPU") catch &.{};
}

/// DRIVER / PCI_ID / PCI_SLOT_NAME fields of a drm device uevent file.
/// Slices borrow from the input buffer.
pub const GpuUevent = struct {
    driver: []const u8 = "",
    pci_id: []const u8 = "",
    slot: []const u8 = "",
};

pub fn parseGpuUevent(content: []const u8) GpuUevent {
    var out = GpuUevent{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "DRIVER=")) {
            out.driver = std.mem.trim(u8, line["DRIVER=".len..], " \t\r");
        } else if (std.mem.startsWith(u8, line, "PCI_ID=")) {
            out.pci_id = std.mem.trim(u8, line["PCI_ID=".len..], " \t\r");
        } else if (std.mem.startsWith(u8, line, "PCI_SLOT_NAME=")) {
            out.slot = std.mem.trim(u8, line["PCI_SLOT_NAME=".len..], " \t\r");
        }
    }
    return out;
}

/// Marketing model name from /proc/driver/nvidia/gpus/<slot>/information
/// ("Model:" line). Borrows from the input buffer; null when absent.
pub fn parseNvidiaModel(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Model:")) {
            const val = std.mem.trim(u8, line["Model:".len..], " \t\r");
            if (val.len > 0) return val;
        }
    }
    return null;
}

/// PCI vendor prefix of a "VVVV:DDDD" PCI_ID → human vendor name; "" when
/// unrecognised.
pub fn gpuVendorName(pci_id: []const u8) []const u8 {
    if (pci_id.len < 4) return "";
    const v = pci_id[0..4];
    if (std.ascii.eqlIgnoreCase(v, "10DE")) return "NVIDIA";
    if (std.ascii.eqlIgnoreCase(v, "1002")) return "AMD";
    if (std.ascii.eqlIgnoreCase(v, "8086")) return "Intel";
    return "";
}

const MAX_GPUS = 4;

/// Detect PCI GPUs via /sys/class/drm/card<N>/device/uevent. NVIDIA cards get
/// their marketing name from the proprietary driver's procfs when available;
/// others show "<vendor> (<driver>)". Names are alloc-owned (collector arena).
/// Existence only — no usage/VRAM/temp (zero-deps rule).
fn detectGpus(alloc: std.mem.Allocator) []const []const u8 {
    var names: [MAX_GPUS][]const u8 = undefined;
    var nums: [MAX_GPUS]u32 = undefined;
    var count: usize = 0;

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, "/sys/class/drm", .{ .iterate = true }) catch return &.{};
    defer dir.close(ctx.io);
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (count >= MAX_GPUS) break;
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        // "card1" passes; connectors like "card1-HDMI-A-1" don't parse.
        const num = std.fmt.parseInt(u32, entry.name["card".len..], 10) catch continue;

        var path_buf: [128]u8 = undefined;
        const uevent_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/device/uevent", .{entry.name}) catch continue;
        var uevent_buf: [1024]u8 = undefined;
        const n = readSmallFile(uevent_path, &uevent_buf) catch continue;
        const ue = parseGpuUevent(uevent_buf[0..n]);
        if (ue.pci_id.len == 0) continue; // not a PCI device (vgem, vkms, ...)

        const vendor = gpuVendorName(ue.pci_id);
        var name: []const u8 = "";
        if (std.mem.eql(u8, vendor, "NVIDIA") and ue.slot.len > 0) {
            var info_path_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&info_path_buf, "/proc/driver/nvidia/gpus/{s}/information", .{ue.slot}) catch null) |info_path| {
                var info_buf: [2048]u8 = undefined;
                if (readSmallFile(info_path, &info_buf) catch null) |in_n| {
                    if (parseNvidiaModel(info_buf[0..in_n])) |m| {
                        name = alloc.dupe(u8, m) catch "";
                    }
                }
            }
        }
        if (name.len == 0) {
            if (vendor.len > 0) {
                name = std.fmt.allocPrint(alloc, "{s} ({s})", .{ vendor, ue.driver }) catch continue;
            } else if (ue.driver.len > 0) {
                name = alloc.dupe(u8, ue.driver) catch continue;
            } else continue;
        }

        // Insertion sort by card number for a stable display order.
        var i = count;
        while (i > 0 and nums[i - 1] > num) : (i -= 1) {
            nums[i] = nums[i - 1];
            names[i] = names[i - 1];
        }
        nums[i] = num;
        names[i] = name;
        count += 1;
    }

    const out = alloc.alloc([]const u8, count) catch return &.{};
    @memcpy(out, names[0..count]);
    return out;
}

/// Extract the highest `cpu MHz` value reported by /proc/cpuinfo.
/// Keeping this parser separate makes the hot path testable without sysfs.
pub fn parseCpuFreqMhz(content: []const u8) u32 {
    var max_mhz: f64 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "cpu MHz")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const value = std.fmt.parseFloat(f64, std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r")) catch continue;
        if (value > max_mhz) max_mhz = value;
    }
    if (max_mhz <= 0 or max_mhz > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return 0;
    return @intFromFloat(max_mhz);
}

/// Highest current core frequency in MHz. /proc/cpuinfo supplies all cores in
/// one open/read, avoiding one serial sysfs open per logical CPU. On platforms
/// that omit `cpu MHz`, sample cpu0 once as a conservative fallback.
fn readCpuFreqMhz() u32 {
    var cpuinfo_buf: [512 * 1024]u8 = undefined;
    if (readSmallFile("/proc/cpuinfo", &cpuinfo_buf)) |n| {
        const mhz = parseCpuFreqMhz(cpuinfo_buf[0..n]);
        if (mhz > 0) return mhz;
    } else |_| {}

    var freq_buf: [32]u8 = undefined;
    const n = readSmallFile("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", &freq_buf) catch return 0;
    const khz = std.fmt.parseInt(u64, std.mem.trim(u8, freq_buf[0..n], " \t\r\n"), 10) catch return 0;
    return @intCast(@min(khz / 1000, std.math.maxInt(u32)));
}

fn parseBattery(alloc: std.mem.Allocator, pct_out: *?u8, status_out: *[]const u8) void {
    pct_out.* = null;
    status_out.* = "";
    var cap_buf: [32]u8 = undefined;
    var stat_buf: [64]u8 = undefined;
    const bat_paths = [_][]const u8{
        "/sys/class/power_supply/BAT0",
        "/sys/class/power_supply/BAT1",
        "/sys/class/power_supply/BATC",
    };
    for (bat_paths) |path| {
        var path_cap: [256]u8 = undefined;
        var path_stat: [256]u8 = undefined;
        const cap_file = std.fmt.bufPrint(&path_cap, "{s}/capacity", .{path}) catch continue;
        const stat_file = std.fmt.bufPrint(&path_stat, "{s}/status", .{path}) catch continue;
        const cn = readSmallFile(cap_file, &cap_buf) catch continue;
        const sn = readSmallFile(stat_file, &stat_buf) catch continue;
        const cap_str = std.mem.trim(u8, cap_buf[0..cn], " \t\r\n");
        const stat_str = std.mem.trim(u8, stat_buf[0..sn], " \t\r\n");
        if (std.fmt.parseInt(u8, cap_str, 10)) |pct| {
            pct_out.* = pct;
            status_out.* = alloc.dupe(u8, stat_str) catch "";
            return;
        } else |_| {}
    }
}

fn queryIfaceIp(iface_name: []const u8, alloc: std.mem.Allocator) []const u8 {
    if (iface_name.len == 0 or iface_name.len >= 16) return "";
    const AF_INET = 2;
    const SOCK_DGRAM = 2;
    const rc_fd = std.os.linux.socket(AF_INET, SOCK_DGRAM, 0);
    const err_check = std.os.linux.errno(rc_fd);
    if (err_check != .SUCCESS) return "";
    const sockfd: i32 = @intCast(rc_fd);
    defer _ = std.os.linux.close(sockfd);

    var ifr: extern struct {
        name: [16]u8,
        addr: std.os.linux.sockaddr,
        padding: [16]u8 = undefined,
    } = undefined;
    @memset(ifr.name[0..], 0);
    std.mem.copyForwards(u8, ifr.name[0..iface_name.len], iface_name);

    const SIOCGIFADDR = 0x8915;
    const rc_ioctl = std.os.linux.ioctl(sockfd, SIOCGIFADDR, @intFromPtr(&ifr));
    const err = std.os.linux.errno(rc_ioctl);
    if (err == .SUCCESS) {
        const addr_bytes = ifr.addr.data[2..6];
        return std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3] }) catch "";
    }
    return "";
}
