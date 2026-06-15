# Solarus core-change exit — design

**Date:** 2026-06-15. **Status:** designed, not started. **Productionization feature 3 of 3**
(the others: OSD quest switching, OSD control remap — separate specs).

## Problem

`solarus-run` is a normal ARM/Linux process that **survives FPGA reconfiguration**. When the
user loads a different MiSTer core, the Solarus engine keeps running — holding the audio
loopback device, consuming CPU, and writing stale data into DDR regions the new core now
owns. Nothing currently kills it. (OpenBOR/PICO-8 rely on MiSTer **Frontier's Master_Daemon**
to kill the handler's process tree on a core switch; we don't want to depend on Frontier
being installed/active, so we implement our own watcher — "our own handler for now".)

## Goal

When the loaded core changes away from Solarus, terminate `solarus-run` within ~1–2 s,
with no dependency on Frontier/Master_Daemon, and no orphaned watcher processes.

## Architecture

A standalone watcher script, launched detached by the shared launch logic so both launch
paths (Frontier `_handler.sh` and manual `Scripts/Solarus.sh`) get it.

```
_handler.sh ─┐
             ├─> solarus_run.sh ──(detached)──> core_watch.sh   (polls /tmp/CORENAME)
Scripts/     ─┘        │
Solarus.sh            exec ./solarus-run   <── kill -TERM/-9 on core change
```

### New file: `games/Solarus/core_watch.sh`
Reads three env vars (with production defaults) so the script is testable off-device:
`CORENAME_FILE` (default `/tmp/CORENAME`), `EXPECT_CORE` (default `Solarus`),
`TARGET_PROC` (default `solarus-run`). Poll loop (~1 s interval):
1. `pid=$(pidof solarus-run)`; if empty → the engine exited on its own → **watcher exits**
   (no orphans).
2. Read `/tmp/CORENAME`, trim NUL/CR/whitespace.
3. If it equals `Solarus` → continue looping.
4. If it does **not** equal `Solarus`:
   - **debounce**: re-read after ~0.5 s; if still not `Solarus`,
   - `kill -TERM "$pid"`; wait ~1 s; `kill -9 $(pidof solarus-run) 2>/dev/null`;
   - **watcher exits**.

Single-instance: on start, the watcher kills any prior watcher recorded in
`/tmp/solarus_corewatch.pid`, then writes its own PID there.

### Modify: `games/Solarus/solarus_run.sh`
Immediately before `exec ./solarus-run …`, launch the watcher detached so it outlives the
`exec` (which replaces the shell with the engine):
`setsid sh "$GAMEDIR/core_watch.sh" >/dev/null 2>&1 </dev/null &`

No change needed to `_handler.sh` or `Scripts/Solarus.sh` — they both route through
`solarus_run.sh`.

## Behavior / decisions
- **Poll interval ~1 s + ~0.5 s debounce** → ~1–2 s exit latency. Stale DDR writes in that
  window are benign (the incoming core re-inits its DDR regions on boot). Tunable via one
  constant.
- **Exit = SIGTERM → ~1 s grace → SIGKILL.** Solarus does not save on SIGTERM (saves happen
  at in-game save points via Lua), so this loses no more progress than `kill -9`, but is
  cleaner.
- **Detection signal = `/tmp/CORENAME`** (MiSTer's record of the loaded core; reads `Solarus`
  for our core, changes when another core loads). Compared as the literal `Solarus`.

## Edge cases
- Transient empty/half-written `/tmp/CORENAME` during a load → debounce avoids a false kill.
- Engine exits on its own (quest quit / crash) → `pidof` empty → watcher self-exits.
- Relaunch of the engine → the launch path already `kill -9`s the old engine; the new watcher
  also kills any prior watcher via the pidfile → no stacking.
- busybox shell only (no `pkill`): use `pidof` + `kill`.

## Testing
- **Host dry-run** (no HW): run `core_watch.sh` against a fake `/tmp/CORENAME` and a dummy
  long-sleep process named so `pidof` matches (or a parameterized process-name/CORENAME-path
  for the test); assert: stays alive while CORENAME=Solarus; on flipping CORENAME to another
  value the dummy is killed within ~2 s and the watcher exits; flipping then flipping back
  within the debounce window does NOT kill (debounce). Make the CORENAME path + target
  process name overridable via env so the script is testable off-device.
- **On device:** launch the engine; confirm the watcher runs and the engine survives at
  CORENAME=Solarus; `load_core` a different core; confirm `solarus-run` is gone within ~2 s
  and the watcher process exited; relaunch and confirm only one watcher.

## Out of scope
- OSD quest switching (feature 2) and control remap (feature 1) — separate specs.
- Depending on Frontier/Master_Daemon (the OpenBOR mechanism) — explicitly avoided here.
- Save-on-exit (Solarus saves at its own in-game points; not triggered by core change).
