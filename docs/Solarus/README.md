# Solarus — MiSTer FPGA

A hybrid ARM+FPGA port of the **Solarus** 2D action-RPG engine for MiSTer FPGA.
Solarus is the open-source engine behind Zelda-like quests such as *The Legend of
Zelda: Mystery of Solarus DX*, *Ocean's Heart*, and *Yarntown*. The engine runs on
the DE10-Nano's ARM Cortex-A9 and sends 2D draw commands to the FPGA, which
composites every frame in hardware — no OpenGL, no Mesa, no display server.

**Requires a 128 MB SDRAM expansion board**, like the heavier arcade cores —
the entire quest's graphics are staged there at load.

## Features

- **FPGA-composited video** — 320×240 RGB565; the FPGA fabric builds each frame
  from the engine's draw commands (the ARM never touches frame pixels)
- **Native FPGA audio** — 48 kHz stereo through a DDR3 ring buffer (OpenAL-soft
  loopback → DDR), no ALSA
- **MiSTer OSD quest picker** — pick a quest with the native MiSTer file browser
  (the core's `Load Quest` slot, `.sol` files)
- **Auto-launch** — the engine starts when you pick a quest, switches when you
  pick another, and exits when you load a different core
- **CRT-friendly** — runs on the shared MiSTer FPGA video pipeline (scanlines,
  shadow masks, analog out)

## Install

### Manual

Extract the release zip to the root of your MiSTer SD card (`/media/fat/`):

```
/media/fat/
├── _Other/
│   └── Solarus_YYYYMMDD.rbf         FPGA core (branded, dated)
├── docs/
│   └── Solarus/
│       └── README.md               This file
├── games/
│   └── Solarus/
│       ├── solarus-run             ARM engine binary
│       ├── libs/                   runtime shared libraries
│       ├── solarus_daemon.sh       core-load watcher (auto-launch, self-installs)
│       ├── _handler.sh             auto-launch dispatcher
│       ├── quest_manager.sh        quest lifecycle manager (launch/switch/exit)
│       ├── solarus_run.sh          shared launch logic
│       └── quests/                 place your <name>.sol quests here
├── logs/
│   └── Solarus/                    engine logs
├── saves/
│   └── Solarus/                    per-quest save data
└── Scripts/
    └── Solarus.sh                  manual Scripts-menu launcher
```

Then run **Solarus** from the MiSTer **Scripts** menu once. This starts the
auto-launch daemon (which self-registers into `user-startup.sh` so it persists
across reboots) and loads the core. From then on, just load **Solarus** from
the MiSTer console menu and pick a quest from the OSD (**Load Quest**). The
core idles until a quest is picked — the same pattern as the PICO-8 and OpenBOR
cores. On a quest's first load you'll see a progress bar while its graphics are
staged into SDRAM.

If MiSTer Frontier's Master_Daemon is installed, the daemon defers to it — the
two coexist without double-launching.

> A future path is the **MiSTer Frontier** combined database (`update_all`
> auto-deploy), the same mechanism the OpenBOR port uses. Not yet published for
> Solarus; manual install is the supported route today.

## Adding quests

Solarus quests are individually licensed and supplied separately (most free ones
are direct downloads from solarus-games.org). To add one:

1. Package the quest's `data/` directory into a single-file `.sol` archive (a
   `.sol` IS a Solarus `data.solarus` archive — a zip of the quest's `data/`
   contents). The repo ships `scripts/package_quest.sh` for this:
   ```
   scripts/package_quest.sh /path/to/quest mystery_of_solarus_dx.sol
   ```
2. Copy the `<name>.sol` into `/media/fat/games/Solarus/quests/`.
3. Load the Solarus core, then pick the quest from the MiSTer OSD (**Load Quest**).

Recommended first quest: **The Legend of Zelda: Mystery of Solarus DX** (free, by
the Solarus team).

## Controls

| Button         | Action            |
|----------------|-------------------|
| D-pad / Analog | Move              |
| A / B          | Action / Sword    |
| X / Y          | Items             |
| Start          | Pause menu        |
| Select         | Map / inventory   |
| Menu button    | MiSTer OSD menu   |

Remap from the MiSTer OSD (press F12 or the OSD button on your IO board).
Controller input is read directly from the FPGA via the shared DDR3 joystick
interface (no SDL/evdev). Saves are written to `/media/fat/saves/Solarus/`.

## FPGA Technical Details

- Resolution: 320×240 active, RGB565 (16 bpp), on-chip (BRAM) framebuffer
- Rendering: the engine emits ~32-byte blit commands into a DDR3 command ring;
  the FPGA compositor (`comp_pipeline`) executes them — fills, sprite blits,
  color-key, per-pixel/const alpha, add/multiply blends — one pixel per clock
- Assets: quest sprite/tile atlases are staged once into the SDRAM expansion
  board at quest load and sourced from there by the compositor
- Audio: 48 kHz stereo S16 PCM via DDR3 ring buffer → I2S/SPDIF/DAC
- Input: per-player 32-bit joystick bitmask written by the FPGA to DDR3
- The Solarus FPGA core is **forked from MiSTer_OpenBOR** (shared DDR3
  audio/joystick interface) with the compositor, SDRAM subsystem (jtframe), and
  branded `CONF_STR` (setname `Solarus`, `Load Quest` `.sol` slot) added

## Build Notes

Solarus 1.6.5 cross-compiled for the ARM Cortex-A9 (armhf) with **no OpenGL/GLEW**
(shaders unavailable, which is fine — almost no quests need them). A custom
`MisterBlitterRenderer` backend replaces per-pixel software compositing with
FPGA blit commands. Audio routes Solarus' OpenAL through an OpenAL-soft loopback
device, pumped per-frame into the DDR3 audio ring. Built with NEON flags
(`-mcpu=cortex-a9 -mfpu=neon`) and LuaJIT for the quest scripting.

## Credits

- **Solarus Team** (Christopho et al.) — the [Solarus engine](https://www.solarus-games.org)
  and Mystery of Solarus DX
- **SumolX** — the [original MiSTer OpenBOR port](https://github.com/SumolX/MiSTer_OpenBOR),
  whose DDR3 audio/joystick RTL this core is forked from
- **Jotego** — the jtframe SDRAM controller/cache subsystem
- **Sorgelig & the MiSTer community** — the MiSTer FPGA framework

## License

GPL-3.0. The Solarus engine is GPLv3. Quest data is separately licensed by its
authors and is not included.
