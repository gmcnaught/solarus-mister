# Phase 0 — gprof Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a ranked whole-program attribution of the ~10.7 ms/frame of unaccounted A9 time (and the ~3.5 ms/frame `other` inside eng_cpp) at the heavy save spot, so Phases 1–3 of the 60fps campaign aim at measured targets.

**Architecture:** No product code change. Build a `-pg`-instrumented armhf engine, deploy it beside (not over) the ship engine, capture `gmon.out` at the benchmark spot with a clean exit, post-process with the cross gprof in Docker, write the attribution doc, restore the device. Spec: `docs/superpowers/specs/2026-07-07-60fps-campaign-design.md` (Phase 0).

**Tech Stack:** Docker image `solarus-armhf-build:bullseye` (cross gcc + binutils incl. `arm-linux-gnueabihf-gprof`), `scripts/build_engine.sh` (`SOLARUS_GPROF=1`), `scripts/gprof_report.sh`, MiSTer device at 192.168.20.81.

## OUTCOME (as executed 2026-07-07) — READ THIS FIRST

- gprof is a dead end for this codebase, twice over: (1) glibc's `profil()`
  histogram covers only the main executable's text — libsolarus.so (where all
  engine code lives) is invisible, so gmon.out came back with an empty
  histogram (406 B); (2) a `-pg` executable's `__monstartup` steals `profil()`
  from ld.so's `_dl_start_profile`, so a -pg exe also breaks LD_PROFILE (a run
  with the -pg exe captured exactly 1 sample).
- The recipe that WORKED: ship (non-pg) `solarus-run` + the `-pg`-built
  UNSTRIPPED `libsolarus.so.1.6.5` (only needed for symbols; -pg irrelevant
  here) + in diag.env: `LD_PROFILE=libsolarus.so.1` (the SONAME — not the full
  filename) and `LD_PROFILE_OUTPUT=/media/fat/logs/Solarus`. Output:
  `/media/fat/logs/Solarus/libsolarus.so.1.profile`, mmap-flushed
  continuously — survives kill -9, no clean exit needed.
- Post-process: glibc `sprof` is broken for this .so (dlmopen assertion, both
  device-absent and Docker armhf) — use `scripts/sprof_parse.py <profile>
  <nm-output> <flat-out> <pairs-out>` with `arm-linux-gnueabihf-nm -S -C
  build/armhf/libsolarus.so.1.6.5` output. In the flat profile, the `_init`
  row is the .plt region = LD_PROFILE audit overhead — discount it.
- Tasks 1–4 below are the original gprof plan, retained as history; only
  their capture-logistics (deploy/backup/drive-to-spot recipes) remain
  directly reusable. Deliverable + findings:
  `docs/superpowers/2026-07-07-gprof-attribution.md`; evidence:
  `docs/superpowers/data/2026-07-07-sprof-flat.txt`.

## Global Constraints

- Device: `root@192.168.20.81`, game dir `/media/fat/games/Solarus`, logs `/media/fat/logs/Solarus`.
- **Never `kill -9` the instrumented engine during capture** — gmon.out is written at clean exit only. `kill -9` is fine for the *ship* engine.
- FAT gotchas: cannot overwrite an open executable (kill engine, `rm`, then scp); verify sha1 after every scp; busybox has no `pkill` (use `kill $(pidof solarus-run)`).
- The gprof build's fps numbers are meaningless (mcount overhead, LTO off). It **ranks** cost; only `[blitter …]` banners produce A/B numbers.
- Capture with `SOLARUS_BLITTER_DIAG=0` (banners + their `clock_gettime` accumulators would pollute the profile). The `solarus_run.sh` log redirect still captures boot output (`-n` test on the var).
- Benchmark location: the village save spot (save 1, three Action presses from title). Joypad inject: hammer `devmem 0x3A000008 32 <bits>` in a loop; Action=0x020. Release with `devmem 0x3A000008 32 0`.
- Restore everything at the end: ship engine binaries back on device, `diag.env` back to banner mode, local `build/armhf` rebuilt un-instrumented.

