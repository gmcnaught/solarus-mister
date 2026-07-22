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

**`present` is the #1 A9 leaf in ALL FOUR captures** (6.1–7.7 ms), it is **per-frame**
(not step-amplified), and it has a **large scene-independent floor** (~6 ms standing on both a
parallax overworld and a dense town). The `a9_decompose.py` `LEVER CANDIDATE` line agreed on all
four: `present dominant → overlay dirty-skip`.

**Caveat (not fully fixed): `present` is NOT constant standing→moving.** It rises 6.1→7.7 (m119)
and 6.2→7.6 (m3), ~+1.5 ms (~25 %). The overlay upload is a fixed 76,800 px in all four captures
and so **cannot** explain that increase — a moving-correlated component (upload-bandwidth
contention against a busier fabric, ring/fence interaction, or the diag `ps_frame_end` source
loop) sits in the residual. So the ~6 ms floor is the redundant upload, but the moving legs carry
an extra ≥1.5 ms that the lever will **not** recover. Treat the fps projections below as **upper
bounds**.

**Named limiter:** the **per-frame overlay-composite re-upload** — `SDLRenderer` zeroes the root
to transparent every frame, the whole 320×240 root is re-converted
(`mpix::to_argb4444_unpremultiplied`, 76,800 px) + re-uploaded + re-emitted as the final
full-screen `PALPHA` blit. During standing gameplay and plain walking the *rendered result* (the
HUD over transparent) is pixel-identical frame to frame, so the ~6 ms floor is redundant work —
but see the lever section: this redundancy is **content-level**, not "surface untouched", and the
naive dirty-skip is already implemented.

**Why the working prior (lever 1e / z-sort cache) is refuted:** `emit_walk` is only 3.8–5.4 ms
and `emit_blit = 0` (all pixel work is on the fabric). A z-sort/visible-entity cache helps
only when the camera is static (it invalidates on camera move, like DRAWCACHE), so it cannot
touch the moving case — which is the A9-bound one. `present` beats it in every state.

**Leverage note:** `present` is per-frame (×1 leverage), whereas enemy/entities is
step-amplified (×3.5–5). But (a) `present` is the single largest leaf, (b) its ~6 ms floor is
present standing and moving so the recoverable win is uniform, (c) the enemy cheap wins are
**already banked** (`[blitter movedrill]` shows `qtree_reinsert` ≈ 0.1–0.3 ms — QTREE_MARGIN=8
already crushed it; the residual enemy cost is integration + obstacle-test, which memory
`solarus-enemy-per-update-cost-simd` documents as hard/behaviour-risky). Highest recoverable
magnitude × lowest correctness-risk = `present`. The per-frame leverage is a true fps multiplier
(attacking a per-displayed-frame cost raises fps ~1:1), whereas the step-amplified leaves
partially self-deflate as fps rises.

## The ONE lever (scoped) — corrected after the whole-branch review

**Important prerequisite the review caught:** the naive "skip when the root wasn't touched"
lever is **already implemented and cannot fire in gameplay.** `emit_overlay_composite()` is
gated on `overlay_touched` (`mister_blitter_renderer.cpp:1447`) and the re-upload is *already*
dirty-driven via `mark_src_dirty()` (:1435-1436). It still uploads every frame because
`MainLoop::draw()` issues an **unconditional** `root_surface->clear()` every frame (:1440-1441),
which touches the root → marks it dirty → re-uploads. The redundancy is therefore **content-level**:
the root is cleared then repainted to *pixel-identical* content (same static HUD over transparent),
and the upload of that identical result is what wastes ~6 ms. A "surface untouched" flag will never
be false in play, so the real lever must detect **content identity**, cheaply.

**Overlay content-identity skip** — when the sequence of draw operations painted into the root
this frame is identical to last frame, skip the re-convert + re-upload and re-emit the cached
overlay blit. Gated `SOLARUS_OVERLAYSKIP` (name provisional), **default-off**, `=0` = exact prior
behaviour.

- **Cheap identity signal — NOT a pixel hash.** Do **not** hash the 153 KB surface (that
  reintroduces the cost the lever removes). Instead hash the *draw-op parameter stream* into the
  root — the renderer already param-hashes draws for the `[blitter paramstab]` / `ps_add`
  diagnostic, so the machinery exists: fold each root-targeted draw's (src, dst-rect, blend, op)
  into a per-frame digest; identical digest to last frame ⇒ identical result ⇒ skip. A handful of
  HUD ops/frame, not 76,800 px.
