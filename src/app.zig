const std = @import("std");
const vaxis = @import("vaxis");
const process = @import("process.zig");
const procsrc = @import("procsrc/procsrc.zig");
const sample_mod = @import("sample.zig");
const view_mod = @import("view.zig");
const mode_mod = @import("mode.zig");
const render = @import("render.zig");
const render_detail = @import("render_detail.zig");
const style = @import("style.zig");
const ctx = @import("ctx.zig");
const utils = @import("utils.zig");

const Vaxis = vaxis.Vaxis;
const Tty = vaxis.Tty;

// =============================================================================
// Event union — what the main thread receives via vaxis.Loop
// =============================================================================

pub const RefreshPayload = struct {
    table: process.ProcessTable,
    summary: process.SystemSummary,
};

pub const SamplePayload = struct {
    pid: process.Pid,
    sample: sample_mod.ProcessSample,
};

pub const DetailPayload = struct {
    pid: process.Pid,
    detail: process.ProcessDetail,
};

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    refresh: RefreshPayload,
    sample: SamplePayload,
    detail: DetailPayload,
};

const Loop = vaxis.Loop(Event);

// =============================================================================
// Collector — owns ProcessSource, runs on its own thread, posts events
// =============================================================================

const DETAIL_TICK_MS: u64 = 250;
const DETAIL_FULL_INTERVAL_NS: i64 = std.time.ns_per_s; // 1 s for source.detail()

