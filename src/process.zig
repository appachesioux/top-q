const std = @import("std");

// =============================================================================
// Basic types
// =============================================================================

pub const Pid = u32;

pub const ProcessState = enum(u8) {
    running, // R
    sleeping, // S
    disk_sleep, // D
    stopped, // T
    zombie, // Z
    idle, // I
    unknown,

    pub fn fromChar(c: u8) ProcessState {
        return switch (c) {
            'R' => .running,
            'S' => .sleeping,
            'D' => .disk_sleep,
            'T', 't' => .stopped,
            'Z' => .zombie,
            'I' => .idle,
            else => .unknown,
        };
    }

    pub fn char(self: ProcessState) u8 {
        return switch (self) {
            .running => 'R',
            .sleeping => 'S',
            .disk_sleep => 'D',
            .stopped => 'T',
            .zombie => 'Z',
            .idle => 'I',
            .unknown => '?',
        };
    }
};

pub const Signal = enum(c_int) {
    term = 15,
    kill = 9,
    hup = 1,
    int = 2,
    quit = 3,
    usr1 = 10,
    usr2 = 12,

    pub fn name(self: Signal) []const u8 {
        return switch (self) {
            .term => "TERM",
            .kill => "KILL",
            .hup => "HUP",
            .int => "INT",
            .quit => "QUIT",
            .usr1 => "USR1",
            .usr2 => "USR2",
        };
    }

    /// Cycle through the user-confirmable signals: TERM → KILL → HUP → INT → TERM.
    /// (USR1/USR2/QUIT are exposed as values but not in the cycle.)
    pub fn cycle(self: Signal) Signal {
        return switch (self) {
            .term => .kill,
            .kill => .hup,
            .hup => .int,
            .int => .term,
            else => .term,
        };
    }
};

/// Send a POSIX signal to `pid` from any thread. Doesn't touch ProcessSource
/// state, so it's safe to call from the main UI thread while the collector
/// owns the source. Returns:
///   error.PermissionDenied  → EPERM (caller likely lacks rights to signal)
///   error.NoSuchProcess     → ESRCH (process gone between selection and send)
pub fn sendSignal(pid: Pid, sig: Signal) !void {
    std.posix.kill(@intCast(pid), @enumFromInt(@intFromEnum(sig))) catch |e| switch (e) {
        error.PermissionDenied => return error.PermissionDenied,
        error.ProcessNotFound => return error.NoSuchProcess,
        else => return e,
    };
}

// =============================================================================
// Process — instantaneous snapshot of one process
// =============================================================================

pub const Process = struct {
    pid: Pid,
    ppid: Pid,
    uid: u32,
    user: []const u8, // resolved via UidCache; lives in ProcessTable.arena
    comm: []const u8, // short name (from /proc/<pid>/stat between parens)
    cmdline: []const u8, // full command line (NUL-separated joined with space)
    state: ProcessState,

    // Instantaneous metrics
    cpu_pct: f32, // 0.0..100.0 × num_cpus
    mem_rss_bytes: u64,
    mem_vsz_bytes: u64,
    nthreads: u32,

    // Accumulated IO bytes (delta is computed by consumers when needed)
    io_read_bytes: u64,
    io_write_bytes: u64,
    io_available: bool,

    // Bookkeeping for cpu% delta computation across generations
    last_jiffies: u64,
    last_sample_ns: i64,
};

// =============================================================================
// ProcessTable — collection per generation, with PID index and arena-owned strings
// =============================================================================

