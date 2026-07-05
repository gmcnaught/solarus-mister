# Profile-Guided Optimization (PGO) for the Solarus MiSTer cross-build

PGO feeds the compiler a real execution profile so it can lay out branches,
inline, and order code for the paths that actually run hot. For Solarus on the
Cortex-A9 the wins concentrate exactly where this port spends its A9 budget:

- the **LuaJIT dispatch / fast-function C code** invoked by gameplay scripts,
- the engine's **`Entities::update()` / collision loops**, and
- the **`Quadtree::get_elements` + `shared_ptr` hotspots** already hand-tuned in
  `build_engine.sh` (`[#26]`).

Typical measured gains for this class of workload are ~5–15%. It stacks on top of
the existing LTO (`SOLARUS_LTO`) and the A9/NEON arch flags.

## Why it needs a device round-trip

PGO is inherently three-phase: **instrument → train → optimize**. The training
run has to execute the instrumented binary. Because this is a *cross*-build
(arm64/x86 Docker host producing **armhf**), the instrumented engine can't run on
the build host — it runs on the **DE10-Nano**, and the resulting `.gcda` profiles
are copied back into the build tree before the optimize phase. `scripts/pgo_train.sh`
automates that round-trip.

The instrumented binary bakes in an absolute host path (`$PGO_DIR`, default
`build/pgo-profiles`) as the place to write `.gcda`. That path doesn't exist on
the device, so at runtime `GCOV_PREFIX` / `GCOV_PREFIX_STRIP` redirect the writes
to a device-writable dir; `pgo_train.sh collect` pulls them back and re-stages
them under `$PGO_DIR`, where `-fprofile-use=$PGO_DIR` picks them up.

## Workflow

```bash
# 0. Prereqs: build LuaJIT once, build the image (see CLAUDE.md).
scripts/build_luajit.sh

# 1. INSTRUMENT — build the -fprofile-generate binary.
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  env SOLARUS_PGO=generate scripts/build_engine.sh

# 2. Deploy the instrumented binary to the device.
./deploy.py --no-rbf

# 3. TRAIN — collect a profile. Two options:
#    (a) automated, repeatable headless run (boot + title + intro):
scripts/pgo_train.sh run 90
#    (b) BEST profile — play a quest by hand so real input exercises the hot
#        update/collision loops. Print the env to prepend to a manual launch:
scripts/pgo_train.sh env
#        ...launch + play + quit cleanly, then:
scripts/pgo_train.sh collect

# 4. OPTIMIZE — rebuild consuming the profile.
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  env SOLARUS_PGO=use scripts/build_engine.sh

# 5. Ship the optimized binary.
./deploy.py
```

`run` and `collect` are additive — profiles accumulate across runs, so you can
train several quests / scenarios and merge them. `scripts/pgo_train.sh clean`
wipes both the device and host profile dirs to start fresh.

## Build-script knobs

| Variable | Default | Meaning |
|---|---|---|
| `SOLARUS_PGO` | `off` | `off` / `generate` / `use` — selects the phase. |
| `SOLARUS_PGO_DIR` | `build/pgo-profiles` | Absolute dir holding the `.gcda`; kept **outside** `SOLARUS_BUILD_DIR` so a build-dir wipe between phases doesn't lose the profile. Must be the same value in `build_engine.sh` and `pgo_train.sh`. |

Robustness details baked into the `use` phase (`build_engine.sh`):

- `-fprofile-correction` — tolerates the multithreaded counter races from the
  audio mix thread (`SOLARUS_AUDIO_THREAD`).
- `-fprofile-partial-training` — functions the profile never exercised keep
  normal `-O2` heuristics instead of being pessimized as cold.
- `-Wno-*coverage-mismatch` / `-Wno-missing-profile` — the in-tree source patches
  evolve; a slightly-stale profile degrades gracefully (warn + use what matches)
  rather than failing the build. Regenerate the profile after large source
  changes to recover the full gain.

The `generate` phase adds `-fprofile-update=atomic` so the shared-TU counters
stay correct under the engine's threads.

## Interaction with LTO

Leave `SOLARUS_LTO=ON` (default). GCC applies the profile during the LTO link, so
PGO + LTO compound rather than conflict.

## Scope note — LuaJIT

This wiring drives PGO for the **engine** (`libsolarus` + `solarus-run`), which
contains the update/collision/quadtree hot loops. LuaJIT's *core* interpreter
dispatch is hand-written DynASM **assembly**, which gcc PGO cannot reorder; only
its C portions (libraries, the trace/optimizer C code) would benefit, at a much
higher wiring cost (separate profile round-trip through `build_luajit.sh`). It is
intentionally left out of this first cut; the engine-side profile captures the
Lua↔C call overhead that dominates gameplay Lua on the A9.
