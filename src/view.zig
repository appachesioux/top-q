const std = @import("std");
const process = @import("process.zig");
const mode_mod = @import("mode.zig");
const sample_mod = @import("sample.zig");

pub const DetailPanel = enum { graphs, threads, fds };

pub const SortKey = enum { cpu, mem, pid, name, user };
pub const SortDir = enum { desc, asc };

pub fn cycleSortKey(k: SortKey) SortKey {
    return switch (k) {
        .cpu => .mem,
        .mem => .pid,
        .pid => .name,
        .name => .user,
        .user => .cpu,
    };
}

pub fn sortKeyLabel(k: SortKey) []const u8 {
    return switch (k) {
        .cpu => "CPU%",
        .mem => "MEM%",
        .pid => "PID",
        .name => "NAME",
        .user => "USER",
    };
}

pub const FilterField = enum { any, command, user };

pub fn cycleFilterField(f: FilterField) FilterField {
    return switch (f) {
        .any => .command,
        .command => .user,
        .user => .any,
    };
}

pub fn filterFieldLabel(f: FilterField) []const u8 {
    return switch (f) {
        .any => "any",
        .command => "cmd",
        .user => "user",
    };
}

pub const Filter = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    field: FilterField = .any,

    pub fn text(self: *const Filter) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isActive(self: *const Filter) bool {
        return self.len > 0;
    }

    pub fn clear(self: *Filter) void {
        self.len = 0;
    }

    pub fn appendChar(self: *Filter, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    pub fn backspace(self: *Filter) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn deleteWord(self: *Filter) void {
        // Trim trailing spaces, then trim until next space
        while (self.len > 0 and self.buf[self.len - 1] == ' ') self.len -= 1;
        while (self.len > 0 and self.buf[self.len - 1] != ' ') self.len -= 1;
    }

    pub fn matches(self: *const Filter, p: *const process.Process) bool {
        if (self.len == 0) return true;
        const needle = self.text();
        return switch (self.field) {
            .command => containsCI(p.cmdline, needle),
            .user => containsCI(p.user, needle),
            .any => containsCI(p.cmdline, needle) or containsCI(p.user, needle),
        };
    }
};

/// Incremental search. Unlike `Filter`, this never hides rows: it moves the
/// selection to the next process whose command matches, htop-F3 style.
pub const Search = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Search) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isActive(self: *const Search) bool {
        return self.len > 0;
    }

    pub fn clear(self: *Search) void {
        self.len = 0;
    }

    pub fn appendChar(self: *Search, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    pub fn backspace(self: *Search) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn deleteWord(self: *Search) void {
        while (self.len > 0 and self.buf[self.len - 1] == ' ') self.len -= 1;
        while (self.len > 0 and self.buf[self.len - 1] != ' ') self.len -= 1;
    }

    pub fn matches(self: *const Search, p: *const process.Process) bool {
        if (self.len == 0) return false;
        return matchesNeedle(p, self.text());
    }
};

pub const SearchDir = enum { fwd, back };

fn matchesNeedle(p: *const process.Process, needle: []const u8) bool {
    return containsCI(p.cmdline, needle) or containsCI(p.comm, needle);
}

/// Scan `sorted` (view order) for the next process matching `needle`, starting
/// at view index `start` and wrapping around exactly once. `start` is
/// inclusive — pass `cur + 1` to advance past the current row. Returns a view
/// index, or null when nothing matches.
pub fn findNextMatch(
    procs: []const process.Process,
    sorted: []const usize,
    start: usize,
    needle: []const u8,
    dir: SearchDir,
) ?usize {
    if (sorted.len == 0 or needle.len == 0) return null;
    const n = sorted.len;
    const s = start % n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const view_idx = switch (dir) {
            .fwd => (s + i) % n,
            .back => (s + n - i) % n,
        };
        const real_idx = sorted[view_idx];
        if (real_idx >= procs.len) continue;
        if (matchesNeedle(&procs[real_idx], needle)) return view_idx;
    }
    return null;
}

/// Case-insensitive substring search (ASCII fold).
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// Comparator context for std.mem.sort.
pub const SortCtx = struct {
    procs: []const process.Process,
    key: SortKey,
    dir: SortDir,

    pub fn lessThan(self: SortCtx, a: usize, b: usize) bool {
        const pa = self.procs[a];
        const pb = self.procs[b];
        const ord: std.math.Order = switch (self.key) {
            .cpu => std.math.order(pa.cpu_pct, pb.cpu_pct),
            .mem => std.math.order(pa.mem_rss_bytes, pb.mem_rss_bytes),
            .pid => std.math.order(pa.pid, pb.pid),
            .name => std.mem.order(u8, pa.comm, pb.comm),
            .user => std.mem.order(u8, pa.user, pb.user),
        };
        return switch (self.dir) {
            .desc => ord == .gt,
            .asc => ord == .lt,
        };
    }
};

