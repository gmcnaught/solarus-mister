# Stage 5 (A9 track) — Overlay content-identity skip — HW validation

**Date:** 2026-07-22
**Engine:** `libsolarus.so.1.6.5` sha1 `f1e98fe1` (overlay-skip lever, LuaJIT, lean SDL2),
deployed to the device. **RBF** `Solarus_20260722.rbf` (unchanged — no RBF change this lever).
**Flag:** `SOLARUS_OVERLAYSKIP` (opt-in, default-off). Drive: safe single-engine harness,
`-lua-console=yes` held-FIFO teleport (confirmed non-busy-polling — console thread 0.00 cores).
**Raw:** `docs/superpowers/data/stage5-a9/overlayskip-ab-raw.txt`.

## Step 2 — Correctness precheck (flag OFF, `[blitter overlayid] mode=measure`)

The digest + per-frame mutation guard were measured before enabling the skip:

| Phase (map 119) | overlay_frames | skippable | guard_fires |
|---|--:|--:|--:|
| **static HUD** (idle) | 60 | **60** | 0 |
| **HUD churn** (`add_money` every 50 ms → rupee redraws) | 60 | 6–32 | **28–54** |
| after churn stops | 60 | **60** | 0 |

**Verdict:** the digest identifies the static overlay as identical every frame (60/60
skippable — the win is ~100 % of standing frames), and the stale-HUD guard **fires** the
moment a HUD source is re-rendered (`guard_fires` jumps, `skippable` drops), then recovers.
This is the empirical proof that the lever will not skip a frame whose HUD actually changed.

## Step 3 — A/B (flag OFF vs ON), standing, both scenes

| Scene | `present` OFF | `present` ON | A9 OFF | A9 ON | fps OFF | fps ON |
|---|--:|--:|--:|--:|--:|--:|
| **map 119** | 6.3–6.4 ms | **0.5–0.6 ms** | 21.9–22.1 | **11.5–12.1** | ~20 | **29.5** |
| **map 3** | 6.6–6.7 ms | **0.5–0.8 ms** | 21.2–22.0 | **14.2–14.9** | 27.7 | **30.2** |

- **`present` collapses ~6.5 ms → ~0.6 ms** (−90 %) on both scenes — the redundant per-frame
  root ARGB4444 re-convert+re-upload is eliminated (`[blitter overlayid] mode=SKIP,
  skippable=60/60`). Matches the decision-doc prediction (present 6 → ~1 ms).
- **A9 drops more than `present` alone** (map 119 −10 ms, map 3 −7 ms): cutting a fixed
  per-frame cost raises fps, which reduces the catch-up-amplified update tick (`lua`) too —
  the super-linear leverage the decision doc predicted for a per-displayed-frame cost.
- **Regression guard:** flag-OFF reproduces the measure-first baseline `present` (~6.3–6.7 ms),
  so `=0` is a true no-op.

**Safety re-check with the flag ON (mode=SKIP):** repeating the HUD-churn test with the skip
*active* — `guard_fires` = 41–42, `skippable` = 18–19, i.e. frames where the rupee HUD
updates are **not** skipped. Reverts to 60/60 when static. So the live skip never serves a
stale HUD in this test.

## Step 4 — Operator visual gate — **PENDING**

Per the repo rule (never self-declare visual correctness), the final gate is the operator:
play with `SOLARUS_OVERLAYSKIP=1` and confirm the HUD/UI stay **live** — hearts update on
damage, rupee/magic counters on change, dialogs + pause menu open/animate, transitions/fades
render, no frozen/stale HUD element. The `guard_fires` evidence above strongly predicts a
pass, but the operator's eyes decide.

## Ship recommendation

Flip `SOLARUS_OVERLAYSKIP` **default-on** IF the operator visual gate passes clean — the A/B
shows a large, uniform win (present −90 %, A9 −7 to −10 ms, fps +2.5 to +9.5) with no
regression and a mechanically-proven stale-HUD guard. Until the operator gate passes, it stays
opt-in (default-off), exactly as shipped in this branch.

## References
- `docs/superpowers/2026-07-22-stage5-a9-decision.md` — the verdict this lever implements.
- `docs/superpowers/plans/2026-07-22-stage5-a9-overlay-skip-lever.md` — the implementation plan.
- `patches/mister/mister_overlay_id.h` + `mister_blitter_renderer.cpp` — the lever.
- Memory `solarus-luaconsole-heldfifo-no-busypoll` — the harness is not lua-console-confounded.
