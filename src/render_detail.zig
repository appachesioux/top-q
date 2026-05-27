const std = @import("std");
const vaxis = @import("vaxis");
const process = @import("process.zig");
const sample_mod = @import("sample.zig");
const view_mod = @import("view.zig");
const style = @import("style.zig");
const utils = @import("utils.zig");
const graph = @import("graph.zig");

const Window = vaxis.Window;

pub fn draw(
    alloc: std.mem.Allocator,
    win: Window,
    focused: ?*const process.Process,
    history: ?*const sample_mod.ProcessHistory,
    detail: *const process.ProcessDetail,
    state: *const view_mod.ViewState,
    no_color: bool,
) void {
    const w = win.width;
    const h = win.height;
    if (w < 60 or h < 16) {
        const msg = "detail view needs at least 60x16";
        _ = win.printSegment(.{ .text = msg, .style = style.error_style }, .{
            .row_offset = h / 2,
            .col_offset = if (w > msg.len) (w - @as(u16, @intCast(msg.len))) / 2 else 0,
        });
        return;
    }

    var row: u16 = 0;

    // ---------- Header lines (2) ----------
    drawHeader(alloc, win, w, focused);
    row = 2;

    // ---------- Graph panel (4 sparklines) ----------
    const graph_h: u16 = 4;
    drawGraphs(alloc, win, w, row, history, focused, state, no_color);
    row += graph_h + 1; // +1 separator

    // ---------- Threads panel (variable, share remaining with FDs) ----------
    const status_row: u16 = h - 1;
    const remaining = if (status_row > row + 4) status_row - row - 4 else 0;
    const threads_h = remaining / 2;
    const fds_h = remaining - threads_h;

    drawThreadsPanel(alloc, win, w, row, threads_h + 2, detail, state, no_color);
    row += threads_h + 2;

    drawFdsPanel(alloc, win, w, row, fds_h + 2, detail, state, no_color);

    // ---------- Status bar ----------
    drawStatus(alloc, win, w, status_row, state);
}

fn drawHeader(alloc: std.mem.Allocator, win: Window, w: u16, focused: ?*const process.Process) void {
    for (0..w) |x| {
        win.writeCell(@intCast(x), 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style.header_style });
        win.writeCell(@intCast(x), 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style.header_style });
    }

    const p = focused orelse return;
    const title = std.fmt.allocPrint(alloc, " DETAIL  PID {d}  comm '{s}'  state {c}", .{ p.pid, p.comm, p.state.char() }) catch return;
    _ = win.printSegment(.{ .text = title, .style = style.header_style }, .{ .row_offset = 0, .col_offset = 0 });

    const meta = std.fmt.allocPrint(alloc, " user {s}  ppid {d}  threads {d}  rss ", .{ p.user, p.ppid, p.nthreads }) catch return;
    _ = win.printSegment(.{ .text = meta, .style = style.header_style }, .{ .row_offset = 1, .col_offset = 0 });

    var rss_buf: [16]u8 = undefined;
    const rss = utils.formatBytes(p.mem_rss_bytes, &rss_buf);
    _ = win.printSegment(.{ .text = rss, .style = style.title_style }, .{ .row_offset = 1, .col_offset = @intCast(meta.len) });
}

fn drawGraphs(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    y: u16,
    history: ?*const sample_mod.ProcessHistory,
    focused: ?*const process.Process,
    state: *const view_mod.ViewState,
    no_color: bool,
) void {
    const focus_style: vaxis.Style = if (state.detail_panel == .graphs and !no_color)
        style.title_style
    else
        style.default_style;

    const labels = [_][]const u8{ "CPU% ", "MEM  ", "IO RD", "IO WR" };
    inline for (labels, 0..) |lbl, i| {
        const row: u16 = y + @as(u16, @intCast(i));
        _ = win.printSegment(.{ .text = lbl, .style = focus_style }, .{ .row_offset = row, .col_offset = 0 });
    }

    const graph_x: u16 = 6;
    const right_pad: u16 = 12; // right-side numeric label
    if (w <= graph_x + right_pad) return;
    const graph_w: u16 = w - graph_x - right_pad;

    const h = history orelse return;
    const fp = focused orelse return;

    // Build sample slices in oldest..newest order.
    var cpu_samples = alloc.alloc(f64, h.cpu.len) catch return;
    var mem_samples = alloc.alloc(f64, h.mem_rss.len) catch return;
    var rd_samples = alloc.alloc(f64, h.io_read.len) catch return;
    var wr_samples = alloc.alloc(f64, h.io_write.len) catch return;
    for (0..h.cpu.len) |i| cpu_samples[i] = @floatCast(h.cpu.at(i));
    for (0..h.mem_rss.len) |i| mem_samples[i] = @floatFromInt(h.mem_rss.at(i));
    for (0..h.io_read.len) |i| rd_samples[i] = @floatFromInt(h.io_read.at(i));
    for (0..h.io_write.len) |i| wr_samples[i] = @floatFromInt(h.io_write.at(i));

    const cpu_style: vaxis.Style = if (no_color) .{} else style.green_style;
    const mem_style: vaxis.Style = if (no_color) .{} else style.cyan_style;
    const rd_style: vaxis.Style = if (no_color) .{} else style.purple_style;
    const wr_style: vaxis.Style = if (no_color) .{} else style.orange_style;

    graph.drawSparkline(win, graph_x, y + 0, graph_w, cpu_samples, 100.0, cpu_style);
    graph.drawSparkline(win, graph_x, y + 1, graph_w, mem_samples, 0, mem_style);
    graph.drawSparkline(win, graph_x, y + 2, graph_w, rd_samples, 0, rd_style);
    graph.drawSparkline(win, graph_x, y + 3, graph_w, wr_samples, 0, wr_style);

    // Right-side numeric labels
    var num_buf: [16]u8 = undefined;
    var num: []const u8 = undefined;

    num = std.fmt.bufPrint(&num_buf, "{d:>5.1}%", .{fp.cpu_pct}) catch "";
    _ = win.printSegment(.{ .text = num, .style = focus_style }, .{ .row_offset = y + 0, .col_offset = w - right_pad + 1 });

    var bbuf: [16]u8 = undefined;
    const mem_str = utils.formatBytes(fp.mem_rss_bytes, &bbuf);
    _ = win.printSegment(.{ .text = mem_str, .style = focus_style }, .{ .row_offset = y + 1, .col_offset = w - right_pad + 1 });

    if (fp.io_available) {
        var rb: [16]u8 = undefined;
        var wb: [16]u8 = undefined;
        const rd = utils.formatBytes(if (h.io_read.len > 0) h.io_read.at(h.io_read.len - 1) else 0, &rb);
        const wr = utils.formatBytes(if (h.io_write.len > 0) h.io_write.at(h.io_write.len - 1) else 0, &wb);
        _ = win.printSegment(.{ .text = rd, .style = focus_style }, .{ .row_offset = y + 2, .col_offset = w - right_pad + 1 });
        _ = win.printSegment(.{ .text = wr, .style = focus_style }, .{ .row_offset = y + 3, .col_offset = w - right_pad + 1 });
    } else {
        _ = win.printSegment(.{ .text = "  --", .style = style.dim_style }, .{ .row_offset = y + 2, .col_offset = w - right_pad + 1 });
        _ = win.printSegment(.{ .text = "  --", .style = style.dim_style }, .{ .row_offset = y + 3, .col_offset = w - right_pad + 1 });
    }
}

