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

pub const PerfStats = struct {
    apply_us: u64 = 0,
    draw_us: u64 = 0,
    tty_us: u64 = 0,
    tty_bytes: u64 = 0,
    refresh_gap_us: u64 = 0,
};

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
pub const NET_MAX_W: u16 = 32;

/// Fixed sys-block content rows: OS, Kernel, Uptime, CPU, Load, Battery.
/// GPUs add one row each on top of these.
pub const SYS_FIXED_ROWS: u16 = 6;

pub const TopLayoutHeights = struct { row1: u16, row2: u16, total: u16 };

pub fn topLayoutHeights(h: u16, w: u16, ncores: u16, ngpus: u16) TopLayoutHeights {
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
    perf: ?PerfStats,
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
    drawStatusBar(alloc, win, w, h, table, procs_sorted, state, no_color, perf);

    if (state.mode == .help) {
        drawHelp(win, w, h, state.help_scroll);
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

    // Row 1: sys, mem, disk, net — mem/disk carry the longer "used/total ·
    // avail" rows, so they get extra width at the expense of sys/net.
    const n_blocks: u16 = if (w < 115) 2 else if (w < 150) 3 else 4;
    const base_w = w / n_blocks;
    const delta: u16 = base_w / 5;

    // 1. sys block (shrunk)
    const sys_w = base_w -| delta;
    drawSysBlock(alloc, win, 0, 0, sys_w, heights.row1, s);
    var x = sys_w;

    // 2. mem block (widened)
    const mem_w = if (n_blocks == 2) w - x else base_w + delta;
    drawMemBlock(alloc, win, x, 0, mem_w, heights.row1, s, sys_history);
    x += mem_w;

    // 3. disk block (widened; when 4 blocks are visible, absorbs surplus above NET_MAX_W)
    if (n_blocks >= 3) {
        const net_w: u16 = if (n_blocks >= 4) @min(base_w -| delta, NET_MAX_W) else 0;
        const disk_w = w - x - net_w;
        drawDiskBlock(alloc, win, x, 0, disk_w, heights.row1, s, sys_history);
        x += disk_w;
    }

    // 4. net block (capped so disk's duf-style table gets the extra width)
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
    /// Invert color scale (green when high, red when low) for availability metrics.
    invert_color: bool = false,
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
            _ = box.printSegment(.{ .text = r.abs, .style = style.default_style }, .{
                .row_offset = @intCast(i),
                .col_offset = label_w,
            });
        }
        if (bar_w >= 3) {
            _ = drawBar(box, bar_col, @intCast(i), bar_w, r.pct, r.invert_color);
        }
    }
}

fn pctOf(used: u64, total: u64) f32 {
    if (total == 0) return 0;
    return @floatCast(100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total)));
}

/// Denominator for disk percentages, same as df: used + avail. Blocks reserved
/// for root are neither, so dividing by total would leave Used% + Avail% short
/// of 100% (~5% on ext4) and Used% below what df reports.
fn diskPctBase(d: process.DiskMount) u64 {
    return d.used_bytes + d.avail_bytes;
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
    const avail_pct = pctOf(s.mem_available_bytes, s.mem_total_bytes);
    const swap_pct = pctOf(s.swap_used_bytes, s.swap_total_bytes);

    const rows = [_]LabelledRow{
        .{ .label = " Used:", .pct = used_pct, .abs = absUsedTotal(alloc, s.mem_used_bytes, s.mem_total_bytes) },
        .{ .label = "Avail:", .pct = avail_pct, .abs = absUsedTotal(alloc, s.mem_available_bytes, s.mem_total_bytes), .invert_color = true },
        .{ .label = "Cache:", .pct = cache_pct, .abs = absUsedTotal(alloc, s.mem_cache_bytes, s.mem_total_bytes) },
        .{ .label = " Swap:", .pct = swap_pct, .abs = absUsedTotal(alloc, s.swap_used_bytes, s.swap_total_bytes) },
    };
    drawLabelledBars(alloc, box, &rows);

    // Sparkline of mem% history at the row below the labelled bars (if any).
    if (box.height >= 4 and box.width >= 4) {
        renderSparklineF32(alloc, box, 1, box.height - 1, box.width - 2, &sys_history.mem_pct, 100.0, style.gradientStyle(used_pct));
    }

    // If swap is absent, overwrite the swap bar with " (none)" after the label
    // so users can tell the 0% isn't usage but unavailability.
    if (s.swap_total_bytes == 0 and box.height >= 4) {
        const swap_row: u16 = 3; // Used=0, Cache=1, Avail=2, Swap=3
        const text = " Swap      (none)";
        if (text.len <= box.width) {
            // Clear the bar portion by printing spaces then the "(none)" marker.
            for (0..box.width) |col| {
                box.writeCell(@intCast(col), swap_row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = style.default_style,
                });
            }
            _ = box.printSegment(.{ .text = text, .style = style.default_style }, .{
                .row_offset = swap_row,
                .col_offset = 0,
            });
        }
    }
}

