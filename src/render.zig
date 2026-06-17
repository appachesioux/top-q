const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");
const process = @import("process.zig");
const view_mod = @import("view.zig");
const mode_mod = @import("mode.zig");
const style = @import("style.zig");
const utils = @import("utils.zig");
const sample_mod = @import("sample.zig");
const graph = @import("graph.zig");

const Window = vaxis.Window;

pub const MIN_W: u16 = 80;
pub const MIN_H: u16 = 24;

// Top panel area takes 1/TOP_RATIO_DEN of the screen height.
pub const TOP_RATIO_DEN: u16 = 5;

// Fixed widths for the leftmost top blocks. CPU block flexes to fill rest.
// MEM/DISK rows carry "label NN% used/total [bar]" — 32 cols keep the bar legible.
pub const SYS_BLOCK_W: u16 = 50;
pub const MEM_BLOCK_W: u16 = 35;
pub const DISK_BLOCK_W: u16 = 40;
pub const NET_BLOCK_W: u16 = 25;

/// Fixed sys-block content rows: OS, Kernel, Uptime, CPU, Load, Battery.
/// GPUs add one row each on top of these.
pub const SYS_FIXED_ROWS: u16 = 6;

pub fn topLayoutHeights(h: u16, w: u16, ncores: u16, ngpus: u16) struct { row1: u16, row2: u16, total: u16 } {
    // Row 1 is content-driven: tall enough for the full sys block (+2 border
    // rows); the process list gives up the rows (user decision 2026-06-05).
    // Very short terminals keep the old compact height and cut sys content.
    const row1: u16 = if (h < 28) 4 else SYS_FIXED_ROWS + ngpus + 2;

    // Minimum CPU height matching standard layouts
    const min_cpu_h: u16 = if (h < 28) 4 else if (h < 35) 5 else 6;

    // Budget: header total cannot exceed 33% of h, but we allow at least 11 rows total as fallback.
    // The cpu budget is computed against the pre-growth row1 baseline (5) so
    // a taller sys block shrinks the process list, not the cpu block.
    const row1_baseline: u16 = if (h < 28) 4 else 5;
    const max_total_h = @max(11, h / 3);
    const max_cpu_h = if (max_total_h > row1_baseline) max_total_h - row1_baseline else min_cpu_h;

    const box_w: u16 = if (w > 2) w - 2 else 0;
    const min_cell_w: u16 = 13;
    const target_cell_w: u16 = 28;

    // Calculate ncols for target layout
    var ncols = if (box_w >= target_cell_w) box_w / target_cell_w else 1;
    if (ncols > ncores) ncols = ncores;

    // Calculate minimum ncols needed to fit vertically in budget
    const avail_inner_rows = if (max_cpu_h > 2) max_cpu_h - 2 else 1;
    const min_ncols_needed = if (ncores > 0) (ncores + avail_inner_rows - 1) / avail_inner_rows else 1;

    // If we need more columns to fit vertically, increase ncols
    if (ncols < min_ncols_needed) {
        ncols = min_ncols_needed;
    }

    const cell_w = if (ncols > 0) box_w / ncols else box_w;
    const rows_needed = if (ncols > 0 and ncores > 0) (ncores + ncols - 1) / ncols else 1;
    const cpu_height_as_bars = rows_needed + 2;

    const grid_inner_rows = if (box_w > 0 and ncores > 0) (ncores + box_w - 1) / box_w else 1;
    const cpu_height_as_grid = grid_inner_rows + 2;

    // Fall back to grid if columns don't fit minimum cell width
    const row2: u16 = if (cell_w >= min_cell_w and cpu_height_as_bars <= max_cpu_h)
        @max(min_cpu_h, cpu_height_as_bars)
    else
        @min(max_cpu_h, @max(min_cpu_h, cpu_height_as_grid));

    return .{ .row1 = row1, .row2 = row2, .total = row1 + row2 };
}

/// Height reserved at the top of the window for the info blocks.
pub fn topAreaHeight(h: u16, w: u16, ncores: u16, ngpus: u16) u16 {
    return topLayoutHeights(h, w, ncores, ngpus).total;
}

/// Total rows reserved for chrome: top panels + list box borders (2) +
/// column header (1, inside the box) + status bar (1).
pub fn chromeRows(h: u16, w: u16, ncores: u16, ngpus: u16) u16 {
    return topAreaHeight(h, w, ncores, ngpus) + 4;
}

/// Top-level draw function. `procs_sorted` is a slice of indices into
/// `table.procs` already sorted/filtered for display.
pub fn draw(
    alloc: std.mem.Allocator,
    win: Window,
    table: *const process.ProcessTable,
    procs_sorted: []const usize,
    summary: *const process.SystemSummary,
    sys_history: *const sample_mod.SystemHistory,
    state: *const view_mod.ViewState,
    no_color: bool,
) void {
    const w = win.width;
    const h = win.height;

    if (w < MIN_W or h < MIN_H) {
        drawMinSize(win, w, h);
        return;
    }

    const top_h = topAreaHeight(h, w, @intCast(summary.per_cpu.len), @intCast(summary.gpus.len));
    drawTopPanels(alloc, win, w, top_h, summary, sys_history, state);

    // Bordered frame around column header + process list (btop-style).
    // Height covers from the bottom of top panels down to one row above the
    // status bar; status bar stays outside the frame at the very bottom row.
    const list_box_h: u16 = if (h > top_h + 1) h - top_h - 1 else 0;
    if (list_box_h >= 3) {
        const list_box = win.child(.{
            .x_off = 0,
            .y_off = @intCast(top_h),
            .width = w,
            .height = list_box_h,
            .border = .{
                .where = .all,
                .glyphs = .single_rounded,
                .style = style.border_style,
            },
        });
        const proc_title = std.fmt.allocPrint(alloc, " processes · {d} ", .{procs_sorted.len}) catch " processes ";
        drawBorderTitle(win, 0, top_h, proc_title);
        drawColumnHeader(alloc, list_box, list_box.width, 0, state, no_color);
        drawList(alloc, list_box, list_box.width, list_box.height, 1, table, procs_sorted, state, summary, no_color);
    }
    drawStatusBar(alloc, win, w, h, table, procs_sorted, state);

    if (state.mode == .help) {
        drawHelp(win, w, h);
    }
    if (state.mode == .signal_confirm) {
        drawSignalConfirm(alloc, win, w, h, table, state);
    }
}

