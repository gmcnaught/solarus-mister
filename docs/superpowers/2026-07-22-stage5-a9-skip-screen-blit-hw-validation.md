# Stage 5 (A9 track) — SW-3 skip-screen-blit HW validation

**Date:** 2026-07-22
**Change:** series patch `0042` — skip the dead `Video::render` root→screen full-frame blit on the
FPGA compositor path. **Default-ON** when `SOLARUS_BLITTER` owns scanout; `SOLARUS_SKIP_SCREEN_BLIT=0`
restores the stock blit; never skipped on the shader path. **Engine-only, no RBF.**
**Ship:** `libsolarus.so.1.6.5` sha1 `002eb946…` (device-verified). RBF `Solarus_20260722.rbf` (unchanged).
**Scene:** map 3 town (save1, teleport `out_link_house`), standing + moving.
**Raw:** `docs/superpowers/data/stage5-a9/drill-m3-{A-baseline,B-skipblit,C-defaulton}.txt`.

## A/B/C result (median of 5 windows)

| metric | A: flag OFF (baseline) | B: `SKIP_SCREEN_BLIT=1` | C: default-on (no flag) |
|---|--:|--:|--:|
| **fps standing** | 30.7 | 52.9 | **52.9** |
| **fps moving** | 32.1 | 40.5 | — |
| A9 standing (ms) | 15.4 | 9.5 | 9.6 |
| A9 moving (ms) | 17.8 | 13.8 | — |
| `[MiSTer draw] composite` (ms) | 1.6 | **0.0** | **0.0** |
| `[blitter a9split] emit` (ms) | 5.7 | 3.9 | 3.8 |
| `lua` standing (ms) | 8.7 | 4.9 | 5.1 |
| steps/fr standing | 3.25 | 1.85 | ~1.9 |

## Verdict: PASS

1. **The blit is eliminated.** `[MiSTer draw] composite` 1.6 → **0.0 ms** with the flag on (B) and by
   default (C). `blits/frame` 9 → 8, `tgt_switch` 2 → 0 — the full-frame root→screen copy is gone.

2. **The win far exceeds the 1.8 ms blit — it compounds.** Standing A9 dropped **15.4 → 9.5 ms**
   (−5.9 ms) and **fps 30.7 → 52.9 (+72 %)**. The blit itself is ~1.8 ms; the rest is
   **step-amplification unwinding**: higher fps → fewer game-logic catch-up steps per displayed frame
   (`steps/fr` 3.25 → 1.85) → less `lua` per frame (8.7 → 4.9 ms) → higher fps still. Moving:
   fps 32.1 → 40.5 (+26 %). Map 3 standing is now near the 60 cap.

3. **Default-on verified.** With no flag set and the device lib sha-verified (`002eb946`), C shows
   `composite=0`, A9 9.6 ms, fps 52.9 — identical to the explicit-flag B. (An earlier default-on
   capture showed `composite=1.6`/`present=6 ms`/`readpix=1`; root-caused to a **stale device lib** —
   a FAT open-exe overwrite skipped by a daemon-relaunched engine — not a logic error. Fixed by a
   firm kill of all engines/daemons + redeploy + sha verification. Recorded so the trap is not
   re-hit.)

4. **Operator visual gate: PASS.** User confirmed map 3 renders correctly with the blit skipped
   ("It's visually correct"). Consistent with the code invariant: `screen_surface` has no scanout
   consumer (independently verified by exhaustive grep in the SW-3 task review), the fabric composites
   from the root overlay (`g_tagged_root`) + camera alias — neither touched by this change — so the
   scanned-out frame is identical by construction.

## Correctness basis (for the record)
- `screen_surface` / `get_screen_surface()` consumers: only `Video::render` (the skipped writer) and
  `video:on_draw` (already invisible in MiSTer — its target is never scanned out). No output/scanout
  reader. Overlay composite uploads `g_tagged_root` (`mister_blitter_renderer.cpp:1483`).
- Never skipped on the shader path (`final_draw_with_shader`) — a shader needs the screen composite.

## References
- `patches/series/0042-perf-video-skip-dead-root-screen-blit-on-blitter-pat.patch` — the change.
- `docs/superpowers/2026-07-22-stage5-a9-drawresidsplit-decision.md` — the lever's decision + `[MiSTer draw]` drill.
- `docs/superpowers/data/stage5-a9/drill-m3-{A,B,C}-*.txt` — raw A/B/C captures.
