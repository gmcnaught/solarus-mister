# Solarus self-owned core-load daemon — design

**Date:** 2026-06-16. **Status:** designed. Follows the three productionization features
(remap/quest-select/core-exit, all merged + HW-validated).

## Problem / goal

The Solarus core's ARM-side auto-launch depends on *something* spawning
`games/Solarus/_handler.sh` when the core loads. Today that "something" is **only**
MiSTer Frontier's `Master_Daemon` (`/media/fat/MiSTer_Frontier/Master_Daemon.sh`). The
repo ships no daemon and never touches `user-startup.sh`, so on a system **without
Frontier installed (or with it installed but not started)** nothing fires the handler:
loading the core does nothing, the OSD "Load Quest" pick writes `config/Solarus.s0` but
no engine launches. This bit us 2026-06-16 (Frontier had dropped out of `user-startup.sh`).

Solarus is not part of the Frontier platform, so we cannot assume Frontier is present.
**Goal:** ship our own minimal, Solarus-only daemon that provides auto-launch standalone,
and **defers cleanly to Frontier when Frontier is running** (no double-spawn).

See [[frontier-master-daemon-required]] for the Master_Daemon mechanics this mirrors.

## Architecture

`games/Solarus/solarus_daemon.sh` (new) — a single-core mirror of `Master_Daemon`:
watch `/tmp/CORENAME`, spawn our `_handler.sh` on Solarus, own that child's lifecycle,
and step aside when Frontier is active.

### Loop (~1 s)
1. **Defer check.** If Frontier's `Master_Daemon.sh` is running — detected with
   `ps -o pid,args | grep '[M]aster_Daemon.sh'` (busybox-safe; its `pidof` has no `-x`,
   see [[solarus-osd-quest-select-hw-pending]]) — stay fully passive this tick: spawn
   nothing, own nothing. Re-checked every tick, so we self-heal if Frontier starts/stops.
2. **Otherwise we are the spawner.** Track `CORENAME`:
   - On `Solarus` **and** no `quest_manager.sh` already running (same `ps | grep '[q]uest_manager.sh'`
     guard) → spawn `_handler.sh`, record its PID as our child. The "no manager already
     running" guard dedupes against a Frontier race and against fast re-entry where a prior
     manager still lingers.
   - On transition **away** from Solarus while we own a child → SIGTERM → sleep 1 → SIGKILL
     it. (Safety net only: `quest_manager` self-exits on core change and `core_watch` kills
     the engine; kills are idempotent.)
   - If our child dies while still on Solarus → respawn (crash recovery; mirrors Frontier).

### What we deliberately do NOT mirror from Frontier
- **No `<core>.s0` clearing.** Frontier clears it on entry so re-entry waits for a fresh
  OSD pick; our `quest_manager` already ignores a stale `.s0` via its mtime baseline, so
  replicating the clear is unnecessary.
- **No generic multi-core discovery.** Solarus-only: we don't presume to run other vendors'
  `games/*/_handler.sh` (OpenBOR/PICO-8). That's Frontier's job if installed.

## Boot persistence + activation

- **Self-register (mirrors Frontier):** on first run the daemon idempotently appends
  `bash /media/fat/games/Solarus/solarus_daemon.sh &` to `/media/fat/linux/user-startup.sh`
  (only if not already present). Once it has run once, it survives reboot.
- **First start:**
  - `deploy.py` starts + registers it on every deploy (dev workflow).
  - `scripts/Solarus.sh` (the manual Scripts-menu launcher) ensures the daemon is running
    (starts it if not) before loading the core — so an end user who copies the SD-mirror
    tree gets it activated the first time they launch, after which boot self-start persists.
- If `user-startup.sh` is absent we create it (with a `#!/bin/sh` shebang) before appending;
  if Frontier later also self-registers, both lines coexist and our defer-check prevents
  double-spawn.

## Files
- **Create** `games/Solarus/solarus_daemon.sh` — the watcher.
- **Modify** `deploy.py` — add to the shipped helper-script list; start + register the
  daemon in the post-upload step.
- **Modify** `scripts/Solarus.sh` — ensure the daemon is running before `load_core`.
- **Create** `tests/solarus_daemon_test.sh` — host test; add to `tests/run_tests.sh`.

## Testing (host, TDD — same style as `quest_manager_test`)
Env-overridable `CORENAME_FILE`, an injectable spawn command (records invocations), a
fake "Frontier" process, and a fake `user-startup.sh`. Assert:
- **Defer:** while a fake `Master_Daemon.sh` process is running → no spawn, even on Solarus.
- **Spawn:** Frontier absent + CORENAME=Solarus + no manager → spawns `_handler.sh` once.
- **No double-spawn:** a `quest_manager.sh` already running → no spawn.
- **Respawn:** child dies while still on Solarus → respawns.
- **Teardown:** CORENAME leaves Solarus → owned child is killed.
- **Self-register:** appends the boot line to a fake `user-startup.sh` exactly once
  (idempotent on a second run).

## Edge cases
- Frontier installed but **not running** → we take over (the exact bug we hit). If Frontier
  starts later, our next-tick defer-check backs off; the guard stops a double-spawn in the race.
- Fast core-away-and-back (< quest_manager's poll) → if the old manager lingers, the guard
  skips spawn (it's the right manager); if it exited, we respawn. Self-healing either way.
- `/tmp/CORENAME` is updated by MiSTer Main even on `load_core` via `/dev/MiSTer_cmd`, so
  remote/headless loads also fire the daemon (enables headless HW validation).
- busybox only: no `pkill`, `pidof` has no `-x` → all process matching via `ps | grep '[x]…'`.

## Out of scope
- Replacing/uninstalling Frontier, or auto-installing it (we are not part of that platform).
- Managing non-Solarus cores.
- Any change to `quest_manager`/`core_watch`/`_handler` lifecycle (reused as-is).
