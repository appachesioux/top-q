const std = @import("std");
const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

// =============================================================================
// Palette — Dracula-flavoured (vibrant, dark-bg first). Comparing to lzd/lzg:
// keys saturated to "pop", borders/dim still desaturated to recede.
//
// Styles are runtime variables, not compile-time constants: setScheme() swaps
// the whole UI between the dark (default) and light palettes, driven by the
// terminal's reported color scheme (OSC 996 / DEC mode 2031 via libvaxis
// subscribeToColorSchemeUpdates). Terminals that never reply keep dark.
//
// Light palette: Dracula hues darkened for contrast on pale backgrounds, UI
// surfaces flipped to light-grey bars, Dracula's bg colour reused as "ink".
// =============================================================================

pub var default_style: Style = .{
    .fg = .{ .rgb = .{ 248, 248, 242 } }, // Dracula foreground
};

pub var dim_style: Style = .{
    .fg = .{ .rgb = .{ 98, 114, 164 } }, // Dracula comment — punchier than before
};

pub var cpu_hot_style: Style = .{
    .fg = .{ .rgb = .{ 255, 85, 85 } }, // Dracula red
    .bold = true,
};

pub var cpu_warm_style: Style = .{
    .fg = .{ .rgb = .{ 241, 250, 140 } }, // Dracula yellow
};

pub var state_running_style: Style = .{
    .fg = .{ .rgb = .{ 80, 250, 123 } }, // Dracula green
    .bold = true,
};

pub var state_zombie_style: Style = .{
    .fg = .{ .rgb = .{ 255, 85, 85 } }, // Dracula red
    .bold = true,
};

// =============================================================================
// UI chrome
// =============================================================================

pub var header_style: Style = .{
    .fg = .{ .rgb = .{ 248, 248, 242 } },
    .bold = true,
    .bg = .{ .rgb = .{ 40, 42, 54 } }, // Dracula background
};

pub var title_style: Style = .{
    .fg = .{ .rgb = .{ 139, 233, 253 } }, // Dracula cyan — pops on border
    .bold = true,
};

/// Highlight applied to the active sort column header.
pub var active_col_style: Style = .{
    .fg = .{ .rgb = .{ 80, 250, 123 } }, // Dracula green
    .bold = true,
    .bg = .{ .rgb = .{ 40, 42, 54 } },
};

/// Status bar background — dark surface so bright key glyphs pop against it.
/// Cyan-bg version was too low-contrast for the action labels.
pub var status_style: Style = .{
    .fg = .{ .rgb = .{ 189, 195, 215 } }, // soft white-grey — dim relative to keys
    .bg = .{ .rgb = .{ 40, 42, 54 } }, // Dracula background
};

/// Used for the key glyph inside the status bar (e.g., `j/k`, `Enter`, `q`).
/// Bright yellow on the dark status bar — high luminance contrast.
pub var status_key_style: Style = .{
    .fg = .{ .rgb = .{ 241, 250, 140 } }, // Dracula yellow
    .bg = .{ .rgb = .{ 40, 42, 54 } },
    .bold = true,
};

/// Text-entry modes repaint the whole status bar in a solid colour, so "you are
/// typing" is unmistakable and each prompt is told apart at a glance. Purple and
/// orange are the two palette colours not already used in the bar (yellow =
/// keys, cyan = titles, green = active sort, red = errors). Mid-tone bgs with
/// dark ink read fine on BOTH schemes, so these stay theme-independent.
pub const filter_mode_style: Style = .{
    .fg = .{ .rgb = .{ 40, 42, 54 } }, // Dracula background, as ink
    .bg = .{ .rgb = .{ 189, 147, 249 } }, // Dracula purple
    .bold = true,
};

pub const search_mode_style: Style = .{
    .fg = .{ .rgb = .{ 40, 42, 54 } },
    .bg = .{ .rgb = .{ 255, 184, 108 } }, // Dracula orange
    .bold = true,
};