fn drawMinSize(win: Window, w: u16, h: u16) void {
    win.clear();
    const msg = "top-q requires at least 80x24";
    if (h < 1) return;
    const col: u16 = if (w > msg.len) (w - @as(u16, @intCast(msg.len))) / 2 else 0;
    const row: u16 = h / 2;
    _ = win.printSegment(.{ .text = msg, .style = style.error_style }, .{
        .row_offset = row,
        .col_offset = col,
    });
}

const block_chars = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// Pick a vertical block character for `pct` 0..100.
fn blockForPct(pct: f32) []const u8 {
    var lvl: usize = @intFromFloat(@floor((pct / 100.0) * @as(f32, @floatFromInt(block_chars.len - 1))));
    if (lvl >= block_chars.len) lvl = block_chars.len - 1;
    if (pct <= 0) lvl = 0;
    return block_chars[lvl];
}

/// Filled-bar character (used for Mem/Swap/Disk progress bars).
const BAR_FILLED: []const u8 = "█";
const BAR_EMPTY: []const u8 = "░";

fn drawTopPanels(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    top_h: u16,
    s: *const process.SystemSummary,
    sys_history: *const sample_mod.SystemHistory,
    state: *const view_mod.ViewState,
) void {
    _ = top_h;
    const heights = topLayoutHeights(win.height, w, @intCast(s.per_cpu.len), @intCast(s.gpus.len));
    if (heights.total < 6) return;

    // Row 1: sys, mem, disk, net (distributed symmetrically)
    const n_blocks: u16 = if (w < 115) 2 else if (w < 150) 3 else 4;
    const base_w = w / n_blocks;

    // 1. sys block
    const sys_w = base_w;
    drawSysBlock(alloc, win, 0, 0, sys_w, heights.row1, s);
    var x = sys_w;

    // 2. mem block
    const mem_w = if (n_blocks == 2) w - x else base_w;
    drawMemBlock(alloc, win, x, 0, mem_w, heights.row1, s, sys_history);
    x += mem_w;

    // 3. disk block
    if (n_blocks >= 3) {
        const disk_w = if (n_blocks == 3) w - x else base_w;
        drawDiskBlock(alloc, win, x, 0, disk_w, heights.row1, s, sys_history);
        x += disk_w;
    }

    // 4. net block
    if (n_blocks >= 4) {
        const net_w = w - x;
        drawNetBlock(alloc, win, x, 0, net_w, heights.row1, s, sys_history);
    }

    // Row 2: cpu (spans entire width w)
    drawCpuBlock(alloc, win, 0, heights.row1, w, heights.row2, s, sys_history, state, true);
}

fn borderedBox(win: Window, x: u16, y: u16, w: u16, h: u16) Window {
    return win.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style.border_style,
        },
    });
}

/// Paint a title overlay on the top border of a box at (x, y) of the
/// parent window — lzd/lazygit-style `╭─ title ─╮`. Title text replaces
/// border glyphs starting 2 cols from the left corner; caller should pad
/// the title with leading/trailing spaces (e.g. " mem ") so the border
/// stays visible on either side.
fn drawBorderTitle(win: Window, x: u16, y: u16, title: []const u8) void {
    if (title.len == 0) return;
    _ = win.printSegment(.{ .text = title, .style = style.title_style }, .{
        .row_offset = y,
        .col_offset = x + 2,
    });
}

fn renderSparklineF32(
    alloc: std.mem.Allocator,
    win: Window,
    x: u16,
    y: u16,
    w: u16,
    rb: *const utils.RingBuffer(f32, sample_mod.HISTORY_CAPACITY),
    max_hint: f64,
    s: vaxis.Style,
) void {
    if (rb.len == 0) return;
    const samples = alloc.alloc(f64, rb.len) catch return;
    for (0..rb.len) |i| samples[i] = @floatCast(rb.at(i));
    graph.drawSparkline(win, x, y, w, samples, max_hint, s);
}

fn renderSparklineU64(
    alloc: std.mem.Allocator,
    win: Window,
    x: u16,
    y: u16,
    w: u16,
    rb: *const utils.RingBuffer(u64, sample_mod.HISTORY_CAPACITY),
    s: vaxis.Style,
) void {
    if (rb.len == 0) return;
    const samples = alloc.alloc(f64, rb.len) catch return;
    for (0..rb.len) |i| samples[i] = @floatFromInt(rb.at(i));
    graph.drawSparkline(win, x, y, w, samples, 0, s);
}

const LabelledRow = struct {
    label: []const u8,
    pct: f32,
    /// Absolute figure shown between label and bar, e.g. "12G/31G". Empty → skip.
    abs: []const u8 = "",
};

