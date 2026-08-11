/// Library aggregator for unit tests. Exposes internal modules so tests
/// can import everything via a single `top-q` named module.
pub const utils = @import("utils.zig");
pub const process = @import("process.zig");
pub const linux = @import("procsrc/linux.zig");
pub const render = @import("render.zig");
pub const view = @import("view.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