/// Top-level view state.
pub const ViewState = struct {
    mode: mode_mod.Mode = .list,
    selected_pid: ?process.Pid = null,
    scroll_top: usize = 0,
    /// Mode to restore after closing the help overlay.
    prev_mode: mode_mod.Mode = .list,
    /// First visible content row of the help overlay. Reset when F1 opens it.
    help_scroll: usize = 0,

    // ----- US2: detail view -----
    detail_history: ?sample_mod.ProcessHistory = null,
    detail_panel: DetailPanel = .graphs,
    detail_threads_scroll: usize = 0,
    detail_fds_scroll: usize = 0,

    // ----- US3: sort + filter -----
    sort_key: SortKey = .cpu,
    sort_dir: SortDir = .desc,
    filter: Filter = .{},

    // ----- US5: incremental search -----
    search: Search = .{},
    /// Selection to restore when search_input is cancelled with Esc.
    search_restore_pid: ?process.Pid = null,
    /// Set while typing so the status bar can say so without rescanning.
    search_no_match: bool = false,

    // ----- US4: signal_confirm + transient flash status -----
    pending_signal: process.Signal = .term,
    flash_buf: [128]u8 = undefined,
    flash_len: usize = 0,
    flash_ttl_ticks: u8 = 0,

    pub fn flashText(self: *const ViewState) []const u8 {
        return self.flash_buf[0..self.flash_len];
    }

    pub fn setFlash(self: *ViewState, text: []const u8) void {
        const n = @min(text.len, self.flash_buf.len);
        @memcpy(self.flash_buf[0..n], text[0..n]);
        self.flash_len = n;
        self.flash_ttl_ticks = 3; // ~3 refreshes ≈ 4–5 s at default cadence
    }

    pub fn tickFlash(self: *ViewState) void {
        if (self.flash_ttl_ticks == 0) return;
        self.flash_ttl_ticks -= 1;
        if (self.flash_ttl_ticks == 0) self.flash_len = 0;
    }
};

test "command filter searches the displayed full command line" {
    const p: process.Process = .{
        .pid = 42,
        .ppid = 1,
        .uid = 1000,
        .user = "alice",
        .comm = "python",
        .cmdline = "python /srv/report-worker.py --daily",
        .state = .sleeping,
        .cpu_pct = 0,
        .mem_rss_bytes = 0,
        .mem_vsz_bytes = 0,
        .nthreads = 1,
        .io_read_bytes = 0,
        .io_write_bytes = 0,
        .io_available = false,
        .last_jiffies = 0,
        .last_sample_ns = 0,
    };
    var filter: Filter = .{ .field = .command };
    for ("REPORT-WORKER") |c| filter.appendChar(c);
    try std.testing.expect(filter.matches(&p));
}

fn testProc(pid: process.Pid, comm: []const u8, cmdline: []const u8) process.Process {
    return .{
        .pid = pid,
        .ppid = 1,
        .uid = 1000,
        .user = "alice",
        .comm = comm,
        .cmdline = cmdline,
        .state = .sleeping,
        .cpu_pct = 0,
        .mem_rss_bytes = 0,
        .mem_vsz_bytes = 0,
        .nthreads = 1,
        .io_read_bytes = 0,
        .io_write_bytes = 0,
        .io_available = false,
        .last_jiffies = 0,
        .last_sample_ns = 0,
    };
}

test "findNextMatch walks forward and wraps around exactly once" {
    const procs = [_]process.Process{
        testProc(1, "init", "/sbin/init"),
        testProc(2, "nginx", "nginx: worker process"),
        testProc(3, "bash", "-bash"),
        testProc(4, "nginx", "nginx: master process"),
    };
    const sorted = [_]usize{ 0, 1, 2, 3 };

    // From the top: first nginx is at view index 1.
    try std.testing.expectEqual(@as(?usize, 1), findNextMatch(&procs, &sorted, 0, "nginx", .fwd));
    // Advancing past it lands on the second one.
    try std.testing.expectEqual(@as(?usize, 3), findNextMatch(&procs, &sorted, 2, "nginx", .fwd));
    // Advancing past the last wraps back to the first.
    try std.testing.expectEqual(@as(?usize, 1), findNextMatch(&procs, &sorted, 4, "nginx", .fwd));
}

test "findNextMatch walks backward and wraps around" {
    const procs = [_]process.Process{
        testProc(1, "init", "/sbin/init"),
        testProc(2, "nginx", "nginx: worker process"),
        testProc(3, "bash", "-bash"),
        testProc(4, "nginx", "nginx: master process"),
    };
    const sorted = [_]usize{ 0, 1, 2, 3 };

    try std.testing.expectEqual(@as(?usize, 1), findNextMatch(&procs, &sorted, 2, "nginx", .back));
    // Walking back past the first match wraps to the last one.
    try std.testing.expectEqual(@as(?usize, 3), findNextMatch(&procs, &sorted, 0, "nginx", .back));
}

test "findNextMatch is case-insensitive and honors view order, not table order" {
    const procs = [_]process.Process{
        testProc(1, "init", "/sbin/init"),
        testProc(2, "Nginx", "NGINX: worker process"),
        testProc(3, "bash", "-bash"),
    };
    // Sorted view puts the nginx row last.
    const sorted = [_]usize{ 2, 0, 1 };
    try std.testing.expectEqual(@as(?usize, 2), findNextMatch(&procs, &sorted, 0, "nginx", .fwd));
}

test "findNextMatch returns null with no match, empty needle or empty view" {
    const procs = [_]process.Process{
        testProc(1, "init", "/sbin/init"),
        testProc(2, "bash", "-bash"),
    };
    const sorted = [_]usize{ 0, 1 };
    const empty: []const usize = &.{};

    try std.testing.expectEqual(@as(?usize, null), findNextMatch(&procs, &sorted, 0, "postgres", .fwd));
    try std.testing.expectEqual(@as(?usize, null), findNextMatch(&procs, &sorted, 0, "", .fwd));
    try std.testing.expectEqual(@as(?usize, null), findNextMatch(&procs, empty, 0, "init", .fwd));
}

test "search matches command line as well as comm" {
    const p = testProc(42, "python", "python /srv/report-worker.py --daily");
    var search: Search = .{};
    try std.testing.expect(!search.matches(&p)); // empty search matches nothing

    for ("REPORT-WORKER") |c| search.appendChar(c);
    try std.testing.expect(search.matches(&p));

    search.clear();
    for ("PYTH") |c| search.appendChar(c);
    try std.testing.expect(search.matches(&p));
}
