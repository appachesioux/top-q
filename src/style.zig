const vaxis = @import("vaxis");

pub const Style = vaxis.Style;
pub const Color = vaxis.Color;

// =============================================================================
// Palette — Dracula-flavoured (vibrant, dark-bg first). Comparing to lzd/lzg:
// keys saturated to "pop", borders/dim still desaturated to recede.
// =============================================================================

pub const default_style: Style = .{
    .fg = .{ .rgb = .{ 248, 248, 242 } }, // Dracula foreground
};

pub const dim_style: Style = .{
    .fg = .{ .rgb = .{ 98, 114, 164 } }, // Dracula comment — punchier than before
};

pub const cpu_hot_style: Style = .{
    .fg = .{ .rgb = .{ 255, 85, 85 } }, // Dracula red
    .bold = true,
};

pub const cpu_warm_style: Style = .{
    .fg = .{ .rgb = .{ 241, 250, 140 } }, // Dracula yellow
};

pub const state_running_style: Style = .{
    .fg = .{ .rgb = .{ 80, 250, 123 } }, // Dracula green
    .bold = true,
};

pub const state_zombie_style: Style = .{
    .fg = .{ .rgb = .{ 255, 85, 85 } }, // Dracula red
    .bold = true,
};

// =============================================================================
// UI chrome
// =============================================================================

pub const header_style: Style = .{
    .fg = .{ .rgb = .{ 248, 248, 242 } },
    .bold = true,
    .bg = .{ .rgb = .{ 40, 42, 54 } }, // Dracula background
};

pub const title_style: Style = .{
    .fg = .{ .rgb = .{ 139, 233, 253 } }, // Dracula cyan — pops on border
    .bold = true,
};

/// Highlight applied to the active sort column header.
pub const active_col_style: Style = .{
    .fg = .{ .rgb = .{ 80, 250, 123 } }, // Dracula green
    .bold = true,
    .bg = .{ .rgb = .{ 40, 42, 54 } },
};

/// Status bar background — dark surface so bright key glyphs pop against it.
/// Cyan-bg version was too low-contrast for the action labels.
pub const status_style: Style = .{
    .fg = .{ .rgb = .{ 189, 195, 215 } }, // soft white-grey — dim relative to keys
    .bg = .{ .rgb = .{ 40, 42, 54 } }, // Dracula background
};

/// Used for the key glyph inside the status bar (e.g., `j/k`, `Enter`, `q`).
/// Bright yellow on the dark status bar — high luminance contrast.
pub const status_key_style: Style = .{
    .fg = .{ .rgb = .{ 241, 250, 140 } }, // Dracula yellow
    .bg = .{ .rgb = .{ 40, 42, 54 } },
    .bold = true,
};

pub const border_style: Style = .{
    .fg = .{ .rgb = .{ 98, 114, 164 } }, // brighter than Catppuccin overlay
};

pub const error_style: Style = .{
    .fg = .{ .rgb = .{ 255, 85, 85 } }, // Dracula red
    .bold = true,
};

pub const help_border_style: Style = .{
    .fg = .{ .rgb = .{ 241, 250, 140 } }, // Dracula yellow
    .bold = true,
};

pub const purple_style: Style = .{
    .fg = .{ .rgb = .{ 189, 147, 249 } }, // Dracula purple
};

pub const pink_style: Style = .{
    .fg = .{ .rgb = .{ 255, 121, 198 } }, // Dracula pink
};

pub const orange_style: Style = .{
    .fg = .{ .rgb = .{ 255, 184, 108 } }, // Dracula orange
};

pub const green_style: Style = .{
    .fg = .{ .rgb = .{ 80, 250, 123 } }, // Dracula green
};

pub const cyan_style: Style = .{
    .fg = .{ .rgb = .{ 139, 233, 253 } }, // Dracula cyan
};

pub const selected_bg_style: Style = .{
    .fg = .{ .rgb = .{ 248, 248, 242 } }, // Dracula foreground
    .bg = .{ .rgb = .{ 68, 71, 90 } }, // Dracula current line
    .bold = true,
};

// =============================================================================
// Gradient — usage 0..100 → green / yellow / red (Dracula values)
// =============================================================================

pub const grad_low_rgb: [3]u8 = .{ 80, 250, 123 }; // Dracula green   ≤ 60%
pub const grad_mid_rgb: [3]u8 = .{ 241, 250, 140 }; // Dracula yellow  60–85%
pub const grad_high_rgb: [3]u8 = .{ 255, 85, 85 }; // Dracula red     ≥ 85%

pub fn gradientFg(pct: f32) Color {
    if (pct >= 85.0) return .{ .rgb = grad_high_rgb };
    if (pct >= 60.0) return .{ .rgb = grad_mid_rgb };
    return .{ .rgb = grad_low_rgb };
}

pub fn gradientStyle(pct: f32) Style {
    return .{ .fg = gradientFg(pct), .bold = pct >= 85.0 };
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
