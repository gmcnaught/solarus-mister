# Stage 5 (A9 track) — map 3 + map 119 A9 limiter decision

**Date:** 2026-07-22
**Engine:** `libsolarus.so.1.6.5` sha1 `bde7861d…` (on-device; full drill instrumentation
confirmed present — all `[blitter a9split…movedrill]` banner strings + `g_me_*` counters
in the deployed `.so`). **RBF** `Solarus_20260722.rbf` (current ship, enlarged P_SRC cache).
**Scenes:** map 119 parallax (save1, teleport `from_dungeon_10`) ; map 3 town (save1, teleport
`out_link_house`). Standing + moving (held DOWN).
**Raw:** `docs/superpowers/data/stage5-a9/drill-map{119,3}.txt` ; `decompose-map{119,3}.txt`.

This doc is committed **before** any lever code — the anti-bias gate (spec §4). The lever was
data-selected from the capture, not pre-picked. The brainstorm's working prior (a z-sorted
visible-entity cache, "lever 1e") was **refuted** by the data.

## Per-scene A9 decomposition (median of ≥3 windows; `*` = step-amplified)

| Leaf (ms) | m119 standing | m119 moving | m3 standing | m3 moving |
|---|--:|--:|--:|--:|
| **A9 total** | 21.2 | 29.7 | 20.3 | 25.0 |
| **present** (fixed) | **6.1** | **7.7** | **6.2** | **7.6** |
| emit_walk (fixed) | 3.8 | 4.1 | 4.9 | 5.4 |
| ent_entities `*` | 4.0 | 6.8 | 3.3 | 5.1 |
| — of which enemy | 3.8 | 6.3 | 2.3 | 3.4 |
| lua_vm `*` | 2.3 | 3.5 | 2.0 | 2.3 |
| ent_other `*` | 1.5 | 3.1 | 0.8 | 1.9 |
| ent_sound `*` | 1.3 | 2.0 | 1.0 | 1.6 |
| ent_hero / ent_tileset `*` | 0.9 / 0.9 | 1.4 / 1.4 | 1.2 / 0.7 | 1.3 / 0.8 |
| emit_blit | 0.0 | 0.0 | 0.0 | 0.0 |
| steps/fr | 5.03 | 5.05 | 3.53 | 3.75 |

**`[blitter hwperf]` bound verdict (HW busy counter):**
- map 3: **A9-bound** both states (fabric_hw ≈ 18.8 ms < A9). Clean A9 read.
- map 119: **A9-bound moving** (A9 29.7 > fabric_hw 27); standing is a coin-flip
  (fabric_hw 27 ≳ A9 21) — its standing fps is still gated on the FPGA track's fabric work.
  Moving is the operative A9-bound case, and it agrees with map 3.

**`[blitter cvt]` (both maps, every frame):** `dyn_reup = 4,608,000 px / 60 fr = 76,800
px/frame = exactly one 320×240 ARGB4444 surface`. The **root/overlay surface is
converted + re-uploaded every single frame**, standing or moving — this is the
`reupload_in_place` overlay-composite path.

**Reproducibility:** today's map 119 standing (A9 median 21.2 ms) matches the independently
captured, previously-committed `data/stage5/ab-enlarged-map119.txt` (A9 median 21.3 ms) — two
captures, different days, agree within 0.1 ms. Gate satisfied.

## Verdict — fork rule applied

**`present` is the #1 A9 leaf in ALL FOUR captures** (6.1–7.7 ms), and it is **fixed
per-frame** (not step-amplified) and **scene-independent** (near-constant across a parallax
overworld and a dense town). The `a9_decompose.py` `LEVER CANDIDATE` line agreed on all four:
`present dominant → overlay dirty-skip`.

**Named limiter:** the **per-frame overlay-composite re-upload** — `SDLRenderer` zeroes the root
to transparent every frame, the whole 320×240 root is re-converted
(`mpix::to_argb4444_unpremultiplied`, 76,800 px) + re-uploaded + re-emitted as the final
full-screen `PALPHA` blit, **whether or not the root's contents (HUD/dialog/menu/Lua draws)
actually changed**. During standing gameplay and plain walking the HUD is static most frames,
so most of this ~6 ms is redundant work.

**Why the working prior (lever 1e / z-sort cache) is refuted:** `emit_walk` is only 3.8–5.4 ms
and `emit_blit = 0` (all pixel work is on the fabric). A z-sort/visible-entity cache helps
only when the camera is static (it invalidates on camera move, like DRAWCACHE), so it cannot
touch the moving case — which is the A9-bound one. `present` beats it in every state.

