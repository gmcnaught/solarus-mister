# Stage 5 (A9 track) — `emit_walk` decomposition design

**Date:** 2026-07-22
**Branch:** `feat/stage5-a9-next-lever` (off `origin/master` @ 238ebcf — overlay-skip merged, PR #137).
**Status:** design approved; Phase 1–2 in this spec, Phase 3 is a follow-on plan.

## Context — why this lever, why measure-first

The just-merged overlay-skip lever crushed the `present` A9 leaf (~6–7 ms → ~0.5 ms). Current-engine
data (`docs/superpowers/data/stage5-a9/overlayskip-ab-raw.txt`) shows the two target maps are now in
**different bottleneck classes**:

| | map 3 (town) | map 119 (parallax) |
|---|--:|--:|
| fps | ~50 | ~29 |
| `[blitter hwperf]` verdict | **A9-bound** | **FABRIC-bound** |
| A9 total | ~12 ms | ~12 ms |
| — present | ~0.5 ms | ~0.5 ms |
| — **emit (walk)** | **~5.2 ms** (per-frame) | ~3.8 ms |
| — lua/eng_cpp | ~5.8 ms (step-amplified) | ~8 ms |
| fabric_hw | ~10 ms | **~20 ms** (comp ~14.9 ms @ 73 % active) |

Consequences that scope this work:

- **Map 3 is A9-bound**; with `present` gone, the largest *per-frame* A9 leaf is `emit_walk` (~5.2 ms).
  Per-frame cost is a true fps multiplier (attacking it raises fps ~1:1), unlike the step-amplified
  `eng_cpp`/enemy leaves that self-deflate as fps rises. The prior decision doc
  (`2026-07-22-stage5-a9-decision.md`) named `emit_walk` collapse as the deferred, best-leveraged
  runner-up.
- **Map 119 is FABRIC-bound** (fabric_hw ~20 ms ≫ A9 ~12 ms). **No A9 lever can raise map 119's fps** —
  lifting it needs a fabric/RTL lever (new RBF), tracked separately. The prior K-grid decomposition
  (`SOLARUS_GRIDOV`) was built and measured **perf-neutral**; the P_SRC cache enlargement (Phase 1,
  shipped `Solarus_20260722.rbf`) gave the partial fabric win. This spec does **not** address map 119's
  fabric bound. (Decision recorded with the user: A9 `emit_walk` first, map 119 fabric a later track.)

**Why measure-first (not "just build the obvious lever"):** `emit_walk` is currently a black box.
`[blitter emitsplit]` splits `emit` only into `walk` vs `blit`, and `blit ≈ 0.0 ms` (all pixel work is on
the fabric), so `walk ≈ emit`. Below that there is no attribution. The renderer facts already pinned down:
- the resident tile emit is **cheap** — one `blt_tile_list_static` / `OP_TILEMAP` command per bucket
  referencing a *resident* TL_BUF (map 3: `buckets=1`, `entries=1016`, `tl_used=8128 B`), **not** 1016
  per-frame ring writes; the patch pass is 251 CFT-byte writes;
- `[blitter drawcat]` shows `anim_tiles=0/fr + entities=61/fr` — all tiles ride the resident channel, so
  the walk's variable cost is the **61 entity draws** (engine traversal + per-sprite push), ~80 µs/draw,
  which is high enough to suspect the per-sprite resolution path rather than pure traversal.

The obvious lever the prior doc *named* — a z-sort / visible-set cache — was in the **same doc refuted as
standing-only** (camera-move invalidates it), and moving is the A9-bound case. If instead the 5 ms is
per-sprite resolution (`map_blend`/`upload`/buffer, re-run for all 61 sprites every frame), that is
motion-independent and cacheable — a real moving-case win. **We do not know which.** Guessing risks
building the wrong thing. This spec adds the missing attribution first, then a follow-on plan selects the
lever from the data — the same anti-bias discipline that produced the overlay-skip lever (decision doc
committed *before* the lever, target data-selected).

## Scope

**In scope (this spec):** Phase 1 (walk sub-bracket instrumentation) + Phase 2 (HW capture + committed
decision doc). Pure instrumentation — zero behaviour change, zero correctness risk.

**Out of scope:** Phase 3 (the actual optimization lever) — a follow-on plan authored off the Phase 2
decision doc. Map 119's fabric bound — a separate RTL track.

## Component 1 — walk sub-brackets (instrumentation)

Add three `ScopedNs` accumulators (the existing RAII ns-accumulator at
`mister_blitter_renderer.cpp:172`; diag-gated, a predictable-branch no-op when diag is off — identical
mechanism to the shipped `g_emit_blit_ns` / `g_emit_psadd_ns`). Each wraps a verified call site:

| Accumulator | Measures | Wrap site |
|---|---|---|
| `g_sprite_push_ns`   | per-sprite resolution (`map_blend` + `upload` + channel buffer) | `sprite_channel_push` (`:2217`) |
| `g_resident_emit_ns` | resident tilemap/tile-list command emit | `res_emit_bucket_` (`:3330`) **and** `res_emit_static_bucket_` (`:3371`) |
| `g_overlay_ns`       | root convert + composite + upload | `emit_overlay_composite` (`:1462`) |

Each accumulator is `volatile long long`, module scope, reset per report window (like the existing
`g_emit_*`). The wrap is one `ScopedNs _x(&g_<name>_ns, diag);` at function entry — no early-return leaks
(RAII fires on every exit path).

**Nesting note (must not double-count):** `sprite_channel_push` is called from
`MisterBlitterRenderer::draw()` (`:2813`); `res_emit_*` and `emit_overlay_composite` are called from the
engine-driven emit path, disjoint from `sprite_channel_push`. The three buckets are mutually exclusive by
construction (different call trees), so summing them and subtracting from `emit` yields a clean residual.
`g_emit_blit_ns` (inside `emit_draw`) is a *separate* path from `sprite_channel_push` (the batched channel);
in the resident+sprite-channel configuration these captures do not overlap. If a future config routed a
sprite through both, the residual (Component 2) would surface it as a negative term — the built-in guard.

## Component 2 — attribution + `[blitter walksplit]` banner

In the once-per-60fr report block, adjacent to `[blitter emitsplit]` (`:3728`), read+reset the three
accumulators and print:

```
[blitter walksplit] /60fr: walk=5.0ms = engine_traversal=X + sprite_push=Y + resident_emit=Z + overlay=W
```

- `sprite_push (Y)`, `resident_emit (Z)`, `overlay (W)` = each accumulator / N / 1e6 (N = 60).
- `engine_traversal (X) = emit_ms − Y − Z − W − blit_ms` — the residual: Solarus `Entities::draw` z-sort +
  per-drawable virtual dispatch (engine code) plus our thin `draw()` glue. `blit_ms` is the existing
  `g_emit_blit_ns` term (≈ 0).
- **Self-check:** `X` must be ≥ 0. A negative `X` means a bracket is mis-scoped or double-counted (e.g. a
  nesting the note above missed) — treat it as a bug in the instrumentation, fix before trusting the
  capture, do not ship a decision off a negative residual.

Print unconditionally inside the existing `if (diag)` report path (same gating as every other banner).

## Component 3 — capture protocol + decision gate

1. **Type-check** the renderer edit natively (CLAUDE.md recipe, `-std=c++17 -DMISTER_NATIVE_VIDEO
   -DMISTER_NATIVE_AUDIO`) — both `-D` flags mandatory or the `#ifdef MISTER_NATIVE_VIDEO` body isn't
   compiled and the check is worthless.
2. **Host suite** `bash tests/run_tests.sh` stays green (the edit touches no host-modeled logic).
3. **Extend `scripts/perf/a9_decompose.py`** (+ `scripts/perf/test_a9_decompose.py`) to parse the
   `walksplit` line and surface the four sub-leaves in its decomposition table. TDD: add the parser test
   first against a captured sample line, watch it fail, implement.
4. **Build** the engine (`bash scripts/build_engine.sh`); confirm the banner string is in the binary
   (`strings build/armhf/libsolarus.so.1.6.5 | grep -c 'blitter walksplit'` ≥ 1).
5. **Deploy engine-only** (`./deploy.py --no-rbf`; verify on-device `.so` sha1). No RBF — host
   instrumentation only.
6. **Capture** with `scripts/perf/capture_a9_drill.sh` at the prior decision doc's exact spots
   (`MAP=3 DEST=out_link_house TAG=map3`, `MAP=119 DEST=from_dungeon_10 TAG=map119`), standing + moving,
   under `SOLARUS_BLITTER_DIAG=1`. Save raw to `docs/superpowers/data/stage5-a9/walksplit-map{3,119}.txt`.
7. **Gate — commit the decision doc BEFORE any lever code.** Write
   `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md`: the median-of-≥3-windows walksplit for
   each map/state, the named dominant sub-leaf, and the selected Phase 3 lever with its expected magnitude
   and correctness traps. Reproducibility check: `walk` total must match the `emit` from the same window's
   `[blitter emitsplit]` (they measure the same quantity two ways).

## Phase 3 (follow-on, NOT this spec) — candidate levers

The decision doc selects exactly one, data-driven. Named here only so the follow-on plan has a starting
menu; none is pre-chosen:

- **Per-sprite resolution cache** (if `sprite_push` dominates) — memoize the resolved blit params per
  `(src surface, frame, blend, opacity)` so repeat/static sprites skip `map_blend`/`upload`. Motion-
  independent ⇒ helps the moving case. Correctness trap: staleness on animation-frame or source-pixel
  change — needs a mutation guard like the overlay-skip's `written_this_frame`.
- **Dispatch-overhead reduction** (if `engine_traversal` dominates and is our glue, not pure engine) —
  reduce the per-drawable virtual-call/routing cost in `draw()`.
- **Z-sort / visible-set cache** (if `engine_traversal` dominates and is engine z-sort) — cache the
  z-sorted visible drawable list across frames. **Known low-value for moving** (camera-keyed
  invalidation, refuted in `2026-07-22-stage5-a9-decision.md`); selected only if the data forces it and
  a standing-only win is accepted.

Phase 3 carries its own `SOLARUS_*` flag (default-off), TDD'd bit-exact/host test, HW A/B, and operator
visual gate (never self-declared — see `solarus-no-self-declared-visual-validation`).

## Correctness

This spec's scope is three RAII timers + one `fprintf`, all behind the existing `diag` bool. It cannot
change an emitted pixel or command, standing or moving, diag on or off (accumulators are `volatile
long long`, never read by any emit path). The `SOLARUS_BLITTER_DIAG`-off path is byte-identical to master.
The only new correctness surface is the `a9_decompose.py` parser, covered by its unit test.

## References

- `docs/superpowers/2026-07-22-stage5-a9-decision.md` — prior A9 decomposition; names `emit_walk` as the
  deferred runner-up and refutes the z-sort cache for moving.
- `docs/superpowers/data/stage5-a9/overlayskip-ab-raw.txt` — current-engine (post-overlay-skip) data
  underpinning the map 3 A9-bound / map 119 fabric-bound split.
- `docs/superpowers/2026-07-21-stage5-fabric-parallelization-analysis.md` — map 119 fabric bound
  (fetch → cache), context for why the A9 lever cannot lift map 119.
- `mister_blitter_renderer.cpp` — `ScopedNs` (:172), `emit_overlay_composite` (:1462),
  `sprite_channel_push` (:2217), `res_emit_bucket_` (:3330), `res_emit_static_bucket_` (:3371),
  `[blitter emitsplit]` report (:3728).
- CLAUDE.md — native type-check recipe; whole-file-copy status of `mister_blitter_renderer.cpp`.
