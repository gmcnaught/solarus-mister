# Solarus — MiSTer FPGA Port

![Mystery of Solarus DX running on MiSTer](docs/screenshot.png)

*The Legend of Zelda: Mystery of Solarus DX, captured live from a MiSTer's video
output.*

A port of the **[Solarus](https://www.solarus-games.org)** 2D action-RPG engine
(the open-source, Zelda-like engine behind *The Legend of Zelda: Mystery of
Solarus DX*, *Ocean's Heart*, *Yarntown*, and many more) to **MiSTer FPGA**.

**This is not an FPGA recreation of a console.** The Solarus engine runs as ARM
software on the DE10-Nano's CPU, while a custom FPGA core does the heavy
lifting: the CPU sends the FPGA a list of 2D draw commands each frame, and the
FPGA fabric composites the actual pixels and drives the video output — through
the same MiSTer video pipeline you already use (HDMI, analog out, scanlines,
shadow masks). No OpenGL, no Linux desktop, no display server. Think of it as a
Linux port of Solarus that uses the MiSTer FPGA as its GPU.

## Quick Install

1. Copy the contents of the release zip to the root of your MiSTer SD card
   (`/media/fat/`). It contains the FPGA core (`_Other/Solarus_YYYYMMDD.rbf`),
   the engine (`games/Solarus/`), and a `Scripts/Solarus.sh` launcher.
2. Put at least one quest (a `<name>.sol` file — see
   [Getting quests](#getting-quests)) into `/media/fat/games/Solarus/quests/`.
3. Run **Solarus** from the MiSTer **Scripts** menu once. This starts the
   auto-launch daemon (which registers itself to persist across reboots) and
   loads the core. After this first run, loading the core from the menu is all
   you ever need.
4. Pick your quest from the OSD (**Load Quest**). The engine starts
   automatically; on first load of a quest you'll see a progress bar while its
   graphics are staged into video memory.

> **Requires a 128 MB SDRAM expansion board** (like the heavier arcade cores) —
> the entire quest's graphics are staged there at load.

There is no published MiSTer Frontier / `update_all` database entry yet; manual
install is the supported route today.

## Getting quests

Solarus is an engine; games ("quests") are separate downloads, each with its own
license. Many are free — the [Solarus quest library](https://www.solarus-games.org)
is the main source. No quest data ships with this port.

A `.sol` file is simply a Solarus `data.solarus` archive (a zip of the quest's
`data/` contents) renamed so the MiSTer OSD file browser can filter on it. To
convert a downloaded quest, use the packaging script from this repo on your PC:

```bash
scripts/fetch_quest.sh                                  # downloads Mystery of Solarus DX
scripts/package_quest.sh /path/to/quest my_quest.sol    # packages any quest dir
```

Copy the result into `/media/fat/games/Solarus/quests/`. The recommended first
quest is **The Legend of Zelda: Mystery of Solarus DX** — free, by the Solarus
team, and the port's primary test game.

## Controls

| Button         | Action            |
|----------------|-------------------|
| D-pad / Analog | Move              |
| A / B          | Action / Sword    |
| X / Y          | Items             |
| Start          | Pause menu        |
| Select         | Map / inventory   |
| Menu button    | MiSTer OSD menu   |

Buttons can be remapped from the MiSTer OSD (Define buttons). Controller input
is read directly from the FPGA — no per-quest configuration needed. Saves go to
`/media/fat/saves/Solarus/`; engine logs to `/media/fat/logs/Solarus/`.

## Features

- **FPGA-accelerated 2D compositor.** The CPU never touches frame pixels — every
  clear/fill/sprite draw becomes a hardware blit command, composited by the
  fabric into an on-chip framebuffer at 320×240.
- **Quest assets resident in SDRAM.** A quest's sprite/tile atlases are staged
  into SDRAM once at load (with an on-screen progress bar), then sourced by the
  compositor directly — no per-frame texture traffic from the CPU.
- **Native FPGA audio** — 48 kHz stereo through a DDR3 ring buffer, out the
  normal MiSTer audio paths (HDMI, I2S, SPDIF, analog).
- **OSD quest picker + auto-launch** — pick a `.sol` with the native MiSTer file
  browser; the engine launches, switches quests, and exits with the core.
- **CRT-friendly** — standard MiSTer video pipeline, so scanline/shadow-mask
  filters and analog output work as with any core.
- **LuaJIT** quest scripting (Solarus quests are scripted in Lua) with full JIT
  on the ARM Cortex-A9.

## Known limitations

- Fixed **320×240** output (the native resolution of most Solarus quests).
- **Shaders are unavailable** (the engine's shader support needs OpenGL, which
  this port deliberately has none of). Quests that require shaders for core
  mechanics may misbehave; the vast majority don't use them.
- Very busy scenes in large quests can still dip below 60 fps; performance work
  is ongoing.
- Quest compatibility is validated primarily against Mystery of Solarus DX;
  other quests should work but are less tested.

## Building from source

Everything cross-compiles in Docker on any x86_64/arm64 host (including Apple
Silicon); the FPGA core builds in GitHub Actions — no local Quartus needed. No
binaries or quest data are committed; scripts rebuild/refetch everything.

```bash
# One-time: build the cross toolchain image + register the armhf qemu handler
docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
docker run --rm --privileged tonistiigi/binfmt --install arm

# scripts/docker_run.sh wraps `docker run` (mounts the repo at /src; from a
# linked git worktree it also bind-mounts the shared .git so git works inside
# the container). Works identically from the main checkout or any worktree.
RUN="scripts/docker_run.sh"
$RUN scripts/build_sdl2.sh            # lean SDL2 (no X11/Wayland/GBM)
$RUN scripts/build_luajit.sh          # LuaJIT 2.1 for armhf
$RUN scripts/build_engine.sh          # solarus-run + libsolarus → build/armhf/
$RUN scripts/collect_runtime_libs.sh  # shippable .so closure   → deploy/libs/
```

The engine is upstream **Solarus 1.6.5** plus a reviewable series of MiSTer
patches (`patches/series/*.patch` — the blitter renderer, DDR video/audio/input
bridges, and performance work), applied by `scripts/build_engine.sh`.

The FPGA core (forked from the MiSTer OpenBOR core) lives in `fpga/`; push to
GitHub and CI builds the RBF (`.github/workflows/build-rbf.yml`), or build
locally with Quartus 17.0+ via `fpga/build_solarus.sh`. For development,
`./deploy.py [--no-rbf] [--host IP]` pushes the whole tree to a MiSTer over SSH.

Developer documentation:

| Doc | Contents |
|-----|----------|
| `docs/frame-dataflow.md` | How a frame flows CPU → command ring → FPGA compositor → video |
| `docs/blitter-renderer-integration.md` | How the engine's renderer maps onto the hardware blitter |
| `docs/env-variables.md` | Every runtime/build tunable the port reads |
| `docs/gprof-profiling.md` | Profiling the engine and MiSTer Main with gprof |
| `docs/Solarus/README.md` | The end-user README that ships on the SD card |

## AI disclosure

Substantial parts of this port — engine patches, FPGA RTL, and documentation —
were developed with AI assistance (Claude). Changes are validated on real
DE10-Nano hardware before merge.

## Credits

- **The Solarus Team** (Christopho et al.) — the
  [Solarus engine](https://www.solarus-games.org) and Mystery of Solarus DX.
- **SumolX** — the [MiSTer OpenBOR port](https://github.com/SumolX/MiSTer_OpenBOR)
  whose core this one is forked from (DDR3 video/audio/joystick interface).
- **Jotego** — the [jtframe](https://github.com/jotego/jtframe) SDRAM
  controller/cache subsystem vendored by the FPGA core.
- **Sorgelig & the MiSTer community** — the MiSTer FPGA framework.

## License

**GPL-3.0.** The Solarus engine is GPLv3; the FPGA core inherits GPL-3.0 from
the MiSTer OpenBOR core it forks. Quest data is separately licensed by its
authors and is never included here.
