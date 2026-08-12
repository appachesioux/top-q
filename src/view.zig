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

/// Smallest scroll adjustment that keeps view row `idx` on screen. Returns the
/// new `scroll_top`, unchanged when the row is already visible — the hysteresis
/// is what stops the viewport from lurching on every refresh.
pub fn scrollToKeepVisible(scroll_top: usize, idx: usize, visible: usize) usize {
    if (visible == 0) return scroll_top;
    if (idx < scroll_top) return idx;
    if (idx >= scroll_top + visible) return idx + 1 - visible;
    return scroll_top;
}

/// Screen-row offset of a selection inside the process viewport. Selections
/// outside the viewport are clamped to the nearest edge; this also lets a
/// refresh recover cleanly from an old, already-hidden selection.
pub fn viewportOffset(scroll_top: usize, idx: usize, visible: usize) usize {
    if (visible == 0 or idx <= scroll_top) return 0;
    return @min(idx - scroll_top, visible - 1);
}

/// View index occupying `offset` after a refresh, without moving the viewport.
/// Keeping the cursor on a screen row (instead of following its old PID) is
/// important for live sorts: a process falling in the CPU ranking must not drag
/// the viewport away from the hottest processes.
pub fn indexAtViewportOffset(scroll_top: usize, offset: usize, visible: usize, total: usize) ?usize {
    if (total == 0) return null;
    const bounded_offset = if (visible == 0) 0 else @min(offset, visible - 1);
    return @min(scroll_top + bounded_offset, total - 1);
}

/// How many rows the active search matches, and which one the cursor is on.
/// `pos` is 1-based; 0 means the selection is not itself a match.
pub const MatchStats = struct { total: usize = 0, pos: usize = 0 };

pub fn matchStats(
    procs: []const process.Process,
    sorted: []const usize,
    needle: []const u8,
    selected_pid: ?process.Pid,
) MatchStats {
    if (needle.len == 0) return .{};
    var out: MatchStats = .{};
    for (sorted) |real_idx| {
        if (real_idx >= procs.len) continue;
        const p = &procs[real_idx];
        if (!matchesNeedle(p, needle)) continue;
        out.total += 1;
        if (selected_pid) |pid| {
            if (p.pid == pid) out.pos = out.total;
        }
    }
    return out;
}

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

        // pdq sort is intentionally unstable. Without an explicit tiebreaker,
        // the many processes sharing 0% CPU (or the same name/user) can change
        // places on every /proc enumeration even though their sort value did
        // not change. PID gives every row a deterministic order.
        if (ord == .eq) return pa.pid < pb.pid;
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

test "scrollToKeepVisible leaves an already visible row alone" {
    // Viewport shows rows 10..19. Anything inside must not move the view —
    // this hysteresis is what keeps the list from lurching every refresh.
    try std.testing.expectEqual(@as(usize, 10), scrollToKeepVisible(10, 10, 10));
    try std.testing.expectEqual(@as(usize, 10), scrollToKeepVisible(10, 15, 10));
    try std.testing.expectEqual(@as(usize, 10), scrollToKeepVisible(10, 19, 10));
}

test "scrollToKeepVisible scrolls the minimum needed in both directions" {
    // Row above the viewport → it becomes the first visible row.
    try std.testing.expectEqual(@as(usize, 7), scrollToKeepVisible(10, 7, 10));
    try std.testing.expectEqual(@as(usize, 0), scrollToKeepVisible(10, 0, 10));

    // Row below → it becomes the last visible row, not the first.
    try std.testing.expectEqual(@as(usize, 11), scrollToKeepVisible(10, 20, 10));
    try std.testing.expectEqual(@as(usize, 91), scrollToKeepVisible(10, 100, 10));
}

test "scrollToKeepVisible handles the one-row and zero-row viewports" {
    // visible == 0 means the list has no room; the view must not be touched.
    try std.testing.expectEqual(@as(usize, 42), scrollToKeepVisible(42, 0, 0));
    // A single visible row always scrolls exactly onto the target.
    try std.testing.expectEqual(@as(usize, 5), scrollToKeepVisible(0, 5, 1));
    try std.testing.expectEqual(@as(usize, 5), scrollToKeepVisible(9, 5, 1));
}

test "refresh keeps the cursor row without following a reordered PID" {
    // Before refresh, the cursor is on the first visible (and hottest) row.
    const offset = viewportOffset(0, 0, 12);

    // Its old PID may fall far down after a CPU re-sort. The replacement
    // selection remains row zero, so the viewport continues to show rank #1.
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expectEqual(@as(?usize, 0), indexAtViewportOffset(0, offset, 12, 200));
}