pub const ProcessTable = struct {
    procs: std.ArrayListUnmanaged(Process),
    index_by_pid: std.AutoHashMapUnmanaged(Pid, usize),
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,
    sampled_at_ns: i64,
    generation: u64,

    pub fn init(alloc: std.mem.Allocator) ProcessTable {
        return .{
            .procs = .empty,
            .index_by_pid = .empty,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
            .sampled_at_ns = 0,
            .generation = 0,
        };
    }

    pub fn deinit(self: *ProcessTable) void {
        self.procs.deinit(self.alloc);
        self.index_by_pid.deinit(self.alloc);
        self.arena.deinit();
    }

    pub fn clear(self: *ProcessTable) void {
        self.procs.clearRetainingCapacity();
        self.index_by_pid.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn append(self: *ProcessTable, p: Process) !void {
        const idx = self.procs.items.len;
        try self.procs.append(self.alloc, p);
        try self.index_by_pid.put(self.alloc, p.pid, idx);
    }

    pub fn lookup(self: *const ProcessTable, pid: Pid) ?*const Process {
        const idx = self.index_by_pid.get(pid) orelse return null;
        return &self.procs.items[idx];
    }

    pub fn lookupMut(self: *ProcessTable, pid: Pid) ?*Process {
        const idx = self.index_by_pid.get(pid) orelse return null;
        return &self.procs.items[idx];
    }

    pub fn count(self: *const ProcessTable) usize {
        return self.procs.items.len;
    }
};

// =============================================================================
// SystemSummary — header data
// =============================================================================

pub const SystemSummary = struct {
    cpu_pct_total: f32 = 0,
    /// Per-core usage 0..100. Slice owned by the SystemSummary's allocator
    /// (collector arena). Length = nproc.
    per_cpu: []f32 = &.{},
    mem_used_bytes: u64 = 0,
    mem_total_bytes: u64 = 0,
    mem_cache_bytes: u64 = 0, // Buffers + Cached + SReclaimable
    swap_used_bytes: u64 = 0,
    swap_total_bytes: u64 = 0,
    loadavg: [3]f32 = .{ 0, 0, 0 },
    uptime_seconds: u64 = 0,
    nproc: u32 = 1,

    // ----- US5: disk + filesystem -----
    disk_read_bps: u64 = 0,
    disk_write_bps: u64 = 0,
    fs_root_used_bytes: u64 = 0,
    fs_root_total_bytes: u64 = 0,
    /// Mountpoint currently shown in the disk block. Cyclable via `D`. Arena-owned.
    fs_mount_path: []const u8 = "/",
    /// Filesystem type name ("btrfs", "ext4", ...) of the shown mount; empty
    /// when unknown. Static string (not arena-owned).
    fs_type_name: []const u8 = "",

    // ----- Network (primary physical interface) -----
    /// Empty when no physical interface was detected. Arena-owned.
    net_iface_name: []const u8 = "",
    net_rx_bps: u64 = 0,
    net_tx_bps: u64 = 0,
    net_ip: []const u8 = "",

    // ----- System Information (conf.png / fastfetch) -----
    os_name: []const u8 = "",
    kernel_release: []const u8 = "",
    host_model: []const u8 = "",
    cpu_model: []const u8 = "",
    /// Highest current core frequency in MHz; 0 when cpufreq is unavailable.
    cpu_freq_mhz: u32 = 0,
    /// PCI GPU names (existence only — no usage metrics). Arena-owned.
    gpus: []const []const u8 = &.{},
    battery_pct: ?u8 = null,
    battery_status: []const u8 = "",
};

// =============================================================================
// Detail-view structures (declared early so app types don't churn when US2 lands)
// =============================================================================

pub const FdKind = enum { regular, socket, pipe, anon, char, block, dir, symlink, unknown };

pub const ThreadInfo = struct {
    tid: Pid,
    state: ProcessState,
    cpu_pct: f32,
    name: []const u8,
};

pub const FdInfo = struct {
    fd: u32,
    kind: FdKind,
    target: []const u8,
};

pub const ProcessDetail = struct {
    pid: Pid,
    threads: std.ArrayListUnmanaged(ThreadInfo),
    fds: std.ArrayListUnmanaged(FdInfo),
    fds_truncated: bool,
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, pid: Pid) ProcessDetail {
        return .{
            .pid = pid,
            .threads = .empty,
            .fds = .empty,
            .fds_truncated = false,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ProcessDetail) void {
        self.threads.deinit(self.alloc);
        self.fds.deinit(self.alloc);
        self.arena.deinit();
    }
};
