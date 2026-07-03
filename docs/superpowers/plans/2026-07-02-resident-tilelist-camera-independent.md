# Camera-Independent Resident Tile List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the resident animated-tile path camera-independent so per-frame A9 cost is O(buckets) whether the hero is moving or standing still, and collapse to a single fabric-resolved path (delete Tier A, the legacy non-resident walk, and the per-tile loop).

**Architecture:** Resident entries store **map-coordinate** dsts for the **whole map** (not the viewport). Each `BLT_OP_TILELIST_RES` batch carries a signed per-bucket `{bias_x, bias_y}` in the header's (informational, free) `src_x`/`src_y` fields; the fabric adds it to each entry's map-coord dst in `S_TLR_SLICE` and culls off-screen entries. Camera motion becomes a per-bucket bias update + fabric re-cull — no A9 walk, no rebuild. The scene signature drops `vpx/vpy`.

**Tech Stack:** C/C++ (armhf engine + host emitter), SystemVerilog (blitter_top.sv, blitter_defs.vh), Icarus Verilog sim (`fpga/sim/run_sims.sh`), Docker `solarus-armhf-build:bullseye`.

## Global Constraints

- **No fallback.** No overflow-escape to legacy, no gate-to-legacy, no per-tile oracle. Overflow / unbatchable = loud diagnostic failure, not a degrade path. (Spec: Design principles.)
- **Coupled deploy.** ABI + RTL + engine change together; sim proves bit-exact before the RBF is trusted. fps/tearing/whole-map-cull-bandwidth confirmation is HW-deferred.
- **DDR3 region:** all buffers in the core-reserved top (`0x3B000000–0x3C000000`), reached over f2h. TL_BUF base stays `0x3BF40000`.
- **Entry ABI unchanged:** `blt_tile_entry_res_t {u16 pattern_id; i16 dst_x,dst_y; u16 _rsvd}`, 8 bytes; `dst_x/dst_y` now carry MAP coords.
- **Bias fields:** `bias_x` → header `u32[2][31:16]` (the `src_x` slot), `bias_y` → header `u32[4][15:0]` (the `src_y` slot); both `int16_t`.
- **Bit-exact rule:** every RTL/refmodel change must keep `fpga/sim/run_sims.sh` gating TBs green (`tb_tilelist_res`, `tb_tilelist`, and the comp/system suite).
- **Sim run:** `cd fpga/sim && ./run_sims.sh` (auto-discovers TBs; gating failures are non-zero exit). Single TB: `iverilog -g2012 -o /tmp/tb.vvp -s tb_tilelist_res fpga/sim/tb_tilelist_res.sv fpga/rtl/blitter_top.sv <deps> && vvp /tmp/tb.vvp` — but prefer `run_sims.sh` which wires deps.

---

## File Structure

- `patches/mister/blitter/blitter_ref.h` — ABI structs + refmodel; document bias fields; refmodel adds bias in the RES resolver.
- `patches/mister/blitter/blt_emitter.h` / `blt_emitter.c` — `blt_tile_list_res` gains `bias_x/bias_y`; delete `blt_tile_list` / `blt_tile_list_at` (legacy).
- `fpga/rtl/blitter_top.sv` — latch bias at `OP_TILELIST_RES` decode; add in `S_TLR_SLICE`.
- `fpga/rtl/blitter_defs.vh` + `patches/mister/mister_blitter_renderer.cpp` (DDR constants) — TL_BUF 512 KiB, FRT/CFT reshuffle, static_asserts.
- `fpga/sim/tb_tilelist_res.sv` — bias field, temporal (pan+advance) case, whole-map cull case.
- `patches/mister/mister_blitter_renderer.cpp` — whole-map map-coord record, bucket-split-by-ratio, per-frame per-bucket bias, signature drop `vpx/vpy`, delete Tier A / legacy / escapes; overflow hard-fail; entry-count banner.
- `scripts/build_engine.sh` — the injected `Entities::draw` walk: whole-map record (drop `overlaps` filter), delete `SOLARUS_TILEBATCH=0` and legacy `draw_tile_batch` branches.

---