/// Render rows of "<label> NN% [abs] [bar]" starting at inner row 0.
/// When `abs` is empty, the column collapses and the bar grows to fill.
fn drawLabelledBars(
    alloc: std.mem.Allocator,
    box: Window,
    rows: []const LabelledRow,
) void {
    const inner_w = box.width;
    const inner_h = box.height;
    if (inner_w < 10 or inner_h < 1) return;

    // " LABEL NN% " = 13 cols prefix (leading space, label padded to 6, space,
    // pct padded to 3, %, trailing space that separates from the abs column).
    const label_w: u16 = 13;

    // Widest `abs` string across the rows; column is reserved that wide so
    // all bars in the block start at the same column.
    var abs_w: u16 = 0;
    for (rows) |r| {
        if (r.abs.len > abs_w) abs_w = @intCast(r.abs.len);
    }
    // Trailing space between abs and bar when abs is present.
    const abs_col_w: u16 = if (abs_w > 0) abs_w + 1 else 0;

    const bar_col = label_w + abs_col_w;
    const bar_w: u16 = if (inner_w > bar_col + 2) inner_w - bar_col else 0;

    var i: usize = 0;
    while (i < rows.len and i < inner_h) : (i += 1) {
        const r = rows[i];
        const prefix = std.fmt.allocPrint(alloc, " {s:<6} {d:>3.0}% ", .{ r.label, r.pct }) catch continue;
        _ = box.printSegment(.{ .text = prefix, .style = style.default_style }, .{
            .row_offset = @intCast(i),
            .col_offset = 0,
        });
        if (r.abs.len > 0) {
            _ = box.printSegment(.{ .text = r.abs, .style = style.dim_style }, .{
                .row_offset = @intCast(i),
                .col_offset = label_w,
            });
        }
        if (bar_w >= 3) {
            _ = drawBar(box, bar_col, @intCast(i), bar_w, r.pct);
        }
    }
}

fn pctOf(used: u64, total: u64) f32 {
    if (total == 0) return 0;
    return @floatCast(100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total)));
}

/// Format "used/total" in human-friendly units; empty slice when total == 0.
/// Memory is arena-allocated (frame arena); lifetime ends at the next frame.
fn absUsedTotal(alloc: std.mem.Allocator, used: u64, total: u64) []const u8 {
    if (total == 0) return "";
    var ub: [16]u8 = undefined;
    var tb: [16]u8 = undefined;
    const u = utils.formatBytes(used, &ub);
    const t = utils.formatBytes(total, &tb);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ u, t }) catch "";
}

fn drawMemBlock(alloc: std.mem.Allocator, win: Window, x: u16, y: u16, w: u16, h: u16, s: *const process.SystemSummary, sys_history: *const sample_mod.SystemHistory) void {
    const box = borderedBox(win, x, y, w, h);
    drawBorderTitle(win, x, y, " mem ");

    const used_pct = pctOf(s.mem_used_bytes, s.mem_total_bytes);
    const cache_pct = pctOf(s.mem_cache_bytes, s.mem_total_bytes);
    const swap_pct = pctOf(s.swap_used_bytes, s.swap_total_bytes);

    const rows = [_]LabelledRow{
        .{ .label = "Used:", .pct = used_pct, .abs = absUsedTotal(alloc, s.mem_used_bytes, s.mem_total_bytes) },
        .{ .label = "Cache:", .pct = cache_pct, .abs = absUsedTotal(alloc, s.mem_cache_bytes, s.mem_total_bytes) },
        .{ .label = "Swap:", .pct = swap_pct, .abs = absUsedTotal(alloc, s.swap_used_bytes, s.swap_total_bytes) },
    };
    drawLabelledBars(alloc, box, &rows);

    // Sparkline of mem% history at the row below the labelled bars (if any).
    if (box.height >= 4 and box.width >= 4) {
        renderSparklineF32(alloc, box, 1, box.height - 1, box.width - 2, &sys_history.mem_pct, 100.0, style.gradientStyle(used_pct));
    }

    // If swap is absent, overwrite the swap bar with " (none)" after the label
    // so users can tell the 0% isn't usage but unavailability.
    if (s.swap_total_bytes == 0 and box.height >= 3) {
        const swap_row: u16 = 2; // Used=0, Cache=1, Swap=2
        const text = " Swap      (none)";
        if (text.len <= box.width) {
            // Clear the bar portion by printing spaces then the "(none)" marker.
            for (0..box.width) |col| {
                box.writeCell(@intCast(col), swap_row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = style.default_style,
                });
            }
            _ = box.printSegment(.{ .text = text, .style = style.dim_style }, .{
                .row_offset = swap_row,
                .col_offset = 0,
            });
        }
    }
}

fn drawDiskBlock(alloc: std.mem.Allocator, win: Window, x: u16, y: u16, w: u16, h: u16, s: *const process.SystemSummary, sys_history: *const sample_mod.SystemHistory) void {
    const box = borderedBox(win, x, y, w, h);
    const disk_title = if (s.fs_type_name.len > 0)
        std.fmt.allocPrint(alloc, " disk · {s} ", .{s.fs_type_name}) catch " disk "
    else
        " disk ";
    drawBorderTitle(win, x, y, disk_title);
    if (box.height < 1) return;

    const root_pct = pctOf(s.fs_root_used_bytes, s.fs_root_total_bytes);
    // Truncate long paths so they fit the 6-col label budget; keep root visible.
    const label = if (s.fs_mount_path.len <= 6) s.fs_mount_path else s.fs_mount_path[s.fs_mount_path.len - 6 ..];
    const rows = [_]LabelledRow{
        .{
            .label = label,
            .pct = root_pct,
            .abs = absUsedTotal(alloc, s.fs_root_used_bytes, s.fs_root_total_bytes),
        },
    };
    drawLabelledBars(alloc, box, &rows);

    // Throughput lines below the bar.
    var rb: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    const rd = utils.formatBytes(s.disk_read_bps, &rb);
    const wr = utils.formatBytes(s.disk_write_bps, &wb);

    if (box.height >= 2) {
        const t = std.fmt.allocPrint(alloc, " rd {s}/s · wr {s}/s", .{ rd, wr }) catch return;
        _ = box.printSegment(.{ .text = t, .style = style.default_style }, .{
            .row_offset = 1,
            .col_offset = 0,
        });
    }

    if (box.height >= 3 and box.width >= 4) {
        renderSparklineU64(alloc, box, 1, box.height - 1, box.width - 2, &sys_history.disk_bps, style.title_style);
    }
}

