# Solarus-MiSTer environment variables

Every tunable the port reads from the environment, grouped by when it takes
effect. Most are read once at startup (`std::getenv`) in the patched engine; a
few are build-time knobs read by `scripts/build_engine.sh`. The launch scripts
(`games/Solarus/solarus_run.sh`, called by `quest_manager.sh` and
`Scripts/Solarus.sh`) set the defaults a normal boot uses.

Flag conventions:

- **default-ON (opt-out)** — unset, or any value not starting with `0`, means ON;
  set `=0` to disable (`mister_flag_default_on()`). The HW-validated performance
  levers are baked in this way so a normal boot needs no flags.
- **presence-based (opt-in)** — setting it to anything (`=1`) turns it on;
  leaving it unset turns it off.
- **value** — parsed as an integer.

To set flags without editing the launch script, drop a `diag.env` file in
`/media/fat/games/Solarus/` — one `NAME=value` per line; `solarus_run.sh`
sources and exports it after the base environment (absent by default → no-op).

---

## 1. Launch / transport (set by `solarus_run.sh`)

These establish the headless SDL + library environment and pick the render path.
A normal OSD boot sets them for you; override via `diag.env` or by exporting
before a manual launch.

| Variable | Default | Purpose |
|---|---|---|
| `SDL_VIDEODRIVER` | `dummy` | Headless SDL — no X / no `/dev/dri` on MiSTer. Forces the windowless `SDL_CreateSoftwareRenderer` path. Do not change. |
| `LD_LIBRARY_PATH` | `<gamedir>/libs:<gamedir>` | Resolves the shipped `.so` closure (libsolarus, SDL2, LuaJIT, …). |
| `HOME` | `/media/fat/saves/Solarus` | Where Solarus writes per-quest save data (the squashfs root's `/root` is read-only). |
| `SOLARUS_BLITTER` | `1` (unless `SOLARUS_SW`) | Enable the **FPGA compositor** path (`MisterBlitterRenderer` → DDR command ring → fabric). The primary — effectively only — render path. If the renderer can't map DDR it falls back to software. |
| `SOLARUS_BLITTER_SINGLEBUF` | `1` (unless `SOLARUS_SW`) | Engine-side single persistent framebuffer — **required** with the on-chip (BRAM) framebuffer: the compositor writes one WORK buffer and the fabric's vblank snapshot (`fbram_snapshot`) provides the tear-free double-buffer. Do not unset with current cores. |
| `SOLARUS_SW` | unset | Force the legacy pure-software path (plain `SDLRenderer` → RGB565 → DDR via `NativeVideoWriter`). **Produces no video on current cores** — the scanout no longer reads the DDR3 framebuffer. Engine-side debugging only. |
| `SOLARUS_GPROF` | unset | `=1`: set `GMON_OUT_PREFIX` so a `-pg` build's `gmon.out` lands in a writable dir (see `docs/gprof-profiling.md`). Needs a `SOLARUS_GPROF=1` engine build and a clean (non-`kill -9`) exit. |
| `SOLARUS_GMON_DIR` | `/media/fat/logs/Solarus` | Where the gprof `gmon.out.<pid>` files go (with `SOLARUS_GPROF=1`). |
| `SOLARUS_DIAG_LOG` | `/media/fat/logs/Solarus/Solarus.diag.log` | Where engine stdout/stderr is captured when `SOLARUS_BLITTER_DIAG` is set (the daemon launch path otherwise discards it). |

Removed flags you may find in old notes: `SOLARUS_BGCACHE` / `SOLARUS_SCROLLCACHE`
(the background-composite cache diverged the double-buffer's blended layers and
was deleted) and `SOLARUS_SDRAM_SRC` (SDRAM source staging is now hardwired on —
it is the architecture, not an experiment).

---

## 2. Renderer / performance levers (runtime, default **ON**)

Read once when `MisterBlitterRenderer` is constructed (except as noted). All are
HW-validated and baked default-ON; each can be disabled with `=0` for A/B
testing without a rebuild.

| Variable | Purpose (set `=0` to disable) |
|---|---|
| `SOLARUS_TILERESIDENT` | Resident **animated**-tile lists: each map layer's animated tiles are recorded once into a DDR tile-list buffer (`TL_BUF`) and replayed by the fabric as one `BLT_OP_TILELIST` command per layer — camera-independent. Required for animated tiles to render on the fabric path. |
| `SOLARUS_TILESTATIC` | Resident **static**-tile lists: non-animated tiles are emitted directly from the permanent SDRAM atlas via `BLT_OP_TILELIST`, retiring the CPU-side intermediate tile staging. |
| `SOLARUS_PRELOAD` | One-time whole-quest atlas preload into permanent SDRAM at quest load. `=0` falls back to lazy stage-on-first-draw. |
| `SOLARUS_LOADBAR` | Progress bar painted during the preload (so the screen shows load progress instead of uninitialized framebuffer content). |
| `SOLARUS_FASTPACE` | Skip the redundant half-frame vblank-barrier wait in frame pacing. |
| `SOLARUS_IDLEPARK` | Park idle destructibles (bushes, pots, …) out of the per-frame entity walk; wake hooks + an incremental sweep re-activate them. Big win on entity-heavy overworlds. |
| `SOLARUS_AUDIO_THREAD` | Mix audio on a dedicated thread (second core) instead of inline in the frame loop. Auto-disables on single-CPU systems. Read in `mister_native_audio.cpp`. |
| *(opaque blits)* | The opaque-blit fast path (straight copy instead of the premultiplied BLEND compose for known-opaque full-surface draws) is default-ON; disable with `SOLARUS_NO_OPAQUE_BLITS=1`. |
| `SOLARUS_VSYNC_BARRIER` | **Default OFF.** Restores the `ensure_frame` post-handshake vblank barrier (blocks until the reader's `vsync_count` ticks). Retired 2026-07-25 as a Stage-5-Phase-2 vestige: it blocked a full frame before the write it guarded, and Phase 2 had already removed the fabric-side gate (`S_SNAP_WAIT`) for the same hazard because the snapshot writes the inactive DDR3 buffer. Pacing is now the free-running 60 fps cap in `present()`. Escape hatch for tearing regressions. |

Value-based tuning knobs (also runtime):

| Variable | Default | Purpose |
|---|---|---|
| `SOLARUS_CULL_MARGIN` | `64` | Draw-cull margin in pixels around the camera (entities outside camera+margin are not drawn). |
| `SOLARUS_QTREE_MARGIN` | `8` | Quadtree fat-AABB hysteresis margin in pixels — an entity is only re-inserted when it moves outside its inflated stored box (~70% fewer re-inserts). |

---

## 3. Renderer behaviour / compatibility (runtime, default OFF)

Presence-based opt-ins; mostly debugging escapes.

| Variable | Purpose |
|---|---|
| `SOLARUS_IDLESKIP` | Older idle-destructible lever (skip the update call but keep walking the list). Superseded by `SOLARUS_IDLEPARK`; kept for A/B. |
| `SOLARUS_NO_CAMERA_TAG` | Disable camera-region tagging (normally on). Debug. |
| `SOLARUS_NO_VSYNC` | **Deprecated no-op alias** — its effect (no `ensure_frame` vblank barrier) is the default since 2026-07-25. Retained so existing capture scripts keep running. Use `SOLARUS_VSYNC_BARRIER=1` to get the old blocking behaviour back. |
| `SOLARUS_ALIAS_SW` | Allow the software renderer to service aliased/non-accelerated surfaces instead of asserting the blitter path. Compatibility escape hatch. |
| `SOLARUS_BLT_THROTTLE` | Throttle the DDR command-ring submission rate. Diagnostic knob from the command-ring backpressure bring-up. |
| `SOLARUS_BGPLANE` | **Removed in Stage 3b Phase A.** Previously: a per-**layer** background-plane bake, each map layer with static (non-animated) tile content baked ONCE per map/tileset change into its own permanent SDRAM plane (ARGB4444, real per-pixel alpha via the fabric's `bgplane_coverage` tracker), replacing that layer's per-frame `BLT_OP_TILELIST` static replay with one `BLT_BLEND_PALPHA` COPY. It shipped default OFF (flipped off 2026-07-20) because the bake was the confirmed cause of three HW-validated defects — the scroll seam (#122), the transition hitch + bg-colour flash (#127), and probably the scroll black frame (#123) — and was deleted outright rather than fixed; the host-side subsystem, the `SOLARUS_BGPLANE*` env vars, and their callers are gone. The env var is now a no-op if set. The fabric's `bgplane_coverage`/`OP_BGPLANE_WRITE` RTL still physically exists (never issued) and is removed in Phase B — see `docs/frame-dataflow.md`. |

---

## 4. Profiling & diagnostics (runtime, default OFF)

For bring-up, profiling, and automated testing. These add logging / dumps and
should stay off in shipping use.

| Variable | Source | Purpose |
|---|---|---|
| `SOLARUS_BLITTER_DIAG` | renderer | Verbose blitter diagnostics: per-60-frame `[blitter hwperf]` / `[blitter timing]` fabric-vs-A9 attribution (from the fabric's HW counters), command counts, fallbacks. The launch script captures the output to `SOLARUS_DIAG_LOG`. |
| `SOLARUS_BLITTER_TRACE_N` | renderer | Trace the first *N* blit commands of each frame (integer). |
| `SOLARUS_MISTER_PROF` | native video | Per-frame MiSTer-side profiling (present/DMA timing). |
| `SOLARUS_DRAW_PROF` | native video | Draw-call profiling in the SDL draw path. |
| `SOLARUS_NEON_READBACK` | native video | NEON-accelerated surface→RGB565 readback (legacy software path only). |
| `SOLARUS_MISTER_DUMP` | native video | Dump rendered frames for offline inspection. |
| `SOLARUS_INPUT_SCRIPT` | native video | Replay a scripted input sequence — automated / unattended testing. |

---

## 5. Engine build-time (`scripts/build_engine.sh`)

Read by the cross-build, not by the running engine. Control how
`solarus-run` + `libsolarus.so.1.6.5` are produced in the armhf Docker toolchain.

| Variable | Default | Purpose |
|---|---|---|
| `SOLARUS_REF` | `v1.6` | Upstream Solarus branch/tag to build (1.6.5). |
| `SOLARUS_BUILD_DIR` | `build/armhf` | Output directory for the engine + `.so`. |
| `SOLARUS_USE_LUAJIT` | `1` | Link the cross-built armhf LuaJIT 2.1 (HW-validated full JIT on the A9). Set `0` for vanilla Lua 5.1. Run `scripts/build_luajit.sh` first. |
| `SOLARUS_LTO` | `ON` | Link-time optimisation / cross-TU inlining. Forced OFF by `SOLARUS_GPROF=1`. |
| `SOLARUS_GPROF` | `0` | Build with gcc `-pg` mcount instrumentation for gprof (see `docs/gprof-profiling.md`). Never ship an instrumented build. |
| `SOLARUS_PATCH_ONLY` | `0` | Stop after applying the `patches/series/` git patch series (text-only, no compile) — for patch authoring/review. |
| `SOLARUS_CHECK_SDL` | — | Run the SDL sanity check during configure. |

The MiSTer modifications themselves are applied as a git patch series
(`patches/series/*.patch` via `scripts/apply_patch_series.sh`), not by env vars;
per-feature gates are the **runtime** flags in §2.

---

## 6. FPGA build-time (Verilog macro, not an env var)

Passed to Quartus / the sim, not to the engine. Listed here because it's the
HDL counterpart to the runtime debug flags.

| Macro | Default | Purpose |
|---|---|---|
| `SOLARUS_DBG_PROBES` | undefined (off) | Enable the scanout debug probe in `openbor_video_reader.sv` (reader display-side state → `VSYNC_ADDR` high word `0x3A070004`, plus `scan_acc`/`max_dline` tracking). Off ships a clean reader (`0x3A070004 = 0`; the low word `0x3A070000` = engine vsync pacing, which is core). Enable for HW bring-up with `+define+SOLARUS_DBG_PROBES` (sim) or `set_global_assignment -name VERILOG_MACRO SOLARUS_DBG_PROBES` (qsf). |

---

## Quick reference — a normal boot

```sh
# what quest_manager.sh / solarus_run.sh effectively export:
export SDL_VIDEODRIVER=dummy
export LD_LIBRARY_PATH=/media/fat/games/Solarus/libs:/media/fat/games/Solarus
export HOME=/media/fat/saves/Solarus
export SOLARUS_BLITTER=1            # FPGA compositor path
export SOLARUS_BLITTER_SINGLEBUF=1  # single WORK buffer (fabric snapshots at vblank)
./solarus-run -force-software-rendering /tmp/solarus_quest
```

Every performance lever (§2) is default-ON — a normal boot needs nothing else.
To A/B one on hardware, put e.g. `SOLARUS_IDLEPARK=0` in
`/media/fat/games/Solarus/diag.env` and relaunch.