## Task 1: ABI — bias fields in the TILELIST_RES header (emitter + refmodel)

Add bias to the resident header path with no fabric behavior change yet (refmodel encodes the intended semantics; RTL follows in Task 3). Delete the now-doomed legacy emitters in the same task since they share `tl_emit_header`.

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.c:272-328` (`tl_emit_header`, `blt_tile_list_res`; delete `blt_tile_list`, `blt_tile_list_at`)
- Modify: `patches/mister/blitter/blt_emitter.h:195-213` (decls + doc)
- Modify: `patches/mister/blitter/blitter_ref.h` (TILELIST_RES header comment ~176-206; refmodel RES resolver — the function that resolves an 8-byte entry to a blit)
- Test: `patches/mister/blitter/blt_emitter.c` self-test (`-DBLT_EMITTER_SELFTEST`)

**Interfaces:**
- Produces: `int blt_tile_list_res(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags, uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);`
- Produces (refmodel): resident entry resolves to `dst = (i16 entry.dst_x + bias_x, i16 entry.dst_y + bias_y)`, src from `FRT[pid][CFT[pid]]`.

- [ ] **Step 1: Update the refmodel to apply bias (the executable spec).** Locate the RES resolver: `grep -n "OP_TILELIST_RES\|->frt\|->cft\|pattern_id" patches/mister/blitter/blitter_ref.h` (the C model uses the `frt`/`cft` context pointers at `:202-208`). Find where it resolves a `BLT_OP_TILELIST_RES` entry (reads `pattern_id`, looks up `CFT`→`FRT`, emits a blit at `entry.dst_x/dst_y`). Change the header decode to read `bias_x = (int16_t)hdr.src_x`, `bias_y = (int16_t)hdr.src_y`, and the per-entry dst to `dst_x = (int16_t)entry.dst_x + bias_x`, `dst_y = (int16_t)entry.dst_y + bias_y`. Update the header comment block (~176-206) to state: "TILELIST_RES: `src_x`/`src_y` header slots carry signed `bias_x`/`bias_y` added to every entry dst (map-coord → screen). Entry `dst_x/dst_y` are MAP coords."

- [ ] **Step 2: Add bias params to the header emitter.** In `blt_emitter.c`, give `tl_emit_header` two params `int16_t bias_x, int16_t bias_y` and replace `c.src_x = tex.w; c.src_y = tex.h;` with `c.src_x = (uint16_t)bias_x; c.src_y = (uint16_t)bias_y;` (tex bounds were informational — confirmed unused; RTL overwrites per entry).

- [ ] **Step 3: Thread bias through `blt_tile_list_res`; delete legacy emitters.** New signature per Interfaces; body: `return tl_emit_header(e, BLT_OP_TILELIST_RES, tex, blend, key, alpha, flags, entry_off, n, bias_x, bias_y);`. Delete `blt_tile_list` and `blt_tile_list_at` (and their decls in `blt_emitter.h`) — the legacy TILELIST walk is being removed. Update `blt_tile_list_res`'s doc comment in `blt_emitter.h` to document the bias params.

- [ ] **Step 4: Update the self-test.** In the `blt_tile_list_res` self-test (`blt_emitter.c` ~469+), pass `bias_x=3, bias_y=-5` and assert the emitted header's `src_x`/`src_y` bytes decode to `3` / `(uint16_t)-5`. Remove any `test_blt_tile_list_at` / `blt_tile_list` self-tests.

- [ ] **Step 5: Build + run the self-test.**

Run: `cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter -o /tmp/blt_self patches/mister/blitter/blt_emitter.c && /tmp/blt_self`
Expected: `ok test_blt_tile_list_res` (and no reference to the deleted tests); exit 0.

- [ ] **Step 6: Commit.**

```bash
git add patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_emitter.h patches/mister/blitter/blitter_ref.h
git commit -m "feat(abi): TILELIST_RES per-batch dst bias; drop legacy tile-list emitters (#52)"
```

---

## Task 2: Sim — TILELIST_RES bias in the testbench (RED against current RTL)

Extend the gating TB to submit a non-zero bias and expect shifted dsts. This FAILS against current RTL (which ignores bias); Task 3 makes it pass. TDD across the RTL boundary.

**Files:**
- Modify: `fpga/sim/tb_tilelist_res.sv` (the `run_case` task signature already has trailing args — add bias; the header build; the reference model `cftmem`/`frtmem` dst compare)

**Interfaces:**
- Consumes: refmodel semantics from Task 1 (`dst = map_dst + bias`).
- Produces: `run_case(name, blend, format, flags, bias_x, bias_y, eoff)` — replace the two currently-unused `16'd0,16'd0` args (they sit where blend-detail/reserved were) with signed `bias_x/bias_y`, and pack them into the header `src_x`/`src_y` slots the DUT reads.

- [ ] **Step 1: Wire bias into the header the TB submits.** In `tb_tilelist_res.sv` where the TILELIST_RES header qwords are assembled (the `mem[RINGB+...]` writes for the RES command), set the `src_x` field (`u32[2][31:16]`) `= bias_x` and `src_y` (`u32[4][15:0]`) `= bias_y`. Add `bias_x`/`bias_y` as signed inputs to the `run_case` task (reuse the two `16'd0` argument slots at calls; keep them 0 in the existing cases).

