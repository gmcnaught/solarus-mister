# Pacing barrier retirement + region-blend capture — operator runbook

**Device:** `root@192.168.20.81` (key-authed SSH, no password).
**Repo root (host):** `/Users/gmcnaught/MisterFPGA-Projects/solarus-mister-pacing`.
**Purpose:** settle the two operator gates for this branch's two engine-only
levers — Part A (pacing: retire the `ensure_frame` vblank barrier, free-run on
the `present()` 60 fps cap) and Part B (region-aware blend capture: the pause
menu's atlas-backed backdrop offloads to the fabric). Neither lever can be
validated by the host suite (`bash tests/run_tests.sh`); both are settled by a
human looking at the device.

This is an **engine-only** exercise. No RTL/RBF change; both legs ship on
`Solarus_20260724.rbf` (Stage 5 Phase 2, FB→DDR3) — the current pin in
`scripts/perf/stage5_device_launch.sh`.

Escape hatches, if either gate fails:
- Gate A (pacing): `SOLARUS_VSYNC_BARRIER=1` restores the old vblank-gated pacing.
- Gate B (menu): `SOLARUS_BLENDLAYER=0` restores the software blend into the root
  surface (pre-Task-4/5 behaviour).

---

## 0. Prerequisites

- Solarus core loaded from `_Other/Solarus_20260724.rbf`.
- Quest `mystery_of_solarus_dx.sol` + `save1.dat` present in
  `/media/fat/games/Solarus/quests/` and `/media/fat/saves/Solarus/` respectively.
- Only **one** `solarus-run` at a time — every launch below kills
  `quest_manager.sh` / `core_watch.sh` / `solarus_daemon.sh` / `solarus-run`
  first (see `scripts/perf/stage5_device_launch.sh` and the two-engines-wedge
  memory).
- Record, for every leg captured below: the deployed `libsolarus.so.1.6.5`
  sha1, the RBF name, the map, and the raw banner tails — following the format
  already used in `docs/superpowers/data/blendlayer-ab/leg-*.txt`.

```bash
ssh root@192.168.20.81 'sha1sum /media/fat/games/Solarus/libs/libsolarus.so.1.6.5'
```

---

## Gate A — pacing (Part A: retired vblank barrier)

**Scene:** map 40 (`dungeon_3`), dialog held (auto-fires on
opening-transition-finished).

**Script:** `scripts/perf/capture_pacing_ab.sh`. Runs leg B (default, no
barrier) first, then leg A (`SOLARUS_VSYNC_BARRIER=1`), one engine on the
fabric at a time. Output:
`docs/superpowers/data/pacing-ab/leg-{A-barrier,B-freerun}.txt`.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister-pacing
scripts/perf/capture_pacing_ab.sh
```

### Numeric checks (from the captured banners)

- **Leg A** (`SOLARUS_VSYNC_BARRIER=1`, old pacing): expect `[blitter timing]`
  `fps≈26.4`, `sleep≈11ms`, and `[MiSTer draw] vblank≈11` (ms).
- **Leg B** (default, free-running): expect `[blitter timing] fps≈35`,
  `sleep≈0`, `[MiSTer draw] vblank=0.0`, and `clear=` **sub-millisecond** —
  that number alone confirms the Task 2 bracket split landed correctly,
  because the old (unsplit) bracket read `clear=18.7` ms for the same scene
  (it was folding the fabric handshake and the vblank wait into the memset).
- **Fabric cross-check — use `fabric_hw`, NOT `fabwait`.** The invariant is
  `[blitter hwperf] fabric_hw=`, the fabric's own busy counter: the pacing lever
  must not change how much work the fabric does. Measured 2026-07-25:
  **16.94 ms (leg A) vs 16.42 ms (leg B)** — unchanged, so the fps delta is a
  clean A/B for the barrier alone. If `fabric_hw` moves materially between legs,
  **stop and investigate before reporting a result.**

  `[MiSTer draw] fabwait=` is expected to **RISE** in leg B (measured 7.7 → 10.0 ms)
  and that is not a defect: it is the host's spin waiting on `C_DONE`, so removing
  a ~10 ms sleep that preceded it necessarily makes the A9 arrive earlier and wait
  longer for the same fabric work. An earlier draft of this runbook wrongly
  required `fabwait` to be equal across legs; that criterion would have failed a
  correct result.

### OPERATOR VISUAL — tear check (ships or blocks Part A)

**The overworld walk below does NOT exercise the cap and is not sufficient
evidence by itself.** Gate A's own numeric expectations for that leg are
`fps≈35` and `sleep≈0` (see Numeric checks above) — the free-run cap is not
engaging at all at 35 fps. A 35 fps producer physically cannot land two
snapshots inside one reader scan window regardless of whether pacing is
correct, so a clean tear check on the overworld walk alone would pass even if
the cap's rate-limiting were completely broken. Treat it as a baseline sanity
check, not the gate.

**Step 1 — overworld walk (baseline, not decisive).** Walk the hero
**continuously for at least 30 seconds** across a scrolling overworld area
(not standing still, not a single screenshot) and watch the **bottom of the
screen** for a horizontal tear line during the walk. Record PASS/FAIL, but do
not stop here.

**Step 2 — cap-limited tear watch (DECISIVE — this is what settles Gate A).**
The cap only does real work in a scene that would otherwise run at or above
the reader's scan rate. Candidates on this quest: the **title screen**, the
**Select-a-File menu**, and the **pause menu**.

1. Pick one of the candidate scenes and open it.
2. **First confirm the cap is actually engaging** by reading the
   `[blitter timing]` banner: expect `sleep > 0` and `fps ≈ 59.9`. If a
   candidate scene does not show `sleep > 0`, it is not exercising the cap —
   try the next candidate. Do not proceed to the visual watch on a scene that
   fails this check.
3. Once a scene confirms `sleep > 0` / `fps≈59.9`, watch the **bottom of the
   screen sustained for several minutes**, not a brief glance. A residual
   timing drift between the free-run cap and the fabric's actual scan period
   beats slowly — the visible tear position (if any) drifts up/down the frame
   over minutes rather than sitting still or appearing instantly, so a short
   observation window can miss a real, slowly-cycling tear.

- **PASS** requires the cap-limited observation (Step 2) to show no tear line,
  steady or drifting, over the full sustained watch — the overworld walk alone
  is not sufficient evidence either way. Part A ships as-is
  (`SOLARUS_VSYNC_BARRIER` stays default-off).
- **FAIL** = a tear line appears (steady or drifting) during the cap-limited
  watch. Set `SOLARUS_VSYNC_BARRIER=1` in the shipping launch env (restores
  the retired barrier) and file a follow-up; do not ship Part A with the
  barrier off.

---

## Gate B — menu (Part B: region-aware blend capture)

**Scene:** pause menu open (submenu backdrop is the atlas-backed full-screen
translucent overlay Task 4/5 changed capture behaviour for). Compare the
current build against a build predating Task 5 (or `SOLARUS_BLENDLAYER=0` on
the current build, which restores the software blend as a same-build A/B).

### Numeric checks

- Expect `[blitter blendlayer] armed=1 layers=1 capture=1 blits=1 escape=0` on the new
  build. The old build (or `SOLARUS_BLENDLAYER=0`) shows `capture=0` — the
  atlas-backed region never captured before this branch.
- Expect `[MiSTer draw] game=` to fall by roughly the software blend cost, and
  `[blitter timing] fps=` to rise from the pre-existing ~20 baseline.
- If `capture=1` lands but fps barely moves, that is a **real, expected
  outcome, not a failure** — the design's magnitude estimate was inferred from
  the dialog-blend shape (Gate A's scene), not independently measured for the
  menu. Decompose the menu frame with `SOLARUS_DRAW_PROF` before proposing a
  second lever; do not treat a small fps delta here as a Gate B failure.

### OPERATOR VISUAL — all four submenus (ships or blocks Part B)

Cycle through **every one of the four pause submenus** (not just the one that
opens first). Each submenu must show its **own** background, at the correct
216 translucency.

This is the specific defect Task 5's `sx`/`sy` region-origin threading exists
to prevent: a wrong `sx` shows the **neighbouring** submenu's backdrop instead
of the current one. It is **invisible on submenu 0** (offset 0 masks an `sx`
bug), so submenu 0 alone is not a valid check — all four must be cycled.

- **PASS** = all four submenus show their own correct backdrop at the correct
  translucency. Part B ships as-is.
- **FAIL** = any submenu shows a neighbouring submenu's backdrop, or the
  translucency is visibly wrong. Set `SOLARUS_BLENDLAYER=0` in the shipping
  launch env (restores the software blend) and file a follow-up; do not ship
  Part B with a wrong-region capture live.

### OPERATOR VISUAL — cap-limited tear watch with the pause menu open (ships or blocks Part B)

**This is where Part A and Part B interact, and it is not covered by the
four-submenus check above.** Part B's whole purpose is to raise the pause
menu's fps by moving its backdrop blend to the fabric — which pushes the menu
toward, or past, the 60 fps reader scan rate. That is exactly the regime where
Part A's free-run cap is the sole thing preventing two snapshots from landing
inside one reader scan window (see the design spec §3, "Why this is
correct" — the fabric has no reader acknowledgement). A menu that renders its
four backgrounds correctly (the check above) can still tear if Part B pushed
its fps into the cap-limited regime and pacing is off.

Run the same procedure as Gate A's Step 2, with the pause menu open instead of
title/Select-a-File:

1. Open the pause menu on the current (Part B) build.
2. Confirm from `[blitter timing]` that the cap is engaging: `sleep > 0`,
   `fps ≈ 59.9`. If the menu does not show this — i.e. Part B did not raise it
   into the cap-limited regime — note that and fall back to whichever
   candidate scene from Gate A's Step 2 you used there.
3. Watch the **bottom of the screen sustained for several minutes** for a
   horizontal tear line, steady or drifting, exactly as in Gate A's Step 2.

- **PASS** = no tear line over the full sustained watch. Part B ships as-is.
- **FAIL** = a tear line appears. Treat this as a Part A regression triggered
  by Part B's fps increase, not a Part B-only defect — do not "fix" it by
  reverting Part B alone; re-verify Gate A's cap-limited watch (Step 2) on
  this build too, and if it also fails, set `SOLARUS_VSYNC_BARRIER=1` in the
  shipping launch env rather than (or in addition to) `SOLARUS_BLENDLAYER=0`.

### HW WATCH-ITEM — INTER arena occupancy (record, do not gate on)

A code review of Task 5 surfaced a hardware-observable side effect worth
recording during this same gate, even though it is not itself a pass/fail
criterion: capturing the atlas-backed menu layer uploads the **whole
1280x240** source surface as ARGB4444 (~600 KB) even though only a 320x240
region is drawn per frame. The quest's atlas backing that menu surface is
probably not registered as immutable, so it stages into the 4 MiB `INTER`
arena (`SDRAM_INTER_SIZE`) rather than the 64 MiB permanent one — roughly 15%
of `INTER` for this single surface.

`INTER` arena overflow is a known failure class on this project (issue #84:
preload format-guess → gameplay permanent re-stage overflow). A jump in
`INTER` occupancy specifically when the menu opens is the thing to catch here
before it becomes another #84.

With `SOLARUS_BLITTER_DIAG=1` set (already on in `capture_pacing_ab.sh`'s
launch env, and set it explicitly if driving the menu gate by hand), read the
`[blitter inter]` diagnostic banner emitted every 60 frames:

```
[blitter inter] /60fr: used=%u/%u bytes (%.2f/%.2f MiB) leaked=%u
```

i.e. fields `used=<bytes>/<cap bytes>`, `(<used MiB>/<cap MiB>)`,
`leaked=<bytes>`. Capture this banner's tail (last 2-4 windows) **both with the
pause menu closed and immediately after opening it**, and record both in the
leg output alongside the numeric checks above:

```bash
ssh root@192.168.20.81 "grep -aE '\[blitter inter\]' /media/fat/logs/Solarus/stage5-boot.log | tail -4"
```

Record the `used=`/`MiB` delta across the menu-open transition. A large,
sustained jump (roughly the ~15% figure above, and not reclaimed on menu
close) is the early signal of the class #84 failure; note it in the leg file
even if it does not, by itself, fail Gate B.

---

## Recording captures

Follow the format already used in `docs/superpowers/data/blendlayer-ab/`: a
`leg-<TAG>.txt` per leg, header line with the tag / flag value / RBF / map,
then the raw `grep` tails for each relevant banner, then the engine
alive/dead check. `scripts/perf/capture_pacing_ab.sh` already produces this
shape for Gate A into `docs/superpowers/data/pacing-ab/`; for Gate B, capture
by hand into `docs/superpowers/data/menu-ab/leg-{A-old,B-new}.txt` using the
same `ssh ... grep -aE '\[banner\]' ... | tail -N` pattern against
`blendlayer`, `MiSTer draw`, `timing`, and `inter`.

---

## Post-implementation

Once both gates pass, use `superpowers:finishing-a-development-branch` to
decide on merge/PR. **The PR body must note that `clear=` and `emit=` changed
meaning in this PR** (`clear=` no longer includes the fabric handshake or the
vblank wait; see the Task 2 bracket split above) — captures in
`docs/superpowers/data/blendlayer-ab/` (pre-PR) are not directly comparable to
post-PR captures on those two columns.