const Collector = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    source: procsrc.ProcessSource,
    delay_ms: u64,
    focus_pid: std.atomic.Value(u64), // 0 = no detail; else PID
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread,

    fn init(alloc: std.mem.Allocator, loop: *Loop, delay_ms: u64) !Collector {
        return .{
            .alloc = alloc,
            .loop = loop,
            .source = try procsrc.ProcessSource.init(alloc),
            .delay_ms = delay_ms,
            .focus_pid = std.atomic.Value(u64).init(0),
            .should_stop = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    fn deinit(self: *Collector) void {
        self.stop();
        self.source.deinit();
    }

    fn start(self: *Collector) !void {
        self.thread = try std.Thread.spawn(.{}, workerEntry, .{self});
    }

    fn stop(self: *Collector) void {
        self.should_stop.store(true, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn setFocus(self: *Collector, pid: ?process.Pid) void {
        const v: u64 = if (pid) |p| @intCast(p) else 0;
        self.focus_pid.store(v, .seq_cst);
    }

    fn cycleNet(self: *Collector) void {
        self.source.cycleNet();
    }

    fn cycleDisk(self: *Collector) void {
        self.source.cycleDisk();
    }

    fn workerEntry(self: *Collector) void {
        var first = true;
        var last_enum_ns: i64 = 0;
        var last_detail_ns: i64 = 0;

        while (!self.should_stop.load(.seq_cst)) {
            const focus_raw = self.focus_pid.load(.seq_cst);
            const focus: ?process.Pid = if (focus_raw == 0) null else @intCast(focus_raw);

            // Sleep — variable cadence. First tick fires immediately.
            if (!first) {
                const ms: u64 = if (focus == null) self.delay_ms else DETAIL_TICK_MS;
                ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
            }
            first = false;

            const now: i64 = utils.nanoTimestamp();

            // ----- Enumerate (full process table) at delay_ms cadence -----
            if (focus == null or now - last_enum_ns >= @as(i64, @intCast(self.delay_ms * std.time.ns_per_ms))) {
                var table = process.ProcessTable.init(self.alloc);
                self.source.enumerate(&table) catch {
                    table.deinit();
                    continue;
                };
                var summary: process.SystemSummary = .{};
                // SystemSummary's per_cpu slice is allocated from the table's
                // arena so it lives and dies with the same payload.
                self.source.systemSummary(table.arena.allocator(), &summary) catch {};
                self.loop.postEvent(.{ .refresh = .{ .table = table, .summary = summary } }) catch {};
                last_enum_ns = now;
            }

            // ----- Sub-second sample of focused process -----
            if (focus) |f_pid| {
                var sample: sample_mod.ProcessSample = undefined;
                self.source.sample(f_pid, &sample) catch {
                    // process likely vanished; skip — main thread will catch up at next enumerate
                    continue;
                };
                self.loop.postEvent(.{ .sample = .{ .pid = f_pid, .sample = sample } }) catch {};

                // Heavier detail at ~1 Hz
                if (now - last_detail_ns >= DETAIL_FULL_INTERVAL_NS) {
                    var detail = process.ProcessDetail.init(self.alloc, f_pid);
                    self.source.detail(f_pid, &detail) catch {
                        detail.deinit();
                        continue;
                    };
                    self.loop.postEvent(.{ .detail = .{ .pid = f_pid, .detail = detail } }) catch {};
                    last_detail_ns = now;
                }
            }
        }
    }
};

// =============================================================================
// App — main thread state and event loop
// =============================================================================

pub const Options = struct {
    delay_ms: u64 = 1500,
    no_color: bool = false,
    initial_user_filter: ?[]const u8 = null,
};

pub const App = struct {
    alloc: std.mem.Allocator,
    tty: Tty,
    vx: Vaxis,
    loop: Loop,
    tty_buf: [4096]u8,

    collector: Collector,

    have_table: bool,
    table: process.ProcessTable,
    summary: process.SystemSummary,
    sorted: std.ArrayListUnmanaged(usize),

    detail: ?process.ProcessDetail,

    /// Sliding window of system-wide metrics (cpu/mem/disk/net), pushed on
    /// every refresh tick. Drives the mini-sparklines in the top blocks.
    system_history: sample_mod.SystemHistory,

    /// Frame arena — reset at the start of each `draw()`. NEVER deinit'd
    /// between frames: vaxis stores slice pointers into the cells we write
    /// and reads them again during `vx.render()`, which runs AFTER draw().
    frame_arena: std.heap.ArenaAllocator,

    state: view_mod.ViewState,
    options: Options,
    should_quit: bool,

    pub fn init(alloc: std.mem.Allocator, opts: Options) !*App {
        const self = try alloc.create(App);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .tty = undefined,
            .vx = undefined,
            .loop = undefined,
            .tty_buf = undefined,
            .collector = undefined,
            .have_table = false,
            .table = process.ProcessTable.init(alloc),
            .summary = .{},
            .sorted = .empty,
            .detail = null,
            .system_history = .init(),
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
            .state = .{},
            .options = opts,
            .should_quit = false,
        };

        self.tty = try Tty.init(ctx.io, &self.tty_buf);
        self.vx = try Vaxis.init(ctx.io, alloc, ctx.env_map, .{});
        self.loop = .init(ctx.io, &self.tty, &self.vx);
        try self.loop.installResizeHandler();
        try self.loop.start();

        self.collector = try Collector.init(alloc, &self.loop, opts.delay_ms);

        self.vx.caps.unicode = .unicode;
        try self.vx.enterAltScreen(self.tty.writer());

        // Pre-apply user filter if requested via CLI
        if (opts.initial_user_filter) |name| {
            self.state.filter.field = .user;
            for (name) |c| {
                if (c >= 0x20 and c < 0x7f) self.state.filter.appendChar(c);
            }
        }

        try self.collector.start();
        return self;
    }

    pub fn deinit(self: *App) void {
        // 1. Stop the collector so no new events can be posted.
        self.collector.deinit();

        // 2. Drain any events still in the loop queue. Each refresh/sample/
        //    detail payload owns an arena that we must free explicitly,
        //    otherwise the GPA reports leaks at shutdown.
        while (self.loop.tryEvent() catch null) |event| {
            switch (event) {
                .refresh => |payload| {
                    var t = payload.table;
                    t.deinit();
                },
                .detail => |payload| {
                    var d = payload.detail;
                    d.deinit();
                },
                .sample, .key_press, .winsize => {},
            }
        }

        if (self.detail) |*d| d.deinit();
        self.frame_arena.deinit();
        self.sorted.deinit(self.alloc);
        self.table.deinit();

        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.writer().flush() catch {};
        self.tty.deinit();
        // Clear screen and home cursor on exit (like xpl-f does)
        std.Io.File.stdout().writeStreamingAll(ctx.io, "\x1b[2J\x1b[H") catch {};

        self.alloc.destroy(self);
    }

    pub fn run(self: *App) !void {
        while (!self.should_quit) {
            const event = try self.loop.nextEvent();
            try self.update(event);
            self.draw();
            try self.vx.render(self.tty.writer());
        }
    }

    // ------------- event dispatch -------------

    fn update(self: *App, event: Event) !void {
        switch (event) {
            .winsize => |ws| try self.vx.resize(self.alloc, self.tty.writer(), ws),
            .refresh => |payload| self.acceptRefresh(payload),
            .sample => |payload| self.acceptSample(payload),
            .detail => |payload| self.acceptDetail(payload),
            .key_press => |key| try self.handleKey(key),
        }
    }

    fn acceptRefresh(self: *App, payload: RefreshPayload) void {
        self.table.deinit();
        self.table = payload.table;
        self.summary = payload.summary;
        self.system_history.push(&self.summary);
        self.have_table = true;

        // Detail mode + selected PID disappeared → close detail gracefully
        if (self.state.mode == .detail) {
            if (self.state.selected_pid) |pid| {
                if (self.table.lookup(pid) == null) {
                    self.closeDetail();
                }
            }
        }

        self.recompute();
        self.clampScroll();
        self.state.tickFlash();
    }

    fn acceptSample(self: *App, payload: SamplePayload) void {
        if (self.state.mode != .detail) return;
        if (self.state.detail_history) |*h| {
            if (h.pid != payload.pid) return; // stale
            h.push(payload.sample);
        }
    }

    fn acceptDetail(self: *App, payload: DetailPayload) void {
        if (self.state.mode != .detail) {
            // Stale event after close — drop
            var d = payload.detail;
            d.deinit();
            return;
        }
        if (self.state.selected_pid) |pid| {
            if (pid != payload.pid) {
                var d = payload.detail;
                d.deinit();
                return;
            }
        }
        // Replace
        if (self.detail) |*old| old.deinit();
        self.detail = payload.detail;
    }

    // ------------- signal confirm transitions -------------

    fn openSignalConfirm(self: *App) void {
        if (self.state.selected_pid == null) return;
        self.state.pending_signal = .term;
        self.state.prev_mode = self.state.mode;
        self.state.mode = .signal_confirm;
    }

    fn handleSignalConfirmKey(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.tab, .{})) {
            self.state.pending_signal = self.state.pending_signal.cycle();
            return;
        }
        if (key.matches('y', .{}) or key.matches('Y', .{})) {
            const pid = self.state.selected_pid orelse {
                self.state.mode = self.state.prev_mode;
                return;
            };
            const sig = self.state.pending_signal;
            process.sendSignal(pid, sig) catch |e| {
                var buf: [128]u8 = undefined;
                const msg = switch (e) {
                    error.PermissionDenied => std.fmt.bufPrint(&buf, "✗ permission denied (PID {d})", .{pid}) catch "✗ permission denied",
                    error.NoSuchProcess => std.fmt.bufPrint(&buf, "✗ no such process (PID {d})", .{pid}) catch "✗ no such process",
                    else => std.fmt.bufPrint(&buf, "✗ signal failed: {s}", .{@errorName(e)}) catch "✗ signal failed",
                };
                self.state.setFlash(msg);
                self.state.mode = self.state.prev_mode;
                return;
            };
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "✓ sent SIG{s} to PID {d}", .{ sig.name(), pid }) catch "✓ signal sent";
            self.state.setFlash(msg);
            self.state.mode = self.state.prev_mode;
            return;
        }
        // Anything else cancels
        self.state.mode = self.state.prev_mode;
    }

    // ------------- detail open/close transitions -------------

    fn openDetail(self: *App) void {
        const pid = self.state.selected_pid orelse return;
        self.state.mode = .detail;
        self.state.detail_history = sample_mod.ProcessHistory.init(pid);
        self.state.detail_panel = .graphs;
        self.state.detail_threads_scroll = 0;
        self.state.detail_fds_scroll = 0;

        if (self.detail) |*old| old.deinit();
        self.detail = process.ProcessDetail.init(self.alloc, pid);

        self.collector.setFocus(pid);
    }

    fn closeDetail(self: *App) void {
        self.state.mode = .list;
        self.state.detail_history = null;
        if (self.detail) |*d| d.deinit();
        self.detail = null;
        self.collector.setFocus(null);
    }

    // ------------- list state, filter & sort -------------

    /// Filter then sort `self.table.procs` into `self.sorted`. Called whenever
    /// the table is replaced (refresh) or the filter/sort settings change.
    fn recompute(self: *App) void {
        self.sorted.clearRetainingCapacity();
        const procs = self.table.procs.items;
        self.sorted.ensureTotalCapacity(self.alloc, procs.len) catch return;
        for (procs, 0..) |*p, i| {
            if (self.state.filter.matches(p)) {
                self.sorted.appendAssumeCapacity(i);
            }
        }
        const sort_ctx = view_mod.SortCtx{
            .procs = procs,
            .key = self.state.sort_key,
            .dir = self.state.sort_dir,
        };
        std.sort.pdq(usize, self.sorted.items, sort_ctx, view_mod.SortCtx.lessThan);
    }

    fn clampScroll(self: *App) void {
        const visible = self.visibleRows();
        const max_scroll: usize = if (self.sorted.items.len > visible) self.sorted.items.len - visible else 0;
        if (self.state.scroll_top > max_scroll) self.state.scroll_top = max_scroll;
    }

    fn visibleRows(self: *App) usize {
        const h = self.vx.window().height;
        const chrome = render.chromeRows(@intCast(h));
        if (h <= chrome) return 0;
        return @as(usize, h) - @as(usize, chrome);
    }

    fn currentSelectedIdx(self: *App) ?usize {
        if (self.state.selected_pid == null) {
            if (self.sorted.items.len > 0) return 0;
            return null;
        }
        const want = self.state.selected_pid.?;
        for (self.sorted.items, 0..) |real_idx, view_idx| {
            if (real_idx >= self.table.procs.items.len) continue;
            if (self.table.procs.items[real_idx].pid == want) return view_idx;
        }
        if (self.sorted.items.len > 0) return 0;
        return null;
    }

    fn setSelectionByViewIdx(self: *App, view_idx: usize) void {
        if (self.sorted.items.len == 0) {
            self.state.selected_pid = null;
            return;
        }
        const idx = @min(view_idx, self.sorted.items.len - 1);
        const real_idx = self.sorted.items[idx];
        self.state.selected_pid = self.table.procs.items[real_idx].pid;

        const visible = self.visibleRows();
        if (visible == 0) return;
        if (idx < self.state.scroll_top) self.state.scroll_top = idx;
        if (idx >= self.state.scroll_top + visible) {
            self.state.scroll_top = idx + 1 - visible;
        }
    }

    // ------------- key handling -------------

    fn handleKey(self: *App, key: vaxis.Key) !void {
        if (self.state.mode == .help) {
            self.state.mode = self.state.prev_mode;
            return;
        }

        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }
        if (key.matches(vaxis.Key.f1, .{})) {
            self.state.prev_mode = self.state.mode;
            self.state.mode = .help;
            return;
        }

        switch (self.state.mode) {
            .list => try self.handleListKey(key),
            .detail => try self.handleDetailKey(key),
            .filter_input => try self.handleFilterInputKey(key),
            .signal_confirm => try self.handleSignalConfirmKey(key),
            else => {},
        }
    }

    fn handleListKey(self: *App, key: vaxis.Key) !void {
        if (key.matches('q', .{})) {
            self.should_quit = true;
            return;
        }
        const total = self.sorted.items.len;
        if (total == 0) return;
        const cur = self.currentSelectedIdx() orelse return;
        const visible = self.visibleRows();
        const page: usize = if (visible > 1) visible - 1 else 1;

        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (cur + 1 < total) self.setSelectionByViewIdx(cur + 1);
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (cur > 0) self.setSelectionByViewIdx(cur - 1);
        } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
            const target = @min(cur + page, total - 1);
            self.setSelectionByViewIdx(target);
        } else if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
            const target = if (cur > page) cur - page else 0;
            self.setSelectionByViewIdx(target);
        } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) {
            self.setSelectionByViewIdx(0);
        } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) {
            self.setSelectionByViewIdx(total - 1);
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('d', .{})) {
            self.openDetail();
        } else if (key.matches('s', .{})) {
            self.state.sort_key = view_mod.cycleSortKey(self.state.sort_key);
            self.recompute();
        } else if (key.matches('r', .{})) {
            self.state.sort_dir = if (self.state.sort_dir == .desc) .asc else .desc;
            self.recompute();
        } else if (key.matches('/', .{})) {
            self.state.mode = .filter_input;
        } else if (key.matches('\\', .{})) {
            self.state.filter.clear();
            self.recompute();
        } else if (key.matches('K', .{})) {
            self.openSignalConfirm();
        } else if (key.matches('n', .{})) {
            self.collector.cycleNet();
        } else if (key.matches('D', .{})) {
            self.collector.cycleDisk();
        }
    }

    fn handleFilterInputKey(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            // Cancel: discard pending text and go back to list
            self.state.filter.clear();
            self.state.mode = .list;
            self.recompute();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.state.mode = .list;
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.state.filter.field = view_mod.cycleFilterField(self.state.filter.field);
            self.recompute();
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            self.state.filter.backspace();
            self.recompute();
            return;
        }
        if (key.matches('w', .{ .ctrl = true })) {
            self.state.filter.deleteWord();
            self.recompute();
            return;
        }
        if (key.matches('u', .{ .ctrl = true })) {
            self.state.filter.clear();
            self.recompute();
            return;
        }
        // Append printable ASCII (single codepoint keys)
        if (key.text) |t| {
            for (t) |c| {
                if (c >= 0x20 and c < 0x7f) self.state.filter.appendChar(c);
            }
            self.recompute();
        }
    }

    fn handleDetailKey(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('d', .{}) or key.matches('q', .{})) {
            self.closeDetail();
            return;
        }
        if (key.matches('K', .{})) {
            self.openSignalConfirm();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.state.detail_panel = switch (self.state.detail_panel) {
                .graphs => .threads,
                .threads => .fds,
                .fds => .graphs,
            };
            return;
        }
        // Scroll inside focused panel
        const det = self.detail orelse return;
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            switch (self.state.detail_panel) {
                .threads => if (self.state.detail_threads_scroll + 1 < det.threads.items.len) {
                    self.state.detail_threads_scroll += 1;
                },
                .fds => if (self.state.detail_fds_scroll + 1 < det.fds.items.len) {
                    self.state.detail_fds_scroll += 1;
                },
                .graphs => {},
            }
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            switch (self.state.detail_panel) {
                .threads => if (self.state.detail_threads_scroll > 0) {
                    self.state.detail_threads_scroll -= 1;
                },
                .fds => if (self.state.detail_fds_scroll > 0) {
                    self.state.detail_fds_scroll -= 1;
                },
                .graphs => {},
            }
        }
    }

    // ------------- render dispatch -------------

    fn draw(self: *App) void {
        // Reset (don't deinit) — vaxis cells reference slices we write here,
        // and `vx.render()` runs AFTER draw() returns. The buffers must stay
        // valid until the NEXT draw() resets them.
        _ = self.frame_arena.reset(.retain_capacity);
        const a = self.frame_arena.allocator();

        const win = self.vx.window();
        win.clear();

        // Initialize selection if not yet set
        if (self.state.selected_pid == null and self.sorted.items.len > 0) {
            const first_real = self.sorted.items[0];
            self.state.selected_pid = self.table.procs.items[first_real].pid;
        }

        const focused: ?*const process.Process = if (self.state.selected_pid) |pid| self.table.lookup(pid) else null;

        switch (self.state.mode) {
            .detail => {
                if (self.detail) |*d| {
                    const hist_ptr: ?*const sample_mod.ProcessHistory = if (self.state.detail_history) |*h| h else null;
                    render_detail.draw(a, win, focused, hist_ptr, d, &self.state, self.options.no_color);
                } else {
                    render.draw(a, win, &self.table, self.sorted.items, &self.summary, &self.system_history, &self.state, self.options.no_color);
                }
            },
            else => render.draw(a, win, &self.table, self.sorted.items, &self.summary, &self.system_history, &self.state, self.options.no_color),
        }

        win.hideCursor();
    }
};
