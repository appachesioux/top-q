const std = @import("std");
pub fn main() !void {
    var file = try std.fs.cwd().openFile("/proc/stat", .{});
    defer file.close();
    std.debug.print("Success!\n", .{});
}