const DISK_NUM_W: u16 = 7; // fits formatBytes outputs like "1022.0M", "887.6G"
const DISK_PCT_W: u16 = 6; // "100.0%"
const DISK_TYPE_W: u16 = 5; // "ext4 ", "vfat ", "btrfs"

const DiskTableLayout = struct {
    mount_col: u16,
    mount_w: u16,
    size_col: ?u16 = null,
    used_col: ?u16 = null,
    avail_col: ?u16 = null,
    bar_col: ?u16 = null,
    bar_w: u16 = 0,
    pct_col: u16,
    type_col: ?u16 = null,
};

fn computeDiskTableLayout(inner_w: u16, disks: []const process.DiskMount) DiskTableLayout {
    // Desired mount column width: wide enough for "MOUNT" (5) and actual paths, capped at 16.
    var max_mount: u16 = 5;
    for (disks) |d| {
        const len: u16 = @intCast(@min(d.mount_path.len, 16));
        if (len > max_mount) max_mount = len;
    }

    // Usable width excludes 1-col left/right padding inside the box.
    const usable: u16 = inner_w -| 2;
    const mount_col: u16 = 1;

    // Helper: try fitting a combination of optional columns with a minimum bar width.
    // Returns null if it does not fit in `usable`.
    const Tier = struct {
        size: bool,
        used: bool,
        avail: bool,
        min_bar: u16,
        fs_type: bool,
    };
    const tiers = [_]Tier{
        .{ .size = true, .used = true, .avail = true, .min_bar = 8, .fs_type = true },
        .{ .size = true, .used = true, .avail = true, .min_bar = 6, .fs_type = false },
        .{ .size = false, .used = true, .avail = true, .min_bar = 5, .fs_type = false },
        .{ .size = false, .used = false, .avail = true, .min_bar = 4, .fs_type = false },
        .{ .size = false, .used = false, .avail = true, .min_bar = 0, .fs_type = false },
    };

    for (tiers) |t| {
        var fixed: u16 = DISK_PCT_W; // always present
        if (t.size) fixed += 1 + DISK_NUM_W;
        if (t.used) fixed += 1 + DISK_NUM_W;
        if (t.avail) fixed += 1 + DISK_NUM_W;
        if (t.min_bar > 0) fixed += 2 + t.min_bar + 1; // 2-col gap before bar, 1-col gap before pct
        if (t.min_bar == 0) fixed += 1; // 1-col gap before pct
        if (t.fs_type) fixed += 1 + DISK_TYPE_W;

        const mount_w: u16 = if (usable >= fixed + max_mount)
            max_mount
        else if (usable >= fixed + 5)
            usable - fixed
        else
            continue;

        const extra: u16 = usable - (fixed + mount_w);
        var cur: u16 = mount_col + mount_w;
        var out: DiskTableLayout = .{
            .mount_col = mount_col,
            .mount_w = mount_w,
            .pct_col = 0,
        };
        if (t.size) {
            cur += 1;
            out.size_col = cur;
            cur += DISK_NUM_W;
        }
        if (t.used) {
            cur += 1;
            out.used_col = cur;
            cur += DISK_NUM_W;
        }
        if (t.avail) {
            cur += 1;
            out.avail_col = cur;
            cur += DISK_NUM_W;
        }
        if (t.min_bar > 0) {
            cur += 2;
            out.bar_col = cur;
            out.bar_w = t.min_bar + extra;
            cur += out.bar_w + 1;
        } else {
            cur += 1;
        }
        out.pct_col = cur;
        cur += DISK_PCT_W;
        if (t.fs_type) {
            cur += 1;
            out.type_col = cur;
        }
        return out;
    }

    // Extreme fallback for tiny boxes: MOUNT + USE%.
    const pct_col: u16 = if (inner_w > DISK_PCT_W + 1) inner_w - 1 - DISK_PCT_W else 1;
    const mount_w: u16 = if (pct_col > mount_col + 1) pct_col - mount_col - 1 else 1;
    return .{
        .mount_col = mount_col,
        .mount_w = mount_w,
        .pct_col = pct_col,
    };
}

