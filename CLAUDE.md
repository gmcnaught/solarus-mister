# solarus-mister — porting notes

Port the **Solarus 1.6.5** engine to MiSTer with **pure software rendering** →
direct DDR framebuffer write. Engine-build project (like
`../epic-mister-sdl-buffer-output`), NOT per-game packaging. Device IP
`192.168.20.81`; deploy root `/media/fat/games/solarus/`.

Upstream: `https://gitlab.com/solarus-games/solarus` (GPLv3), tag/branch `v1.6`
(version 1.6.5). API id for raw/tree fetch: project `solarus-games%2Fsolarus`.

## Why this is viable (verified — do not re-litigate)

Solarus has a built-in software renderer; OpenGL is optional (only for shaders).
Evidence in upstream `v1.6`:
- `src/graphics/Video.cpp`: arg `-force-software-rendering` → window WITHOUT
  `SDL_WINDOW_OPENGL`; renderer = `create_chain<GlRenderer, SDLRenderer>` (GL
  first, SDL software fallback); force-software skips GL entirely.
- `src/graphics/sdlrenderer/SDLRenderer.cpp`:
  - `create()`: force_software → `SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER,
    "software", OVERRIDE)` + `SDL_CreateRenderer(window,-1,SDL_RENDERER_SOFTWARE)`.
  - Windowless ctor: `software_screen = SDL_CreateRGBSurface(...)` then
    `renderer = SDL_CreateSoftwareRenderer(software_screen)` → game composites to
    a CPU surface in system memory.
  - `present()` ends with `SDL_RenderPresent(renderer)` — **the DDR hook point**.

## DDR sink (reuse from epic-mister-sdl-buffer-output)

The blitter already writes frames to MiSTer DDR at `0x3A000000` via a
`NativeVideoWriter` (see `../epic-mister-sdl-buffer-output/gmloader/mister/`).
Lift that writer here; it is engine-agnostic (takes a CPU pixel buffer +
WxH + format). Solarus `software_screen` is an `SDL_Surface` (RGBA8888/RGB) at
the quest's native size (usually 320×240) — convert to the DDR format (RGB565 per
`blitter-config-and-launch`/`fps-profiling-shaders` memories) and write.

## Build phases

0. **[DONE] De-risk** — software path confirmed (above).
1. **Engine build, armhf.** Cross-compile Solarus 1.6.5 in the epic Docker arm
   toolchain. CMake: disable OpenGL/GLEW (software only — shaders unavailable, ok).
   Deps to cross-build/provide (all must be armhf, glibc ≤2.31 / focal like the
   Mesa builds): SDL2, SDL2_image, SDL2_ttf, Lua 5.1 or **LuaJIT** (ARM32 ok),
   OpenAL-soft, libvorbis/ogg, libmodplug, physfs. Output: `solarus-run` binary.
   Note PortMaster ships per-game `libmodplug.so.1` + `libphysfs.so.1` — confirms
   those are the dynamic deps to ship.
2. **Headless boot.** No X / no `/dev/dri` on MiSTer. Run SDL2 with the **dummy**
   video driver (`SDL_VIDEODRIVER=dummy`) so the windowless
   `SDL_CreateSoftwareRenderer(software_screen)` path is taken. Goal: engine
   reaches the main loop without a display.
3. **DDR video hook.** Patch `SDLRenderer::present()` (or post-`SDL_RenderPresent`)
   to push `software_screen` → `NativeVideoWriter` (`patches/` holds the diff).
   Verify frames hit DDR: `busybox devmem 0x3A000000` increments.
4. **First quest.** Mystery of Solarus DX (free official). Run
   `solarus-run quests/mystery_of_solarus_dx.solarus`. (Quest data is byo — the
   PortMaster port zip carries only libs + scripts, not the `.solarus`; fetch the
   quest from solarus-games.org. `scripts/fetch_quest.sh`.)
5. **Input + audio.** Map MiSTer controllers (SDL_GameController / the gptk map
   `zmos.gptk` from the port for reference); OpenAL → ALSA.

## Invocation (target)

```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH=/media/fat/games/solarus/libs:. \
  ./solarus-run -force-software-rendering quests/mystery_of_solarus_dx.solarus 2>&1 | tee /tmp/solarus.log'
```

## Perf outlook

Solarus games are 2D tile + sprite blits at ~320×240, no 3D. The SDL software
renderer (`SDL_RENDERER_SOFTWARE`) does CPU surface blits — far cheaper than the
GameMaker softpipe texture-sampling path. Expect this to be CPU-comfortable on the
A9; the Lua quest scripting (LuaJIT) is the variable to watch on script-heavy
quests. This is exactly why Solarus was chosen over GameMaker.

## Asset / licensing

Engine GPLv3. Quests are individually licensed; Mystery of Solarus DX is free
(GPL/CC, by the Solarus team). Keep engine binaries + quest data OUT of git;
`scripts/` re-fetches.
