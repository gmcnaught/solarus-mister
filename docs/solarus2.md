# Solarus 2.x — test option

A **second, opt-in engine line** alongside the shipping Solarus 1.6.5 build. It
replaces nothing: `scripts/build_engine.sh`, `deploy.py`, `patches/series/` and the
RBF pairing are all untouched, and a device that never sets `SOLARUS_ENGINE=2`
never runs a line of this.

Upstream pin: **v2.1.0** (`09d45b3c40ab08388eee29e285903e8e3b90a4cc`), set in
`scripts/lib/patch_common.sh` as `SOLARUS2_REF` / `SOLARUS2_SHA`.

## What it is now

The 2.x build **is offloaded to the FPGA**: `scripts/build_engine2.sh` applies
`patches/series2/` (the 2.x MiSTer series) plus the shared whole-file additions in
`patches/mister/`, so `MisterBlitterRenderer` is the active renderer and the fabric
composites the frame exactly as it does on the 1.6 line.

| | 2.x fabric build |
|---|---|
| cross-builds armhf against our lean SDL2 + LuaJIT | yes |
| links with no `libGL`/`libGLEW`/`libEGL` `DT_NEEDED` | yes, asserted by the build |
| boots, loads an OSD-picked quest, runs game logic | yes |
| **video — FPGA compositor** | **yes: blitter renderer, tile channels, overlay, sprite channel** |
| DDR3 audio ring (OpenAL loopback) | yes |
| controller input, OSD restart, FPS overlay | yes |
| the 1.6 **perf** series (patches 0003–0036) | **no — deliberately not ported** |

`SOLARUS2_STOCK=1` still builds pristine upstream with no patch phase, for
measuring or bisecting against stock. **That build renders nothing** — it is the
old behaviour of this line, kept as a reference leg.

### Why the perf series is not ported

Patches 0003–0036 of the 1.6 series are perf levers whose *defaults were set by HW
validation against 1.6.5's engine behaviour*. 2.x has its own changes in exactly
those areas (`Entities`, `Quadtree`, `LuaContext`, `Camera`, `Entity`), so their
measured wins do not transfer. Porting them unmeasured would ship a set of
default-ON levers nobody has evidence for. Get a frame rate first, then measure.

Concretely: expect the 2.x fabric build to be **slower than the 1.6 ship build**,
because none of the A9-side work (draw cull, DRAWCACHE, STATICPARK, ground cache,
LuaContext field cache, …) is in it — the fabric does the pixels either way, but
the A9 does more work per frame.

## Why the 2.x line has its own series

The 46 patches in `patches/series/` are authored against pristine 1.6.5 and cannot
apply to 2.x. This is not a matter of fuzz:

- `src/main/Main.cpp`, which patch 0001 touches, **no longer exists** — the CLI
  moved to `cli/src/main.cpp` behind a `SOLARUS_CLI` option.
- The files the series leans on hardest have all drifted heavily:
  `src/core/MainLoop.cpp` (+151 lines), `src/entities/Entities.cpp` (+188),
  `src/graphics/Video.cpp` (+68), `src/core/Game.cpp` (+373).
- The `Renderer` interface changed: `create_texture()` gained a `margin` argument
  and a new pure-virtual `notify_target_changed()` appeared.
- The build system was rewritten into `cmake/Add*.cmake` modules.

So `patches/series2/` **re-derives** the picture-critical hooks against the 2.x
tree — six patches instead of forty-six, because it carries only the hooks the
renderer needs, not the perf work. Authoring flow mirrors the 1.6 line:

```bash
scripts/apply_patch_series2.sh          # pristine 2.x -> git am series2 -> copy patches/mister
cd work/solarus2 && $EDITOR ... && git commit -am "feat: ..."
scripts/export_patches2.sh              # regenerate patches/series2/
```

## The 2.x deltas that actually mattered

Three, and they are worth knowing before you touch this:

1. **The camera scroll moved into a per-surface `View`.** In 1.6 the engine
   subtracted the camera top-left itself, so every rect reaching the renderer was
   already screen-relative. In 2.x `Map::draw` calls `camera->apply_view()`,
   entities draw in **map** coordinates, and `SDLRenderer::draw` subtracts
   `view.center - size/2` at blit time. The fabric path bypasses that, so
   `mister_blitter_renderer.cpp` mirrors the subtraction in
   `mister_dst_view_offset()` — the **only** `SOLARUS_MAJOR_VERSION >= 2` switch
   in the shared renderer. Get this wrong and the map composites at map
   coordinates and the camera never appears to move.
2. **Multiple maps and multiple cameras.** `Game::draw` iterates `current_maps`
   and `cameras`; the per-camera draw moved into `Map::draw` and the transition
   moved onto the `Camera`. So the camera/background publication hooks live in
   `Map::draw` (per camera, after `apply_view()`), and the transition publication
   lives at the top of `Game::draw` — it must run **before** any map is drawn,
   because `resident_begin_frame()` branches on it.
3. **The root surface is rebuilt on resize.** `MainLoop::make_root_surface()` can
   recreate it, so `mister_tag_root_surface()` is called there rather than once in
   the constructor as on 1.6.

Everything else the renderer depends on — `DrawInfos`, `Color`, `Rectangle`,
`Point`, `Surface`, `SurfaceImpl`, `Tileset`, `ResourceProvider` — drifted by
almost nothing, which is why `mister_blitter_renderer.cpp` (4.8k lines) compiles
against both engine lines from one copy.

## Quest compatibility — 1.6 quests run on 2.x

