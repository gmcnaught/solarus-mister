# Solarus — MiSTer FPGA (software rendering, direct framebuffer)

Port of the **Solarus** 2D action-RPG engine (the Zelda-like engine behind
*Mystery of Solarus DX*, *Ocean's Heart*, *Yarntown*, etc.) to **MiSTer FPGA**,
rendering entirely in software and writing frames directly to the MiSTer DDR
framebuffer — the same `NativeVideoWriter` sink (`0x3A000000`) used by the
gmloader blitter, but with **no OpenGL / no Mesa** anywhere in the path.

## Why Solarus is the target

Best "build-once, unlock-many" engine on the PortMaster no-GL shortlist
(`misterfpga-nogl-engines` memory): one engine build unlocks **13 PortMaster
quests**, all free/fan-made 2D Zelda-likes at ~320×240 — ideally sized for the
DE10-Nano's Cortex-A9. Unlike GameMaker/gmloader, Solarus has a **first-class
software renderer**, so it sidesteps the render-performance problem that path is
stuck on.

## Verified: Solarus has a real no-GL path (the gating risk, retired)

From Solarus 1.6 source (`src/graphics/Video.cpp`, `.../sdlrenderer/SDLRenderer.cpp`):

- CLI flag **`-force-software-rendering`** → window created **without**
  `SDL_WINDOW_OPENGL`; shaders disabled; renderer chain skips `GlRenderer`.
- `SDLRenderer` uses **`SDL_CreateRenderer(..., SDL_RENDERER_SOFTWARE)`** and sets
  `SDL_HINT_RENDER_DRIVER=software`.
- Windowless path renders into a CPU **`SDL_Surface` (`software_screen`)** via
  **`SDL_CreateSoftwareRenderer`** — i.e. the whole game composites into a
  system-memory RGB buffer we control.
- `SDL_RenderPresent` is the single hook point.

→ Integration is identical in spirit to the blitter: at present time, take the
`software_screen` pixels, format-convert, and DMA to MiSTer DDR. See `CLAUDE.md`.

## How a Solarus game runs

`solarus-run path/to/quest.solarus` — the engine is a shared runtime; each game
is a `.solarus` file (a zip of the quest's data + Lua scripts). Quest data is
supplied separately (most are free downloads). First target: **The Legend of
Zelda: Mystery of Solarus DX** (free official demo game by the Solarus team).

## Build approach

Cross-compile Solarus 1.6.5 for **armhf** reusing the Docker arm toolchain from
`../epic-mister-sdl-buffer-output`, **without** OpenGL/GLEW (software only), and
patch the SDL renderer to emit frames to DDR. Engine deps: SDL2, SDL2_image,
SDL2_ttf, Lua/LuaJIT, OpenAL, vorbis/ogg, modplug, physfs.

## Status

**Phase 1 complete** — `solarus-run` cross-builds cleanly for armhf
(`scripts/build_engine.sh`), with **no OpenGL/GLEW/Mesa runtime dependency** (GL
renderer compiled out; SDL software path only). Next: headless boot (Phase 2) +
DDR present-hook (Phase 3). See `CLAUDE.md` phases.