---

### Task 1: Build the gprof-instrumented engine (preserving the ship build)

**Files:**
- Create: `build/armhf-ship/` (local backup dir, gitignored under `build/`)
- Modify: none (build output only)

**Interfaces:**
- Produces: `build/armhf/solarus-run` + `build/armhf/libsolarus.so.1.6.5` instrumented with `-pg -g`, LTO off. Task 2 deploys these; Task 4 needs this exact `solarus-run` ELF to symbolize gmon.out.
- Produces: `build/armhf-ship/{solarus-run,libsolarus.so.1.6.5}` — un-instrumented ship binaries for Task 6 restore.

- [ ] **Step 1: Back up the current ship binaries**

```bash
mkdir -p build/armhf-ship
cp build/armhf/solarus-run build/armhf/libsolarus.so.1.6.5 build/armhf-ship/
shasum build/armhf-ship/*
```
Expected: two files copied; record the sha1s (Task 6 compares).

- [ ] **Step 2: Clean the engine work tree and build with SOLARUS_GPROF=1**

```bash
git -C work/solarus checkout -- . && git -C work/solarus clean -fdq
docker run --rm -v "$(pwd):/src" -w /src -e SOLARUS_GPROF=1 \
  solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tee /tmp/gprof_build.log | tail -25
```
Expected: `SOLARUS_GPROF=1: building with -pg gprof instrumentation (LTO forced OFF).` near the top of the log, build completes.

- [ ] **Step 3: Verify the build is clean and instrumented**

```bash
grep -c 'error:' /tmp/gprof_build.log
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye bash -c \
  'arm-linux-gnueabihf-nm -D build/armhf/libsolarus.so.1.6.5 | grep -ci mcount; \
   arm-linux-gnueabihf-nm build/armhf/solarus-run | grep -ci mcount'
```
Expected: `0` errors; both nm counts ≥ 1 (ARM mcount symbol is `__gnu_mcount_nc`). If a count is 0, the `-pg` flags did not reach that target — stop and fix `build_engine.sh` flag plumbing before proceeding.

- [ ] **Step 4: Commit nothing (no repo change) — record state in the session notes instead**

No git action: build outputs are gitignored. Confirm `git status --short` shows no new tracked-file changes.

---

### Task 2: Deploy the instrumented engine beside the ship engine

**Files:**
- Modify (device): `/media/fat/games/Solarus/solarus-run`, `/media/fat/games/Solarus/libs/libsolarus.so.1.6.5`, `/media/fat/games/Solarus/diag.env`

**Interfaces:**
- Consumes: `build/armhf/{solarus-run,libsolarus.so.1.6.5}` from Task 1.
- Produces: device runs the instrumented engine with `GMON_OUT_PREFIX=/media/fat/logs/Solarus/gmon.out`; device-side backups `solarus-run.ship`, `libs/libsolarus.so.1.6.5.ship`, `diag.env.bak` for Task 6.

- [ ] **Step 1: Stop the engine and back up device binaries + diag.env**

```bash
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1; \
  cd /media/fat/games/Solarus && \
  cp solarus-run solarus-run.ship && cp libs/libsolarus.so.1.6.5 libs/libsolarus.so.1.6.5.ship && \
  cp diag.env diag.env.bak && rm solarus-run libs/libsolarus.so.1.6.5 && echo BACKED-UP'
```
Expected: `BACKED-UP`. (kill -9 is fine here — this is the ship engine, no profile to lose.)

- [ ] **Step 2: Upload instrumented binaries and verify integrity**

```bash
scp build/armhf/solarus-run root@192.168.20.81:/media/fat/games/Solarus/solarus-run
scp build/armhf/libsolarus.so.1.6.5 root@192.168.20.81:/media/fat/games/Solarus/libs/
shasum build/armhf/solarus-run build/armhf/libsolarus.so.1.6.5
ssh root@192.168.20.81 'sha1sum /media/fat/games/Solarus/solarus-run /media/fat/games/Solarus/libs/libsolarus.so.1.6.5'
```
Expected: sha1s match pairwise. A mismatch = truncated FAT upload — re-scp.

