# Per-quest controller mapping — HW validation

**Date:** 2026-07-26
**Result:** PASS (operator-confirmed, all three quests)
**Branch:** `chore/remove-mangled-fps-script` — PR #153
**Spec:** `docs/superpowers/specs/2026-07-25-per-quest-controller-mapping-design.md`

## What was deployed

- **Engine** `solarus-run` sha1 `fb9d2f1fc397`, `libsolarus.so.1.6.5` sha1
  `ca3331a29aba0af658ea984f704d439de38e6aa2` (built via
  `scripts/docker_run.sh scripts/build_engine.sh`).
- **Core** `Solarus_20260726.rbf` sha1 `37e1f872b4e6`, built in CI
  (`.github/workflows/build-rbf.yml`, run 30189062099). Timing clean — all setup slacks
  positive, worst `+0.082ns` on `pll_hdmi`, TNS `0.000` on every clock. The `CONF_STR`
  change is string-only, so this is the expected no-impact result.
- **Config** `controls.cfg.default` sha1 `82c988151d6c`; `controls.cfg` seeded on the
  device (did not previously exist).
- All 28 runtime libs re-staged and sha1-verified.

Deploy was `./deploy.py`, sha1-verified stage-and-swap throughout, loader probe and
`ldd` GL check both clean.

## Operator gate — PASS

The operator loaded the new core, re-ran OSD **Define buttons** (mandatory: the `J1`
rename invalidates any existing `Solarus_input.map`), and reported **all quests work**.

Per project rule, the visual/behavioral result is the operator's, never self-declared.

## Objective corroboration

No `[MiSTer input]` startup banner was captured: by the time the log was fetched the
device had returned to the MENU core, `Solarus.s0` was empty and no engine was running.
Loading cores and picking quests purely to harvest a banner was judged more intrusive
than the evidence warranted.

It is not needed for the load-bearing claim. **Patched Tunics' map, inventory and escape
working is itself proof that per-quest section selection resolved end to end.** Those
three actions map to `l`, `r` and `start`, which are `none` in `[default]`; they can only
do anything if `SOLARUS_QUEST_ID=patched-tunics-b007e656` reached the engine and the
`[patched-tunics-b007e656]` section was applied. Under any failure of that chain — env var
missing, section name mismatch, config not found — those buttons are inert.

Equally, PT's attack works only if the profile supplied `s`; the stock table sends `c`,
which PT ignores.

## What this fixed

| Quest | Before | After |
| --- | --- | --- |
| Patched Tunics | attack unreachable; item buttons dead; pause sent item_2; map/inventory/escape unreachable | all seven actions reachable |
| Zelda ROTH SE | standard commands only; **no way to save** (`keyboard_save="escape"` unmapped) | save on Select, run on L, map on R |
| Mystery of Solarus DX | working | unchanged — regression gate held |

## Verified during this session, worth keeping

- The engine that runs resolves `libsolarus.so.1` from `libs/`, sha1-identical to the
  build. A **stale `libsolarus.so.1.6.5` (Jul 23, sha1 `488f5711…`) sits loose in
  `games/Solarus/`** and is never loaded because `libs/` precedes the gamedir in
  `LD_LIBRARY_PATH`. Harmless today; worth deleting so it cannot mislead a future debug
  session.
- `deploy/` held **Jul 23** artifacts before this deploy. `deploy.py` ships from `deploy/`,
  not `build/armhf`, so deploying without refreshing would have silently shipped the old
  engine and the feature would have appeared not to work. Refreshed and sha1-matched
  before deploying. See `fpga-deploy-refresh-from-build-armhf`.

## Not covered

- Only the three quests on the device were exercised. Any other quest is covered solely by
  `[default]` (stock Solarus keyboard bindings) and is unverified on hardware.
- ROTH's three remaining quest-private commands — `monsters` (`m`), `look`
  (`left control`), `commands` (`f1`) — are unmapped for lack of spare pad inputs and were
  not tested. Note `SDL_GetKeyFromName("left control")` does **not** resolve (SDL spells it
  `Left Ctrl`), so promoting `look` later needs that name corrected.
- The `SOLARUS_INPUTDBG=1` per-edge trace was not exercised on hardware.
- Long-session soak, and behavior across quest switching, were not tested.
