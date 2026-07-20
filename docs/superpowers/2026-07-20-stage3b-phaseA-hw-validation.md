# Stage 3b Phase A — HW validation record

**Date:** 2026-07-20
**Branch:** `feat/retained-scene-stage3b-tilemap` (14 commits off `master` @ `97ae768`)
**Plan:** `docs/superpowers/plans/2026-07-20-retained-scene-stage3b-phaseA-bake-deletion.md`
**Spec:** `docs/superpowers/specs/2026-07-20-retained-scene-stage3b-tilemap-channel-design.md`

## What was validated

Deletion of the host-side bgplane background-plane bake. **No RTL changed**, so this ran on the
existing core.

## Build and deploy provenance

| Item | Value |
|---|---|
| Core loaded | `Solarus_20260719.rbf` (`CORENAME=Solarus`) — correct; Phase A changed no RTL |
| Engine binary sha1 | `fb9d2f1fc39747bd3c4ac66ac94dc9794c2b06cb` |
| `libsolarus.so.1.6.5` sha1 | `7aaf2e0857b278ba7231f23f8cba516e9dd264cc` |
| Device sha1 match | **both verified identical on device** |
| Engines running | 1 (no two-engine wedge) |
| Log | `/media/fat/logs/Solarus/phaseA.log` |

Launched detached with a private `S0_FILE`, leaving `/media/fat/config/Solarus.s0` untouched so
`quest_manager` could not race the session.

## Objective results (machine-checkable)

- **`strings libsolarus.so.1.6.5 | grep -i bgplane` → nothing.** The subsystem is absent from the
  shipped artifact, not merely flag-disabled.
- **Zero `bgplane` mentions in the runtime log.** The launch banner reports OVERLAY, SPRITECH,
  SCROLLFAB and PALETTE, and carries no bgplane line at all.
- No errors, fatals, or ring overflow.
- PAL8 residency: 322 surfaces 8bpp-paletted, **0 CLUT-overflow**, perm 31.74 MiB — matches the
  known-good post-#84 state, confirming the deletion did not disturb asset residency.
- Host gates: `build_host_tests.sh` pass; `test_wire_constants.py` pass (37 host↔fabric pairs,
  file unedited); patch series 0001–0038 contiguous and round-trip byte-identical.

## Operator verdicts (the acceptance gate — not self-declared)

Operator's words: *"scroll transitions looked good, no hitch, no black frame."*

| Issue | Scope | Verdict |
|---|---|---|
| **#122** — scroll-transition hold frame | scroll only | **CLOSED** — confirmed absent |
| **#123** — scroll-transition black frame | scroll only | **CLOSED** — confirmed absent |
| **#127** — transition hitch + bg-colour flash | **all** transition types | **scroll leg PASSES; still open** — a fade-transition leg has not been observed, and #127 is explicitly filed as broader than scroll |

Note on #123: the Stage 3 spec only predicted this *probably* resolves. It did. Recorded as an
observation, not a confirmation of the prediction's reasoning.

## New observation — entity flicker after transition

Operator: *"a slight evidence of entities (bushes, doors) flickering in after transition."*

Operator decision: **track as a performance follow-up, do not bandaid with a guard.** Filed
separately. Deliberately NOT fixed in Phase A.

**Open question, stated plainly:** it is not established whether this flicker is pre-existing or
introduced by Phase A. No A/B against the pre-branch build was taken for it. Phase A touched only
the *static tile* emission seam (`resident_emit_static_layer`), whereas bushes and doors are
entities/dynamic tiles on the sprite channel — so a causal link is not obvious, but it is also not
ruled out. The follow-up issue must resolve this before assuming it is pre-existing.

## What this does NOT establish

- **Fade transitions were not observed** — so #127 is not closed.
- **No before/after A/B** was captured for the entity flicker.
- Phase B (`TilemapChannel` + `tilemap_unit` + bgplane RTL removal) is untouched by this session.
