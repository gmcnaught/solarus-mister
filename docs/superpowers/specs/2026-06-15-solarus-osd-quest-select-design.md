# Solarus OSD quest select + load — design

**Date:** 2026-06-15. **Status:** designed, not started. **Productionization feature 2 of 3**
(feature 3 = core-change exit watcher, merged; feature 1 = OSD control remap, deferred).

## Problem / goal

Match the PICO-8 / OpenBOR / PSX pattern: **the core loads with no game; a quest loads
only when selected from the OSD.** Two gaps today:

1. **Launch-time OSD selection is broken.** `Solarus.s0` holds a path relative to
   `/media/fat` (e.g. `games/Solarus/quests/mystery_of_solarus_dx.sol`), but
   `solarus_run.sh` checks `[ -f "$SEL" ]` while `cd`'d into `GAMEDIR`, so the file is
   never found → it silently **falls back to the first `*.sol`**. The OSD pick is ignored;
   it only appears to work because there's one quest.
2. **No "no game until selected" behavior, and no live switching.** Today a quest always
   auto-loads on core start, and re-picking in the OSD while running does nothing.

Goal: core load → black/idle (no engine) until a quest is picked from the OSD; on a valid
pick the engine launches on it; re-picking a different quest reloads it; no auto-load
fallback; works on both the Frontier handler path and the manual Scripts path.

## Architecture

A lifecycle manager process owns the engine; the engine never runs until a quest is selected.

```
core load ─> quest_manager.sh (poll Solarus.s0 + /tmp/CORENAME, ~1s)
   no valid pick      -> no engine (black/idle)
   valid NEW pick     -> (kill old engine) launch engine on it
   same pick          -> no-op
   invalid pick       -> ignore (stay idle / stay on current quest)
   CORENAME != Solarus-> kill engine + exit
```

### `quest_manager.sh` (new) — the lifecycle manager
- Launched (foreground/exec) by `_handler.sh` on core load, and by `Scripts/Solarus.sh`
  after `load_core`. Replaces the direct engine launch.
- Loop (~1 s):
  1. If `/tmp/CORENAME` != `Solarus` → kill the engine (if any) and exit.
  2. Resolve the selected quest from `Solarus.s0` via the shared `resolve_quest` helper
     (returns a valid quest file path, or empty if none/invalid).
  3. If a valid quest is selected AND it differs from the currently-loaded one (or no
     engine is running) → kill the old engine, launch the engine on the new quest (via the
     `solarus_run.sh` helper, backgrounded so the manager keeps looping), and record it as
     the loaded quest.
  4. If no valid quest → ensure no engine runs (idle).
- Tracks the engine child PID; debounces `.s0` (validate the picked file exists before
  switching) so a transient/garbage write doesn't thrash.
- Env-overridable (`CORENAME_FILE`, `EXPECT_CORE`, `S0_FILE`, `POLL_SEC`, and an injectable
  launch command) so it's testable off-device.

### `solarus_run.sh` (refactored) — engine-launch helper
- Keep: env (SDL dummy, LD_LIBRARY_PATH, HOME save dir), `data.solarus` indirection,
  `exec ./solarus-run …`, and launching `core_watch.sh` (feature 3) per engine instance.
- **Fix:** `resolve_quest` resolves the `.s0` path against the MiSTer root — try `"$SEL"`
  and `"/media/fat/$SEL"`, use whichever is a real file (keep CR-trim + cut-at-`.sol`).
  Extract this into a `resolve_quest` function in a small sourced helper
  (`games/Solarus/quest_lib.sh`) that BOTH `solarus_run.sh` and `quest_manager.sh`
  `. source`, so there is one correct implementation (and one host-test target).
- **Remove the auto-load fallback** (the "first `*.sol` / first quest dir" defaults). With
  no valid selection, the helper launches nothing. `quest_manager` only invokes it when a
  valid quest is selected, so in practice the helper always gets a valid pick.

### Feature 3 (`core_watch.sh`) — reused as-is
`core_watch` still kills the engine on core change (launched by `solarus_run.sh` per engine
instance, unchanged + tested). `quest_manager` additionally self-exits on core change so it
stops polling `.s0`. The minor redundancy (both glance at `/tmp/CORENAME`) is intentional —
it keeps feature 3 exactly as merged, no rework.

## Behavior / decisions
- **Idle = no engine, black screen.** The OSD is the selection UI (no built-in splash;
  `solarus-run` can't run without a quest). A splash/auto-open-OSD is a possible later
  enhancement, out of scope here.
- **Switch = engine restart** on the new quest (Solarus can't swap quests in-process);
  ~couple-second reload, current unsaved progress lost (deliberate switch).
- **Manual `Scripts/Solarus.sh` also routes through `quest_manager`** (`load_core` then exec
  `quest_manager.sh`), so it follows the same no-game-until-selected behavior — one
  consistent path.
- **Detection signal = `Solarus.s0`** (the framework writes the OSD pick there; same source
  `resolve_quest` already reads). Re-picking the same quest leaves `.s0` unchanged → no-op.

## Edge cases
- Invalid/nonexistent picked path → `resolve_quest` returns empty → ignored (stay idle or
  on the current quest).
- `.s0` absent at core load → idle until a pick.
- Engine exits on its own (quest quit/crash) → manager notices (no child) → returns to idle
  (does NOT auto-reload the same quest, matching "no game until selected"); its `core_watch`
  self-exits.
- Relaunch on switch: kill old engine (+ its `core_watch` self-exits) → fresh
  `solarus_run.sh` (new engine + new `core_watch`).
- busybox shell only (no `pkill`): `pidof`/`kill`.

## Testing
- **Host (off-device):**
  - `resolve_quest`: relative `games/…` path, absolute path, missing file, CR/junk suffix →
    correct resolved path or empty.
  - `quest_manager` dry-run with env-overridable `CORENAME_FILE`/`S0_FILE` + an injectable
    launch command (records invocations): idle while no/invalid selection; launches once on
    first valid pick; relaunches on a changed pick; no-op on same pick; exits on
    `CORENAME` change; returns to idle if the (fake) engine exits.
- **Device:** ≥2 quests installed. Load core → black/idle (no `solarus-run`). Pick quest A
  in OSD → A launches. Pick B → reloads B within ~2 s. Re-pick B → no reload. Switch cores →
  engine + manager exit.

## Out of scope
- Control remap (feature 1).
- A splash / auto-opening the OSD browser on idle.
- In-process quest swapping (restart is the switch mechanism).
- Reworking feature 3's `core_watch` (reused as-is).