test "refresh preserves a cursor offset in a scrolled viewport" {
    const offset = viewportOffset(40, 44, 10);
    try std.testing.expectEqual(@as(usize, 4), offset);
    try std.testing.expectEqual(@as(?usize, 44), indexAtViewportOffset(40, offset, 10, 200));

    // A shorter replacement table clamps safely to its final row.
    try std.testing.expectEqual(@as(?usize, 42), indexAtViewportOffset(40, offset, 10, 43));
    try std.testing.expectEqual(@as(?usize, null), indexAtViewportOffset(0, 0, 10, 0));
}

test "CPU sort uses PID as a deterministic tiebreaker" {
    var procs = [_]process.Process{
        testProc(30, "c", "c"),
        testProc(10, "a", "a"),
        testProc(20, "b", "b"),
    };
    procs[0].cpu_pct = 7.5;
    procs[1].cpu_pct = 7.5;
    procs[2].cpu_pct = 50.0;

    var sorted = [_]usize{ 0, 1, 2 };
    const ctx: SortCtx = .{ .procs = &procs, .key = .cpu, .dir = .desc };
    std.sort.pdq(usize, &sorted, ctx, SortCtx.lessThan);

    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, &sorted);
}

test "matchStats counts matches and locates the selection among them" {
    const procs = [_]process.Process{
        testProc(1, "init", "/sbin/init"),
        testProc(2, "nginx", "nginx: worker process"),
        testProc(3, "bash", "-bash"),
        testProc(4, "nginx", "nginx: master process"),
        testProc(5, "nginx", "nginx: cache manager"),
    };
    const sorted = [_]usize{ 0, 1, 2, 3, 4 };

    // Selection on the first match → 1 of 3.
    var st = matchStats(&procs, &sorted, "nginx", 2);
    try std.testing.expectEqual(@as(usize, 3), st.total);
    try std.testing.expectEqual(@as(usize, 1), st.pos);

    // Selection on the last match → 3 of 3.
    st = matchStats(&procs, &sorted, "nginx", 5);
    try std.testing.expectEqual(@as(usize, 3), st.total);
    try std.testing.expectEqual(@as(usize, 3), st.pos);

    // pos is the ordinal among matches, not the row number.
    st = matchStats(&procs, &sorted, "nginx", 4);
    try std.testing.expectEqual(@as(usize, 2), st.pos);
}

test "matchStats reports pos 0 when the cursor is not on a match" {
    const procs = [_]process.Process{
        testProc(1, "init", "/sbin/init"),
        testProc(2, "nginx", "nginx: worker process"),
    };
    const sorted = [_]usize{ 0, 1 };

    // Cursor sits on a non-matching row: there are matches, just not here.
    var st = matchStats(&procs, &sorted, "nginx", 1);
    try std.testing.expectEqual(@as(usize, 1), st.total);
    try std.testing.expectEqual(@as(usize, 0), st.pos);

    // No selection at all.
    st = matchStats(&procs, &sorted, "nginx", null);
    try std.testing.expectEqual(@as(usize, 1), st.total);
    try std.testing.expectEqual(@as(usize, 0), st.pos);

    // Nothing matches.
    st = matchStats(&procs, &sorted, "postgres", 1);
    try std.testing.expectEqual(@as(usize, 0), st.total);
    try std.testing.expectEqual(@as(usize, 0), st.pos);
}

test "matchStats follows view order, not table order" {
    const procs = [_]process.Process{
        testProc(1, "nginx", "nginx: first in table"),
        testProc(2, "bash", "-bash"),
        testProc(3, "nginx", "nginx: second in table"),
    };
    // Sorted view shows pid 3 before pid 1, so pid 1 is match 2 of 2.
    const sorted = [_]usize{ 2, 1, 0 };
    const st = matchStats(&procs, &sorted, "nginx", 1);
    try std.testing.expectEqual(@as(usize, 2), st.total);
    try std.testing.expectEqual(@as(usize, 2), st.pos);
}

test "matchStats treats an empty needle as no search at all" {
    const procs = [_]process.Process{testProc(1, "init", "/sbin/init")};
    const sorted = [_]usize{0};
    const st = matchStats(&procs, &sorted, "", 1);
    try std.testing.expectEqual(@as(usize, 0), st.total);
    try std.testing.expectEqual(@as(usize, 0), st.pos);
}
