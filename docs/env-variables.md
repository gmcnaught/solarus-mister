# Solarus-MiSTer environment variables

Every tunable the port reads from the environment, grouped by when it takes
effect. Most are read once at startup (`std::getenv`) in the patched engine; a
few are build-time knobs read by `scripts/build_engine.sh`. The launch scripts
(`games/Solarus/solarus_run.sh`, called by `_handler.sh` and `Scripts/Solarus.sh`)
set the defaults a normal boot uses.

Unless noted, a runtime flag is **presence-based**: setting it to anything
(`=1`) turns it on; leaving it unset turns it off.

---

## 1. Launch / transport (set by `solarus_run.sh`)

These establish the headless SDL + library environment and pick the render path.
A normal OSD boot sets them for you; override by exporting before launch.

| Variable | Default | Purpose |
|---|---|---|
| `SDL_VIDEODRIVER` | `dummy` | Headless SDL — no X / no `/dev/dri` on MiSTer. Forces the windowless `SDL_CreateSoftwareRenderer` path. Do not change. |
| `LD_LIBRARY_PATH` | `<gamedir>/libs:<gamedir>` | Resolves the shipped `.so` closure (libsolarus, SDL2, LuaJIT, …). |
| `HOME` | `/media/fat/saves/Solarus` | Where Solarus writes per-quest save data. |
| `SOLARUS_SW` | unset | Force the **pure software path** (plain `SDLRenderer` → RGB565 → DDR via `NativeVideoWriter`). When set, the launch script does **not** enable the blitter. Transitional fallback only. |
| `SOLARUS_BLITTER` | `1` (unless `SOLARUS_SW`) | Enable the **FPGA-accelerated compositor** path (`MisterBlitterRenderer` → DDR command ring → fabric). The primary path. If the renderer can't map DDR it falls back to software. |
| `SOLARUS_BGCACHE` | `1` (unless `SOLARUS_SW`) | Cache static background layers so unchanged tiles aren't re-blitted every frame. On by default with the blitter. |

---

## 2. Blitter / renderer behaviour (runtime, `mister_blitter_renderer.cpp`)

Read once when `MisterBlitterRenderer` is constructed. These tune *how* the
FPGA compositor path behaves; all default OFF unless the launch script sets them
(§1).

| Variable | Default | Purpose |
|---|---|---|
| `SOLARUS_SCROLLCACHE` | off | Enable the scroll cache (`d->scroll_cache`) — reuse a cached scrolled background across frames instead of recompositing. |
| `SOLARUS_SDRAM_SRC` | off | Stage source atlases DDR3→SDRAM and composite at `C_SRCSEL=1`. **Default OFF is the HW-proven render path** (sources stay in DDR3, `C_SRCSEL=0`); with the jtframe SDRAM-cache FB the framebuffer is in SDRAM either way, so this only selects the *source* path. Opt-in for experimentation. See `[#39]`. |
| `SOLARUS_NO_CAMERA_TAG` | off (tagging on) | Disable camera-region tagging (`d->camera_tag`). Tagging is normally on; set this to turn it off for debugging. |
| `SOLARUS_NO_VSYNC` | off (pacing on) | Disable engine vsync pacing. Normally the engine paces to the reader's `vsync_count` (`0x3A070000`); set this to free-run (diagnostic — can tear / over-produce). |
| `SOLARUS_ALIAS_SW` | off | Allow the software renderer to service aliased/!accelerated surfaces instead of asserting the blitter path. Compatibility escape hatch. |
| `SOLARUS_BLITTER_SINGLEBUF` | off | Force single-buffered framebuffer (no double-buffer ping-pong). Diagnostic — exposes tearing / partial frames. |
| `SOLARUS_BLT_THROTTLE` | off | Throttle the DDR command-ring submission rate (`[#34]`). Diagnostic knob from the command-ring backpressure bring-up. |
| `SOLARUS_OPAQUE_BLITS` | off | Treat fully-opaque blits as copies (skip the per-pixel alpha RMW). Throughput optimisation; off until validated per-quest. |