fn drawPanelHeader(alloc: std.mem.Allocator, win: Window, w: u16, y: u16, label: []const u8, focused: bool) void {
    const s: vaxis.Style = if (focused) style.title_style else style.dim_style;
    const line_style = if (focused) style.title_style else style.border_style;
    for (0..w) |x| {
        win.writeCell(@intCast(x), y, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = line_style });
    }
    // Allocate from the per-frame arena — bytes must outlive draw() return,
    // since vaxis stores grapheme slice pointers into its current screen and
    // reads them again during the subsequent vx.render().
    const wrapped = std.fmt.allocPrint(alloc, " {s} ", .{label}) catch label;
    _ = win.printSegment(.{ .text = wrapped, .style = s }, .{ .row_offset = y, .col_offset = 2 });
}

fn drawThreadsPanel(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    y: u16,
    h: u16,
    detail: *const process.ProcessDetail,
    state: *const view_mod.ViewState,
    no_color: bool,
) void {
    if (h < 2) return;
    const label = std.fmt.allocPrint(alloc, "THREADS ({d})", .{detail.threads.items.len}) catch "THREADS";
    drawPanelHeader(alloc, win, w, y, label, state.detail_panel == .threads and !no_color);

    const inner_h = h - 1;
    const items = detail.threads.items;
    const start = @min(state.detail_threads_scroll, items.len);
    var i = start;
    var row: u16 = y + 1;
    while (i < items.len and row < y + inner_h) : ({
        i += 1;
        row += 1;
    }) {
        const t = items[i];
        const text = std.fmt.allocPrint(alloc, "  {d:>7} {c}  {s}", .{ t.tid, t.state.char(), t.name }) catch continue;
        _ = win.printSegment(.{ .text = text, .style = style.default_style }, .{ .row_offset = row, .col_offset = 0 });
    }
}

fn drawFdsPanel(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    y: u16,
    h: u16,
    detail: *const process.ProcessDetail,
    state: *const view_mod.ViewState,
    no_color: bool,
) void {
    if (h < 2) return;
    const trunc_suffix: []const u8 = if (detail.fds_truncated) " [+more truncated]" else "";
    const label = std.fmt.allocPrint(alloc, "FDS ({d}){s}", .{ detail.fds.items.len, trunc_suffix }) catch "FDS";
    drawPanelHeader(alloc, win, w, y, label, state.detail_panel == .fds and !no_color);

    const inner_h = h - 1;
    const items = detail.fds.items;
    const start = @min(state.detail_fds_scroll, items.len);
    var i = start;
    var row: u16 = y + 1;
    while (i < items.len and row < y + inner_h) : ({
        i += 1;
        row += 1;
    }) {
        const fd = items[i];
        const kind_str = switch (fd.kind) {
            .regular => "file",
            .socket => "sock",
            .pipe => "pipe",
            .anon => "anon",
            .char => "char",
            .block => "blk ",
            .dir => "dir ",
            .symlink => "link",
            .unknown => "??? ",
        };
        const text = std.fmt.allocPrint(alloc, "  {d:>4} {s}  {s}", .{ fd.fd, kind_str, fd.target }) catch continue;
        _ = win.printSegment(.{ .text = text, .style = style.default_style }, .{ .row_offset = row, .col_offset = 0 });
    }
}

fn drawStatus(alloc: std.mem.Allocator, win: Window, w: u16, row: u16, state: *const view_mod.ViewState) void {
    for (0..w) |x| {
        win.writeCell(@intCast(x), row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style.status_style });
    }
    const panel: []const u8 = switch (state.detail_panel) {
        .graphs => "graphs",
        .threads => "threads",
        .fds => "fds",
    };
    const text = std.fmt.allocPrint(alloc, " DETAIL  panel:{s}  Tab cycle  ↑↓ scroll  Esc/d back  q quit ", .{panel}) catch return;
    _ = win.printSegment(.{ .text = text, .style = style.status_style }, .{ .row_offset = row, .col_offset = 0 });
}