fn drawNetBlock(alloc: std.mem.Allocator, win: Window, x: u16, y: u16, w: u16, h: u16, s: *const process.SystemSummary, sys_history: *const sample_mod.SystemHistory) void {
    const box = borderedBox(win, x, y, w, h);
    drawBorderTitle(win, x, y, " net ");
    if (box.height < 1) return;

    if (s.net_iface_name.len == 0) {
        _ = box.printSegment(.{ .text = " (no iface)", .style = style.dim_style }, .{
            .row_offset = 0,
            .col_offset = 0,
        });
        return;
    }

    const iface_line = if (s.net_ip.len > 0)
        std.fmt.allocPrint(alloc, " {s} · {s}", .{ s.net_iface_name, s.net_ip }) catch return
    else
        std.fmt.allocPrint(alloc, " {s}", .{s.net_iface_name}) catch return;
    const truncated_iface = truncOrPad(iface_line, box.width - 2);
    _ = box.printSegment(.{ .text = truncated_iface, .style = style.default_style }, .{
        .row_offset = 0,
        .col_offset = 0,
    });

    var rb: [16]u8 = undefined;
    var tb: [16]u8 = undefined;
    const rx = utils.formatBytes(s.net_rx_bps, &rb);
    const tx = utils.formatBytes(s.net_tx_bps, &tb);

    if (box.height >= 2) {
        const t = std.fmt.allocPrint(alloc, " ↓ {s}/s · ↑ {s}/s", .{ rx, tx }) catch return;
        _ = box.printSegment(.{ .text = t, .style = style.default_style }, .{
            .row_offset = 1,
            .col_offset = 0,
        });
    }

    if (box.height >= 3 and box.width >= 4) {
        renderSparklineU64(alloc, box, 1, box.height - 1, box.width - 2, &sys_history.net_bps, style.title_style);
    }
}

/// Render per-core bars htop/btop-style inside the CPU block. Packs cores
/// into as many columns as fit horizontally (1 col when only a few cores and
/// plenty of vertical room; 2+ cols when rows are scarce). Falls back to the
/// 1-char-per-core coloured grid if even the shortest per-core cell doesn't
/// fit horizontally.
pub const CpuLayout = struct {
    ncols: u16,
    cell_w: u16,
    bar_interior_w: u16,
    fallback_to_grid: bool,
};

pub fn computeCpuLayout(ncores: u16, avail_rows: u16, box_width: u16, min_cell_w: u16) CpuLayout {
    if (ncores == 0 or avail_rows == 0 or box_width == 0) {
        return .{
            .ncols = 1,
            .cell_w = 0,
            .bar_interior_w = 0,
            .fallback_to_grid = true,
        };
    }

    var ncols: u16 = 1;
    while (ncols < ncores) {
        const rows_needed = (ncores + ncols - 1) / ncols;
        if (rows_needed <= avail_rows) break;
        ncols += 1;
    }
    // Respect horizontal budget: drop columns until the cell fits min width.
    while (ncols > 1 and box_width / ncols < min_cell_w) : (ncols -= 1) {}

    const rows_needed = (ncores + ncols - 1) / ncols;
    if (box_width / ncols < min_cell_w or rows_needed > avail_rows) {
        return .{
            .ncols = ncols,
            .cell_w = box_width / ncols,
            .bar_interior_w = 0,
            .fallback_to_grid = true,
        };
    }

    const cell_w = box_width / ncols;
    const bar_interior_w = cell_w - min_cell_w + 1;
    return .{
        .ncols = ncols,
        .cell_w = cell_w,
        .bar_interior_w = bar_interior_w,
        .fallback_to_grid = false,
    };
}

/// Render per-core bars htop/btop-style inside the CPU block. Packs cores
/// into as many columns as fit horizontally (1 col when only a few cores and
/// plenty of vertical room; 2+ cols when rows are scarce). Falls back to the
/// 1-char-per-core coloured grid if even the shortest per-core cell doesn't
/// fit horizontally.
fn drawCpuCores(
    alloc: std.mem.Allocator,
    box: Window,
    per_cpu: []const f32,
    first_row: u16,
    last_row: u16,
) void {
    if (last_row < first_row) return;
    const avail_rows: u16 = last_row - first_row + 1;
    const ncores: u16 = @intCast(per_cpu.len);
    if (ncores == 0 or avail_rows == 0 or box.width == 0) return;

    // Per-core cell overhead: " cNN [" + bar_interior + "] NNN%" + 1 separator
    // Label 3, leading/brackets/spaces 5, pct 4, trailing separator 1 → 13 fixed.
    const min_cell_w: u16 = 13;

    const layout = computeCpuLayout(ncores, avail_rows, box.width, min_cell_w);

    if (layout.fallback_to_grid) {
        // Not enough room for labelled bars — fall back to the 1-char grid.
        drawCpuCoreGrid(box, per_cpu, first_row, last_row);
        return;
    }

    const cell_w = layout.cell_w;
    const bar_interior_w = layout.bar_interior_w;
    const ncols = layout.ncols;

    for (per_cpu, 0..) |core_pct, i| {
        const col: u16 = @intCast(i % ncols);
        const row_idx: u16 = @intCast(i / ncols);
        if (row_idx >= avail_rows) break;
        const x: u16 = col * cell_w + 1;
        const y: u16 = first_row + row_idx;

        // " cNN "
        const label = std.fmt.allocPrint(alloc, "c{d:0>2}", .{i}) catch continue;
        _ = box.printSegment(.{ .text = label, .style = style.dim_style }, .{
            .row_offset = y,
            .col_offset = x,
        });

        // Bar: width includes the [ ] brackets.
        const bar_w_total: u16 = bar_interior_w + 2;
        _ = drawBar(box, x + 4, y, bar_w_total, core_pct);

        // "NNN%"
        const pct_text = std.fmt.allocPrint(alloc, "{d:>3.0}%", .{core_pct}) catch continue;
        _ = box.printSegment(.{ .text = pct_text, .style = style.gradientStyle(core_pct) }, .{
            .row_offset = y,
            .col_offset = x + 4 + bar_w_total + 1,
        });
    }
}

