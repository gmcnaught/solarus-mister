# Stage 3a — hardware validation record (scroll-transition fabric path)

**Date:** 2026-07-20
**Branch:** `feat/retained-scene-stage3a-transition`
**Device:** MiSTer @ 192.168.20.81
**Plan:** `docs/superpowers/plans/2026-07-19-retained-scene-stage3a-transition-bandaid.md` (Task 8)

## Deployed artifacts

| Artifact | sha1 |
|---|---|
| `solarus-run` | `fb9d2f1fc39747bd3c4ac66ac94dc9794c2b06cb` |
| `libsolarus.so.1.6.5` | `cd8a8d8035b558751f1a5ff619ea2e227bfdc870` |

Both verified on-device against `build/armhf/` after deploy. **`solarus-run` is byte-identical
across the fix** — the renderer lives in `libsolarus.so.1.6.5`, so the `.so` sha1 is the only one
that distinguishes the builds. A first deploy attempt reported success while leaving the OLD `.so`
in place (the lib was staged to `deploy/games/Solarus/` instead of `deploy/libs/`); it was caught
only by the sha1 check, which is exactly the failure mode the plan's Step 2 warns about.

**Core:** `Solarus_20260719.rbf`, confirmed loaded via `CORENAME=Solarus`. Only one Solarus RBF is
present on the device, so the "older RBF has no opcode-10 arm" ambiguity does not apply. No RTL
changed in Stage 3a.

**Configuration:** `SOLARUS_BLITTER_DIAG=1 SOLARUS_SCROLLFAB=1`, verified both in
`/proc/<pid>/environ` and by the `[MiSTer blitter] scroll fabric path ENABLED (SOLARUS_SCROLLFAB)`
banner. `SOLARUS_SPRITECH=1` held constant (from `diag.env`). Quest: Mystery of Solarus DX.

## A defect was found and fixed during this session

The first flag-ON run surfaced a real Stage 3a bug that the A/B is precisely what earned:

> **Operator, verbatim:** "we have an offset bug in scroll transitions - the entities are being
> rendered progressively more misaligned with the base background as each transition happens" —
> then corrected: "the offset looks relatively constant, and it's offset by whichever direction the
> last transition was - if I transition north, the entities are offset north, if I transition south
> they are offset south by the same amount from the correct spot."

The correction from *cumulative* to *constant, direction-signed* is what identified it as a stale
latch rather than an accumulation.

**Root cause.** The camera-alias offset had no clear path when a scroll **ends**. Both maintenance
sites — `draw()` and `resident_begin_frame()` — reset `alias_off_x/y` to zero only inside the
"camera surface changed" adoption branch, and refreshed it per frame only while
`g_transition_scroll` was true. When a scroll ended with the camera unchanged, neither ran, so the
offset latched its last in-scroll value indefinitely.

It presented as *entities vs background* misalignment specifically because the two consumers read
the offset differently:

- background / tiles: `Impl::scroll_bias_x/y()`, already gated on
  `(scrollfab && g_transition_scroll)` — **self-clearing**;
- sprites / entities: the raw `alias_off_x/y` field (`sprite_channel_push`, `emit_draw`) — **not**.

**Fix.** The rule was extracted into `patches/mister/scroll_alias.h`
(`mister_scroll_alias_update()`) and called from both sites. The bug existed *because* the logic
was hand-duplicated and drifted, so fixing it twice in place would have preserved the trap. The
helper takes an `alias_is_tagged_cam` argument: without it the clear would also zero the legacy
`looks_like_promote` alias's legitimately non-zero offset. Flag-OFF is provably untouched — the
helper returns early when `scrollfab` is false.

**Regression lock.** `patches/mister/test_scrollalias.cpp` case 7 calls the same inline function the
renderer calls (not a re-modelled copy) and was demonstrated red→green: reverting only the clear
fails "alias offset returns to 0 when the scroll ends" and "entities and background agree after the
scroll"; restoring passes. An earlier draft of this test modelled the fixed logic separately and
would have passed against the broken renderer — it was rewritten for that reason.

## Operator observations

**Flag ON, before the fix:** entities misaligned from the background by the last transition's
direction, constant magnitude, persisting after the transition ended.

**Flag ON, after the fix:** "misallignment is fixed." Several north/south scrolls triggered, no
corruption reported.

## Objective signals (post-fix run, `stage3a-hw/scroll_on_fixed.log`)

| Signal | Value | Reading |
|---|---|---|
| `scroll_oldmap` | 9, 13, 13, 14, 18, 19, 31 across 7 windows | Task 5's fabric old-map branch **fired**. Had this been 0, the old map was still going to the overlay and the A/B would have compared two identical renders. |
| `scroll_oldclip` | `0` in all **116** windows | No old-map blit was ever fully clipped → offsets correct in sign, both axes. |
| `scroll_off` | `(0,195)/(0,-45)` | A **vertical** transition with **negative** `old_dy` → the `ddy < 0` destination-clip branch executed on hardware for the first time. |
| `heap_peak` | `918376` / `15204352` cap (~6%) | The `g_transition_scroll` bandaid's heap justification (2) was **unreachable** in this build, confirming the code reading rather than merely being consistent with it. |
| `overflow` | `0` (116 windows) | — |
| `dropped` | `0` (232 windows) | — |

Earlier horizontal-only run (pre-fix) recorded `scroll_off` samples `(230,0)/(-90,0)`,
`(-230,0)/(90,0)`, `(-145,0)/(175,0)` — both X directions, so the `ddx < 0` branch is covered too.

## Verdicts

- **#122 (bgplane hold frame on scroll):** *no verdict.* Not separately observed or measured in this
  session; the session was consumed by finding and fixing the alias-latch defect. Do not read the
  clean post-fix run as closing it.
- **#123 (scroll-path black flicker):** *not closed.* The `heap_peak` result disposes of the
  **heap premise** behind the bandaid, but the operator was not asked to characterise black-frame
  behaviour before and after, so the visible symptom itself is unadjudicated.
- **Can `g_transition_scroll` be deleted?** *Not on this evidence alone.* The fabric path is now
  confirmed live, correct in sign in both axes, non-overflowing, and visually clean per the
  operator. What is missing is a deliberate flag-OFF/flag-ON comparison of the #122/#123 symptoms
  in separate processes — deletion removes the baseline, so it should follow that comparison.

## What is NOT established

- No flag-OFF (baseline) leg was captured **after** the fix. The pre-fix baseline that ran was from
  an auto-relaunched engine, not a controlled leg, and its process was not restarted for a
  comparable `heap_peak`.
- Only **one** vertical `scroll_off` sample exists. `scroll_off` is sampled instantaneously per
  60-frame window, so a positive-`dy` sample was not captured; the positive-`dy` clip branch rests
  on `scroll_oldclip=0` plus the operator seeing no corruption. Note a `uint16_t` wrap would present
  as visible garbage rather than as a clip count, so the operator's eyes — not the counter — are the
  load-bearing evidence for that specific failure mode.
- `#122`/`#123` were not characterised before/after (see Verdicts).
- Frame-rate / pacing effects of the fabric scroll path were not measured.
- Nothing here speaks to #127 (transition hitch + bg-colour flash on all transition types), which is
  a separate, still-open defect with its own falsifying experiment.

## Device state left behind

- `quest_manager.sh` was killed for the session (it relaunches the engine with a bare environment,
  overwriting per-leg flags). It returns on the next core load.
- Prior logs preserved as `Solarus.diag.log.{baseline_off,autolaunch,prefix}`.