/// Same colours as chips on the normal status bar, marking a filter or search
/// that is still active after you left its prompt.
pub const filter_chip_style: Style = filter_mode_style;
pub const search_chip_style: Style = search_mode_style;

/// --no-color fallback for both: reverse video still reads as "different mode".
pub const mono_mode_style: Style = .{
    .reverse = true,
    .bold = true,
};

pub const border_style: Style = .{
    .fg = .{ .rgb = .{ 98, 114, 164 } }, // brighter than Catppuccin overlay
};

pub var error_style: Style = .{
    .fg = .{ .rgb = .{ 255, 85, 85 } }, // Dracula red
    .bold = true,
};

pub var help_border_style: Style = .{
    .fg = .{ .rgb = .{ 241, 250, 140 } }, // Dracula yellow
    .bold = true,
};

pub var purple_style: Style = .{
    .fg = .{ .rgb = .{ 189, 147, 249 } }, // Dracula purple
};

pub var pink_style: Style = .{
    .fg = .{ .rgb = .{ 255, 121, 198 } }, // Dracula pink
};

pub var orange_style: Style = .{
    .fg = .{ .rgb = .{ 255, 184, 108 } }, // Dracula orange
};

pub var green_style: Style = .{
    .fg = .{ .rgb = .{ 80, 250, 123 } }, // Dracula green
};

pub var cyan_style: Style = .{
    .fg = .{ .rgb = .{ 139, 233, 253 } }, // Dracula cyan
};

pub var selected_bg_style: Style = .{
    .fg = .{ .rgb = .{ 248, 248, 242 } }, // Dracula foreground
    .bg = .{ .rgb = .{ 68, 71, 90 } }, // Dracula current line
    .bold = true,
};

// =============================================================================
// Gradient — usage 0..100 → green / yellow / red (Dracula values)
// =============================================================================

pub var grad_low_rgb: [3]u8 = .{ 80, 250, 123 }; // Dracula green   ≤ 60%
pub var grad_mid_rgb: [3]u8 = .{ 241, 250, 140 }; // Dracula yellow  60–85%
pub var grad_high_rgb: [3]u8 = .{ 255, 85, 85 }; // Dracula red     ≥ 85%

// =============================================================================
// Theme switching
// =============================================================================

/// Light-scheme counterparts of the Dracula palette: same hues, darkened so
/// they keep ≥ ~4.5:1 contrast on pale terminal backgrounds, plus light-grey
/// "surface" bars replacing the dark Dracula bg.
const light_ink: [3]u8 = .{ 40, 42, 54 }; // Dracula bg as text ink
const light_dim: [3]u8 = .{ 88, 100, 140 };
const light_red: [3]u8 = .{ 204, 48, 48 };
const light_yellow: [3]u8 = .{ 146, 108, 0 };
const light_green: [3]u8 = .{ 20, 128, 58 };
const light_cyan: [3]u8 = .{ 10, 106, 140 };
const light_purple: [3]u8 = .{ 110, 60, 178 };
const light_pink: [3]u8 = .{ 194, 54, 122 };
const light_orange: [3]u8 = .{ 190, 92, 8 };
const light_surface: [3]u8 = .{ 205, 210, 222 }; // header/status bar bg
const light_surface_sel: [3]u8 = .{ 193, 199, 214 }; // selected row bg
const light_status_fg: [3]u8 = .{ 72, 78, 98 };