- [ ] **Step 2: Apply bias in the TB reference.** In the TB's software reference that computes expected pixels (it already resolves `frt_sx/sy/w/h` via `cur_f[pid]` and places at `ent_dx/ent_dy`), change the expected dst to `ent_dx[k] + bias_x` / `ent_dy[k] + bias_y` before rasterizing into framebuffer B.

- [ ] **Step 3: Add a bias case.** After Case 4, add Case 5 `R5_BIAS`: reuse Case 2's entities but call `run_case("R5_BIAS", 0,0,0, 16'sd7, -16'sd9, 32'd16)`. Expected: with correct RTL, framebuffer A==B (entries shifted by (+7,−9), off-screen ones culled).

- [ ] **Step 4: Run the TB — expect FAIL (RTL ignores bias).**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | grep -A2 TB_TILELIST_RES`
Expected: `TB_TILELIST_RES: FAIL (... mismatches)` for `R5_BIAS` (and the existing cases still PASS since their bias is 0).

- [ ] **Step 5: Commit.**

```bash
git add fpga/sim/tb_tilelist_res.sv
git commit -m "test(sim): tb_tilelist_res bias case (red; RTL applies bias next) (#52)"
```

---

## Task 3: RTL — apply the per-batch bias in the fabric (GREEN)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (reg decls ~262-266; `OP_TILELIST_RES` decode ~542-556; `S_TLR_SLICE` ~728-737; reset ~351)

**Interfaces:**
- Consumes: header `c_src_x`/`c_src_y` (decoded at `:484/:487` = header `src_x`/`src_y` = bias).
- Produces: `S_TLR_SLICE` sets `c_dst_x = res_dx + bias`, `c_dst_y = res_dy + bias`.

- [ ] **Step 1: Declare bias regs.** Near the other `tl_res`/`frt_*` regs (`:262-266`), add: `reg signed [15:0] res_bias_x, res_bias_y;`

- [ ] **Step 2: Reset them.** In the reset block (`:351`, alongside `tl_res<=1'b0; ...`), add: `res_bias_x<=16'sd0; res_bias_y<=16'sd0;`

