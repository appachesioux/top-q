const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");
const App = @import("app.zig").App;
const AppOptions = @import("app.zig").Options;
const ctx = @import("ctx.zig");

pub const panic = vaxis.panic_handler;

const help_text =
    \\Usage: top-q [options]
    \\
    \\Options:
    \\  -h, --help           Show this help and exit
    \\  -V, --version        Show version and exit
    \\  -d, --delay <ms>     Refresh interval in ms (200..10000, default 1500)
    \\  -u, --user <name>    Pre-apply user filter at startup
    \\      --no-color       Disable colours (also via NO_COLOR env)
    \\
;

fn writeStderr(s: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(ctx.io, s) catch {};
}

fn writeStdout(s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(ctx.io, s) catch {};
}

fn parseArgs(alloc: std.mem.Allocator, init: std.process.Init) !AppOptions {
    var opts: AppOptions = .{};

    var args = try init.minimal.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(help_text);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            var buf: [64]u8 = undefined;
            const v = try std.fmt.bufPrint(&buf, "{s} v{s}\n", .{ build_options.app_name, build_options.version });
            writeStdout(v);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delay")) {
            const next = args.next() orelse {
                writeStderr("top-q: --delay requires a value\n");
                std.process.exit(1);
            };
            const v = std.fmt.parseInt(u64, next, 10) catch {
                writeStderr("top-q: --delay must be a number in ms\n");
                std.process.exit(1);
            };
            if (v < 200 or v > 10000) {
                writeStderr("top-q: --delay must be in range 200..10000\n");
                std.process.exit(1);
            }
            opts.delay_ms = v;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            const next = args.next() orelse {
                writeStderr("top-q: --user requires a value\n");
                std.process.exit(1);
            };
            // Dup the value so it outlives the args iterator.
            opts.initial_user_filter = try alloc.dupe(u8, next);
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "top-q: unknown argument '{s}' (use --help)\n", .{arg}) catch "top-q: bad args\n";
            writeStderr(m);
            std.process.exit(1);
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    ctx.io = init.io;
    ctx.env_map = init.environ_map;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var opts = try parseArgs(alloc, init);
    if (init.minimal.environ.getPosix("NO_COLOR")) |_| opts.no_color = true;
    defer if (opts.initial_user_filter) |s| alloc.free(s);

    const app = App.init(alloc, opts) catch |e| {
        var buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "top-q: failed to initialize: {s}\n", .{@errorName(e)}) catch "top-q: init error\n";
        writeStderr(m);
        std.process.exit(2);
    };
    defer app.deinit();

    app.run() catch |e| {
        var buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "top-q: runtime error: {s}\n", .{@errorName(e)}) catch "top-q: runtime error\n";
        writeStderr(m);
        std.process.exit(3);
    };
}
