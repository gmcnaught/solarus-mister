# Solarus — MiSTer FPGA

A hybrid ARM+FPGA port of the **Solarus** 2D action-RPG engine for MiSTer FPGA.
Solarus is the open-source engine behind Zelda-like quests such as *The Legend of
Zelda: Mystery of Solarus DX*, *Ocean's Heart*, and *Yarntown*. The engine runs on
the DE10-Nano's ARM Cortex-A9 in **pure software rendering** and writes finished
frames straight to a MiSTer FPGA DDR3 framebuffer — no OpenGL, no Mesa.

## Features

- **Native FPGA video output** — 320×240 RGB565 via DDR3 double-buffer, fed by the
  engine's software renderer (no GPU, no X11)
- **Native FPGA audio** — 48 kHz stereo through a DDR3 ring buffer (OpenAL-soft
  loopback → DDR), no ALSA
- **MiSTer OSD quest picker** — pick a quest with the native MiSTer file browser
  (the core's `Load Quest` slot, `.sol` files)
- **Auto-launch** — the engine starts automatically when you load the Solarus core
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
│       ├── _handler.sh             Master_Daemon auto-launch dispatcher
│       ├── solarus_run.sh          shared launch logic
│       └── quests/                 place your <name>.sol quests here
├── logs/
│   └── Solarus/                    engine logs
└── Scripts/
    └── Solarus.sh                  manual Scripts-menu launcher
```

Then register the auto-launch daemon once (idempotent):

```
Scripts/Install_MiSTer_Frontier.sh
```

Load **Solarus** from the MiSTer console menu — the engine launches automatically.

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
   With no selection, the engine falls back to the first quest in `quests/`.

First target quest: **The Legend of Zelda: Mystery of Solarus DX** (free, by the
Solarus team).

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
interface (no SDL/evdev).

## FPGA Technical Details

- Resolution: 320×240 active, RGB565 (16 bpp)
- Video: DDR3 double-buffer at phys `0x3A000000`, read by the FPGA video reader
- Audio: 48 kHz stereo S16 PCM via DDR3 ring buffer → I2S/SPDIF/DAC
- Input: per-player 32-bit joystick bitmask written by the FPGA to DDR3
- The Solarus FPGA core is **forked from MiSTer_OpenBOR**: it shares the same DDR3
  video/audio/joystick RTL interface. The branded core changes `CONF_STR`
  (setname `Solarus`, `Load Quest` `.sol` slot) so the OSD picker and
  Master_Daemon auto-launch target Solarus.

## Build Notes

Solarus 1.6.5 cross-compiled for the ARM Cortex-A9 (armhf) with **no OpenGL/GLEW**
(software renderer only — shaders unavailable, which is fine). Video goes through
a patched `SDLRenderer::present()` that pushes the engine's `software_screen` CPU
surface (ARGB8888 → RGB565) to DDR3. Audio routes Solarus' OpenAL through an
OpenAL-soft loopback device, pumped per-frame into the DDR3 audio ring. Built with
NEON flags (`-mcpu=cortex-a9 -mfpu=neon`) and LuaJIT for the quest scripting.

## Credits

- **Solarus Team** (Christopho et al.) — the [Solarus engine](https://www.solarus-games.org)
  and Mystery of Solarus DX
- **SumolX** — the [original MiSTer OpenBOR port](https://github.com/SumolX/MiSTer_OpenBOR),
  whose DDR3 video/audio/joystick RTL this core is forked from
- **Sorgelig & the MiSTer community** — the MiSTer FPGA framework

## License

GPL-3.0. The Solarus engine is GPLv3. Quest data is separately licensed by its
authors and is not included.
