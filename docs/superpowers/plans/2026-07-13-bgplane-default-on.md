# SOLARUS_BGPLANE default-on — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip `SOLARUS_BGPLANE` to default-on so the per-layer static plane bake ships, collapsing the parallax map's ~1,500 per-frame BLEND draws into baked plane COPYs (the large fabric-side perf win), after proving bake × PAL8 in sim and HW-validating that backgrounds stay clean.

**Architecture:** The full bgplane × PAL8 datapath already exists on the base branch (inherited from PR #120's shared `res_bucket_params` refactor). This plan (1) adds the never-before-run bake × PAL8 correctness gate in sim, (2) HW-validates bgplane-ON opt-in, then flips the default, and (3) holds one host-side contingency for the narrow partial-alpha bake defect if HW shows it.

**Tech Stack:** SystemVerilog (Icarus/iverilog, `fpga/sim`), C++17 host renderer (`patches/mister/`, armhf cross-build in Docker), bash patch-series tooling, on-device HW validation (MiSTer `192.168.20.81`).

**Design doc (source of truth):** `docs/superpowers/specs/2026-07-13-bgplane-default-on-design.md`. Read it before starting.

## Global Constraints

- **Base:** `origin/master` @ `58d2691` (PR #120 merged). Branch: `feat/bgplane-default-on`. Do NOT rebase onto the pre-#120 `test/fast-follow-tbs-*` branch — it lacks the paletted infra this work depends on.
- **No RBF re-synth expected.** bgplane × PAL8 is host-only on top of the #120 32-bank RBF. Re-synth only if Task 1's sim gate reveals a real fabric gap.
- **Canonical renderer source:** `patches/mister/mister_blitter_renderer.cpp` (a whole-file source carried by `patches/series/0001-*.patch`). After ANY edit to a `patches/mister/*` file you MUST regenerate the series: `scripts/export_patches.sh`, then confirm round-trip with `scripts/verify_patches.sh`. Pin `git -c diff.algorithm=myers` if your git default is `patience` (CI round-trip breaks otherwise — `[[solarus-ci-patch-roundtrip-and-astgrep-config]]`).
- **Revert path:** `SOLARUS_BGPLANE=0` forces the flag off at runtime (via `mister_flag_default_on` semantics: on unless env is literally `"0"`).
- **Sim runner:** `cd fpga/sim && ./run_sims.sh <tb_name>` runs a subset; `./run_sims.sh` runs all. A new `tb_*.sv` gates on printing `PASS` and printing none of `FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|PROTO:|TIMEOUT`. Default timeout budget is 120 s; add a case in `budget_for()` only if the TB needs more.
- **Visual validation is mandatory and human-driven.** NEVER self-declare a frame visually correct (`[[solarus-no-self-declared-visual-validation]]`). The default-on flip commit lands ONLY after the operator confirms clean backgrounds on HW.
- **Deploy:** refresh `deploy/` from `build/armhf/{solarus-run,libsolarus.so.1.6.5}` first, then `./deploy.py [--no-rbf]`. Verify sha1 after upload (FAT truncation gotcha).

## File Structure

- **Create** `fpga/sim/tb_pal8_bgplane.sv` — the bake × PAL8 correctness gate. One responsibility: prove a PAL8 source baked through `OP_BGPLANE_WRITE` reads back as CLUT-resolved RGB565 (opaque) / untouched background (transparent). Composes the harnesses of `tb_pal8_tilelist.sv` (CLUT + PAL8 tile-list) and `tb_bgplane_equivalence.sv` (bake → readback).
- **Modify** `patches/mister/mister_blitter_renderer.cpp` — line 2166 (flag read) + line 562 (comment). Single-line behavior change.
- **Modify (regenerated, not hand-edited)** `patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch` — via `scripts/export_patches.sh`.
- **Modify (contingency only)** `patches/mister/mister_blitter_renderer.cpp` — static-bucket routing split (Task 3, only if HW shows static-translucent corruption).

---

## Task 1: bake × PAL8 correctness gate (sim)

Prove, deterministically and before any HW cycle, that a PAL8 source layer baked into a plane reads back correctly. This composition has never been exercised. Expected to pass with no RTL change; a failure localizes a real fabric gap.

**Files:**
- Create: `fpga/sim/tb_pal8_bgplane.sv`
- Model (read, copy scaffolding — do NOT modify): `fpga/sim/tb_pal8_tilelist.sv`, `fpga/sim/tb_bgplane_equivalence.sv`

**Interfaces:**
- Consumes (from `tb_pal8_tilelist.sv`): `comp_clut.vh` params (`CLUT_BANKS`=32, `CLUT_ENTRIES`=256, `CLUT_MAKE(a4,rgb565)`, `CLUT_BUF_QW`); the CLUTBUF-region SDRAM-model branch (`raddr >= CLUT_BUF_QW …`); `seed_clut` (fills `clut_mem[g] = {32'd0, CLUT_MAKE(4'hF, g[15:0])}` so global entry `g` decodes to RGB565 `g[15:0]`, A4=F); `blt_pal_color` packing `{pal_id[4:0]<<8 | base_off[7:0]}`; `wr_tilelist(blend, fmt, flags, stride, …, color, eoff, bx, by)` with `fmt = COMP_PAL8`; `getpx(dx,dy)`.
- Consumes (from `tb_bgplane_equivalence.sv`): the bake→readback sequence — coverage/WORK clear FILL (`wr_fill(…, flags=BLT_F_BGCOV)` and the RGB-clear FILL), `wr_bgw`/`wr_bgw_flags(plane_qw, stride_qw)` (`OP_BGPLANE_WRITE`), `flush_to_sdram`, and the readback COPY blit over a fresh lower layer; `set_ctrl`, `run_submit`, the sdram model, clock/reset/init-wait boilerplate.
- Produces: a self-checking TB printing `RESULT: PASS` (and none of the FAIL tokens) when the bake resolves PAL8 correctly.

- [ ] **Step 1: Write the TB (this is the failing test).** Create `fpga/sim/tb_pal8_bgplane.sv`. Copy the clock/reset/SDRAM-model/init-wait/`run_submit`/`set_ctrl` boilerplate from `tb_bgplane_equivalence.sv`; copy the CLUTBUF SDRAM-model branch, `comp_clut.vh` include, `seed_clut`, and `blt_pal_color`/`COMP_PAL8` usage from `tb_pal8_tilelist.sv`. Use a small reduced geometry (e.g. one bake cell, a single-tile PAL8 source) so it fits the 120 s budget. Concretely:

  - Params: `localparam [4:0] PAL_ID = 5'd5; localparam [7:0] PAL_BASE = 8'd0;` (non-zero bank proves header pal_id bank-select survives the bake); `localparam PAL_COLOR = blt_pal_color(PAL_ID, PAL_BASE);`.
  - Seed a PAL8 source tile with a **transparent index** and an **opaque index**. Model the CLUT so the opaque index's global entry decodes to a known RGB565 (A4=F), and reserve one index whose CLUT entry is A4=0 (transparent). Reuse `seed_clut`'s convention but override the transparent index's A4:
    ```systemverilog
    // opaque index OP_IDX -> CLUT[PAL_ID*256+PAL_BASE+OP_IDX] = {A4=F, RGB565=OP_RGB}
    // transparent index TR_IDX -> CLUT[...+TR_IDX] = {A4=0, RGB565=<don't-care>}
    localparam [7:0]  OP_IDX = 8'd7, TR_IDX = 8'd0;
    localparam [15:0] OP_RGB = 16'hABCD, LOWER = 16'h1357; // LOWER = readback background
    ```
  - Golden expectation (mirror `tb_pal8_tilelist.sv:golden_px`):
    ```systemverilog
    function [15:0] golden_bake(input [7:0] idx);
      // opaque index resolves to CLUT RGB; transparent index leaves the lower layer.
      golden_bake = (idx == TR_IDX) ? LOWER : clut_decode(PAL_ID*256 + PAL_BASE + idx);
    endfunction
    ```
  - Sequence: (a) upload CLUT (`BLT_OP_CLUT_UPLOAD`, as `tb_pal8_tilelist`); (b) bake — clear-WORK FILL, `BLT_F_BGCOV` coverage-clear FILL, `wr_tilelist(COPY, COMP_PAL8, flags, stride, …, PAL_COLOR, eoff, 0, 0)` painting the PAL8 tile into WORK, then `wr_bgw_flags(plane_qw, stride_qw)`; (c) `flush_to_sdram`; (d) readback — fill a fresh lower layer with `LOWER`, then COPY-blit the plane back on top; (e) assert.
  - Assertion (gating):
    ```systemverilog
    mism = 0;
    for (yy=0; yy<TILE_H; yy=yy+1) for (xx=0; xx<TILE_W; xx=xx+1) begin
      exp = golden_bake(idx_at(xx,yy));
      if (getpx(xx,yy) !== exp) begin
        if (mism < 12) $display("  PAL8-BGPLANE MISMATCH (%0d,%0d): exp=%h got=%h", xx, yy, exp, getpx(xx,yy));
        mism = mism + 1;
      end
    end
    if (mism == 0) $display("PAL8-BGPLANE bake==CLUT: RESULT: PASS (%0d px)", TILE_W*TILE_H);
    else           $display("PAL8-BGPLANE bake==CLUT: FAIL (%0d mismatches)", mism);
    $finish;
    ```

- [ ] **Step 2: Run it, expect PASS (or a localizing FAIL).**

Run: `cd fpga/sim && ./run_sims.sh tb_pal8_bgplane`
Expected: `RESULT: PASS`. If it prints `FAIL`, the bake genuinely mis-decodes PAL8 — STOP and diagnose (`superpowers:systematic-debugging`); this is the gap the gate exists to catch, and it would mean an RTL fix + re-synth (escalate to the operator; revisit the spec's "no re-synth expected" assumption).

- [ ] **Step 3: Confirm no regression across the sim suite.**

Run: `cd fpga/sim && ./run_sims.sh` (or at least `./run_sims.sh tb_bgplane_equivalence tb_pal8_tilelist tb_pal8_lookup tb_pal8_fill_8bpp tb_tilelist tb_tilelist_res`)
Expected: all gating TBs PASS; the pre-existing `tb_bgplane_equivalence` partial-alpha case stays `KNOWN-DEFECT` (non-gating). If `tb_pal8_bgplane` exceeds 120 s, add `tb_pal8_bgplane) echo 300 ;;` to `budget_for()` in `run_sims.sh`.

- [ ] **Step 4: Commit.**

```bash
git add fpga/sim/tb_pal8_bgplane.sv fpga/sim/run_sims.sh
git commit -m "test(sim): prove bgplane bake resolves PAL8 sources to CLUT RGB565 (tb_pal8_bgplane)"
```

---

## Task 2: HW-validate bgplane-ON, then flip default-on

Validate on device using the existing opt-in env (no code change yet), then land the one-line default flip. The flip commit is LAST and gated on the operator's visual confirmation.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:2166` (flag read) and `:562` (comment)
- Regenerate: `patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch` (via `scripts/export_patches.sh`)

**Interfaces:**
- Consumes: `mister_flag_default_on(const char*)` (`mister_blitter_renderer.cpp:95`) — returns `true` unless the env var is literally `"0"`.
- Produces: `bgplane_enabled` defaulting ON; `SOLARUS_BGPLANE=0` as the revert.

- [ ] **Step 1: Build the current (opt-in) engine + deploy.** Build via the Docker armhf toolchain (`scripts/build_engine.sh`), refresh `deploy/` from `build/armhf/{solarus-run,libsolarus.so.1.6.5}`, then `./deploy.py --no-rbf` (the #120 32-bank RBF is already the target on device; only if the device RBF predates #120, ship it too). Verify the deployed `libsolarus.so.1.6.5` sha1 matches the build.

- [ ] **Step 2: Launch with bgplane ON (opt-in — no default change yet) + timing diag.** On device:
```
SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH=/media/fat/games/solarus/libs:. \
  SOLARUS_BLITTER=1 SOLARUS_BLITTER_SINGLEBUF=1 SOLARUS_BGPLANE=1 SOLARUS_BLITTER_DIAG=1 \
  ./solarus-run -force-software-rendering /tmp/solarus_quest 2>&1 | tee /tmp/solarus.log
```
(Detached-launch recipe for survive-disconnect: `[[solarus-ssh-launch-dies-on-disconnect]]`.)

- [ ] **Step 3: Objective gate — parallax perf.** Drive to the parallax map. In `/tmp/solarus.log` confirm vs. the ~15 fps / ~1,500-BLEND baseline (`[[solarus-parallax-fabric-bound-perf]]`): `[blitter p0]` BLEND draws/frame drop sharply (the layers are now baked, not per-tile BLENDed), fabric period falls / fps rises, and the bake shows no escalating ring-overflow or `upload_fail_buckets` (the `[MiSTer bgplane] FATAL` line must NOT appear). Record the numbers in the spec's validation notes.

- [ ] **Step 4: Human visual gate (operator, required).** Walk the `[[solarus-84-luaconsole-teleport-repro]]` route through ≥6 distinct tilesets AND across several dungeon transitions. Capture screenshots (mrext ws `kbd:screenshot`, recipe in `[[solarus-120-paletted-hw-validation-fail]]`). The operator confirms: backgrounds render clean (the bgplane-ON confirmation that the shared #84 fix carries to the bake path). **Do NOT self-declare — wait for the operator's verdict.**
  - If clean → proceed to Step 5.
  - If static-translucent corruption (dark/opaque pots/shadows/still-water blocks, sprites/UI fine) → go to **Task 3**, then re-run Steps 1–4.
  - If broad background corruption (like classic #84) → STOP; the #120-inheritance assumption failed; diagnose before flipping.

- [ ] **Step 5: Flip the default.** Edit `patches/mister/mister_blitter_renderer.cpp`:
  - Line 2166: `self->d->bgplane_enabled = (std::getenv("SOLARUS_BGPLANE") != nullptr);`
    → `self->d->bgplane_enabled = mister_flag_default_on("SOLARUS_BGPLANE");  // HW-validated default ON (parallax perf); SOLARUS_BGPLANE=0 forces off`
  - Line 562 comment: change `SOLARUS_BGPLANE, opt-in (default OFF until HW-validated)` → `SOLARUS_BGPLANE, HW-validated default ON (SOLARUS_BGPLANE=0 forces off)`.

- [ ] **Step 6: Regenerate + verify the patch series.**

```bash
git -c diff.algorithm=myers scripts/export_patches.sh 2>/dev/null || scripts/export_patches.sh
scripts/verify_patches.sh
```
Expected: `verify_patches.sh` reports the series round-trips byte-identically (no diff). If it reports a diff, re-run `export_patches.sh` with `diff.algorithm=myers` pinned.

- [ ] **Step 7: Rebuild default-on engine, deploy, re-confirm the OSD launch path.** Rebuild (`scripts/build_engine.sh`), refresh `deploy/`, `./deploy.py --no-rbf`. Launch WITHOUT `SOLARUS_BGPLANE` in the env (as the real `solarus_run.sh` OSD path does) and confirm the log shows bgplane active and the parallax perf gate (Step 3) still holds — i.e. the default now delivers what the opt-in did.

- [ ] **Step 8: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch
git commit -m "feat(render): SOLARUS_BGPLANE default-on — ship the per-layer static plane bake (parallax perf)"
```

---

## Task 3 (CONTINGENCY — only if Task 2 Step 4 shows static-translucent corruption)

Route static **translucent** buckets off the bake and back onto the per-frame resident tile-list, so the alpha-less-WORK + binary-coverage bake never packs a partial-alpha tile as opaque-darkened. Only opaque static layers get baked. Skip this task entirely if HW backgrounds were clean.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (static-bucket routing in `resident_record_static` / the bake loop in `bake_background_plane_step`)
- Regenerate: `patches/series/0001-*.patch` (via `scripts/export_patches.sh`)

**Interfaces:**
- Consumes: `StaticBucket{ …, uint8_t blend, uint8_t fmt, … }` (`:534`); `res_bucket_params` sets `bl`/`fmt` (blend `PALPHA`=translucent per `map_blend`). The bake loop at `:2816` iterates `res_static_buckets` for the layer.
- Produces: bake consumes only opaque buckets; translucent static buckets emit via the resident tile-list each frame (unchanged visual result, no bake corruption).

- [ ] **Step 1: Write the failing check.** Add a focused host assertion (extend `tests/pal_restage_test.c` or a small new host test): given a synthetic bucket set with one opaque (`blend=COPY`) and one translucent (`blend=PALPHA`) static bucket, the set routed to the bake contains only the opaque bucket, and the translucent bucket appears in the per-frame resident emit list. Assert the partition.

- [ ] **Step 2: Run it, expect FAIL** (routing not yet split — the translucent bucket is currently baked).

Run: `cd tests && cc -o /tmp/t pal_restage_test.c && /tmp/t` (match the existing test's build line).
Expected: FAIL on the partition assertion.

- [ ] **Step 3: Implement the split.** In `bake_background_plane_step`'s per-bucket loop (`:2816`), skip buckets whose `b.blend == BLT_BLEND_PALPHA` (translucent). In the resident static emit path (`resident_emit_static_layer` / `res_arm_`), ensure those same translucent buckets are emitted per-frame when `bgplane_enabled` (today the bake owns all static content; add the translucent-static re-emit so they don't vanish). Gate the whole split on `bgplane_enabled` so the non-bgplane path is unchanged.

- [ ] **Step 4: Run host test + full sim suite.**

Run: `cd tests && cc -o /tmp/t pal_restage_test.c && /tmp/t` → PASS; then `cd fpga/sim && ./run_sims.sh` → all gating PASS (including `tb_pal8_bgplane`).

- [ ] **Step 5: Regenerate the patch series + rebuild/deploy/re-validate.** `scripts/export_patches.sh && scripts/verify_patches.sh`; rebuild, deploy, re-run Task 2 Steps 2–4. Operator confirms the previously-corrupt static-translucent tiles now render translucent.

- [ ] **Step 6: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/series/0001-*.patch tests/pal_restage_test.c
git commit -m "fix(render): keep static-translucent tiles off the bgplane bake (per-frame BLEND) — avoids partial-alpha opaque-darkening"
```

---

## Self-review — spec coverage

- Spec §"Piece 1 (sim gate)" → **Task 1** (new `tb_pal8_bgplane.sv`, opaque==CLUT / transparent==background, no-RTL expectation, full-suite regression).
- Spec §"Piece 3 (flip + HW validation)" → **Task 2** (opt-in HW validate → objective perf gate → mandatory human visual gate → one-line flip at `:2166` → patch round-trip → default-path re-confirm). Flip lands after validation ✓.
- Spec §"Piece 2 (HW-gated contingency)" → **Task 3**, explicitly gated on Task 2 Step 4, no up-front code ✓.
- Spec §"#84 closes with #120 / bake inherits shared fix" → encoded as the Task 2 Step 4 clean-background confirmation (and the broad-corruption STOP branch), not re-implemented ✓.
- Spec §"Out of scope: RTL re-synth / 4-bit-coverage / town A9 / double-buffer" → not present as tasks; Task 1 Step 2 escalates to the operator if a re-synth becomes necessary ✓.
- Global constraints (base branch, patch round-trip, revert flag, no self-declared visual, deploy sha1) → in Global Constraints and referenced per-step ✓.

No placeholders; flag site / flag-helper semantics / TB idioms / runner budget are all concrete and verified against `origin/master`.