- [ ] **Step 3: Switch diag.env to gprof-capture mode**

```bash
ssh root@192.168.20.81 'cd /media/fat/games/Solarus && \
  sed -i "s|^SOLARUS_BLITTER_DIAG=.*|SOLARUS_BLITTER_DIAG=0|" diag.env && \
  grep -q "^SOLARUS_GPROF=1" diag.env || echo "SOLARUS_GPROF=1" >> diag.env; \
  grep -E "BLITTER_DIAG|GPROF" diag.env'
```
Expected: `SOLARUS_BLITTER_DIAG=0` and `SOLARUS_GPROF=1`.

- [ ] **Step 4: Relaunch and verify the gprof environment took effect**

```bash
ssh root@192.168.20.81 'touch /media/fat/config/Solarus.s0; sleep 20; \
  P=$(pidof solarus-run) && tr "\0" "\n" < /proc/$P/environ | grep GMON_OUT_PREFIX && echo PID=$P'
```
Expected: `GMON_OUT_PREFIX=/media/fat/logs/Solarus/gmon.out` and a PID. If no PID after ~30 s, check `tail /media/fat/logs/Solarus/Solarus.diag.log` (boot output is captured there) — the instrumented engine boots slower; retry once before debugging.

---

### Task 3: Capture gmon.out at the save spot (clean exit)

**Files:**
- Create (device): `/media/fat/logs/Solarus/gmon.out.<pid>`

**Interfaces:**
- Consumes: running instrumented engine (Task 2).
- Produces: `gmon.out.<pid>` on the device; Task 4 pulls it. Record the PID — the filename embeds it.

- [ ] **Step 1: Drive to the save spot**

```bash
ssh root@192.168.20.81 'press(){ b=$1; end=$(( $(date +%s) + 1 )); while [ $(date +%s) -lt $end ]; do devmem 0x3A000008 32 $b; done; devmem 0x3A000008 32 0; sleep 1; }; \
  sleep 10; press 0x020; sleep 1; press 0x020; sleep 1; press 0x020; sleep 3; \
  echo screenshot > /dev/MiSTer_cmd; sleep 2; ls -t /media/fat/screenshots/Solarus/ | head -1'
```
Then scp that screenshot and view it. Expected: the village save spot (hero by the fenced houses), NOT the title screen. If still on title, repeat one `press 0x020`.

- [ ] **Step 2: Accumulate 120 s of standing-still samples**

```bash
sleep 120
```
No input during this window — the profile should represent the steady-state benchmark scene.

- [ ] **Step 3: Terminate cleanly and verify gmon.out**

```bash
ssh root@192.168.20.81 'P=$(pidof solarus-run); kill -TERM $P; \
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; pidof solarus-run >/dev/null || break; done; \
  pidof solarus-run >/dev/null && kill -INT $(pidof solarus-run); sleep 3; \
  ls -la /media/fat/logs/Solarus/gmon.out.* 2>/dev/null; echo PID-WAS=$P'
```
Expected: `gmon.out.<PID>` exists and is > 100 KB (a tiny file = histogram missing). Note `PID-WAS`.

- [ ] **Step 4 (contingency — only if no gmon.out appeared): add a SIGTERM→clean-exit patch**

