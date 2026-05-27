# top-q

TUI system monitor in Zig — combines htop's clean layout with btop++'s depth via **progressive disclosure**.

The default view is a clean, navigable process list (htop-like, ≥80% of vertical space dedicated to processes). Select a process and press `Enter`/`d` to expand a btop-style detail panel — sub-second graphs of CPU/MEM/IO, threads list, and open file descriptors — for *that* process only. Press `Esc` to go back.

## Quick Start

```sh
zig build run                  # debug build + run
zig build run -- -d 500        # 500 ms refresh
zig build run -- -u $USER      # pre-filter by user
```

Navigate with `j`/`k` (or arrows), `g`/`G`, `PgUp`/`PgDn`. Sort with `s` (cycle) and `r` (reverse). Filter with `/`, clear with `\`. Send a signal with `K` (confirmation required). Help with `?` or `F1`. Quit with `q`.

## Stack

- **Zig 0.15** with **libvaxis** (terminal rendering)
- Linux only for now (macOS in progress; uses `/proc` for collection)
- Zero external dependencies beyond libvaxis
- Convention over configuration — no config files

## Build & Run

```sh
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # release
zig build run                      # run directly
zig build test                     # parser unit tests
```

Release binary lands in `zig-out/bin/top-q-linux` (currently ~370 KB).

## CLI

```
top-q [options]

  -h, --help           Show this help and exit
  -V, --version        Show version and exit
  -d, --delay <ms>     Refresh interval in ms (200..10000, default 1500)
  -u, --user <name>    Pre-apply user filter at startup
      --no-color       Disable colours (also via NO_COLOR env)
```

## Status

Linux build is feature-complete for v0.1: process list, navigation, progressive-disclosure detail view (CPU/MEM/IO sparklines, threads, FDs), incremental sort/filter, signal sending with confirmation. macOS backend is stubbed; full implementation is on the roadmap.