/// Fallback: one coloured block char per core in a simple grid.
fn drawCpuCoreGrid(box: Window, per_cpu: []const f32, first_row: u16, last_row: u16) void {
    var row_off: u16 = first_row;
    var col_off: u16 = 1;
    for (per_cpu) |core_pct| {
        if (row_off > last_row) break;
        if (col_off >= box.width) {
            row_off += 1;
            col_off = 1;
            if (row_off > last_row) break;
        }
        box.writeCell(col_off, row_off, .{
            .char = .{ .grapheme = blockForPct(core_pct), .width = 1 },
            .style = style.gradientStyle(core_pct),
        });
        col_off += 1;
    }
}

fn formatUptimeShort(seconds: u64, buf: []u8) []const u8 {
    const days = seconds / (24 * 3600);
    const rem = seconds % (24 * 3600);
    const hours = rem / 3600;
    const mins = (rem % 3600) / 60;
    const secs = rem % 60;

    if (days > 0) {
        return std.fmt.bufPrint(buf, "{d}d {d}h", .{ days, hours }) catch buf[0..0];
    } else if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, mins }) catch buf[0..0];
    } else if (mins > 0) {
        return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch buf[0..0];
    }
}

fn drawSysBlock(
    alloc: std.mem.Allocator,
    win: Window,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    s: *const process.SystemSummary,
) void {
    const box = borderedBox(win, x, y, w, h);
    drawBorderTitle(win, x, y, " sys ");
    const inner_h = box.height;
    if (inner_h < 1) return;

    var row: u16 = 0;

    // Row 0: OS / Host
    if (row < inner_h) {
        _ = box.printSegment(.{ .text = " OS: ", .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        const val = if (s.os_name.len > 0 and s.host_model.len > 0)
            std.fmt.allocPrint(alloc, "{s} · {s}", .{ s.os_name, s.host_model }) catch "Linux"
        else if (s.os_name.len > 0)
            s.os_name
        else
            "Linux";
        const truncated = truncOrPad(val, box.width - 5);
        _ = box.printSegment(.{ .text = truncated, .style = style.default_style }, .{
            .row_offset = row,
            .col_offset = 5,
        });
        row += 1;
    }

    // Row 1: Kernel
    if (row < inner_h) {
        _ = box.printSegment(.{ .text = " Kernel: ", .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        const k_val = if (s.kernel_release.len > 0) s.kernel_release else "Unknown";
        const truncated_k = truncOrPad(k_val, box.width - 9);
        _ = box.printSegment(.{ .text = truncated_k, .style = style.default_style }, .{
            .row_offset = row,
            .col_offset = 9,
        });
        row += 1;
    }

    // Row 2: Uptime
    if (row < inner_h) {
        _ = box.printSegment(.{ .text = " Uptime: ", .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        var up_buf: [16]u8 = undefined;
        const raw_up_s = formatUptimeShort(s.uptime_seconds, &up_buf);
        const up_s = alloc.dupe(u8, raw_up_s) catch "";
        const truncated_up = truncOrPad(up_s, box.width - 9);
        _ = box.printSegment(.{ .text = truncated_up, .style = style.green_style }, .{
            .row_offset = row,
            .col_offset = 9,
        });
        row += 1;
    }

    // Row 3: CPU Model
    if (row < inner_h) {
        _ = box.printSegment(.{ .text = " CPU: ", .style = style.cpu_hot_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        const val = if (s.cpu_model.len > 0) s.cpu_model else "Unknown CPU";
        const truncated = truncOrPad(val, box.width - 6);
        _ = box.printSegment(.{ .text = truncated, .style = style.default_style }, .{
            .row_offset = row,
            .col_offset = 6,
        });
        row += 1;
    }

    // GPU rows: one per detected device (existence only).
    for (s.gpus) |gpu_name| {
        if (row >= inner_h) break;
        _ = box.printSegment(.{ .text = " GPU: ", .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        const truncated_g = truncOrPad(gpu_name, box.width - 6);
        _ = box.printSegment(.{ .text = truncated_g, .style = style.default_style }, .{
            .row_offset = row,
            .col_offset = 6,
        });
        row += 1;
    }

    // Load Average
    if (row < inner_h) {
        _ = box.printSegment(.{ .text = " Load: ", .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        const val = std.fmt.allocPrint(alloc, "{d:.2} {d:.2} {d:.2}", .{
            s.loadavg[0],
            s.loadavg[1],
            s.loadavg[2],
        }) catch "Unknown";
        const truncated = truncOrPad(val, box.width - 7);
        _ = box.printSegment(.{ .text = truncated, .style = style.default_style }, .{
            .row_offset = row,
            .col_offset = 7,
        });
        row += 1;
    }

    // Battery (last row)
    if (row < inner_h) {
        _ = box.printSegment(.{ .text = " Battery: ", .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = 0,
        });
        if (s.battery_pct) |pct| {
            const status_suffix = if (s.battery_status.len > 0)
                std.fmt.allocPrint(alloc, " [{s}]", .{s.battery_status}) catch ""
            else
                "";
            const val = std.fmt.allocPrint(alloc, "{d}%{s}", .{ pct, status_suffix }) catch "Unknown";
            const truncated = truncOrPad(val, box.width - 10);
            const bat_style = if (pct <= 20) style.error_style else style.green_style;
            _ = box.printSegment(.{ .text = truncated, .style = bat_style }, .{
                .row_offset = row,
                .col_offset = 10,
            });
        } else {
            _ = box.printSegment(.{ .text = "N/A", .style = style.dim_style }, .{
                .row_offset = row,
                .col_offset = 10,
            });
        }
        row += 1;
    }
}

fn drawCpuBlock(
    alloc: std.mem.Allocator,
    win: Window,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    s: *const process.SystemSummary,
    sys_history: *const sample_mod.SystemHistory,
    state: *const view_mod.ViewState,
    sys_drawn: bool,
) void {
    const box = borderedBox(win, x, y, w, h);
    if (box.width == 0 or box.height == 0) return;

    // Title carries live data: core count + aggregate CPU% + current max core
    // frequency + optional filter tag.
    var freq_buf: [16]u8 = undefined;
    const freq_s: []const u8 = if (s.cpu_freq_mhz == 0)
        ""
    else if (s.cpu_freq_mhz >= 1000)
        std.fmt.bufPrint(&freq_buf, " · {d:.2} GHz", .{@as(f32, @floatFromInt(s.cpu_freq_mhz)) / 1000.0}) catch ""
    else
        std.fmt.bufPrint(&freq_buf, " · {d} MHz", .{s.cpu_freq_mhz}) catch "";
    const title = if (state.filter.isActive()) blk: {
        break :blk std.fmt.allocPrint(alloc, " cpu — {d} cores, avg {d:.0}%{s} · filter {s}: {s} ", .{
            s.per_cpu.len,
            s.cpu_pct_total,
            freq_s,
            view_mod.filterFieldLabel(state.filter.field),
            state.filter.text(),
        }) catch " cpu ";
    } else std.fmt.allocPrint(alloc, " cpu — {d} cores, avg {d:.0}%{s} ", .{
        s.per_cpu.len,
        s.cpu_pct_total,
        freq_s,
    }) catch " cpu ";
    drawBorderTitle(win, x, y, title);

    _ = sys_history; // CPU per-core grid já carrega informação visual rica;
    // não duplicar com sparkline aqui.

    // Core rows: inner rows 0..grid_last inclusive (leaving the last inner row
    // for the loadavg+uptime footer if there's space for it).
    const has_footer = box.height >= 2 and !sys_drawn;
    const grid_last: u16 = if (has_footer) box.height -| 2 else box.height -| 1;

    if (box.width > 0 and s.per_cpu.len > 0) {
        drawCpuCores(alloc, box, s.per_cpu, 0, grid_last);
    }

    // Footer: loadavg on the left, " top-q vX.Y " on the right if it fits.
    if (!has_footer or sys_drawn) return;
    const footer_row: u16 = box.height - 1;

    var up_buf: [16]u8 = undefined;
    const up_s = utils.formatDuration(s.uptime_seconds, &up_buf);
    const load_text = std.fmt.allocPrint(alloc, " L {d:.2} {d:.2} {d:.2} · UP {s} ", .{
        s.loadavg[0], s.loadavg[1], s.loadavg[2], up_s,
    }) catch return;
    if (load_text.len <= box.width) {
        _ = box.printSegment(.{ .text = load_text, .style = style.dim_style }, .{
            .row_offset = footer_row,
            .col_offset = 0,
        });
    }
}

/// Draw a coloured progress bar of width `bar_w` at (col, row).
/// Returns the column right after the bar's closing bracket.
fn drawBar(win: Window, col: u16, row: u16, bar_w: u16, pct: f32) u16 {
    if (bar_w < 3) return col;
    win.writeCell(col, row, .{ .char = .{ .grapheme = "[", .width = 1 }, .style = style.dim_style });
    const inner_w: u16 = bar_w - 2;
    var clamped_pct = pct;
    if (clamped_pct < 0) clamped_pct = 0;
    if (clamped_pct > 100) clamped_pct = 100;
    var filled: u16 = @intFromFloat(@as(f32, @floatFromInt(inner_w)) * (clamped_pct / 100.0));
    // Round-up: if there's any usage at all, show at least one filled cell so
    // small percentages don't look like "empty".
    if (filled == 0 and clamped_pct > 0) filled = 1;
    if (filled > inner_w) filled = inner_w;
    var i: u16 = 0;
    while (i < inner_w) : (i += 1) {
        if (i < filled) {
            win.writeCell(col + 1 + i, row, .{
                .char = .{ .grapheme = BAR_FILLED, .width = 1 },
                .style = style.gradientStyle(pct),
            });
        } else {
            win.writeCell(col + 1 + i, row, .{
                .char = .{ .grapheme = BAR_EMPTY, .width = 1 },
                .style = style.dim_style,
            });
        }
    }
    win.writeCell(col + bar_w - 1, row, .{ .char = .{ .grapheme = "]", .width = 1 }, .style = style.dim_style });
    return col + bar_w;
}

fn drawColumnHeader(alloc: std.mem.Allocator, win: Window, w: u16, row: u16, state: *const view_mod.ViewState, no_color: bool) void {
    const base: vaxis.Style = if (no_color) .{ .bold = true } else style.header_style;
    const active: vaxis.Style = if (no_color) .{ .bold = true } else style.active_col_style;

    for (0..w) |x| {
        win.writeCell(@intCast(x), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = base,
        });
    }

    const arrow: []const u8 = switch (state.sort_dir) {
        .desc => "↓",
        .asc => "↑",
    };

    // Mark active column with the sort arrow appended to its label.
    const ColInfo = struct { off: u16, label: []const u8, key: view_mod.SortKey };
    const cols = [_]ColInfo{
        .{ .off = 0, .label = "    PID", .key = .pid },
        .{ .off = 8, .label = "USER", .key = .user },
        .{ .off = 19, .label = "S", .key = .cpu }, // S column has no sort, treat as cpu sentinel (skipped below)
        .{ .off = 21, .label = "  CPU%", .key = .cpu },
        .{ .off = 28, .label = "  MEM%", .key = .mem },
        .{ .off = 35, .label = "COMMAND", .key = .name },
    };

    inline for (cols, 0..) |col, idx| {
        if (col.off >= w) break;
        const is_state_col = idx == 2;
        const is_active = !is_state_col and col.key == state.sort_key;
        const label_text = if (is_active)
            std.fmt.allocPrint(alloc, "{s}{s}", .{ col.label, arrow }) catch col.label
        else
            col.label;
        const s = if (is_active) active else base;
        _ = win.printSegment(.{ .text = label_text, .style = s }, .{
            .row_offset = row,
            .col_offset = col.off,
        });
    }
}

fn pickRowStyle(p: *const process.Process, no_color: bool) vaxis.Style {
    if (no_color) return .{};
    if (p.state == .zombie) return style.state_zombie_style;
    if (p.cpu_pct >= 50.0) return style.cpu_hot_style;
    if (p.cpu_pct >= 10.0) return style.cpu_warm_style;
    return style.default_style;
}

fn drawList(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    h: u16,
    first_row: u16,
    table: *const process.ProcessTable,
    procs_sorted: []const usize,
    state: *const view_mod.ViewState,
    summary: *const process.SystemSummary,
    no_color: bool,
) void {
    if (first_row >= h) return;
    const list_h: u16 = h - first_row;
    const total = procs_sorted.len;

    var row: usize = 0;
    var idx = state.scroll_top;
    while (row < list_h and idx < total) : ({
        row += 1;
        idx += 1;
    }) {
        const real_idx = procs_sorted[idx];
        if (real_idx >= table.procs.items.len) continue;
        const p = &table.procs.items[real_idx];
        const display_row: u16 = @intCast(row + first_row);

        var line_style = pickRowStyle(p, no_color);
        const is_selected = state.selected_pid == p.pid;
        if (is_selected) {
            if (no_color) {
                line_style.reverse = true;
                line_style.bold = true;
            } else {
                line_style.bg = style.selected_bg_style.bg;
                line_style.bold = true;
            }
        }

        // Fill background
        for (0..w) |x| {
            win.writeCell(@intCast(x), display_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = line_style,
            });
        }

        const mem_pct: f32 = if (summary.mem_total_bytes > 0)
            @floatCast(100.0 * @as(f64, @floatFromInt(p.mem_rss_bytes)) / @as(f64, @floatFromInt(summary.mem_total_bytes)))
        else
            0;

        // Render row text
        const max_cmd: usize = if (w > 35) @as(usize, w) - 35 else 0;
        var truncated_comm: []const u8 = p.comm;
        if (truncated_comm.len > max_cmd) truncated_comm = truncated_comm[0..max_cmd];

        const state_char = [_]u8{p.state.char()};
        const text = std.fmt.allocPrint(alloc, "{d:>7} {s:<10} {s:<1} {d:>5.1} {d:>5.1} {s}", .{
            p.pid,
            truncOrPad(p.user, 10),
            &state_char,
            p.cpu_pct,
            mem_pct,
            truncated_comm,
        }) catch continue;

        _ = win.printSegment(.{ .text = text, .style = line_style }, .{
            .row_offset = display_row,
            .col_offset = 0,
        });

        if (is_selected) {
            var ptr_style = if (no_color) line_style else style.title_style;
            if (!no_color) {
                ptr_style.bg = style.selected_bg_style.bg;
            }
            _ = win.printSegment(.{ .text = "❯", .style = ptr_style }, .{
                .row_offset = display_row,
                .col_offset = 0,
            });
        }
    }
}

fn truncOrPad(s: []const u8, n: usize) []const u8 {
    if (s.len > n) return s[0..n];
    return s;
}

fn drawStatusBar(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    h: u16,
    table: *const process.ProcessTable,
    procs_sorted: []const usize,
    state: *const view_mod.ViewState,
) void {
    if (h < 2) return;
    const row: u16 = h - 1;
    for (0..w) |x| {
        win.writeCell(@intCast(x), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style.status_style,
        });
    }

    // Version tag pinned to the right edge of the status bar. Drawn first so
    // left-side content prints on top when the bar is narrow.
    const ver = std.fmt.allocPrint(alloc, " {s} v{s} ", .{ build_options.app_name, build_options.version }) catch "";
    if (ver.len > 0 and ver.len <= w) {
        const c: u16 = @intCast(w - ver.len);
        _ = win.printSegment(.{ .text = ver, .style = style.status_key_style }, .{
            .row_offset = row,
            .col_offset = c,
        });
    }

    if (state.mode == .filter_input) {
        const text = std.fmt.allocPrint(alloc, " filter [{s}]: {s}_  Tab field · Enter ok · Esc cancel ", .{
            view_mod.filterFieldLabel(state.filter.field),
            state.filter.text(),
        }) catch return;
        _ = win.printSegment(.{ .text = text, .style = style.status_style }, .{ .row_offset = row, .col_offset = 0 });
        return;
    }

    // Transient flash takes precedence over the regular status text
    if (state.flash_len > 0) {
        const flash = std.fmt.allocPrint(alloc, " {s} ", .{state.flashText()}) catch return;
        _ = win.printSegment(.{ .text = flash, .style = style.status_style }, .{ .row_offset = row, .col_offset = 0 });
        return;
    }

    // Lazygit-style key hints: vivid `key` glyph + dim action label, separated
    // by `·`. Caller widths permitting, fits everything before the version tag.
    const KeyHint = struct { key: []const u8, action: []const u8 };
    const hints = [_]KeyHint{
        .{ .key = "j/k", .action = " move" },
        .{ .key = "Enter", .action = " open" },
        .{ .key = "s", .action = " sort" },
        .{ .key = "/", .action = " filter" },
        .{ .key = "K", .action = " kill" },
        .{ .key = "F1", .action = " help" },
        .{ .key = "q", .action = " quit" },
    };

    const right_reserve: u16 = @intCast(ver.len);
    var col: u16 = 1;
    for (hints, 0..) |hint, idx| {
        const sep_w: u16 = if (idx == 0) 0 else 3;
        const need: u16 = @as(u16, @intCast(hint.key.len + hint.action.len)) + sep_w;
        if (col + need + right_reserve > w) break;
        if (sep_w > 0) {
            _ = win.printSegment(.{ .text = " · ", .style = style.status_style }, .{ .row_offset = row, .col_offset = col });
            col += sep_w;
        }
        _ = win.printSegment(.{ .text = hint.key, .style = style.status_key_style }, .{ .row_offset = row, .col_offset = col });
        col += @intCast(hint.key.len);
        _ = win.printSegment(.{ .text = hint.action, .style = style.status_style }, .{ .row_offset = row, .col_offset = col });
        col += @intCast(hint.action.len);
    }

    // Procs count + active sort, painted just before the version tag if it fits.
    const arrow: []const u8 = switch (state.sort_dir) {
        .desc => "↓",
        .asc => "↑",
    };
    const right_text = if (procs_sorted.len != table.count()) blk: {
        break :blk std.fmt.allocPrint(alloc, " {d}/{d} procs · sort {s}{s} ", .{
            procs_sorted.len,
            table.count(),
            view_mod.sortKeyLabel(state.sort_key),
            arrow,
        }) catch return;
    } else std.fmt.allocPrint(alloc, " {d} procs · sort {s}{s} ", .{
        table.count(),
        view_mod.sortKeyLabel(state.sort_key),
        arrow,
    }) catch return;
    if (right_text.len + ver.len <= w and col + right_text.len + ver.len <= w) {
        const c: u16 = @intCast(w - ver.len - right_text.len);
        _ = win.printSegment(.{ .text = right_text, .style = style.status_style }, .{
            .row_offset = row,
            .col_offset = c,
        });
    }
}

const help_lines = [_][]const u8{
    "          top-q — keymap",
    "",
    "  NAVIGATION",
    "    ↓ / j        Move down",
    "    ↑ / k        Move up",
    "    PgDn / C-d   Page down",
    "    PgUp / C-u   Page up",
    "    g / Home     Top",
    "    G / End      Bottom",
    "",
    "  ACTIONS",
    "    Enter / d    Open detail",
    "    Tab          (in detail) cycle panel",
    "    Esc / d / q  (in detail) close",
    "",
    "  SORT & FILTER",
    "    s            Cycle sort column",
    "    r            Reverse sort direction",
    "    /            Open filter input",
    "    \\           Clear active filter",
    "",
    "  TOP PANELS",
    "    n            Cycle network interface",
    "    D            Cycle disk mountpoint",
    "",
    "  SIGNALS",
    "    K            Send signal (TERM default)",
    "                 [y] confirm · [Tab] cycle signal",
    "",
    "  GENERAL",
    "    F1           This help",
    "    q / C-c      Quit",
    "",
    "          press any key to close",
};

fn drawSignalConfirm(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    h: u16,
    table: *const process.ProcessTable,
    state: *const view_mod.ViewState,
) void {
    const pid = state.selected_pid orelse return;
    const p = table.lookup(pid);
    const comm: []const u8 = if (p) |pp| pp.comm else "?";
    const sig = state.pending_signal;

    const popup_w: u16 = @intCast(@min(60, w -| 4));
    const popup_h: u16 = 5;
    if (popup_w < 30 or h < popup_h + 4) return;

    const x_off: i17 = @intCast((w - popup_w) / 2);
    const y_off: i17 = @intCast((h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{ .where = .all, .glyphs = .single_rounded, .style = style.help_border_style },
    });
    popup.clear();

    const line1 = std.fmt.allocPrint(alloc, " Send SIG{s} to PID {d} ({s}) ?", .{ sig.name(), pid, comm }) catch return;
    _ = popup.printSegment(.{ .text = line1, .style = style.title_style }, .{ .row_offset = 0, .col_offset = 1 });

    const line2 = " [y] confirm · [Tab] cycle signal · any other key cancel";
    _ = popup.printSegment(.{ .text = line2, .style = style.default_style }, .{ .row_offset = 2, .col_offset = 1 });
}

fn drawHelp(win: Window, w: u16, h: u16) void {
    const popup_w: u16 = @intCast(@min(55, w -| 4));
    const popup_h: u16 = @intCast(@min(help_lines.len + 2, h -| 4));
    if (popup_w < 30 or popup_h < 6) return;
    const x_off: i17 = @intCast((w - popup_w) / 2);
    const y_off: i17 = @intCast((h - popup_h) / 2);

    const popup = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = popup_w,
        .height = popup_h,
        .border = .{ .where = .all, .glyphs = .single_rounded, .style = style.help_border_style },
    });
    popup.clear();

    for (help_lines, 0..) |line, i| {
        if (i >= popup_h -| 2) break;
        const row: u16 = @intCast(i);
        const s: vaxis.Style = if (line.len > 0 and line[0] != ' ') style.title_style else style.default_style;
        _ = popup.printSegment(.{ .text = line, .style = s }, .{ .row_offset = row, .col_offset = 0 });
    }
}