/// Bracketless duf-style progress bar: filled `█` in usage gradient + `░` track.
fn drawDiskBar(win: Window, col: u16, row: u16, bar_w: u16, pct: f32) void {
    if (bar_w == 0) return;
    const clamped: f32 = std.math.clamp(pct, 0.0, 100.0);
    var filled: u16 = @intFromFloat(@as(f32, @floatFromInt(bar_w)) * (clamped / 100.0));
    if (filled == 0 and clamped > 0) filled = 1;
    if (filled > bar_w) filled = bar_w;
    const bar_style = style.gradientStyle(pct);
    var i: u16 = 0;
    while (i < bar_w) : (i += 1) {
        win.writeCell(col + i, row, .{
            .char = .{ .grapheme = if (i < filled) BAR_FILLED else BAR_EMPTY, .width = 1 },
            .style = if (i < filled) bar_style else style.dim_style,
        });
    }
}

fn drawDiskBlock(alloc: std.mem.Allocator, win: Window, x: u16, y: u16, w: u16, h: u16, s: *const process.SystemSummary, sys_history: *const sample_mod.SystemHistory) void {
    const box = borderedBox(win, x, y, w, h);
    if (box.height < 1) return;

    const disks = if (s.disks.len > 0) s.disks else if (s.fs_root_total_bytes > 0) &[_]process.DiskMount{.{
        .mount_path = s.fs_mount_path,
        .fs_type_name = s.fs_type_name,
        .used_bytes = s.fs_root_used_bytes,
        .total_bytes = s.fs_root_total_bytes,
        .avail_bytes = s.fs_root_avail_bytes,
    }} else &.{};

    const layout = computeDiskTableLayout(box.width, disks);

    // Show fs type in the border title only when the TYPE column isn't shown
    // and every visible disk shares the same type.
    var single_fs_type = s.fs_type_name.len > 0 and layout.type_col == null;
    if (single_fs_type and disks.len > 1) {
        for (disks[1..]) |d| {
            if (!std.mem.eql(u8, d.fs_type_name, disks[0].fs_type_name)) {
                single_fs_type = false;
                break;
            }
        }
    }
    const disk_title = if (single_fs_type)
        std.fmt.allocPrint(alloc, " disk · {s} ", .{s.fs_type_name}) catch " disk "
    else
        " disk ";
    drawBorderTitle(win, x, y, disk_title);

    const has_sparkline = (box.height >= 3 and box.width >= 4);
    const has_throughput = (box.height >= 3);
    const sparkline_row: ?u16 = if (has_sparkline) box.height - 1 else null;
    const throughput_row: ?u16 = if (has_throughput) (if (has_sparkline) box.height - 2 else box.height - 1) else null;
    const table_budget: u16 = if (throughput_row) |tr| tr else box.height;

    if (disks.len > 0 and table_budget > 0 and box.width >= 10) {
        var row: u16 = 0;
        const show_header = table_budget >= 2;
        if (show_header) {
            const hdr_mount = if (layout.mount_w >= 5) "MOUNT" else "MNT"[0..@min(@as(usize, 3), layout.mount_w)];
            _ = box.printSegment(.{ .text = hdr_mount, .style = style.dim_style }, .{
                .row_offset = 0,
                .col_offset = layout.mount_col,
            });
            if (layout.size_col) |c| {
                _ = box.printSegment(.{ .text = "   SIZE", .style = style.dim_style }, .{
                    .row_offset = 0,
                    .col_offset = c,
                });
            }
            if (layout.used_col) |c| {
                _ = box.printSegment(.{ .text = "   USED", .style = style.dim_style }, .{
                    .row_offset = 0,
                    .col_offset = c,
                });
            }
            if (layout.avail_col) |c| {
                _ = box.printSegment(.{ .text = "  AVAIL", .style = style.dim_style }, .{
                    .row_offset = 0,
                    .col_offset = c,
                });
            }
            const use_hdr_col = if (layout.bar_col) |bc| bc else layout.pct_col;
            _ = box.printSegment(.{ .text = "USE%", .style = style.dim_style }, .{
                .row_offset = 0,
                .col_offset = use_hdr_col,
            });
            if (layout.type_col) |c| {
                _ = box.printSegment(.{ .text = "TYPE", .style = style.dim_style }, .{
                    .row_offset = 0,
                    .col_offset = c,
                });
            }
            row = 1;
        }

        const max_disk_rows: usize = table_budget - row;
        var start_idx: usize = 0;
        if (disks.len > max_disk_rows) {
            for (disks, 0..) |d, i| {
                if (std.mem.eql(u8, d.mount_path, s.fs_mount_path)) {
                    start_idx = i;
                    break;
                }
            }
        }

        const visible_n: usize = @min(disks.len, max_disk_rows);
        var count: usize = 0;
        while (count < visible_n) : (count += 1) {
            const d = disks[(start_idx + count) % disks.len];
            const base = diskPctBase(d);
            const used_pct = pctOf(d.used_bytes, base);
            const avail_pct = pctOf(d.avail_bytes, base);

            const mlabel = if (d.mount_path.len <= layout.mount_w)
                d.mount_path
            else
                d.mount_path[d.mount_path.len - layout.mount_w ..];
            _ = box.printSegment(.{ .text = mlabel, .style = style.cyan_style }, .{
                .row_offset = row,
                .col_offset = layout.mount_col,
            });

            if (layout.size_col) |c| {
                var sb: [16]u8 = undefined;
                const s_txt = std.fmt.allocPrint(alloc, "{s:>7}", .{utils.formatBytes(d.total_bytes, &sb)}) catch "";
                _ = box.printSegment(.{ .text = s_txt, .style = style.default_style }, .{
                    .row_offset = row,
                    .col_offset = c,
                });
            }
            if (layout.used_col) |c| {
                var ub: [16]u8 = undefined;
                const u_txt = std.fmt.allocPrint(alloc, "{s:>7}", .{utils.formatBytes(d.used_bytes, &ub)}) catch "";
                _ = box.printSegment(.{ .text = u_txt, .style = style.default_style }, .{
                    .row_offset = row,
                    .col_offset = c,
                });
            }
            if (layout.avail_col) |c| {
                var ab: [16]u8 = undefined;
                const a_txt = std.fmt.allocPrint(alloc, "{s:>7}", .{utils.formatBytes(d.avail_bytes, &ab)}) catch "";
                _ = box.printSegment(.{ .text = a_txt, .style = style.gradientInverseStyle(avail_pct) }, .{
                    .row_offset = row,
                    .col_offset = c,
                });
            }
            if (layout.bar_col) |c| {
                drawDiskBar(box, c, row, layout.bar_w, used_pct);
            }

            const pct_txt = std.fmt.allocPrint(alloc, "{d:>5.1}%", .{used_pct}) catch "";
            _ = box.printSegment(.{ .text = pct_txt, .style = style.default_style }, .{
                .row_offset = row,
                .col_offset = layout.pct_col,
            });

            if (layout.type_col) |c| {
                const tname = if (d.fs_type_name.len <= DISK_TYPE_W) d.fs_type_name else d.fs_type_name[0..DISK_TYPE_W];
                _ = box.printSegment(.{ .text = tname, .style = style.dim_style }, .{
                    .row_offset = row,
                    .col_offset = c,
                });
            }

            row += 1;
        }
    }

    // Throughput lines below the table.
    var rb: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    const rd = utils.formatBytes(s.disk_read_bps, &rb);
    const wr = utils.formatBytes(s.disk_write_bps, &wb);

    if (throughput_row) |tr| {
        const t = std.fmt.allocPrint(alloc, " rd {s}/s · wr {s}/s", .{ rd, wr }) catch return;
        _ = box.printSegment(.{ .text = t, .style = style.default_style }, .{
            .row_offset = tr,
            .col_offset = 0,
        });
    }

    if (sparkline_row) |sr| {
        renderSparklineU64(alloc, box, 1, sr, box.width - 2, &sys_history.disk_bps, style.title_style);
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

    // Per-core cell layout: " cNN NNN% [" + bar_interior + "]" + 1 separator.
    // Its fixed width is unchanged when moving the percentage before the bar.
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

        // "NNN%"
        const pct_text = std.fmt.allocPrint(alloc, "{d:>3.0}%", .{core_pct}) catch continue;
        _ = box.printSegment(.{ .text = pct_text, .style = style.gradientStyle(core_pct) }, .{
            .row_offset = y,
            .col_offset = x + 4,
        });

        // Bar: width includes the [ ] brackets.
        const bar_w_total: u16 = bar_interior_w + 2;
        _ = drawBar(box, x + 9, y, bar_w_total, core_pct, false);
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
    const sys_title = if (s.hostname.len > 0)
        std.fmt.allocPrint(alloc, " sys · {s} ", .{s.hostname}) catch " sys "
    else
        " sys ";
    drawBorderTitle(win, x, y, sys_title);
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
fn drawBar(win: Window, col: u16, row: u16, bar_w: u16, pct: f32, invert_color: bool) u16 {
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
    const bar_style = if (invert_color) style.gradientInverseStyle(pct) else style.gradientStyle(pct);
    var i: u16 = 0;
    while (i < inner_w) : (i += 1) {
        if (i < filled) {
            win.writeCell(col + 1 + i, row, .{
                .char = .{ .grapheme = BAR_FILLED, .width = 1 },
                .style = bar_style,
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
        var truncated_cmd: []const u8 = p.cmdline;
        if (truncated_cmd.len > max_cmd) truncated_cmd = truncated_cmd[0..max_cmd];

        const state_char = [_]u8{p.state.char()};
        const text = std.fmt.allocPrint(alloc, "{d:>7} {s:<10} {s:<1} {d:>5.1} {d:>5.1} {s}", .{
            p.pid,
            truncOrPad(p.user, 10),
            &state_char,
            p.cpu_pct,
            mem_pct,
            truncated_cmd,
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
    no_color: bool,
    perf: ?PerfStats,
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
        const prefix = std.fmt.allocPrint(alloc, " filter [{s}]: ", .{
            view_mod.filterFieldLabel(state.filter.field),
        }) catch return;
        drawPromptBar(
            alloc,
            win,
            w,
            row,
            prefix,
            state.filter.text(),
            "  Tab field · Enter ok · Esc cancel ",
            if (no_color) style.mono_mode_style else style.filter_mode_style,
        );
        return;
    }

    if (state.mode == .search_input) {
        const suffix: []const u8 = if (state.search_no_match)
            "  no match  ·  F3 next · S-F3 prev · Enter ok · Esc cancel "
        else
            "  F3 next · S-F3 prev · Enter ok · Esc cancel ";
        drawPromptBar(
            alloc,
            win,
            w,
            row,
            " search: ",
            state.search.text(),
            suffix,
            if (no_color) style.mono_mode_style else style.search_mode_style,
        );
        return;
    }

    // Transient flash takes precedence over the regular status text
    if (state.flash_len > 0) {
        const flash = std.fmt.allocPrint(alloc, " {s} ", .{state.flashText()}) catch return;
        _ = win.printSegment(.{ .text = flash, .style = style.status_style }, .{ .row_offset = row, .col_offset = 0 });
        return;
    }

    if (perf) |p| {
        const text = std.fmt.allocPrint(
            alloc,
            " PERF gap {d:.1}ms · proc {d:.1} (dir {d:.1} read {d:.1}/{d}w merge {d:.1}) · summary {d:.1} · apply {d:.1} · draw {d:.1} · tty {d:.1}/{d}B · {d} procs ",
            .{
                usToMs(p.refresh_gap_us),
                usToMs(table.collect_total_us),
                usToMs(table.collect_dir_us),
                usToMs(table.collect_read_us),
                table.collect_readers,
                usToMs(table.collect_merge_us),
                usToMs(table.collect_summary_us),
                usToMs(p.apply_us),
                usToMs(p.draw_us),
                usToMs(p.tty_us),
                p.tty_bytes,
                table.count(),
            },
        ) catch return;
        const available: usize = if (@as(usize, w) > ver.len) @as(usize, w) - ver.len else 0;
        const shown = text[0..@min(text.len, available)];
        _ = win.printSegment(.{ .text = shown, .style = style.status_style }, .{ .row_offset = row, .col_offset = 0 });
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
        .{ .key = "F3", .action = " search" },
        .{ .key = "K", .action = " kill" },
        .{ .key = "t", .action = " theme" },
        .{ .key = "F1", .action = " help" },
        .{ .key = "q", .action = " quit" },
    };

    const right_reserve: u16 = @intCast(ver.len);
    var col: u16 = 1;

    // A confirmed filter or search keeps governing the list (and F3) after its
    // prompt closes. Without a chip here that state is invisible.
    const chip_filter = if (no_color) style.mono_mode_style else style.filter_chip_style;
    const chip_search = if (no_color) style.mono_mode_style else style.search_chip_style;

    if (state.filter.isActive()) {
        const chip = std.fmt.allocPrint(alloc, " filter[{s}]:{s} ", .{
            view_mod.filterFieldLabel(state.filter.field),
            state.filter.text(),
        }) catch "";
        if (chip.len > 0) col = drawStatusChip(win, row, col, w, chip, chip_filter) + 1;
    }
    if (state.search.isActive()) {
        const ms = view_mod.matchStats(table.procs.items, procs_sorted, state.search.text(), state.selected_pid);
        const chip = if (ms.total == 0)
            std.fmt.allocPrint(alloc, " search:{s} no match ", .{state.search.text()}) catch ""
        else if (ms.pos == 0)
            std.fmt.allocPrint(alloc, " search:{s} -/{d} ", .{ state.search.text(), ms.total }) catch ""
        else
            std.fmt.allocPrint(alloc, " search:{s} {d}/{d} ", .{ state.search.text(), ms.pos, ms.total }) catch "";
        if (chip.len > 0) col = drawStatusChip(win, row, col, w, chip, chip_search) + 1;
    }

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

fn usToMs(us: u64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

/// Repaint the whole status bar in `bar_style` and park the terminal cursor
/// right after the typed text. A real blinking cursor is the convention every
/// user already knows for "this is a text field"; a literal `_` is not.
fn drawPromptBar(
    alloc: std.mem.Allocator,
    win: Window,
    w: u16,
    row: u16,
    prefix: []const u8,
    typed: []const u8,
    suffix: []const u8,
    bar_style: vaxis.Style,
) void {
    for (0..w) |x| {
        win.writeCell(@intCast(x), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = bar_style,
        });
    }

    const text = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, typed, suffix }) catch return;
    _ = win.printSegment(.{ .text = text, .style = bar_style }, .{ .row_offset = row, .col_offset = 0 });

    // prefix and typed text are ASCII, so byte length is the column count.
    const cursor_col: u16 = @intCast(@min(prefix.len + typed.len, @as(usize, w) -| 1));
    win.showCursor(cursor_col, row);
}

/// Chip marking a filter or search still active after its prompt was confirmed.
/// Returns the column where the next chip (or the hints) should start.
fn drawStatusChip(win: Window, row: u16, col: u16, w: u16, text: []const u8, chip_style: vaxis.Style) u16 {
    const need: u16 = @intCast(text.len);
    if (col + need >= w) return col;
    _ = win.printSegment(.{ .text = text, .style = chip_style }, .{ .row_offset = row, .col_offset = col });
    return col + need;
}

// Help overlay. Two columns, because a keymap you have to scroll through is a
// worse keymap. MIN_W = 80 is enforced before anything draws, so the two-column
// layout always fits horizontally; only height can force scrolling.
const HELP_MAX_W: u16 = 76;
const HELP_LEFT_COL_W: u16 = 37;

const help_left = [_][]const u8{
    "NAVIGATION",
    "  ↓ / j        Move down",
    "  ↑ / k        Move up",
    "  PgDn / C-d   Page down",
    "  PgUp / C-u   Page up",
    "  g / Home     Top",
    "  G / End      Bottom",
    "",
    "LIST",
    "  Enter / d    Open detail",
    "  s            Cycle sort column",
    "  r            Reverse sort dir",
    "  n            Cycle net iface",
    "  D            Cycle disk mount",
    "  q / C-c      Quit",
    "",
    "DETAIL",
    "  Tab          Cycle panel",
    "  j / k        Scroll threads/fds",
    "  Esc / d / q  Close detail",
};

const help_right = [_][]const u8{
    "SEARCH — keeps every row visible",
    "  F3           Search / next match",
    "  Shift-F3     Previous match",
    "  Esc          Clear active search",
    "  prompt: C-w word · C-u all",
    "",
    "FILTER — hides non-matching rows",
    "  /            Open filter prompt",
    "  \\            Clear active filter",
    "  Tab          Field: any/cmd/user",
    "  prompt: C-w word · C-u all",
    "",
    "SIGNALS",
    "  K            Open signal menu",
    "  j / k        Pick signal",
    "  Enter / y    Send",
    "  HUP INT QUIT KILL USR1 USR2 TERM",
    "",
    "GENERAL",
    "  t            Theme light/dark",
    "  C-l          Redraw screen",
    "  F1           This help",
};

/// Content rows the help needs — the taller of the two columns.
pub fn helpContentRows() usize {
    return @max(help_left.len, help_right.len);
}

/// Content rows actually visible: popup minus border (2) and footer (1).
pub fn helpViewportRows(h: u16) usize {
    const avail: usize = @as(usize, h) -| 4; // popup is inset 2 rows top and bottom
    const popup_h = @min(helpContentRows() + 3, avail);
    return popup_h -| 3;
}

pub fn helpMaxScroll(h: u16) usize {
    const content = helpContentRows();
    const vis = helpViewportRows(h);
    return if (content > vis) content - vis else 0;
}

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

    // border(2) + title + blank + one row per signal + blank + hint
    const popup_h: u16 = @intCast(process.Signal.menu.len + 6);
    const popup_w: u16 = @intCast(@min(60, w -| 4));
    if (popup_w < 30 or h < popup_h + 2) return;

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

    const title = std.fmt.allocPrint(alloc, " Signal PID {d} ({s})", .{ pid, comm }) catch return;
    _ = popup.printSegment(.{ .text = title, .style = style.title_style }, .{ .row_offset = 0, .col_offset = 1 });

    const inner_w: u16 = popup_w -| 2;
    for (process.Signal.menu, 0..) |s, i| {
        const selected = s == sig;
        const row: u16 = @intCast(i + 2);
        const line = std.fmt.allocPrint(alloc, " {s} {d:>2}  SIG{s}", .{
            if (selected) "▸" else " ",
            s.number(),
            s.name(),
        }) catch continue;
        const st: vaxis.Style = if (selected) style.selected_bg_style else style.default_style;
        if (selected) {
            // Paint the full row so the highlight reads as a selection bar.
            const pad = std.fmt.allocPrint(alloc, "{s: <[w]}", .{ .s = line, .w = @as(usize, inner_w) }) catch line;
            _ = popup.printSegment(.{ .text = pad, .style = st }, .{ .row_offset = row, .col_offset = 1 });
        } else {
            _ = popup.printSegment(.{ .text = line, .style = st }, .{ .row_offset = row, .col_offset = 1 });
        }
    }

    const hint_row: u16 = @intCast(process.Signal.menu.len + 3);
    const hint = " [j/k] pick · [Enter|y] send · any other key cancel";
    _ = popup.printSegment(.{ .text = hint, .style = style.default_style }, .{ .row_offset = hint_row, .col_offset = 1 });
}

fn drawHelp(win: Window, w: u16, h: u16, scroll: usize) void {
    const popup_w: u16 = @intCast(@min(HELP_MAX_W, w -| 4));
    const viewport = helpViewportRows(h);
    if (popup_w < 40 or viewport == 0) return;
    const popup_h: u16 = @intCast(viewport + 3);

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

    const max_scroll = helpMaxScroll(h);
    const top = @min(scroll, max_scroll);

    var row: u16 = 0;
    while (row < viewport) : (row += 1) {
        const i = top + row;
        drawHelpCell(popup, &help_left, i, row, 0);
        drawHelpCell(popup, &help_right, i, row, HELP_LEFT_COL_W);
    }

    const footer: []const u8 = if (max_scroll > 0)
        " ↑↓ scroll · any other key closes "
    else
        " press any key to close ";
    _ = popup.printSegment(.{ .text = footer, .style = style.dim_style }, .{
        .row_offset = @intCast(viewport + 1),
        .col_offset = 0,
    });
}

fn drawHelpCell(popup: Window, col: []const []const u8, i: usize, row: u16, x: u16) void {
    if (i >= col.len) return;
    const line = col[i];
    if (line.len == 0) return;
    // Section headers sit at column 0; entries are indented.
    const s: vaxis.Style = if (line[0] != ' ') style.title_style else style.default_style;
    _ = popup.printSegment(.{ .text = line, .style = s }, .{ .row_offset = row, .col_offset = x });
}

test "help columns fit inside the enforced minimum width" {
    // MIN_W = 80 → popup_w = 76 → inner width = 74. Both columns must fit
    // there, or the two-column layout silently clips.
    const inner: usize = HELP_MAX_W - 2;
    for (help_left) |line| {
        const cols = std.unicode.utf8CountCodepoints(line) catch line.len;
        try std.testing.expect(cols <= HELP_LEFT_COL_W);
    }
    for (help_right) |line| {
        const cols = std.unicode.utf8CountCodepoints(line) catch line.len;
        try std.testing.expect(HELP_LEFT_COL_W + cols <= inner);
    }
}

test "help scrolls at the minimum terminal height and not when it fits" {
    // 24 rows is the enforced floor: the overlay must still be usable, with
    // scrolling picking up whatever does not fit.
    try std.testing.expect(helpMaxScroll(MIN_H) > 0);
    try std.testing.expect(helpViewportRows(MIN_H) > 0);
    try std.testing.expect(helpViewportRows(MIN_H) < helpContentRows());

    // Tall enough to show everything → no scrolling offered.
    const tall: u16 = @intCast(helpContentRows() + 7);
    try std.testing.expectEqual(@as(usize, 0), helpMaxScroll(tall));
    try std.testing.expectEqual(helpContentRows(), helpViewportRows(tall));
}

test "help viewport never exceeds content, at any height" {
    var h: u16 = MIN_H;
    while (h <= 120) : (h += 1) {
        try std.testing.expect(helpViewportRows(h) <= helpContentRows());
        // Scrolling to the very end must land exactly on the last row.
        try std.testing.expectEqual(helpContentRows(), helpViewportRows(h) + helpMaxScroll(h));
    }
}

test "disk percentages use df base and ignore the root reserve" {
    // 100 blocks: 50 used, 45 avail, 5 reserved for root.
    const d: process.DiskMount = .{ .mount_path = "/", .fs_type_name = "ext4", .used_bytes = 50, .total_bytes = 100, .avail_bytes = 45 };
    const used_pct = pctOf(d.used_bytes, diskPctBase(d));
    const avail_pct = pctOf(d.avail_bytes, diskPctBase(d));
    try std.testing.expectApproxEqAbs(@as(f32, 52.63), used_pct, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), used_pct + avail_pct, 0.01);
}

test "disk table layout never overflows and degrades cleanly across widths" {
    const sample_disks = [_]process.DiskMount{
        .{ .mount_path = "/", .fs_type_name = "ext4" },
        .{ .mount_path = "/boot", .fs_type_name = "vfat" },
        .{ .mount_path = "/home", .fs_type_name = "ext4" },
    };

    var w: u16 = 16;
    while (w <= 120) : (w += 1) {
        const l = computeDiskTableLayout(w, &sample_disks);
        try std.testing.expect(l.mount_col + l.mount_w < l.pct_col);
        if (l.size_col) |c| try std.testing.expect(c + DISK_NUM_W <= w);
        if (l.used_col) |c| try std.testing.expect(c + DISK_NUM_W <= w);
        if (l.avail_col) |c| try std.testing.expect(c + DISK_NUM_W <= w);
        if (l.bar_col) |c| {
            try std.testing.expect(l.bar_w > 0);
            try std.testing.expect(c + l.bar_w < l.pct_col);
        }
        try std.testing.expect(l.pct_col + DISK_PCT_W <= w);
        if (l.type_col) |c| try std.testing.expect(c + DISK_TYPE_W <= w);
    }

    // Wide box (~70 cols, typical 4-block desktop layout): full duf columns.
    const wide = computeDiskTableLayout(70, &sample_disks);
    try std.testing.expect(wide.size_col != null);
    try std.testing.expect(wide.used_col != null);
    try std.testing.expect(wide.avail_col != null);
    try std.testing.expect(wide.bar_col != null and wide.bar_w >= 8);
    try std.testing.expect(wide.type_col != null);

    // Narrowest 3-block disk box (inner_w = 37): sheds TYPE and SIZE, keeps USED + AVAIL + BAR + USE%.
    const narrow = computeDiskTableLayout(37, &sample_disks);
    try std.testing.expect(narrow.type_col == null);
    try std.testing.expect(narrow.size_col == null);
    try std.testing.expect(narrow.used_col != null);
    try std.testing.expect(narrow.avail_col != null);
    try std.testing.expect(narrow.bar_col != null and narrow.bar_w >= 5);
}
