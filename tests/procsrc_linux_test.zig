const std = @import("std");
const top_q = @import("top-q");
const linux = top_q.linux;

const FIXTURE_DIR = "tests/fixtures/proc";

fn readFixture(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURE_DIR, name });
    defer alloc.free(path);
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const max: usize = 1024 * 1024;
    const buf = try alloc.alloc(u8, max);
    const n = try file.readPositionalAll(io, buf, 0);
    return alloc.realloc(buf, n);
}

test "parsePidStat: real /proc/<pid>/stat for self" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "stat_self");
    defer a.free(buf);

    const ps = try linux.parsePidStat(buf);
    try std.testing.expect(ps.pid > 0);
    try std.testing.expect(ps.comm.len > 0);
    try std.testing.expect(ps.num_threads >= 1);
}

test "parsePidStat: real /proc/1/stat (init)" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "stat_pid1");
    defer a.free(buf);

    const ps = try linux.parsePidStat(buf);
    try std.testing.expectEqual(@as(u32, 1), ps.pid);
    try std.testing.expectEqual(@as(u32, 0), ps.ppid);
    try std.testing.expect(ps.comm.len > 0);
}

test "parsePidStat: comm with parens and spaces" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "stat_tricky_comm");
    defer a.free(buf);

    const ps = try linux.parsePidStat(buf);
    try std.testing.expectEqual(@as(u32, 12345), ps.pid);
    // The comm should be "na(me) wi)th )parens" — i.e. content between
    // the FIRST '(' and the LAST ')'.
    try std.testing.expectEqualStrings("na(me) wi)th )parens", ps.comm);
    try std.testing.expectEqual(@as(u32, 1), ps.ppid);
    // State char is 'S' (sleeping) — verify by enum value comparison.
    try std.testing.expect(ps.state == .sleeping);
}

test "parseProcStat reports non-zero totals" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "proc_stat");
    defer a.free(buf);

    const c = try linux.parseProcStat(buf);
    try std.testing.expect(c.total_jiffies > 0);
    try std.testing.expect(c.idle_jiffies > 0);
    try std.testing.expect(c.idle_jiffies < c.total_jiffies);
}

test "parseMeminfo extracts MemTotal and MemAvailable" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "proc_meminfo");
    defer a.free(buf);

    const m = linux.parseMeminfo(buf);
    try std.testing.expect(m.mem_total_bytes > 0);
    try std.testing.expect(m.mem_available_bytes > 0);
    try std.testing.expect(m.mem_available_bytes <= m.mem_total_bytes);
}

test "parseMeminfo extracts SwapTotal and SwapFree correctly" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "meminfo_with_swap");
    defer a.free(buf);

    const m = linux.parseMeminfo(buf);
    // From the fixture: SwapTotal=16047100 kB, SwapFree=14945796 kB, SwapCached=2820 kB
    try std.testing.expectEqual(@as(u64, 16047100 * 1024), m.swap_total_bytes);
    try std.testing.expectEqual(@as(u64, 14945796 * 1024), m.swap_free_bytes);
    try std.testing.expectEqual(@as(u64, 2820 * 1024), m.swap_cached_bytes);
    // Ensure SwapCached doesn't accidentally get parsed as SwapTotal
    try std.testing.expect(m.swap_total_bytes > 1_000_000_000); // > 1 GB sanity
}

test "parseLoadavg returns three plausible floats" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "proc_loadavg");
    defer a.free(buf);

    const la = linux.parseLoadavg(buf);
    try std.testing.expect(la[0] >= 0);
    try std.testing.expect(la[1] >= 0);
    try std.testing.expect(la[2] >= 0);
}

test "parseCpuFreqMhz returns the highest core frequency" {
    const cpuinfo =
        \\processor : 0
        \\cpu MHz   : 2194.531
        \\processor : 1
        \\cpu MHz   : 3150.875
        \\processor : 2
        \\cpu MHz   : invalid
    ;
    try std.testing.expectEqual(@as(u32, 3150), linux.parseCpuFreqMhz(cpuinfo));
    try std.testing.expectEqual(@as(u32, 0), linux.parseCpuFreqMhz("processor : 0\n"));
}

test "parseUptime returns positive integer" {
    const a = std.testing.allocator;
    const buf = try readFixture(a, "proc_uptime");
    defer a.free(buf);

    const up = linux.parseUptime(buf);
    try std.testing.expect(up > 0);
}

