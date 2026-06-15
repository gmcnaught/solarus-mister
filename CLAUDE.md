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
1. **[DONE] Engine build, armhf.** `scripts/build_engine.sh` in
   `solarus-armhf-build:bullseye` → `build/armhf/solarus-run` +
   `libsolarus.so.1.6.5`. All :armhf deps resolved from apt. **No libGL/GLEW
   DT_NEEDED** (libgl-dev not installed → find_package(OpenGL) empty → GL
   renderer compiled out). DT_NEEDED: SDL2/image/ttf, openal, physfs,
   vorbis(file), modplug, libluajit-5.1.so.2, pthread/stdc++/m/gcc_s/c. **LuaJIT is
   now the default** (issue #26): `scripts/build_luajit.sh` cross-builds armhf LuaJIT
   2.1 into `build/luajit-armhf`; `build_engine.sh` defaults `SOLARUS_USE_LUAJIT=1`
   (set =0 for vanilla Lua 5.1). HW-validated full JIT on the A9 (`jit.status()=true
   ARMv7 VFPv3`); ~20-30% A9 win in gameplay (gameplay Lua is C-API-bound so it's
   short of the title's 4.5x — does not alone reach 60fps). Ship `libluajit-5.1.so.2`
   in libs/. Original notes:
   Cross-compile Solarus 1.6.5 in the epic Docker arm
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

## Deploy recipe (end-user SD-mirror, task 007 — VALIDATED on HW 2026-06-12)

The repo IS the MiSTer SD-mirror tree (extracts to `/media/fat/`), modeled on
MiSTer_OpenBOR. End-user model: load the **Solarus** core from the MiSTer OSD →
Master_Daemon (Frontier) routes by CORENAME → runs `games/Solarus/_handler.sh` →
engine auto-launches; pick a quest from the native OSD file browser.

Layout (committed parts in **bold**; the rest are gitignored ship artifacts):
- `_Other/Solarus_YYYYMMDD.rbf` — branded core (CONF_STR setname=Solarus, `SC0,SOL`
  Load-Quest slot). Built in CI; `gh run download <id> -n solarus-rbf`. NOT committed.
- `games/Solarus/solarus-run` + `libs/` — engine + .so closure. Refresh from
  `build/armhf/{solarus-run,libsolarus.so.1.6.5}`. NOT committed.
- **`games/Solarus/_handler.sh`** — Master_Daemon auto-launch dispatcher.
- **`games/Solarus/solarus_run.sh`** — shared launch logic (env + quest resolve +
  exec), called by BOTH the handler and the Scripts launcher.
- `games/Solarus/quests/<name>.sol` — quests. NOT committed.
- **`scripts/Solarus.sh`** → deploys to `/media/fat/Scripts/Solarus.sh` (manual
  launcher: load_core + run shared logic).
- **`docs/Solarus/README.md`**, **`version.txt`**, **`README.md`**.

Quest packaging: a `.sol` IS a `data.solarus` archive = a zip of the quest's
`data/` CONTENTS (quest files at the zip ROOT, NOT under a `data/` prefix; MiSTer
OSD filters the 3-char `SOL` extension). `scripts/package_quest.sh <quest_dir>
[out.sol]`. `solarus-run` needs a quest DIRECTORY, so the handler indirects:
`ln -sf <picked.sol> /tmp/solarus_quest/data.solarus` then
`exec ./solarus-run -force-software-rendering /tmp/solarus_quest`.

Quest selection: the OSD writes the picked path to `/media/fat/config/Solarus.s0`
(may have trailing `\r`/junk — trim CR and cut at the first `.sol`). The handler
reads it; with no selection it falls back to the first `*.sol` (then first quest
DIR) in `quests/`.

Launch env: `SDL_VIDEODRIVER=dummy`, `LD_LIBRARY_PATH=<gamedir>/libs:<gamedir>`,
flag `-force-software-rendering`.

`./deploy.py [--no-rbf] [--host IP]` pushes the tree over SSH (key-authed; plain
ssh/scp/tar, no paramiko). **Device gotchas (learned):** busybox has **no
`pkill`** (use `kill -9 $(pidof solarus-run)`); FAT **can't overwrite an open
exe** in place (rm the old binary first, AND a partial scp leaves a truncated
file — verify sha1 after upload); FAT can't chown (busybox `tar -xof`, macOS
`tar --no-xattrs --no-mac-metadata` to avoid `._` AppleDouble files); **FAT is
CASE-INSENSITIVE** so `games/solarus` == `games/Solarus` (setname capital-S merges
with any old lowercase install — no separate dir).

HW validation 2026-06-12: core load → CORENAME=Solarus; `_handler.sh` fired;
both s0-pick and quests/ fallback paths resolved; engine booted ("Opening quest
'/tmp/solarus_quest'", "Quest format: 1.6"); video frame counter (`0x3A000000`)
advancing; audio ring (`0x3A000030`/`0x38`) flowing+wrapping ("Connected to audio
device 'Loopback'"); joypad enabled; live title-screen screenshot captured.

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