**Leverage note:** `present` is per-frame (×1 leverage), whereas enemy/entities is
step-amplified (×3.5–5). But (a) `present` is the single largest leaf, (b) it is identical
standing and moving so the win is uniform, (c) the enemy cheap wins are **already banked**
(`[blitter movedrill]` shows `qtree_reinsert` ≈ 0.1–0.3 ms — QTREE_MARGIN=8 already crushed
it; the residual enemy cost is integration + obstacle-test, which memory
`solarus-enemy-per-update-cost-simd` documents as hard/behaviour-risky). Highest
magnitude × lowest correctness-risk × helps both scenes both states = `present`.

## The ONE lever (scoped)

**Overlay dirty-skip** — skip the per-frame root re-convert + re-upload + re-emit when the
root surface's contents did not change since the last frame; re-emit the cached full-screen
overlay blit instead. Gated `SOLARUS_OVERLAYSKIP` (name provisional), **default-off**, `=0`
= exact prior behaviour.

- **Expected magnitude:** up to ~5 ms/frame on frames where the HUD is static (present
  6 → ~1 ms). On the A9-bound legs: map 3 moving A9 25 → ~20 ms (fps ~27 → ~30);
  map 119 moving A9 29.7 → ~25 ms. Uniform standing + moving.
- **Files it will likely touch:** renderer-side, **whole-file** copy
  `patches/mister/mister_blitter_renderer.cpp` (the `clear()`/root-draw path + `present()`
  overlay-composite emit + the `reupload_in_place` upload). Very likely no `patches/series`
  engine change.
- **Correctness traps to TDD before HW:**
  1. **Stale HUD** — a false "unchanged" leaves last frame's HUD on screen. The dirty
     signal must be conservative: any draw op into the root this frame (HUD, dialog, menu,
     Lua `main_on_draw`/`game_on_draw`, fades) marks it dirty. Default to dirty when unsure.
  2. **Cheap dirty detection** — do NOT hash 153 KB/frame (that reintroduces the cost).
     Track a boolean "root touched" flag set by the renderer's `clear()`/blit-into-root
     interceptors; the root is zeroed to transparent each frame, so "no draw touched it"
     ⇒ identical-to-a-known-empty (or identical-to-previous if the same static HUD is
     redrawn — needs care: a redraw of identical pixels still "touches" it, so this lever
     wins on *frames with no HUD draws at all*, and a second-tier win — skip when the draw
     ops are byte-identical to last frame — is a follow-up only if tier-1 is insufficient).
  3. **Self-validating A/B** — like `GRIDOV`, the flag-on A/B *is* the attribution: if
     `present` drops, the upload was the cost; if it stays ~6 ms, the cost was
     `poll_input`/doorbell and the lever is inert (then re-scope). Cheap to prove.
- **Present sub-attribution (bounded-escalation, spec §3):** `[blitter cvt] dyn_reup`
  already proves the full-surface upload happens every frame; `poll_input` is a single
  `devmem` read and the doorbell is a few register writes + fence, so elimination points
  strongly at the upload. No probe rebuild is needed *before* the lever — the lever's own
  A/B confirms it. If flag-on leaves `present` unmoved, THEN add a bracket probe.

## Deferred (NOT this stage — one-lever discipline)

- **Enemy obstacle-test prune** (`entsplit` obstacle ≈ 0.5–2.9 ms; step-amplified) — the next
  candidate if more A9 headroom is needed after overlay-skip. Correctness-risky (collision).
- **z-sort visible-entity cache (lever 1e)** — standing-only benefit, refuted as the top
  lever here; revisit only for a standing-heavy scene.
- **`present` tier-2** (byte-identical-HUD skip) — only if tier-1 dirty-skip underdelivers.

## Consequence for the plan

Phase 3–4 (implement + HW-validate the lever) is authored as a **follow-on plan** off this
verdict (spec §4/§7): gated `SOLARUS_OVERLAYSKIP` default-off, TDD the dirty-signal
correctness, `-std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO` type-check, armhf build,
`deploy.py --no-rbf`, HW A/B at these exact spots (`from_dungeon_10` / `out_link_house`),
operator visual gate (never self-declared — watch the HUD/dialog for staleness).

## References
- `docs/superpowers/data/stage5-a9/` — raw drills + decompositions.
- `specs/2026-07-22-stage5-a9-lever-measure-first-design.md` §4 fork rule, §6 F1/device-contention.
- CLAUDE.md — the Overlay channel (root surface, `to_argb4444_unpremultiplied`, composited-last PALPHA blit).
- `solarus-enemy-per-update-cost-simd` — why the enemy residual is deferred (cheap part already banked).