test "computeCpuLayout logic for various core counts and window widths" {
    const render = top_q.render;

    // Case 1: 4 cores, plenty of space
    {
        const layout = render.computeCpuLayout(4, 4, 80, 13);
        try std.testing.expectEqual(false, layout.fallback_to_grid);
        try std.testing.expectEqual(@as(u16, 1), layout.ncols);
        try std.testing.expectEqual(@as(u16, 80), layout.cell_w);
        try std.testing.expectEqual(@as(u16, 68), layout.bar_interior_w);
    }

    // Case 2: 88 cores, 238 cols width (the user's truncation bug)
    // ncols calculated as 22 horizontally, then dropped to 18 to fit width.
    // 88 / 18 needs 5 rows, which > 4 available rows. Must fall back to grid!
    {
        const layout = render.computeCpuLayout(88, 4, 238, 13);
        try std.testing.expectEqual(true, layout.fallback_to_grid);
    }

    // Case 3: 88 cores, 300 cols width (fits all as bars)
    // 300 / 22 = 13 cols per cell, which >= 13 min_cell_w. 4 rows needed <= 4 avail.
    {
        const layout = render.computeCpuLayout(88, 4, 300, 13);
        try std.testing.expectEqual(false, layout.fallback_to_grid);
        try std.testing.expectEqual(@as(u16, 22), layout.ncols);
        try std.testing.expectEqual(@as(u16, 13), layout.cell_w);
        try std.testing.expectEqual(@as(u16, 1), layout.bar_interior_w);
    }
}

test "topLayoutHeights dynamic scaling logic" {
    const render = top_q.render;

    // Case 1: Low height terminal (h=24, 4 cores, w=80) — compact row1, sys cut.
    {
        const h = render.topLayoutHeights(24, 80, 4, 0);
        try std.testing.expectEqual(@as(u16, 4), h.row1);
        try std.testing.expectEqual(@as(u16, 4), h.row2);
        try std.testing.expectEqual(@as(u16, 8), h.total);
    }

    // Case 2: Normal terminal (h=30, 4 cores, w=80)
    // row1 = SYS_FIXED_ROWS (6) + 0 gpus + 2 borders = 8.
    {
        const h = render.topLayoutHeights(30, 80, 4, 0);
        try std.testing.expectEqual(@as(u16, 8), h.row1);
        try std.testing.expectEqual(@as(u16, 5), h.row2);
        try std.testing.expectEqual(@as(u16, 13), h.total);
    }

    // Case 3: Medium height (h=45, 88 cores, w=240)
    // max_total_h = 15, max_cpu_h = 10 (baseline row1 = 5). cpu_height_as_bars
    // = 10 (11 columns). Fits as bars (row2 = 10).
    {
        const h = render.topLayoutHeights(45, 240, 88, 0);
        try std.testing.expectEqual(@as(u16, 8), h.row1);
        try std.testing.expectEqual(@as(u16, 10), h.row2);
        try std.testing.expectEqual(@as(u16, 18), h.total);
    }

    // Case 4: Tall height (h=50, 88 cores, w=240)
    // max_total_h = 16, max_cpu_h = 11. cpu_height_as_bars = 11 (10 columns).
    // Fits as bars (row2 = 11).
    {
        const h = render.topLayoutHeights(50, 240, 88, 0);
        try std.testing.expectEqual(@as(u16, 8), h.row1);
        try std.testing.expectEqual(@as(u16, 11), h.row2);
        try std.testing.expectEqual(@as(u16, 19), h.total);
    }

    // Case 5: Very tall height (h=80, 88 cores, w=240)
    // max_total_h = 26, max_cpu_h = 21. Fits preferred target_cell_w = 28 (8 columns).
    // row2 = 13 (11 inner rows + 2 borders).
    {
        const h = render.topLayoutHeights(80, 240, 88, 0);
        try std.testing.expectEqual(@as(u16, 8), h.row1);
        try std.testing.expectEqual(@as(u16, 13), h.row2);
        try std.testing.expectEqual(@as(u16, 21), h.total);
    }

    // Case 6: GPUs grow row1 (one row per GPU); cpu block budget unchanged.
    {
        const h = render.topLayoutHeights(50, 240, 88, 2);
        try std.testing.expectEqual(@as(u16, 10), h.row1);
        try std.testing.expectEqual(@as(u16, 11), h.row2);
        try std.testing.expectEqual(@as(u16, 21), h.total);
    }
}

test "automatic CPU layout keeps more than 88 cores visible" {
    const render = top_q.render;
    const heights = render.topLayoutHeights(50, 240, 128, 2);
    const cpu_inner_h = heights.row2 -| 2;
    const layout = render.computeCpuLayout(128, cpu_inner_h, 238, 13);

    if (layout.fallback_to_grid) {
        const grid_rows = (128 + 238 - 1) / 238;
        try std.testing.expect(grid_rows <= cpu_inner_h);
    } else {
        const rows = (128 + layout.ncols - 1) / layout.ncols;
        try std.testing.expect(rows <= cpu_inner_h);
    }
}