- **Expected magnitude (UPPER BOUNDS — see Verdict caveat):** up to ~6 ms/frame on static-HUD
  frames (the redundant upload), but only ~4.5 ms of the moving legs' `present` is the upload
  (≥1.5 ms is a non-recoverable moving-variable term). Optimistic A9-bound projections: map 3
  moving 25 → ~21 ms (fps ~27 → ~29); map 119 moving 29.7 → ~26 ms. Standing benefits similarly
  (~6 → ~1 ms) but those legs are nearer fabric-bound so the fps move is smaller.
- **Files it will likely touch:** renderer-side, **whole-file** copy
  `patches/mister/mister_blitter_renderer.cpp` (the root-draw interceptors that build the digest +
  `emit_overlay_composite()`/`upload()` skip path). Very likely no `patches/series` engine change.
- **Correctness traps to TDD before HW:**
  1. **Stale HUD** — a false "identical" freezes the HUD. The digest must fold **every** draw op
     that can reach the root (HUD, dialog, menu, Lua `main_on_draw`/`game_on_draw`, fades) and
     any that draw from a *mutated* source surface (same op params, changed pixels — e.g. an
     animated HUD sprite whose frame advanced). Default to "changed" when a source surface is
     itself dirty. This is the sharp edge — get it wrong and a heart/rupee/dialog goes stale.
  2. **The upload path is a no-op-guard, not a re-emit skip, if done wrong** — the cached blit
     must still be *emitted* every frame (the ring is rebuilt per frame); only the *convert +
     upload* is skipped. Skipping the emit would drop the overlay entirely.
  3. **Self-validating A/B** — like `GRIDOV`, the flag-on A/B *is* the attribution: if `present`
     drops toward ~1 ms standing, the upload was the cost; if it stays ~6 ms, the cost was
     elsewhere (`ps_frame_end` diag loop / `poll_input` / doorbell) and the lever is inert —
     then add a bracket probe and re-scope.
- **Diag-tax note:** `present` is captured under `SOLARUS_BLITTER_DIAG=1`, and `present()` runs
  diag-only `ps_frame_end()` (loops ≤128 sources, :960) with no tax subtraction (unlike `emit`,
  which nets out `ps_add`). Likely sub-ms, but the shippable `present` headroom may be modestly
  below the measured 6 ms. The A/B runs under diag too, so attribution stays self-consistent.

## Deferred (NOT this stage — one-lever discipline)

- **`emit_walk` collapse** (3.8–5.4 ms, **per-frame, NOT step-amplified**) — the best-leveraged
  runner-up (better than the step-amplified enemy work, and `a9_decompose` itself lists
  "emit-walk collapse" as the alternative). The draw-walk/z-sort of the visible set. Revisit as
  the next lever after overlay-skip if more A9 headroom is needed.
- **Enemy obstacle-test prune** (`entsplit` obstacle ≈ 0.5–2.9 ms; step-amplified) — correctness-
  risky (collision); only after the cheaper per-frame levers.
- **z-sort visible-entity cache (lever 1e)** — standing-only benefit (camera-keyed invalidation),
  refuted as the top lever here; revisit only for a standing-heavy scene.

## Consequence for the plan

Phase 3–4 (implement + HW-validate the lever) is authored as a **follow-on plan** off this
verdict (spec §4/§7): gated `SOLARUS_OVERLAYSKIP` default-off, TDD the **content-identity digest**
correctness (fold every root-targeted draw op + guard against mutated source surfaces — trap #1),
`-std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO` type-check, armhf build,
`deploy.py --no-rbf`, HW A/B at these exact spots (`from_dungeon_10` / `out_link_house`),
operator visual gate (never self-declared — watch the HUD/dialog for staleness). The follow-on
plan MUST start from the corrected lever above, not the naive skip (which is already implemented
and inert).

## References
- `docs/superpowers/data/stage5-a9/` — raw drills + decompositions.
- `specs/2026-07-22-stage5-a9-lever-measure-first-design.md` §4 fork rule, §6 F1/device-contention.
- CLAUDE.md — the Overlay channel (root surface, `to_argb4444_unpremultiplied`, composited-last PALPHA blit).
- `solarus-enemy-per-update-cost-simd` — why the enemy residual is deferred (cheap part already banked).