/// Swap every theme-aware style between the dark and light palettes. Called
/// from the event loop on `.color_scheme` events (initial report + live
/// changes); the next frame repaints with the new palette.
pub fn setScheme(scheme: Color.Scheme) void {
    const l = scheme == .light;

    default_style = if (l) .{ .fg = .{ .rgb = light_ink } } else .{ .fg = .{ .rgb = .{ 248, 248, 242 } } };
    dim_style = if (l) .{ .fg = .{ .rgb = light_dim } } else .{ .fg = .{ .rgb = .{ 98, 114, 164 } } };
    cpu_hot_style = if (l) .{ .fg = .{ .rgb = light_red }, .bold = true } else .{ .fg = .{ .rgb = .{ 255, 85, 85 } }, .bold = true };
    cpu_warm_style = if (l) .{ .fg = .{ .rgb = light_yellow } } else .{ .fg = .{ .rgb = .{ 241, 250, 140 } } };
    state_running_style = if (l) .{ .fg = .{ .rgb = light_green }, .bold = true } else .{ .fg = .{ .rgb = .{ 80, 250, 123 } }, .bold = true };
    state_zombie_style = if (l) .{ .fg = .{ .rgb = light_red }, .bold = true } else .{ .fg = .{ .rgb = .{ 255, 85, 85 } }, .bold = true };

    header_style = if (l)
        .{ .fg = .{ .rgb = light_ink }, .bold = true, .bg = .{ .rgb = light_surface } }
    else
        .{ .fg = .{ .rgb = .{ 248, 248, 242 } }, .bold = true, .bg = .{ .rgb = .{ 40, 42, 54 } } };
    title_style = if (l) .{ .fg = .{ .rgb = light_cyan }, .bold = true } else .{ .fg = .{ .rgb = .{ 139, 233, 253 } }, .bold = true };
    active_col_style = if (l)
        .{ .fg = .{ .rgb = light_green }, .bold = true, .bg = .{ .rgb = light_surface } }
    else
        .{ .fg = .{ .rgb = .{ 80, 250, 123 } }, .bold = true, .bg = .{ .rgb = .{ 40, 42, 54 } } };
    status_style = if (l)
        .{ .fg = .{ .rgb = light_status_fg }, .bg = .{ .rgb = light_surface } }
    else
        .{ .fg = .{ .rgb = .{ 189, 195, 215 } }, .bg = .{ .rgb = .{ 40, 42, 54 } } };
    status_key_style = if (l)
        .{ .fg = .{ .rgb = light_yellow }, .bg = .{ .rgb = light_surface }, .bold = true }
    else
        .{ .fg = .{ .rgb = .{ 241, 250, 140 } }, .bg = .{ .rgb = .{ 40, 42, 54 } }, .bold = true };

    error_style = if (l) .{ .fg = .{ .rgb = light_red }, .bold = true } else .{ .fg = .{ .rgb = .{ 255, 85, 85 } }, .bold = true };
    help_border_style = if (l) .{ .fg = .{ .rgb = light_yellow }, .bold = true } else .{ .fg = .{ .rgb = .{ 241, 250, 140 } }, .bold = true };
    purple_style = if (l) .{ .fg = .{ .rgb = light_purple } } else .{ .fg = .{ .rgb = .{ 189, 147, 249 } } };
    pink_style = if (l) .{ .fg = .{ .rgb = light_pink } } else .{ .fg = .{ .rgb = .{ 255, 121, 198 } } };
    orange_style = if (l) .{ .fg = .{ .rgb = light_orange } } else .{ .fg = .{ .rgb = .{ 255, 184, 108 } } };
    green_style = if (l) .{ .fg = .{ .rgb = light_green } } else .{ .fg = .{ .rgb = .{ 80, 250, 123 } } };
    cyan_style = if (l) .{ .fg = .{ .rgb = light_cyan } } else .{ .fg = .{ .rgb = .{ 139, 233, 253 } } };
    selected_bg_style = if (l)
        .{ .fg = .{ .rgb = light_ink }, .bg = .{ .rgb = light_surface_sel }, .bold = true }
    else
        .{ .fg = .{ .rgb = .{ 248, 248, 242 } }, .bg = .{ .rgb = .{ 68, 71, 90 } }, .bold = true };

    grad_low_rgb = if (l) light_green else .{ 80, 250, 123 };
    grad_mid_rgb = if (l) light_yellow else .{ 241, 250, 140 };
    grad_high_rgb = if (l) light_red else .{ 255, 85, 85 };
}