---

## 3. Profiling & diagnostics (runtime)

Off by default; for bring-up, profiling, and automated testing. Reading these
adds logging / dumps and should stay off in shipping use.

| Variable | Source | Purpose |
|---|---|---|
| `SOLARUS_BLITTER_DIAG` | renderer | Verbose blitter diagnostics (command counts, fallbacks, surface decisions). |
| `SOLARUS_BLITTER_VERIFY` | renderer | Cross-check FPGA blit output against a CPU reference (slow; correctness debugging). |
| `SOLARUS_BLITTER_TRACE_N` | renderer | Trace the first *N* blit commands of each frame (set to an integer). |
| `SOLARUS_MISTER_PROF` | native video | Per-frame MiSTer-side profiling (present/DMA timing). |
| `SOLARUS_DRAW_PROF` | native video | Draw-call profiling in the SDL draw path. |
| `SOLARUS_NEON_READBACK` | native video | Use the NEON-accelerated surface→RGB565 readback (software path). |
| `SOLARUS_MISTER_DUMP` | native video | Dump rendered frames (path / enable) for offline inspection. |
| `SOLARUS_INPUT_SCRIPT` | native video | Replay a scripted input sequence — automated / unattended testing. |

---

## 4. Engine build-time (`scripts/build_engine.sh`)

Read by the cross-build, not by the running engine. Control how
`solarus-run` + `libsolarus.so.1.6.5` are produced in the armhf Docker toolchain.

| Variable | Default | Purpose |
|---|---|---|
| `SOLARUS_REF` | `v1.6` | Upstream Solarus branch/tag to build (1.6.5). |
| `SOLARUS_BUILD_DIR` | `build/armhf` | Output directory for the engine + `.so`. |
| `SOLARUS_USE_LUAJIT` | `1` | Link the cross-built armhf LuaJIT 2.1 (HW-validated full JIT on the A9). Set `0` for vanilla Lua 5.1. Run `scripts/build_luajit.sh` first. |
| `SOLARUS_LTO` | `ON` | Link-time optimisation / cross-TU inlining (`[#26]`). |
| `SOLARUS_CHECK_SDL` | — | Run the SDL sanity check during configure. |
| `SOLARUS_OPAQUE_BLITS` / `SOLARUS_NO_OPAQUE_BLITS` | — | Compile-time gate for the opaque-blit fast path (paired with the §2 runtime flag). |
| `SOLARUS_CULL_MARGIN` | — | Off-screen cull margin baked into the build. |

---

## 5. FPGA build-time (Verilog macro, not an env var)

Passed to Quartus / the sim, not to the engine. Listed here because it's the
HDL counterpart to the runtime debug flags.

| Macro | Default | Purpose |
|---|---|---|
| `SOLARUS_DBG_PROBES` | undefined (off) | Enable the scanout debug probe in `openbor_video_reader.sv` (reader display-side state → `VSYNC_ADDR` high word `0x3A070004`, plus `scan_acc`/`max_dline` tracking). Off ships a clean reader (`0x3A070004 = 0`; the low word `0x3A070000` = engine vsync pacing, which is core). Enable for HW bring-up with `+define+SOLARUS_DBG_PROBES` (sim) or `set_global_assignment -name VERILOG_MACRO SOLARUS_DBG_PROBES` (qsf). See `[#39]`. |

---

## Quick reference — a normal boot

```sh
# what _handler.sh / solarus_run.sh effectively export:
export SDL_VIDEODRIVER=dummy
export LD_LIBRARY_PATH=/media/fat/games/Solarus/libs:/media/fat/games/Solarus
export HOME=/media/fat/saves/Solarus
export SOLARUS_BLITTER=1      # FPGA compositor path (primary)
export SOLARUS_BGCACHE=1      # background-layer cache
./solarus-run -force-software-rendering /tmp/solarus_quest
```

Force the transitional software path instead:

```sh
SOLARUS_SW=1 ./solarus-run -force-software-rendering <quest>
```
