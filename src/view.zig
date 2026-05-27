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
            .command => containsCI(p.comm, needle),
            .user => containsCI(p.user, needle),
            .any => containsCI(p.comm, needle) or containsCI(p.user, needle),
        };
    }
};

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

    // ----- US2: detail view -----
    detail_history: ?sample_mod.ProcessHistory = null,
    detail_panel: DetailPanel = .graphs,
    detail_threads_scroll: usize = 0,
    detail_fds_scroll: usize = 0,

    // ----- US3: sort + filter -----
    sort_key: SortKey = .cpu,
    sort_dir: SortDir = .desc,
    filter: Filter = .{},

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