Verified in upstream `src/core/MainLoop.cpp`, `check_version_compatibility()`:
quests declaring Solarus 1.5 or 1.6 are accepted by a 2.x engine (only quests
below 1.5, or newer than the engine, are rejected). Mystery of Solarus DX ships a
1.6 `quest.dat`, so the same `.sol` the shipping engine runs is the one this build
runs — no separate quest packaging, and a genuine like-for-like comparison.

## Dependencies — one real difference from 1.6

Everything the 1.6 build needs, 2.x needs too (GLM is already in
`Dockerfile.solarus-build`; `glad`, `hqx` and `snes_spc` are vendored in
`third_party/`). The one new constraint:

> **Solarus 2.x requires SDL2 >= 2.0.18. Bullseye's `libsdl2-dev:armhf` is
> 2.0.14.**

So the lean from-source SDL2 (`scripts/build_sdl2.sh`, 2.28.5) is **mandatory**
here, where for the 1.6 build it is merely strongly preferred. There is no
`SOLARUS_ALLOW_STOCK_SDL2` escape hatch on this path — `build_engine2.sh` checks
for the prefix up front and fails with that explanation, because the raw CMake
failure ("Could NOT find SDL2: found unsuitable version") is a confusing way to
learn it.

Note also that 2.x **always compiles** `src/graphics/glrenderer/*` (they are
unconditional in `SolarusLibrarySources.cmake`, where 1.6 compiled the GL
renderer out when OpenGL was absent). That is fine: it reaches GL through the
vendored `glad` loader, which resolves entry points at runtime via
`SDL_GL_GetProcAddress`, and `find_package(OpenGL)` is not `REQUIRED` — so with
no `libgl-dev` in the image nothing links `OpenGL::GL` and the binaries carry no
GL `DT_NEEDED`. `GlRenderer` is simply never constructed under
`-force-software-rendering`. Both `build_engine2.sh` and CI assert this, so if it
ever stops being true you find out at build time, not on a black device.

## Recipe

Build (inside the armhf cross image; each step is a separate `docker run` so a
failure is attributable):

```bash
docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
scripts/docker_run.sh scripts/build_sdl2.sh      # MANDATORY here (>= 2.0.18)
scripts/docker_run.sh scripts/build_luajit.sh    # unless SOLARUS2_USE_LUAJIT=0
scripts/docker_run.sh scripts/build_engine2.sh   # SOLARUS2_STOCK=1 for pristine
```

Artifacts land in `build/armhf-v2/` (`solarus-run`, `libsolarus.so.2.1.0`). The
1.6 tree in `work/solarus` and `build/armhf` is never touched — the 2.x source
lives in `work/solarus2`.

Collect the runtime closure into its own directory:

```bash
SOLARUS_BUILD_DIR=build/armhf-v2 SOLARUS_DEPLOY_LIBS=deploy/v2/libs \
  scripts/docker_run.sh scripts/collect_runtime_libs.sh
```

Deploy — into `/media/fat/games/Solarus/v2/`, touching nothing the shipping
install uses:

```bash
scripts/deploy_engine2.sh [--host 192.168.20.81]
```

Select it at launch by adding one line to `/media/fat/games/Solarus/diag.env`:

```
SOLARUS_ENGINE=2
```

Then load the Solarus core and pick a quest as usual. `solarus_run.sh` will exec
`v2/solarus-run` with `v2/libs` first on `LD_LIBRARY_PATH` and export the same
blitter flags as the 1.6 engine.

> **The RBF still pairs with the ENGINE, not the line.** The fabric ABI
> (`OFF_HEAP`, the command ring layout, the wire opcodes) is shared, so the 2.x
> engine needs the *same current RBF* as the 1.6 ship build. Deploying a 2.x
> engine next to a stale bitstream fails exactly the way CLAUDE.md describes for
> the 1.6 line: atlases fetched from the wrong base, silently garbage tiles.

If you deployed a **stock** build (`SOLARUS2_STOCK=1`), add this too:

```
SOLARUS_ENGINE2_STOCK=1
```

which skips the blitter exports (nothing is driving the fabric) and always
captures stdout/stderr to `/media/fat/logs/Solarus/Solarus.diag.log` — that log is
your only instrument on a build that draws nothing.

Back out with `rm -rf /media/fat/games/Solarus/v2` and drop the diag.env line.
There is no shipping state to restore, which is the point of the split.

`deploy.py` deliberately knows nothing about any of this: the real install and
the experiment do not share a code path, so a 2.x session cannot brick a working
device.

## Bumping the pin

Change `SOLARUS2_REF` / `SOLARUS2_SHA` together in
`scripts/lib/patch_common.sh`, then re-run `scripts/apply_patch_series2.sh` and
fix whatever the `git am --3way` rejects. Unlike the 1.6 line there is no
round-trip gate wired into CI yet, so re-export (`scripts/export_patches2.sh`)
and check the diff by eye.

## Not yet done

Recorded so the remaining size is not a surprise:

1. **HW validation.** Nothing here has run on the device. The port type-checks
   against both engine trees and cross-builds in CI; the picture, the tile
   channels, the scroll transition and the overlay are all *expected* to work by
   construction, not observed. Every claim in this file about 2.x rendering is a
   build-time claim until an operator gate says otherwise.
2. **The perf series** (above). Measure on 2.x first; do not port defaults.
3. **`release_test.sh` / `deploy.py` integration.** The 2.x line is still
   deployed by its own script and is not part of an RC.