- [ ] **Step 3: Latch bias at decode.** In the `OP_TILELIST_RES` branch (`:542`), alongside `tl_res<=1'b1;`, add: `res_bias_x <= $signed(c_src_x); res_bias_y <= $signed(c_src_y);` (c_src_x/c_src_y hold the header's bias fields and are not read again until `S_TLR_SLICE` overwrites them).

- [ ] **Step 4: Add bias in the slice.** In `S_TLR_SLICE` (`:734-735`), change to:

```systemverilog
c_dst_x <= $signed(res_dx) + res_bias_x;
c_dst_y <= $signed(res_dy) + res_bias_y;
```

- [ ] **Step 5: Run the TB — expect PASS.**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | grep TB_TILELIST_RES`
Expected: `TB_TILELIST_RES: PASS` (all cases incl. `R5_BIAS`).

- [ ] **Step 6: Run the full gating suite — expect no regressions.**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | tail -30`
Expected: all gating TBs report PASS; script exit 0.

- [ ] **Step 7: Commit.**

```bash
git add fpga/rtl/blitter_top.sv
git commit -m "feat(rtl): apply TILELIST_RES per-batch dst bias in S_TLR_SLICE (#52)"
```

---

## Task 4: DDR map — TL_BUF 512 KiB + FRT/CFT reshuffle

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:188-205` (OFF_/BYTES constants + static_asserts)
- Modify: `fpga/rtl/blitter_defs.vh:95-110` (`TL_BUF_BYTES`, `TL_BUF_QW`, `FRT_BUF_QW`, `CFT_BUF_QW`)

**Interfaces:**
- Produces: `TL_BUF_BYTES = 0x00080000` (512 KiB); `OFF_FRTBUF = 0x00FC0000` (0x3BFC0000); `OFF_CFTBUF = 0x00FC2000` (0x3BFC2000). Fabric `FRT_BUF_QW = 0x3BFC0000>>3`, `CFT_BUF_QW = 0x3BFC2000>>3`.

- [ ] **Step 1: Host constants.** In `mister_blitter_renderer.cpp`: `TL_BUF_BYTES = 0x00080000u;` (512 KiB), `OFF_FRTBUF = 0x00FC0000u;`, `OFF_CFTBUF = 0x00FC2000u;`. Update the `static_assert`s: `OFF_FRTBUF == OFF_TLBUF + TL_BUF_BYTES` (0xF40000+0x80000=0xFC0000 ✓), `OFF_FRTBUF + FRT_BUF_BYTES <= OFF_CFTBUF`, `OFF_CFTBUF + CFT_BUF_BYTES <= BLT_DDR_SIZE`. Update the neighbor comments (`0x3BF50000`→`0x3BFC0000`, etc.).

- [ ] **Step 2: Fabric defs.** In `blitter_defs.vh`: `TL_BUF_BYTES = 32'h0008_0000;`, `` `define FRT_BUF_QW 29'h...`` and `` `define CFT_BUF_QW 29'h...`` recomputed as `(0x3BFC0000>>3)` = `29'h077F8000` and `(0x3BFC2000>>3)` = `29'h077F8400`. Leave `TL_BUF_QW` = `0x3BF40000>>3` = `29'h077E8000` (base unchanged). Verify each `>>3` by hand and put the byte address in the comment.

- [ ] **Step 3: Grep for hardcoded old offsets.** Run: `grep -rn "3BF50000\|3BF52000\|00F50000\|00F52000\|077E9\|FRT_BUF_QW\|CFT_BUF_QW" patches/ fpga/rtl/` — confirm every FRT/CFT reference is the new value (host + fabric agree).

- [ ] **Step 4: Build the host (structs/asserts compile).**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tail -20`
Expected: build succeeds; no `static_assert` failure. (If `build/luajit-armhf` is missing in a fresh worktree, copy it from the main checkout first.)

- [ ] **Step 5: Run sims (FRT/CFT addressing still correct).**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | grep -E "TB_TILELIST_RES|FAIL"`
Expected: `TB_TILELIST_RES: PASS`; no FAIL. (The TB derives FRT/CFT bases from the same defines.)

- [ ] **Step 6: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp fpga/rtl/blitter_defs.vh
git commit -m "feat(mem): enlarge TL_BUF to 512 KiB, reshuffle FRT/CFT above it (#52)"
```

---

## Task 5: Sim — whole-map cull + temporal (pan + animate) cases

Prove the movement scenario the old design couldn't express, and the whole-map over-provisioned batch that the fabric culls. Both must be bit-exact BEFORE the host is rewritten to depend on them.

**Files:**
- Modify: `fpga/sim/tb_tilelist_res.sv`

- [ ] **Step 1: Whole-map cull case.** Add Case 6 `R6_CULL`: `NN=64` entries spread across map-space so that under a chosen bias only ~12 land on-screen and the rest are fully off-screen (negative or > screen dims). Reference model rasterizes only the on-screen subset. Assert A==B.

- [ ] **Step 2: Temporal case (the movement proof).** Add Case 7 `R7_PAN_ADVANCE`: (a) render with `bias=(0,0)`, `cur_f[p]=f0`; snapshot framebuffer A0. (b) WITHOUT rebuilding entries (same TL_BUF), change bias to `(−16,−8)` (camera pan) and advance `cur_f[p]=f0+1` (write CFT), re-issue the same TILELIST_RES header with the new bias; render framebuffer A1. (c) Reference B1 = entries at `map_dst+(−16,−8)` with frame `f0+1`. Assert A1==B1. This proves a moving frame needs only {bias, CFT} updates, no entry rebuild.

- [ ] **Step 3: Run — expect PASS (RTL from Task 3 already supports it).**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | grep TB_TILELIST_RES`
Expected: `TB_TILELIST_RES: PASS` (Cases 1–7).

- [ ] **Step 4: Commit.**

```bash
git add fpga/sim/tb_tilelist_res.sv
git commit -m "test(sim): whole-map cull + pan/animate temporal cases for resident tiles (#52)"
```

---

## Task 6: Host — whole-map map-coord recording + bucket-split-by-ratio + per-frame bias

The core engine change. Record every animated tile (whole map) with a map-coord dst, split buckets by scroll ratio, drop `vpx/vpy` from the signature, and emit per-bucket bias each frame. Compile-testable now; behavior HW-deferred.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — `Impl` resident fields (`:354-396`), `resident_begin_frame` (`:1798-1829`), `resident_record_batch` (`:1880-1950`), `resident_emit_layer_op` (the bucket-header emit; currently calls `blt_tile_list_res`/`blt_tile_list_at`), `res_hw_arm_` (`:1954-1979`), `resident_update` (`:1846-1878` — keep only the Tier B CFT branch)
- Modify: `scripts/build_engine.sh:1336-1420` — the injected `Entities::draw` walk (drop `overlaps` filter in BUILD; pass scroll ratio + map-coord dst to `resident_record_batch`)
- Modify: `patches/mister/mister_blitter_renderer.h` — signature changes for `resident_begin_frame` / `resident_record_batch`

**Interfaces:**
- Consumes: `blt_tile_list_res(..., bias_x, bias_y)` (Task 1); `mister_camera_x()/y()` (existing).
- Produces:
  - `int resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id)` — **`vpx/vpy` removed** from signature and the cached signature (`res_vpx/res_vpy` deleted).
  - `void resident_record_batch(int layer, int scroll_ratio, const SurfaceImpl& tileset_image, BlendMode blend, const std::vector<TileBatchEntry>& map_entries, const std::vector<uintptr_t>& tokens)` — `scroll_ratio` added (1 = normal, r = parallax); `map_entries[i].dst` in MAP coords.
  - `ResBucket` gains `int scroll_ratio;` and the bucket key/flush splits on it.

- [ ] **Step 1: Signature — drop vpx/vpy.** In `Impl` delete `res_vpx/res_vpy` (`:358`). In `resident_begin_frame` change the param list to `(uintptr_t map_id, uintptr_t tileset_id)` and the `sig` test (`:1812-1813`) to `d->res_valid && d->res_map==map_id && d->res_tileset==tileset_id`. Update the header + `build_engine.sh` call site (`:1367-1369`) to pass only `&map, &map.get_tileset()`.

- [ ] **Step 2: Bucket carries scroll ratio.** Add `int scroll_ratio;` to `ResBucket` (`:368`). In `resident_record_batch`, add `int scroll_ratio` param; include it in the bucket-identity so a flush starts a new bucket when `{tsimg, blend, scroll_ratio}` changes (the caller already flushes per tileset image — extend the equality). Store `scroll_ratio` in the emitted `ResBucket`.

- [ ] **Step 3: Store MAP-coord dsts.** In `resident_record_batch` (`:1901-1906` and the Tier B `ResEnt` push), stop adding `alias_off`/camera: store `e.dst.x`/`e.dst.y` as received, now defined as MAP coords. (The `alias_off` screen adjustment moves to the per-frame bias in Step 5.)

- [ ] **Step 4: Walk the whole map, compute map-coord dst + ratio (engine side).** In `build_engine.sh` BUILD branch (`:1419` loop), remove the `overlaps(*camera)` gate so ALL `tiles_in_animated_regions[layer]` are recorded. For each tile compute the MAP-coord dst and scroll ratio: normal tile → `map_dst = top_left` (tile map position), `ratio = 1`; parallax pattern → `map_dst = dst_position` (the pattern's fixed base, camera-independent), `ratio = ParallaxScrollingTilePattern::ratio`. Pass `scroll_ratio` into `resident_record_batch`. Keep repeated/fill per-cell expansion (already present) so nothing escapes.

- [ ] **Step 5: Per-frame per-bucket bias on emit.** In `resident_emit_layer_op` (bucket emit), compute the bias from the live camera and the bucket's `scroll_ratio`:

```cpp
const int cx = mister_camera_x(), cy = mister_camera_y();
int16_t bx, by;
if (bk.scroll_ratio <= 1) { bx = (int16_t)(-cx); by = (int16_t)(-cy); }
else { bx = (int16_t)(cx / bk.scroll_ratio); by = (int16_t)(cy / bk.scroll_ratio); }
blt_tile_list_res(&d->em, tex, bk.blend, bk.key, 255, bk.flags, bk.hw_off, bk.hw_count, bx, by);
```

Delete the `blt_tile_list_at` (Tier A) branch here.

- [ ] **Step 6: `resident_update` — CFT only.** Delete the Tier A src-patch branch (`:1867-1877`) and the `res_hw_active()` guard; keep only the CFT write (`:1852-1865`) as the sole body.

- [ ] **Step 7: Build the engine.**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tail -20`
Expected: compiles clean; `build/armhf/{solarus-run,libsolarus.so.1.6.5}` produced.

- [ ] **Step 8: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h scripts/build_engine.sh
git commit -m "feat(engine): whole-map map-coord resident tiles + per-bucket camera bias (#52)"
```

---

## Task 7: Host — delete Tier A / legacy walk / per-tile loop; single path + overflow hard-fail + banner

Now that the resident path is camera-independent, remove every other path and the fallback machinery.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — `Impl` fields (`:354-396`), env parse (`:1381-1387`), `resident_record_batch` escape path (`:1886-1897`, `:1907-1910`), `present()` finalize (`:2065-2070`), `resident_room_entries`/overflow (`:2053-2056`), diag banner (`:2153-2158`)
- Modify: `scripts/build_engine.sh` — delete the `SOLARUS_TILEBATCH=0` per-tile branch (`:1341-1348`) and the legacy `draw_tile_batch` else-branch (in `flush_bucket`)

**Interfaces:**
- Produces: single gate `SOLARUS_TILERESIDENT` (no `_HW`); `res_hw*` fields removed; TL_BUF overflow / unbatchable bucket → `res_fatal` diagnostic.

- [ ] **Step 1: Remove Tier A/B split + dead fields.** Delete from `Impl`: `res_hw`, `res_hw_overflow`, `res_hw_armed`, `res_hw_active()`, `ResBucket::{entry_off,count}` (Tier A 12-byte), `ResPattern::{src,offs}` (Tier A patch targets). Keep `hw_off/hw_count/hw` (now the only entry layout) and `frame_count/frames/cur_frame`. In env parse (`:1381-1387`) keep only `res_enabled = getenv("SOLARUS_TILERESIDENT")`; delete the `_HW` read and the "A engine/B fabric" banner branch.

- [ ] **Step 2: Delete `res_patch_entry` + Tier A helpers.** Remove `res_patch_entry` and any Tier-A-only members it touched. `res_hw_arm_` becomes the sole arm path (rename to `res_arm_` if desired; keep behavior — writes 8-byte entries + FRT).

- [ ] **Step 3: No-escape / overflow = hard fail.** In `resident_record_batch`, replace the escape paths (`res_bucket_params` fail `:1886-1897`; `blt_tile_list` overflow `:1907-1910`; `res_build_escape`) with a `d->res_fatal = true` flag + a one-line `fprintf(stderr, "[blitter resident] FATAL: <reason>\n")`. Remove `res_build_escape`/`res_eligible` and the `res_ops` per-op escape `esc` handling — every op is a bucket. In `present()` finalize (`:2065-2069`) set `res_valid = true` unconditionally (no eligibility gate); if `res_fatal`, keep the loud log (do not silently fall back).

- [ ] **Step 4: Delete the engine-side legacy + per-tile branches.** In `build_engine.sh`: remove the `if (!tilebatch) { ...per-tile... }` block (`:1341-1348`) and the `static const bool tilebatch` line; in `flush_bucket` remove the `else` (legacy `draw_tile_batch`) branch, leaving only the `rmode==1 → resident_record_batch` record. Remove the `resident_emit_layer_op` escape re-`draw` (`_et != 0` case) — no escapes now.

- [ ] **Step 5: Whole-map entry-count banner + overflow assert.** Extend the `[blitter resident]` banner (`:2153-2158`) to print `entries=<total hw entries this scene>` and `tl_used=<bytes>/<cap>`. In `res_hw_arm_`/record, if `resident_room_entries()` would be exceeded, set `res_fatal` + `fprintf(stderr, "[blitter resident] TL_BUF OVERFLOW: need %zu > cap %d entries\n", ...)`.

- [ ] **Step 6: Build the engine + verify removals.**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tail -10
strings build/armhf/libsolarus.so.1.6.5 | grep -E "SOLARUS_TILERESIDENT_HW|SOLARUS_TILEBATCH" ; echo "exit:$?"
```
Expected: build OK; the `grep` prints nothing and `exit:1` (both symbols gone). `strings ... | grep SOLARUS_TILERESIDENT` still present (the one surviving gate).

- [ ] **Step 7: Run sims (RTL/ABI unaffected by host cleanup).**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | tail -20`
Expected: all gating TBs PASS.

- [ ] **Step 8: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp scripts/build_engine.sh
git commit -m "refactor(engine): single resident path — delete Tier A, legacy walk, per-tile loop, escapes (#52)"
```

---

## Task 8: Whole-map count instrumentation pass + TL_BUF sizing evidence (doc)

Turn the banner into sizing evidence and record the numbers for the HW session. No new runtime behavior.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-02-resident-tilelist-camera-independent-design.md` (append a "Measured sizing" section once numbers exist)
- No code change beyond Task 7's banner.

- [ ] **Step 1: Document the measurement procedure.** In the spec, add a "Measured sizing (HW-deferred)" section: on device, read `grep "blitter resident" /media/fat/logs/Solarus/Solarus.diag.log | tail` across the heaviest MoSDX maps; record max `entries` and `tl_used`; confirm `< 65536` / `< 512 KiB` with margin. If any map approaches the cap, bump `TL_BUF_BYTES` (region allows up to ~800 KiB) per Task 4 and note the new value.

- [ ] **Step 2: Cross-check i16 dst range.** Add a note: verify the largest MoSDX map's map-coord dsts fit `int16` (±32767) before + after bias; if a map exceeds it, the entry `dst` width is the constraint to revisit (out of scope unless hit).

- [ ] **Step 3: Commit.**

```bash
git add docs/superpowers/specs/2026-07-02-resident-tilelist-camera-independent-design.md
git commit -m "docs(perf): resident-tile sizing/measurement procedure for HW session (#52)"
```

---

## HW-deferred (not tasks — the validation checklist for when hardware returns)

Per the spec's HW-deferred boundary, after deploying the coupled engine+RBF (`./deploy.py`; diag.env with `SOLARUS_TILERESIDENT=1`):
- Standing-still vs **moving** emit ms + fps A/B — moving should now match standing-still.
- `[blitter resident]` banner shows `rebuild=0` **while moving**.
- No tearing while moving.
- Whole-map fabric cull stays hidden under the A9 (fabric_hw ms unchanged vs today).
- `entries`/`tl_used` from Task 8 stay under cap on every map (no `FATAL`/`OVERFLOW`).