pub fn gradientFg(pct: f32) Color {
    if (pct >= 85.0) return .{ .rgb = grad_high_rgb };
    if (pct >= 60.0) return .{ .rgb = grad_mid_rgb };
    return .{ .rgb = grad_low_rgb };
}

pub fn gradientStyle(pct: f32) Style {
    return .{ .fg = gradientFg(pct), .bold = pct >= 85.0 };
}

/// Inverse gradient for available/free metrics ("Avail").
/// High available percent (> 40%) is healthy (green), moderate (15..40%) is
/// warning (yellow), and low (<= 15%) is critical (red bold).
pub fn gradientInverseFg(pct: f32) Color {
    if (pct <= 15.0) return .{ .rgb = grad_high_rgb };
    if (pct <= 40.0) return .{ .rgb = grad_mid_rgb };
    return .{ .rgb = grad_low_rgb };
}

pub fn gradientInverseStyle(pct: f32) Style {
    return .{ .fg = gradientInverseFg(pct), .bold = pct <= 15.0 };
}

// =============================================================================
// Column layout — fixed widths; comm takes the remainder
// =============================================================================

pub const PID_W: usize = 7;
pub const USER_W: usize = 10;
pub const STATE_W: usize = 2;
pub const CPU_W: usize = 6;
pub const MEM_W: usize = 6;
// COMM_W = remaining columns

test "gradient style thresholds" {
    const low = gradientStyle(50.0);
    try std.testing.expectEqual(grad_low_rgb, low.fg.rgb);
    try std.testing.expect(!low.bold);

    const mid = gradientStyle(70.0);
    try std.testing.expectEqual(grad_mid_rgb, mid.fg.rgb);
    try std.testing.expect(!mid.bold);

    const high = gradientStyle(90.0);
    try std.testing.expectEqual(grad_high_rgb, high.fg.rgb);
    try std.testing.expect(high.bold);
}

test "inverse gradient style thresholds for available metrics" {
    // High available (> 40%) -> Green, not bold
    const high_avail = gradientInverseStyle(90.0);
    try std.testing.expectEqual(grad_low_rgb, high_avail.fg.rgb);
    try std.testing.expect(!high_avail.bold);

    const mid_high_avail = gradientInverseStyle(45.0);
    try std.testing.expectEqual(grad_low_rgb, mid_high_avail.fg.rgb);
    try std.testing.expect(!mid_high_avail.bold);

    // Medium available (15%..40%) -> Yellow, not bold
    const mid_avail = gradientInverseStyle(30.0);
    try std.testing.expectEqual(grad_mid_rgb, mid_avail.fg.rgb);
    try std.testing.expect(!mid_avail.bold);

    // Low available (<= 15%) -> Red, bold
    const low_avail = gradientInverseStyle(10.0);
    try std.testing.expectEqual(grad_high_rgb, low_avail.fg.rgb);
    try std.testing.expect(low_avail.bold);

    const zero_avail = gradientInverseStyle(0.0);
    try std.testing.expectEqual(grad_high_rgb, zero_avail.fg.rgb);
    try std.testing.expect(zero_avail.bold);
}

test "setScheme swaps and restores palettes" {
    defer setScheme(.dark);

    setScheme(.light);
    try std.testing.expectEqual(light_ink, default_style.fg.rgb);
    try std.testing.expectEqual(light_surface, header_style.bg.rgb);
    try std.testing.expectEqual(light_green, grad_low_rgb);

    setScheme(.dark);
    try std.testing.expectEqual([3]u8{ 248, 248, 242 }, default_style.fg.rgb);
    try std.testing.expectEqual([3]u8{ 40, 42, 54 }, header_style.bg.rgb);
    try std.testing.expectEqual([3]u8{ 80, 250, 123 }, grad_low_rgb);
}