SDL/Solarus may not install a SIGTERM handler, in which case the default action skips the atexit flush. Fix with a minimal, ship-safe patch in the existing series (author via the apply→edit→`scripts/export_patches.sh` flow from PR #71): in `work/solarus/src/main/Main.cpp` (the `solarus-run` main), before the game loop starts, add:

```cpp
#include <csignal>
#include <cstdlib>
// gprof (-pg) writes gmon.out from the atexit hook; default SIGTERM skips it.
// Route SIGTERM/SIGINT through exit() so profiling runs can be stopped cleanly.
static void mister_clean_exit(int) { std::exit(0); }
```
and inside `main()` before the quest launch:
```cpp
std::signal(SIGTERM, mister_clean_exit);
std::signal(SIGINT,  mister_clean_exit);
```
Rebuild (Task 1 Step 2), redeploy (Task 2 Steps 1–2 — backups already exist, skip re-backup), re-run Task 3. Commit the new patch file:
```bash
git add patches/series/ && git commit -m "feat(profiling): SIGTERM/SIGINT clean exit so -pg runs flush gmon.out"
```
Note: `exit(0)` skips Solarus's normal shutdown path; acceptable for a ship engine (process is dying anyway) and required for profiling. Keep it unconditional — it makes future profiling runs one-command.

---

### Task 4: Generate and sanity-check the gprof report

**Files:**
- Create: `build/armhf/gprof-report.txt` (gitignored)
- Create: `gmon.out` (repo root, temporary — delete after)

**Interfaces:**
- Consumes: `gmon.out.<pid>` (Task 3), `build/armhf/solarus-run` (Task 1 — must be the same ELF that ran).
- Produces: `gprof-report.txt` flat profile + call graph; Task 5 turns it into the attribution doc.

- [ ] **Step 1: Pull the profile and run the report in Docker (host has no cross gprof)**

```bash
scp "root@192.168.20.81:/media/fat/logs/Solarus/gmon.out.*" ./gmon.out
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/gprof_report.sh build/armhf/solarus-run gmon.out build/armhf/gprof-report.txt
head -40 build/armhf/gprof-report.txt
```
Expected: a flat profile table with % time / cumulative seconds / calls per symbol.

- [ ] **Step 2: Verify libsolarus attribution (the make-or-break check)**

```bash
grep -cE "Solarus::|Entity|Movement|LuaContext|blt_|mister" build/armhf/gprof-report.txt
```
Expected: dozens of hits — engine symbols from the .so attributed with real % time. **If ~0 (only `main`/libc rows):** classic gprof shared-object blind spot (glibc's histogram covers the executable text only). Do NOT proceed to Task 5 on empty data. Fallback, in order:
1. `LD_PROFILE` (glibc's shared-library profiler, no instrumentation needed): on device set `LD_PROFILE=libsolarus.so.1.6.5 LD_PROFILE_OUTPUT=/media/fat/logs/Solarus` in `diag.env`, re-run the capture, post-process with `sprof` (check `which sprof` on device first; if absent, run sprof under `qemu-arm` in the Docker image against the armhf .so + profile file).
2. If LD_PROFILE also fails: fall back to targeted banner injections (the spec's stated fallback) — pick the top unknowns (`other`, emit, present) and bracket them with `clock_gettime` accumulators exactly like `[blitter entphase]` in the patch series.
Record which path produced the data in the attribution doc.

- [ ] **Step 3: Extract the two views Task 5 needs**

```bash
awk '/^ *%/{p=1} p' build/armhf/gprof-report.txt | head -50        # flat top-50
grep -n "index % time" build/armhf/gprof-report.txt | head -3      # call-graph section offsets
```
Expected: readable top-50 flat profile; call-graph present for walking parent/child attribution of the big rows.

---

### Task 5: Write the attribution doc and amend the Phase 1 lever list

**Files:**
- Create: `docs/superpowers/2026-07-07-gprof-attribution.md`
- Modify: `docs/superpowers/specs/2026-07-07-60fps-campaign-design.md` (Phase 1 lever list, ONLY if the data contradicts/extends it)

**Interfaces:**
- Consumes: `build/armhf/gprof-report.txt` (Task 4).
- Produces: the Phase 0 gate deliverable — the attribution table Phases 1–2 plan against.

- [ ] **Step 1: Write the attribution doc**

Structure (fill every row from the report; no TBDs):

```markdown
# Phase 0 gprof attribution — heavy save spot (2026-07-07)

Capture: <PID>, <secs> standing, SOLARUS_BLITTER_DIAG=0, engine <git describe>.
Method: gprof -pg (or LD_PROFILE/banners — state which, per Task 4).

## Flat top-20 (self time)
| % | self s | calls | symbol | banner bucket (entities/hero/emit/lua/present/other/UNSEEN) |
|---|---|---|---|---|
| … | … | … | … | … |

## The ~10.7 ms/frame per-frame share, attributed
| Component | ms/frame (est. from %) | Lever candidate |
|---|---|---|
| emit (blt_*/renderer) | … | Phase 2 worker |
| Lua VM (draw callbacks etc.) | … | stays main-thread |
| present/pacing | … | Phase 2 worker |
| glue/unattributed | … | … |

## eng_cpp `other` (3.5 ms/frame) + sound (2 ms/frame), attributed
| Symbol/subsystem | ms/frame | Phase 1 lever |
|---|---|---|

## Phase 1/2 plan deltas
- <confirmed / amended levers, each with the report line that justifies it>
```

Cross-check: the gprof %s, scaled to the banner-measured 30 ms A9 frame, should roughly reproduce the banner buckets (entities ~10.5, hero ~2.3, sound ~2). If they disagree wildly, say so and trust banners for magnitude, gprof for ranking.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/2026-07-07-gprof-attribution.md docs/superpowers/specs/2026-07-07-60fps-campaign-design.md
git commit -m "docs(phase0): gprof attribution of A9 frame time at heavy spot"
```

---

### Task 6: Restore ship state (device + local)

**Files:**
- Modify (device): restore `solarus-run`, `libs/libsolarus.so.1.6.5`, `diag.env`
- Modify (local): rebuild un-instrumented `build/armhf/`

**Interfaces:**
- Consumes: `.ship` backups (Task 2), `diag.env.bak` (Task 2), `build/armhf-ship/` (Task 1).
- Produces: device back at 26-fps ship baseline with banners on; local tree ready for Phase 1.

- [ ] **Step 1: Restore device binaries and diag.env, relaunch**

```bash
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1; \
  cd /media/fat/games/Solarus && \
  rm -f solarus-run libs/libsolarus.so.1.6.5 && \
  mv solarus-run.ship solarus-run && mv libs/libsolarus.so.1.6.5.ship libs/libsolarus.so.1.6.5 && \
  mv diag.env.bak diag.env && \
  sed -i "s|^# SOLARUS_BLITTER_DIAG=0.*|SOLARUS_BLITTER_DIAG=1|;s|^SOLARUS_BLITTER_DIAG=.*|SOLARUS_BLITTER_DIAG=1|" diag.env && \
  grep DIAG diag.env && touch /media/fat/config/Solarus.s0'
```
Expected: `SOLARUS_BLITTER_DIAG=1`; engine relaunches. (If the SIGTERM patch from Task 3 Step 4 was added, the restored `.ship` binaries predate it — fine; the patch ships with the next normal build.)

- [ ] **Step 2: Verify baseline is back**

```bash
sleep 30
ssh root@192.168.20.81 'grep "blitter timing" /media/fat/logs/Solarus/Solarus.diag.log | tail -2'
```
Expected: fresh `[blitter timing]` lines (title screen ~44 fps is fine — proves ship engine + banners live).

- [ ] **Step 3: Restore the local un-instrumented build**

```bash
git -C work/solarus checkout -- . && git -C work/solarus clean -fdq
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tail -5
shasum build/armhf/solarus-run build/armhf/libsolarus.so.1.6.5 build/armhf-ship/*
rm -f gmon.out
```
Expected: clean build; new sha1s differ from `armhf-ship` only if the SIGTERM patch landed (otherwise builds are not byte-reproducible — sha equality is NOT required; the requirement is `nm | grep -ci mcount` = 0):
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye bash -c \
  'arm-linux-gnueabihf-nm -D build/armhf/libsolarus.so.1.6.5 | grep -ci mcount'
```
Expected: `0`.

---

## Exit gate (from the spec)

Phase 0 is done when `docs/superpowers/2026-07-07-gprof-attribution.md` contains the ranked attribution of the per-frame ~10.7 ms and the eng_cpp `other`/sound buckets, and the Phase 1 lever list is confirmed or amended with report-line citations. Then write the Phase 1 plan (separate document) against it.
