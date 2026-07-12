# PR #111 defect-reduction batch — on-device HW validation plan

Merged master: **8facf98** ("Defect-reduction batch … (#111)"). Sim/build-validated
only; this plan drives the **9 display-correctness fixes** on real HW. Per
`solarus-no-self-declared-visual-validation`: every VISUAL verdict below is the
**user's eyes**, never a self-declared "looks fine". Objective probes I can run
myself are marked **[objective]**.

## Deploy state — DEPLOYED + sha1-verified 2026-07-12

| Artifact | Source | Device sha1 | Notes |
|---|---|---|---|
| `_Other/Solarus_20260712.rbf` | CI run 29194987771 (`solarus-rbf`, sha 8facf98) | `9b94f1169c12…` | all merged **RTL** fixes (#100/#101/#103/#104/#107) |
| `libs/libsolarus.so.1.6.5` | local Docker `build_engine.sh` off this tree (= master patch series) | `f9bc542812cb…` | all merged **host** fixes (#91/#102/#106/#109) |
| `solarus-run` | (same build) | `51babcb94f24…` | DT_NEEDED clean (SDL2/LuaJIT, no libGL) |
| quests on device | MoSDX, zelda-roth-se, patched-tunics | — | dungeons (transitions), destructibles, decorative rooms |

**Gotcha hit + fixed:** deploy.py ships `deploy/libs/`, not `deploy/` root. The first
`cp build/armhf/libsolarus.so.1.6.5 deploy/` left the stale Jul-9 lib in `deploy/libs/`
(and deploy.py sha1-verified it against that stale copy → false "ok"). Corrected by
`cp … deploy/libs/` + re-deploy; device sha1 now matches the fresh build (above).

Next: load the **Solarus** core from OSD → CORENAME=Solarus → auto-launch → pick
**Mystery of Solarus DX**, then walk the matrix below.

## Per-fix validation matrix

Layer legend: **RTL** = in the RBF; **HOST** = in solarus-run/libsolarus.

| # | Fix | Layer | How to exercise | Expected observable | Judge |
|---|---|---|---|---|---|
| **#91** | default single-buffer → safe FB-in-BRAM path | HOST | Boot engine, stand in overworld | Clean, tear-free frame; no double-buffer garbage/flicker; boots to title→overworld | user-eyes |
| **#100** | decode ARGB4444 in **all** blend modes (comp_pipeline) | RTL | Enter a room with decorative tiles over transparent regions (the "translucent pots" class — white-floor / decorated-floor rooms) | Decorative tiles render as themselves, **NOT** as filled translucent squares/blocks | user-eyes |
| **#101** | fail-safe clamp on bgplane bake-address wrap | RTL | Normal play (safety net; real trigger needs a 128 MB-scale plane base) | **No regression**: planes still bake correctly, no new corruption of atlas/adjacent plane | user-eyes (neg) |
| **#102** | clear WORK RGB before plane-tile bake (kills stale-scene gaps) — the **#84** bug | HOST | Walk through **several** dungeon rooms / map transitions in a row (5+), incl. re-entering a prior room | Static tiles present in every room after many transitions; **no missing tiles / stale-scene gaps** | user-eyes ★ |
| **#103** | scanout CDC edge-detect on resolved sync stages | RTL | Soak overworld + transitions; watch a static high-contrast frame | No sparkle/tear/1-px scanline glitches from metastability over a multi-minute soak | user-eyes (soak) |
| **#104** | 2–3 FF synchronize vs before rising-edge detect | RTL | (same soak as #103) | (same — no CDC-class scanout artifacts) | user-eyes (soak) |
| **#106** | event-driven STATICPARK wake | HOST | Cut/lift destructibles (pots, bushes); trigger switches; approach parked NPCs/enemies | Parked static entities **wake correctly** on the triggering event — nothing stays frozen/unresponsive | user-eyes |
| **#107** | clamp `v_sync_start ≥ V_ACTIVE` (vsync out of active video) | RTL | Boot; observe top/bottom of active image | Stable image, no vsync line intruding into active video, no roll/overscan glitch | user-eyes |
| **#109** | host emitter robustness (16-bit guard, bgplane-write drop check, alloc-leak tally) | HOST | Extended play through heavy scenes (dense overworld, many entities); long session | **No crash / hang / OOM**; heavy scenes composite without corruption; process stays alive | [objective] + user-eyes |

★ = the primary regression this batch targeted (#84 stale-bgplane).

## Objective probes (I can run these over SSH)

- **Frame counter advancing** (engine alive + scanning): `busybox devmem 0x3A000000`
  read twice, value increments. Confirms the render loop + present path.
- **Process liveness / no crash**: `pidof solarus-run` non-empty across the session;
  scan the engine log for `FABRIC-ASSERT`, `abort`, `terminate`, `bad_alloc`,
  segfault, and the #109 tallies (bgplane-write drops, alloc-leak count).
- **#109 alloc-leak tally**: after a long session, the emitter's leak tally in the
  log should be **0** (or bounded/non-growing), proving no per-frame command-buffer leak.
- **RBF actually the Jul-12 core**: confirm `/media/fat/_Other/Solarus_20260712.rbf`
  present + sha1 matches the CI artifact after deploy.

## Sequence

1. `./deploy.py` → verify sha1 of pushed engine + RBF.
2. Load Solarus core (OSD) → CORENAME=Solarus; pick MoSDX.
3. **[objective]** frame counter advancing; log clean; pidof alive.
4. Hand the **user-eyes** rows to the user in order: #91 boot/overworld → #107 vsync
   → #100 decorative room → #102 multi-transition walk (★) → #106 destructibles →
   #103/#104 soak. Capture a screenshot per visual claim.
5. Record verdicts back into this file; only then is PR #111's HW-validation debt cleared.

## Not covered here (tracked separately)

- Fast-follow **TBs** #112/#113/#115 (sim, on branch `test/fast-follow-tbs-112-113-115`).
- #116 comp_replay gating (needs committed capture), #114 CDC hdl-lint rule,
  #117/#118 upstream mirror + re-file — all sim/CI/upstream, no HW.