test "fsTypeName maps known statfs magics and hides unknown" {
    try std.testing.expectEqualStrings("btrfs", linux.fsTypeName(0x9123683E));
    try std.testing.expectEqualStrings("ext4", linux.fsTypeName(0xEF53));
    try std.testing.expectEqualStrings("xfs", linux.fsTypeName(0x58465342));
    try std.testing.expectEqualStrings("tmpfs", linux.fsTypeName(0x01021994));
    try std.testing.expectEqualStrings("", linux.fsTypeName(0x12345678));
}

test "fsUsedBytes excludes reserved filesystem blocks from used space" {
    // 100 total, 20 free in total, but only 15 available to regular users:
    // the 5 reserved blocks are free, not used.
    try std.testing.expectEqual(@as(u64, 80 * 4096), linux.fsUsedBytes(100, 20, 4096));
    try std.testing.expectEqual(@as(u64, 0), linux.fsUsedBytes(100, 101, 4096));
}

test "parseGpuUevent extracts driver, pci id and slot" {
    const content =
        "DRIVER=nvidia\n" ++
        "PCI_CLASS=30000\n" ++
        "PCI_ID=10DE:2D19\n" ++
        "PCI_SUBSYS_ID=103C:8E35\n" ++
        "PCI_SLOT_NAME=0000:01:00.0\n" ++
        "MODALIAS=pci:v000010DEd00002D19sv0000103Csd00008E35bc03sc00i00\n";
    const ue = linux.parseGpuUevent(content);
    try std.testing.expectEqualStrings("nvidia", ue.driver);
    try std.testing.expectEqualStrings("10DE:2D19", ue.pci_id);
    try std.testing.expectEqualStrings("0000:01:00.0", ue.slot);
}

test "parseGpuUevent on non-PCI device leaves pci_id empty" {
    const ue = linux.parseGpuUevent("DRIVER=vgem\nMAJOR=226\nMINOR=0\n");
    try std.testing.expectEqualStrings("vgem", ue.driver);
    try std.testing.expectEqualStrings("", ue.pci_id);
}

test "parseNvidiaModel extracts marketing name" {
    const content =
        "Model: \t\t NVIDIA GeForce RTX 5060 Laptop GPU\n" ++
        "IRQ:   \t\t 67\n";
    const model = linux.parseNvidiaModel(content) orelse return error.TestExpectedModel;
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 5060 Laptop GPU", model);
    try std.testing.expectEqual(@as(?[]const u8, null), linux.parseNvidiaModel("IRQ: 67\n"));
}

test "gpuVendorName maps PCI vendor prefixes" {
    try std.testing.expectEqualStrings("NVIDIA", linux.gpuVendorName("10DE:2D19"));
    try std.testing.expectEqualStrings("AMD", linux.gpuVendorName("1002:164E"));
    try std.testing.expectEqualStrings("Intel", linux.gpuVendorName("8086:46A6"));
    try std.testing.expectEqualStrings("", linux.gpuVendorName("1AF4:1050"));
    try std.testing.expectEqualStrings("", linux.gpuVendorName("10D"));
}

test "enumerateMounts filters pseudo, overlay, EFI, and deduplicates Btrfs subvolumes" {
    const sample_mounts =
        "sysfs /sys sysfs rw 0 0\n" ++
        "proc /proc proc rw 0 0\n" ++
        "/dev/sdb1 /tpol ext4 rw,relatime 0 0\n" ++
        "/dev/sda2 /boot/efi vfat rw,relatime 0 0\n" ++
        "/dev/sda3 / ext4 rw,relatime 0 0\n" ++
        "overlay /var/lib/docker/overlayfs/123 overlay rw 0 0\n" ++
        "/dev/sda3 /home ext4 rw,relatime 0 0\n" ++
        "/dev/nvme0n1p2 /var/tmp btrfs rw,subvol=/@tmp 0 0\n" ++
        "/dev/nvme0n1p2 /var/log btrfs rw,subvol=/@log 0 0\n";

    var entries: [16]linux.MountEntry = undefined;
    const n = linux.enumerateMounts(sample_mounts, entries[0..]);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expectEqualStrings("/", entries[0].path());
    try std.testing.expectEqualStrings("/tpol", entries[1].path());
    try std.testing.expectEqualStrings("/var/tmp", entries[2].path());
}

test "parseHostname returns a non-empty string on Linux" {
    top_q.ctx.io = std.testing.io;
    const a = std.testing.allocator;
    const h = linux.parseHostname(a);
    defer a.free(h);
    try std.testing.expect(h.len > 0);
}
