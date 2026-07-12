# PR #111 defect-reduction batch — on-device HW validation plan

Merged master: **8facf98** ("Defect-reduction batch … (#111)"). Sim/build-validated
only; this plan drives the **9 display-correctness fixes** on real HW. Per
`solarus-no-self-declared-visual-validation`: every VISUAL verdict below is the
**user's eyes**, never a self-declared "looks fine". Objective probes I can run
myself are marked **[objective]**.

## RESULTS — HW-validated 2026-07-12 (user-confirmed on device 192.168.20.81)

| # | Fix | Verdict |
|---|---|---|
| #91 | default single-buffer FB-in-BRAM | ✅ PASS (transient motion tearing is by-design; double-buffer is the known follow-up) |
| #91-shell | diag.env opt-in + rm stale on deploy | ✅ PASS (stale diag.env removed on deploy, confirmed) |
| #100 | ARGB4444 decode all blend modes | ✅ can't-reproduce (translucent-pots decode class gone) |
| #101 | bgplane bake-address clamp | ✅ no regression |
| #102 | WORK-clear before plane bake | ✅ PASS (user-confirmed) |
| #103/#104 | scanout CDC on resolved sync | ✅ PASS (user-confirmed soak) |
| #106 | event-driven STATICPARK wake | ✅ PASS (user-confirmed) |
| #107 | vsync clamp ≥ V_ACTIVE | ✅ PASS (stable image) |
| #109 | host emitter robustness | ✅ no crash/hang/overflow over the session ([objective] + play) |

**#111 HW-validation debt: CLEARED.** One SEPARATE pre-existing bug surfaced during
validation — **#84** (bgplane ARGB4444 static-plane bake/PALPHA-composite corruption,
cumulative across map transitions; sprites/HUD unaffected). Screenshot-confirmed and
re-localized on this device; tracked in issue #84 (comments 4952144771 / 4952200644),
deferred to a deterministic-sim pursuit. Not a #111 regression gate — #111's fixes all
validate; #84 is its own open item in the same bgplane subsystem.

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
