const std = @import("std");
const vaxis = @import("vaxis");

pub const blocks = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

const Window = vaxis.Window;

/// Draw a 1-row sparkline from `samples` (oldest..newest) using Unicode blocks.
/// `max_hint` is an optional ceiling for scaling — pass 0 to auto-scale to data max.
pub fn drawSparkline(
    win: Window,
    x: u16,
    y: u16,
    width: u16,
    samples: []const f64,
    max_hint: f64,
    s: vaxis.Style,
) void {
    if (width == 0 or samples.len == 0) return;

    // Auto-scale: take max of data, fallback to 1.0 to avoid div0
    var max: f64 = max_hint;
    if (max <= 0) {
        for (samples) |v| {
            if (v > max) max = v;
        }
    }
    if (max <= 0) max = 1.0;

    // Bin samples down to `width` columns. We render the most recent `width`
    // samples if we have more, or pad with empty cells on the LEFT if fewer.
    const start_col: u16 = if (samples.len < width)
        width - @as(u16, @intCast(samples.len))
    else
        0;
    const start_idx: usize = if (samples.len > width) samples.len - width else 0;

    var col: u16 = start_col;
    var i: usize = start_idx;
    while (i < samples.len and col < width) : ({
        col += 1;
        i += 1;
    }) {
        const v = samples[i];
        var lvl: usize = @intFromFloat(@floor((v / max) * @as(f64, @floatFromInt(blocks.len - 1))));
        if (lvl >= blocks.len) lvl = blocks.len - 1;
        if (v <= 0) lvl = 0;
        win.writeCell(x + col, y, .{
            .char = .{ .grapheme = blocks[lvl], .width = 1 },
            .style = s,
        });
    }
}
