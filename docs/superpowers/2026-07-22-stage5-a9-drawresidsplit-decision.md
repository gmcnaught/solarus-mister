# Stage 5 (A9 track) — `loop_residual` drill decision

**Date:** 2026-07-22
**Engine:** `libsolarus.so.1.6.5` (Task-1 build, deployed). **RBF** `Solarus_20260722.rbf`.
**Scene:** map 3 town (save1, teleport `out_link_house`), standing + moving.
**Raw:** `docs/superpowers/data/stage5-a9/drill-map3res.txt`.
**Method:** the drawsplit gate (`…-drawsplit-decision.md`) named `loop_residual` (~3.5–4 ms, ~68 % of
`engine_traversal`) the limiter and required one more drill. This drill needed **no new code**: the
engine already emits a `[MiSTer draw]` phase split under `SOLARUS_DRAW_PROF`
(`MainLoop::draw`), captured here alongside `[blitter drawsplit]`/`a9split` on the deployed engine.

## `[MiSTer draw]` phase split (median of 5 windows)

| phase | m3 standing | m3 moving | what it is |
|---|--:|--:|---|
| clear | 16.9 | 12.9 | **frame-pacing idle** — `root_surface->clear()` blocks on the fabric/vsync; equals the blitter `sleep`, NOT draw work. Not a lever. |
| game | 3.8 | 4.7 | `Game::draw` = map background + `entities->draw` + scaffolding + `game_on_draw` |
| lua_main | 0.0 | 0.0 | `main:on_draw` (HUD) — **free** |
| **composite** | **1.8** | **1.8** | `Video::render` root→screen full-frame blit — **motion-independent, real, DEAD** (finding 2) |
| present | ~1.0 | ~1.0 | `video_on_draw` + `Video::finish`→`present()` (noisy; overlaps the blitter present) |

**Reconciliation with the blitter accounting (exact):** `emit ≈ game + composite`
(standing 3.8 + 1.8 = 5.6 ≈ `a9split emit` 5.5; moving 4.7 + 1.8 = 6.5 ≈ 6.0–6.5). Therefore
`loop_residual = emit − (build+luahook+builtin) − remit − ovl ≈ composite (1.8) + game-scaffold
(game − entities ≈ 1.7)`. The two chunks of `loop_residual` are the root→screen blit and the
`Game::draw` scaffolding.

## Findings

1. **`clear` (13–17 ms) is the frame-pacing idle, not a cost.** It matches the blitter `sleep`
   (`[blitter timing]`), i.e. `root_surface->clear()` blocks until the single-buffered fabric is
   ready. It is where the A9's spare time goes; recovering A9 work shrinks it but it is not itself a
   lever.

2. **`composite` (1.8 ms, constant) is a DEAD full-frame blit — the selected lever.** `Video::render`
   (`work/solarus/src/graphics/Video.cpp:408-419`) does `screen_surface->clear()` + a full 320×240
   `proxy.draw(screen_surface, root_surface)` every frame. In the MiSTer FPGA-compositor path,
   `screen_surface` has **zero output consumers**: the overlay composite uploads `g_tagged_root` (the
   **root** surface, `mister_blitter_renderer.cpp:1483`), and the fabric scans out its own on-chip
   framebuffer — nothing reads `screen_surface`. Its only readers are `Video::render` itself and
   `video:on_draw(get_screen_surface())` (`MainLoop.cpp:680`), and the latter is already invisible in
   MiSTer (its target is never scanned out). The `SOLARUS_OPAQUE_BLITS` optimization already made this
   a straight copy instead of a BLEND, but the copy itself is pure waste. Motion-independent, real,
   ~1.8 ms/frame — **larger than every refuted lever (A/B/C/D, all <1 ms).**

3. **`lua_main` = 0 — HUD `on_draw` is free.** Not a lever.

4. **`game`-scaffold (~1.7 ms) is the secondary chunk** — `Game::draw` tileset-bg fill onto root
   (`Game.cpp:638`), `Map::draw_background`/`draw_foreground` (real map render), the camera→root blit
   (usually alias-skipped), `dialog_box.draw` (empty when no dialog), and `map_on_draw`/`game_on_draw`.
   Mixed real + possibly-reducible work; revisit after the composite lever lands.

## Named limiter + selected lever

**Named limiter:** the per-frame `Video::render` **root→screen full-frame blit** (the `composite`
phase) — ~1.8 ms/frame, motion-independent, and **dead** in the FPGA path (its output surface is
never scanned out). This is the largest single, cleanest per-frame A9 recovery found in the arc.

**Selected lever (SW-3, engine-only, no RBF): skip the redundant root→screen blit in `Video::render`
on the blitter path.** Gate behind a flag (e.g. `SOLARUS_SKIP_SCREEN_BLIT`, default-on for the
blitter compositor path, `=0` restores stock). Skip the `screen_surface->clear()` + `proxy.draw()`
when the fabric owns scanout (`SOLARUS_BLITTER` active) — the overlay path already uploads the root
surface, so nothing visible changes.

**Correctness bar (correctness-sensitive — this REMOVES a draw):**
- **Code invariant:** `screen_surface`/`get_screen_surface()` has no output consumer in the scanout
  path (verified: only `Video::render` + the already-invisible `video:on_draw`).
- **Operator visual gate (mandatory, never self-declared):** map 3 + a HUD scene + a dialog scene +
  a menu/title screen, flag-on vs flag-off, must be pixel-indistinguishable. If any quest relies on
  `video:on_draw` it would already be invisible in MiSTer — confirm none of the shipped scenes change.
- **A/B perf:** `[MiSTer draw] composite` → ~0; `[blitter a9split] emit` down ~1.8 ms; fps up
  (upper bound; step-amplified `lua` grows slightly).

**Expected magnitude:** ~1.8 ms of a ~15 ms (standing) / ~17 ms (moving) A9 budget; per-frame →
raises fps ~1:1. Standing A9 ~15 → ~13.2 ms (fps ~31 → ~35, upper bound).

## Refuted / deferred (this arc)

- **Lever A (draw-hook cache)** — refuted (drawsplit gate). **Lever C (z-sort)** — refuted (one-shot).
  **Lever B/D (geometry/dispatch)** — small (<1 ms).
- **`clear`** — frame-pacing idle, not a lever (finding 1).
- **`game`-scaffold (~1.7 ms)** — secondary; revisit after the composite lever (finding 4).
- **`lua`/eng_cpp** (#1 raw leaf) — still deferred (step-amplified, correctness-risky).

## References
- `docs/superpowers/data/stage5-a9/drill-map3res.txt` — raw ([MiSTer draw] + drawsplit + a9split).
- `docs/superpowers/2026-07-22-stage5-a9-drawsplit-decision.md` — parent (named loop_residual).
- `work/solarus/src/graphics/Video.cpp:395-419` — `Video::render` root→screen blit (the lever site).
- `work/solarus/src/core/MainLoop.cpp:671-732` — `MainLoop::draw` + the `SOLARUS_DRAW_PROF` split.
- `patches/mister/mister_blitter_renderer.cpp:1479-1485` — overlay composite uploads `g_tagged_root`.
