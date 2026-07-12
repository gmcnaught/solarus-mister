# Paletted Composition v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the immutable `pal8` PNG assets' SDRAM residency with an 8bpp index atlas + an on-chip palette CLUT, so the compositor reads a 1-byte index per source pixel and expands it to `{A4,RGB565}` via a per-blit-selected CLUT bank — halving the source atlas, dissolving issue #84's perm-region overflow, and improving colour fidelity.

**Architecture:** New source format `COMP_PAL8` alongside RGB565/ARGB4444. Per-blit `pal_id`+`base_off` ride in the otherwise-unused `color` wire field (zero ABI widening). An 8-bank CLUT BRAM (`{A4,R5,G6,B5}`) is uploaded via a new `BLT_OP_CLUT_UPLOAD` opcode modelled on `BLT_OP_FRT_UPLOAD`. The lookup drops into `comp_pipeline`'s existing ARGB4444-expand decode point. Delivered in two R1 steps: **(Step 1)** CLUT + lookup with indices stored 16bpp (fill path untouched — proves correctness, no memory win), then **(Step 2)** 8bpp source packing in `comp_pipeline`'s prefetch fill (the memory win). `comp_burst` and `comp_src_linebuf` are never touched.

**Tech Stack:** SystemVerilog (Cyclone V fabric, Verilator/iverilog sim via `fpga/sim`), C++17 host renderer (`patches/mister/`, armhf cross-build in Docker), C host unit tests (`tests/`, native `cc`).

## Global Constraints

- **Design doc (source of truth):** `docs/superpowers/specs/2026-07-12-paletted-composition-v1-design.md`. Read it before starting.
- **Migration flag:** `SOLARUS_PALETTE` — **default OFF** for all of v1 until HW-validated; then a separate commit flips it default-ON. When OFF, the existing dual-format residency path runs verbatim.
- **CLUT geometry:** `8` banks × `256` entries × `{A4[19:16], R5[15:11], G6[10:5], B5[4:0]}` (20 bits, stored in a 32-bit word). BRAM ≈ 8 KiB.
- **Wire contract (unchanged 32-byte command):** `format` byte gains `BLT_FMT_PAL8 = 2` (RTL `COMP_PAL8 = 8'd2`). For a PAL8 source blit, the `color` field (`u32[7]` low 16) carries `pal_id` in bits `[11:8]` (4 bits) and `base_off` in bits `[7:0]` (8 bits). `color` is unused for COPY/COLORKEY/PALPHA (it is the FILL colour), and this does not collide with the v2 colour-mod bytes (27/30/31) or `cmod_r/g` in `u32[7]` high 16.
- **Wire single source of truth:** `patches/mister/blitter/blt_wire.h` (vendored — edit upstream + re-copy per its header banner) and `fpga/rtl/blitter_top.sv` unpack MUST agree; `blt_pack_cmd`/`blt_unpack_cmd` round-trip is the gate.
- **Never self-declare a frame visually correct** — HW visual validation is the user's, or an objective bit-exact test. (memory `solarus-no-self-declared-visual-validation`.)
- **Build:** armhf engine via `scripts/docker_run.sh scripts/build_engine.sh` (image `solarus-armhf-build:bullseye`); lean SDL2 (never `SOLARUS_ALLOW_STOCK_SDL2=1`); LuaJIT default-ON; no OpenGL.
- **Sim:** run TBs via `fpga/sim/run_sims.sh` (respect its `--jobs`); host tests via `tests/run_tests.sh`.
- **`mister_blitter_renderer.cpp` is a whole-file addition** (cp'd by `scripts/apply_mister_files.sh`) — edit it directly; new headers must be added to that cp list. RTL `.sv`/`.vh` are edited directly.
- **DRY / YAGNI / TDD / frequent commits.** No dedup, no on-disk cache in v1 (Phase 2).

---

## File Structure

**New files**
- `fpga/rtl/comp_clut.vh` — CLUT geometry params + `clut_pack`/`clut_unpack` macros (single source shared by `blitter_top`, `comp_pipeline`, TBs).
- `fpga/sim/tb_clut_upload.sv` — `BLT_OP_CLUT_UPLOAD` DMA→BRAM TB.
- `fpga/sim/tb_pal8_lookup.sv` — `COMP_PAL8` index→{A4,RGB565}→blend golden TB (all blend modes).
- `fpga/sim/tb_pal8_fill_8bpp.sv` — Step-2 8bpp fill/addressing golden TB (sub-qword src_x, hflip).
- `fpga/sim/tb_mixed_format_seq.sv` — interleaved PAL8/RGB565/ARGB4444 sequence TB.
- `patches/mister/palette_atlas.h` — host palette manager (index recovery, bank packing, CLUT byte-image builder). Pure/testable.
- `tests/palette_atlas_test.c` — host unit tests for `palette_atlas.h`.
- `tests/pal_restage_test.c` — cumulative multi-tileset footprint regression (the #84 catcher for the paletted path).

**Modified files**
- `fpga/rtl/comp_defs.vh` — `COMP_PAL8`.
- `fpga/rtl/blitter_defs.vh` — `BLT_FMT_PAL8`, `BLT_OP_CLUT_UPLOAD`, `CLUTBUF` region.
- `fpga/rtl/blitter_top.sv` — opcode decode, CLUT BRAM + upload FSM, `c_pal_id`/`c_base_off` extract, wire to `comp_pipeline`.
- `fpga/rtl/comp_pipeline.sv` — CLUT read port, `COMP_PAL8` decode (Step 1); format-aware prefetch fill (Step 2).
- `patches/mister/blitter/blitter_ref.h` + `blt_wire.h` — `BLT_FMT_PAL8`, `BLT_OP_CLUT_UPLOAD`, `pal_id`/`base_off` accessors, doc.
- `patches/mister/blitter/blt_emitter.{h,c}` — `blt_emit_clut_upload()`, PAL8 emit helper.
- `patches/mister/mister_blitter_renderer.cpp` — CLUTBUF offset, palette-manager integration, PAL8 staging + emit, flag gating.
- `patches/mister/mister_blitter_renderer.h` — new members/prototypes.
- `scripts/apply_mister_files.sh` — cp `palette_atlas.h`.
- `tests/run_tests.sh`, `fpga/sim/run_sims.sh` — register new tests/TBs (tiering per existing pattern).

---

# PHASE 0 — Contract & defs (no behaviour change)

### Task 0.1: Wire + RTL constants for PAL8 and CLUT upload

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.h` (format/opcode enums), `patches/mister/blitter/blt_wire.h` (doc + accessors)
- Modify: `fpga/rtl/comp_defs.vh`, `fpga/rtl/blitter_defs.vh`
- Create: `fpga/rtl/comp_clut.vh`
- Test: `tests/wire_pal8_test.c` (new, or extend an existing wire round-trip test if one exists — grep `blt_pack_cmd` in `tests/`)

**Interfaces:**
- Produces (host): `BLT_FMT_PAL8` (== 2), `BLT_OP_CLUT_UPLOAD` (next free opcode — grep `BLT_OP_` in `blitter_ref.h` for the max), inline helpers `blt_pal_color(uint8_t pal_id, uint8_t base_off)` → `uint16_t` and inverse `blt_pal_id(uint16_t)`, `blt_base_off(uint16_t)`.
- Produces (RTL): `` `COMP_PAL8 `` (`comp_defs.vh`), `` `BLT_FMT_PAL8 ``, `` `BLT_OP_CLUT_UPLOAD `` (`blitter_defs.vh`), and `comp_clut.vh` with `` `CLUT_BANKS 8 ``, `` `CLUT_ENTRIES 256 ``, and pack/unpack macros `` `CLUT_A4(e) ``/`` `CLUT_RGB(e) `` and a builder `` `CLUT_MAKE(a4,rgb) ``.

- [ ] **Step 1: Write the failing test** — `tests/wire_pal8_test.c`:

```c
#include "blitter_ref.h"
#include "blt_wire.h"
#include <assert.h>
#include <string.h>
int main(void) {
    /* pal_id/base_off pack into the color field and survive a wire round-trip */
    assert(blt_pal_color(0xA, 0x37) == ((0xA << 8) | 0x37));
    assert(blt_pal_id(blt_pal_color(0xA, 0x37)) == 0xA);
    assert(blt_base_off(blt_pal_color(0xA, 0x37)) == 0x37);

    blt_cmd_t c; memset(&c, 0, sizeof c);
    c.opcode = BLT_OP_BLIT; c.format = BLT_FMT_PAL8; c.blend_mode = BLT_BLEND_COLORKEY;
    c.color  = blt_pal_color(0x5, 0x80);
    uint8_t wire[BLT_CMD_BYTES]; blt_pack_cmd(&c, wire);
    blt_cmd_t d; blt_unpack_cmd(wire, &d);
    assert(d.format == BLT_FMT_PAL8);
    assert(blt_pal_id(d.color) == 0x5 && blt_base_off(d.color) == 0x80);
    assert(BLT_FMT_PAL8 == 2);
    return 0;
}
```

- [ ] **Step 2: Run it, verify it fails** — `cc -I patches/mister/blitter tests/wire_pal8_test.c -o /tmp/wp && /tmp/wp` → FAIL (undefined `BLT_FMT_PAL8`/`blt_pal_color`).

- [ ] **Step 3: Add the host constants + accessors.** In `blitter_ref.h`, add to the format enum `BLT_FMT_PAL8 = 2` (confirm RGB565=0, ARGB4444=1 there) and `BLT_OP_CLUT_UPLOAD = <next free>`. In `blt_wire.h` (below the existing helpers), add:

```c
static inline uint16_t blt_pal_color(uint8_t pal_id, uint8_t base_off) {
    return (uint16_t)(((uint16_t)(pal_id & 0x0F) << 8) | base_off);
}
static inline uint8_t  blt_pal_id(uint16_t color)   { return (color >> 8) & 0x0F; }
static inline uint8_t  blt_base_off(uint16_t color) { return color & 0xFF; }
```
Also extend the wire-layout doc comment: "when `format==BLT_FMT_PAL8`, `color`(u32[7] low16) = `pal_id[11:8] | base_off[7:0]`."

- [ ] **Step 4: Run it, verify it passes** — same command → exit 0.

- [ ] **Step 5: Add the RTL constants.** `comp_defs.vh`: `` `define COMP_PAL8 8'd2 ``. `blitter_defs.vh`: `` `define BLT_FMT_PAL8 8'd2 `` and `` `define BLT_OP_CLUT_UPLOAD 8'd<match host> `` (grep existing `` `define BLT_OP_ ``). Create `fpga/rtl/comp_clut.vh`:

```systemverilog
`ifndef COMP_CLUT_VH
`define COMP_CLUT_VH
`define CLUT_BANKS   8
`define CLUT_ENTRIES 256
// entry: {A4[19:16], R5[15:11], G6[10:5], B5[4:0]} in a 32-bit word (high 12 = 0)
`define CLUT_MAKE(a4, rgb) ({8'd0, (a4), (rgb)})   // a4:4b, rgb:16b
`define CLUT_A4(e)  ((e)[19:16])
`define CLUT_RGB(e) ((e)[15:0])
`endif
```

- [ ] **Step 6: Commit** — `git add` the four files + test; `git commit -m "feat(pal): PAL8 format + CLUT-upload opcode + wire pal_id/base contract"` (with the repo's Co-Authored-By/Claude-Session trailers).

---

# PHASE 1 — Fabric: CLUT + COMP_PAL8 lookup (indices stored 16bpp)

### Task 1.1: CLUT BRAM + `BLT_OP_CLUT_UPLOAD` (modelled on FRT_UPLOAD)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (opcode decode + CLUT BRAM + upload FSM + read port)
- Modify: `patches/mister/mister_blitter_renderer.cpp` (reserve a `CLUTBUF` DDR region constant next to `OFF_CFTBUF`; grep `OFF_FRTBUF`/`OFF_CFTBUF` at `:260-269` for the pattern and static_asserts)
- Create: `fpga/sim/tb_clut_upload.sv`
- Modify: `fpga/sim/run_sims.sh` (register the TB)

**Interfaces:**
- Produces (RTL): `blitter_top` owns `reg [31:0] clut_bram [0:`CLUT_BANKS*`CLUT_ENTRIES-1]` (M10K-inferred, same `ramstyle` attr as `frt_bram` at `:349`), a registered read port exported to `comp_pipeline` as `clut_rd_data` given `clut_rd_addr = {pal_id, index}` (11 bits), and an upload FSM `S_CLUT_RD`/`S_CLUT_WR` that streams `CLUTBUF` DDR → `clut_bram` exactly like `S_FRT_RD`/`S_FRT_WR` (`:817-825`).
- Consumes: `BLT_OP_CLUT_UPLOAD`, `u32[3]` = qword count (reuse `{c_h,c_w}` like FRT at `:656`), a `CLUTBUF` DDR base (define `` `CLUT_BUF_QW `` in `blitter_defs.vh` mirroring `` `FRT_BUF_QW ``).

- [ ] **Step 1: Write the failing TB** — `fpga/sim/tb_clut_upload.sv`. Model it on `tb_blitter_system_pipe.sv` harness (grep it for the DDR-model + command-ring boilerplate). The test: preload a known 8-bank × 256-entry pattern (`entry = bank*256 + index`, packed via `` `CLUT_MAKE ``) into the DDR `CLUTBUF` region; submit one `BLT_OP_CLUT_UPLOAD` with qword count = `CLUT_BANKS*CLUT_ENTRIES` (each entry one qword, or pack two per qword — pick and document; simplest is one 32-bit entry per 64-bit qword, high 32 = 0); after `done`, drive `clut_rd_addr` across all 2048 addresses and assert `clut_rd_data` matches the pattern. Expected before impl: compile error / mismatch.

- [ ] **Step 2: Run it, verify it fails** — `fpga/sim/run_sims.sh --only tb_clut_upload` (grep `run_sims.sh` for the exact selector flag) → FAIL.

- [ ] **Step 3: Implement in `blitter_top.sv`.** (a) `` `include "comp_clut.vh" ``. (b) Declare `clut_bram` + `clut_q` mirroring `frt_bram`/`frt_q` (`:349-350`) with `reg [31:0] clut_cnt, clut_idx;`. (c) In the opcode dispatch (near `:653` `OP_FRT_UPLOAD`), add an `OP_CLUT_UPLOAD` branch that latches `clut_cnt <= {c_h,c_w}; clut_idx <= 0;` and jumps to `S_CLUT_RD`. (d) Add `S_CLUT_RD`/`S_CLUT_WR` copying `:817-825` verbatim with `FRT_BUF_QW→CLUT_BUF_QW`, `frt_*→clut_*`, `frt_bram[..]→clut_bram[clut_idx]`. (e) Export the read port: `clut_rd_addr` in from `comp_pipeline`, `clut_q <= clut_bram[clut_rd_addr]` registered, `clut_rd_data` out.

- [ ] **Step 4: Run it, verify it passes** — same selector → PASS (all 2048 entries match).

- [ ] **Step 5: Add the host `CLUTBUF` region constant** in `mister_blitter_renderer.cpp` next to `OFF_CFTBUF` (`:262`), sized `CLUT_BANKS*CLUT_ENTRIES*8` bytes, with the same `static_assert` fit checks as the FRT/CFT block (`:264-269`). No emit yet — just the constant + asserts compile.

- [ ] **Step 6: Commit** — `git commit -m "feat(pal): CLUT BRAM + BLT_OP_CLUT_UPLOAD DMA (FRT-modelled) + tb_clut_upload"`.

### Task 1.2: `comp_pipeline` COMP_PAL8 decode → {A4,RGB565}

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv` (decode at `:208-234`; add `c_pal_id`/`c_base_off`/`clut_*` ports at the port list `:42`-area and the `blitter_top` instantiation `:986`)
- Modify: `fpga/rtl/blitter_top.sv` (extract `c_pal_id`/`c_base_off` from `c_color` when `c_format==COMP_PAL8`; wire `clut_rd_addr`/`clut_rd_data` to the `comp_pipeline` instance)
- Create: `fpga/sim/tb_pal8_lookup.sv`

**Interfaces:**
- Consumes: `clut_rd_data` (from Task 1.1), `c_pal_id [3:0]`, `c_base_off [7:0]`, served index `lb_serve_pix[7:0]`.
- Produces: for `COMP_PAL8`, `feed_src = `CLUT_RGB(clut_rd_data)` and `feed_a8 = {`CLUT_A4(...) , `CLUT_A4(...)}`, routed through the SAME `feed_src`/`feed_skip`/mixer path the ARGB4444 case uses. `feed_skip = is_pal8 && (`CLUT_A4==4'd0)`.

- [ ] **Step 1: Write the failing TB** — `fpga/sim/tb_pal8_lookup.sv`. Upload a CLUT (as Task 1.1), stage a small 16bpp **index** source (index in low byte), and run one span per blend mode (COPY, COLORKEY, PALPHA, ADD, MULTIPLY). Golden reference (host-side, in the TB `initial`): `expected = blend(mixer, CLUT[pal_id][index], dst, mode)`, using the same `blt_blend565` semantics referenced in `comp_defs.vh`. Assert the composited band matches, incl. the transparent index (A4=0 → dst unchanged). Expected: FAIL pre-impl.

- [ ] **Step 2: Run it, verify it fails** — `run_sims.sh --only tb_pal8_lookup` → FAIL.

- [ ] **Step 3: Implement the decode.** In `comp_pipeline.sv` near `:228`:

```systemverilog
`include "comp_clut.vh"
wire        is_pal8   = (c_format == `COMP_PAL8);
wire [7:0]  pal_index = lb_serve_pix[7:0] + c_base_off;    // 8-bit wrap OK (banks are 256)
assign      clut_rd_addr = {c_pal_id, pal_index};          // {3?4 bits, 8 bits}
wire [19:0] pal_e   = clut_rd_data[19:0];
wire [15:0] pal_rgb = `CLUT_RGB(pal_e);
wire [3:0]  pal_a4  = `CLUT_A4(pal_e);
```
Extend the existing selects so PAL8 joins the expanded path: `feed_src = is_pal8 ? pal_rgb : (b_palpha || is_argb4444) ? pa_expanded : lb_serve_pix;` and the a8/skip equivalently (`is_pal8 ? {pal_a4,pal_a4} : ...`, `feed_skip = (b_palpha && pa_a4==0) || (is_pal8 && pal_a4==0)`). Note the CLUT read is registered → account for its 1-cycle latency in the s1/s2 pipeline staging (the served index must be presented one stage earlier; align with the existing `serve_pix` T+1 latency comment at `:478`). In `blitter_top.sv`, add `wire [3:0] c_pal_id = c_color[11:8]; wire [7:0] c_base_off = c_color[7:0];` and pass them + the CLUT port to the `comp_pipeline` instance (`:986`).

- [ ] **Step 4: Run it, verify it passes** — `run_sims.sh --only tb_pal8_lookup` → PASS (all modes + transparent index).

- [ ] **Step 5: STA note.** Add a comment at the decode documenting the added registered CLUT stage; flag STA re-run as a Phase-5 gate (do not attempt STA in sim).

- [ ] **Step 6: Commit** — `git commit -m "feat(pal): comp_pipeline COMP_PAL8 index->CLUT->{A4,RGB565} decode + tb_pal8_lookup"`.

### Task 1.3: Mixed-format sequence TB (regression guard)

**Files:** Create `fpga/sim/tb_mixed_format_seq.sv`; register in `run_sims.sh`.

- [ ] **Step 1: Write the TB** — interleave, in one command stream to one framebuffer: an RGB565 COPY, an ARGB4444 PALPHA, a PAL8 COLORKEY, a PAL8 PALPHA, an RGB565 again. Golden-reference each region independently. This proves the serve path stays format-agnostic and PAL8 doesn't perturb the 16bpp formats.
- [ ] **Step 2: Run it** — `run_sims.sh --only tb_mixed_format_seq`. Expected: PASS (the decode is additive). If it fails, the PAL8 select leaked into a non-PAL8 path — fix the `is_pal8` guards.
- [ ] **Step 3: Commit** — `git commit -m "test(pal): mixed PAL8/RGB565/ARGB4444 sequence TB"`.

---

# PHASE 2 — Host: emit PAL8 (indices at 16bpp — end-to-end correctness)

### Task 2.1: Index recovery + palette extraction (`palette_atlas.h`)

**Files:**
- Create: `patches/mister/palette_atlas.h`
- Create: `tests/palette_atlas_test.c`; register in `tests/run_tests.sh`
- Modify: `scripts/apply_mister_files.sh` (cp `palette_atlas.h`)

**Interfaces:**
- Produces: `struct pal_surface { uint8_t* index; int w, h; uint16_t clut_rgb[256]; uint8_t clut_a4[256]; int ncolors; };` and `bool pal_extract(SDL_Surface* s, pal_surface* out)`. Contract: if `s` is 8-bit indexed (`s->format->BytesPerPixel==1 && s->format->palette`), copy `s->pixels` as `index` and build `clut_rgb`/`clut_a4` from `s->format->palette` (+ colorkey/`SDL_GetSurfaceAlphaMod`). Else (32-bit RGBA): build a reverse map from the surface's own colour set (≤256 distinct → `ncolors`; assign indices in first-appearance order) and map each pixel; `clut_a4[i] = round(alpha_i/17)`. Returns false if >256 distinct colours (caller keeps it direct-colour).

- [ ] **Step 1: Write failing tests** — `tests/palette_atlas_test.c`: (a) synth an 8-bit `SDL_Surface` with a 4-colour palette + a known index pattern → assert `pal_extract` copies indices verbatim and CLUT matches. (b) synth a 32-bit RGBA surface using 3 distinct colours incl. one at alpha 127 → assert `ncolors==3`, first-appearance index order, `clut_a4` for the translucent colour == `round(127/17)==7`. (c) a 300-distinct-colour RGBA surface → `pal_extract` returns false.

- [ ] **Step 2: Run, verify fail** — `tests/run_tests.sh` (or `cc -I ... tests/palette_atlas_test.c $(sdl2-config --cflags --libs) -o /tmp/pa && /tmp/pa`) → FAIL.

- [ ] **Step 3: Implement `palette_atlas.h`** — the two branches above. Reverse map = a `std::unordered_map<uint32_t,uint8_t>` on packed RGBA (or a flat 2^24 table if RGB-only + separate alpha). Keep it header-only + dependency-light (SDL types only) so the test builds natively.

- [ ] **Step 4: Run, verify pass** — `tests/run_tests.sh` → the three cases green.

- [ ] **Step 5: Register** — add `palette_atlas.h` to `scripts/apply_mister_files.sh` cp list; add the test to `tests/run_tests.sh`.

- [ ] **Step 6: Commit** — `git commit -m "feat(pal): host index recovery + palette extraction (palette_atlas.h) + tests"`.

### Task 2.2: Palette manager — bank packing

**Files:** Modify `patches/mister/palette_atlas.h` (add the manager); extend `tests/palette_atlas_test.c`.

**Interfaces:**
- Produces: `struct pal_bankset { uint32_t entries[`8`*`256`]; ... };` and `bool pal_pack(pal_bankset* bs, const pal_surface* s, uint8_t* out_bank, uint8_t* out_base)`. Contract: first-fit — find a bank with `256 - used >= s->ncolors`, append `s`'s entries at `used`, return `(bank, base)`. The map's tileset palette is pinned to bank 0. Returns false if all 8 banks are full (caller falls back to direct-colour + a loud log). Also `void pal_bankset_bytes(const pal_bankset*, uint8_t* ddr /*CLUT_BANKS*CLUT_ENTRIES*8*/)` producing the exact `CLUTBUF` byte image the fabric DMAs (one 32-bit `` `CLUT_MAKE ``-format entry per 64-bit qword, high 32 zero — matching Task 1.1).

- [ ] **Step 1: Write failing test** — pack three surfaces (6, 15, 250 colours) → assert distinct `(bank,base)` with no overlap; pack a 4th needing 20 into a bank with 10 free and 250-full others → lands in the 6+15 bank; overflow a 9th → false. Assert `pal_bankset_bytes` round-trips through `` `CLUT_MAKE `` layout for a spot entry.
- [ ] **Step 2: Run, fail.** [ ] **Step 3: Implement first-fit + byte-image builder.** [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(pal): first-fit CLUT bank packing + CLUTBUF byte image + tests"`.

### Task 2.3: Emitter — `blt_emit_clut_upload` + PAL8 blit helper

**Files:** Modify `patches/mister/blitter/blt_emitter.{h,c}`; extend the wire/emitter test.

**Interfaces:**
- Produces: `void blt_emit_clut_upload(blt_emitter* em, uint32_t clutbuf_off, uint32_t qw_count)` (emit one `BLT_OP_CLUT_UPLOAD` command with `{h,w}=qw_count`, mirroring the existing `blt_emit_frt_upload` — grep it), and a PAL8 path in the existing blit-emit helper that sets `format=BLT_FMT_PAL8` + `color=blt_pal_color(pal_id,base)`.

- [ ] **Step 1: Write failing test** — assert `blt_emit_clut_upload` produces a command whose unpack has `opcode==BLT_OP_CLUT_UPLOAD` and `{h,w}` == count; assert the PAL8 blit helper sets format + color correctly. [ ] **Step 2: Fail.** [ ] **Step 3: Implement** (copy `blt_emit_frt_upload` shape). [ ] **Step 4: Pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(pal): blt_emit_clut_upload + PAL8 blit emit"`.

### Task 2.4: Renderer integration (16bpp-index staging) + cumulative regression

**Files:** Modify `patches/mister/mister_blitter_renderer.{cpp,h}`; create `tests/pal_restage_test.c` (register in `run_tests.sh`).

**Interfaces:**
- Consumes: `palette_atlas.h`, `blt_emit_clut_upload`, `BLT_FMT_PAL8`, `CLUTBUF` offset.
- Produces: gated on `SOLARUS_PALETTE` (default OFF), a preload/staging path that, for an immutable `pal8` surface: `pal_extract` → `pal_pack` → stage the **16bpp index plane** (index in low byte) to perm → record `(bank,base,sdram_off)` on the surface → upload the bankset via `blt_emit_clut_upload` when a bank changes; and an emit path that sets `format=PAL8, color=pal_color(bank,base)`. When the flag is OFF or `pal_extract` fails, the existing dual-format path runs unchanged.

- [ ] **Step 1: Write the cumulative regression** — `tests/pal_restage_test.c` (native, links the pure allocator + `palette_atlas.h`; model the harness on the host-fix's `tests/preload_restage_test.c` if present on `master`). Stage ≥6 distinct paletted surfaces via the real perm allocator with `SOLARUS_PALETTE` semantics; assert: (a) every source offset stays in-range (no runaway — the #84 class), and (b) with 16bpp indices the footprint ≈ the 16bpp baseline (Step-2 will assert the halving). Expected: FAIL pre-integration.

- [ ] **Step 2: Run, verify fail** — `tests/run_tests.sh` → FAIL.

- [ ] **Step 3: Integrate in `mister_blitter_renderer.cpp`** — add the flag member `bool palette_enabled = mister_flag_default_on... ` **NO** — default OFF: `bool palette_enabled = getenv("SOLARUS_PALETTE") && atoi(getenv("SOLARUS_PALETTE"));` (match the codebase's OFF-by-default idiom — grep for an existing default-OFF flag). Wire the extract/pack/stage/upload/emit path behind it per the interface above.

- [ ] **Step 4: Run, verify pass** — `tests/run_tests.sh` → cumulative test green.

- [ ] **Step 5: Build gate** — `scripts/docker_run.sh scripts/build_engine.sh` compiles clean (armhf).

- [ ] **Step 6: Commit** — `git commit -m "feat(pal): renderer PAL8 staging+emit (16bpp index, flagged) + cumulative regression"`.

---

# PHASE 3 — 8bpp source packing (the memory win + #84 dissolve)

### Task 3.1: `comp_pipeline` format-aware prefetch fill (highest-risk)

**Files:** Modify `fpga/rtl/comp_pipeline.sv` (`F_WALK` fill + address math, `:388-463`); create `fpga/sim/tb_pal8_fill_8bpp.sv`.

**Interfaces:**
- Consumes: `c_format==COMP_PAL8`, source stored 8bpp (1 B/px). Produces: the same linebuf contents as Phase 1 (16-bit lanes, index in low byte), but read from a **half-size** source.
- Behaviour: for PAL8, source qword index = `(fill_lo>>3)` walking `((fill_hi>>3)-(fill_lo>>3))+1` qwords; each fetched 64-bit qword's **8 index bytes** expand into **two** linebuf writes (`lb_fill_idx = 2*i` gets indices 0..3 zero-extended, `2*i+1` gets 4..7). The linebuf base qword stays `fill_lo>>2` (linebuf is 16bpp). RGB565/ARGB4444 keep the existing 1:1 `>>2` path untouched.

- [ ] **Step 1: Write the golden TB** — `tb_pal8_fill_8bpp.sv`: stage a known 8bpp index row in SDRAM (values `i&0xFF`), including a **non-qword-aligned `src_x`** and an **hflip** case; drive a PAL8 span; assert the served indices (via a trivial identity CLUT `CLUT[k]=k`) match the source bytes exactly. This isolates the fill/addressing from the CLUT. Expected: FAIL pre-impl.

- [ ] **Step 2: Run, verify fail** — `run_sims.sh --only tb_pal8_fill_8bpp` → FAIL.

- [ ] **Step 3: Implement the format-aware fill.** In the F_IDLE kick (`:433-441`) and F_WALK (`:444-458`), branch on `is_pal8`: compute `sf_nqw` and `p0_addr` with `>>3`/`<<3` source geometry; in F_WALK, on each `p0_ok`, perform two `lb_fill_we` writes with `lb_fill_qw` = `{8'd0,b3,8'd0,b2,...}` low half then high half, `lb_fill_idx` = `2*sf_idx` then `2*sf_idx+1`. Keep the non-PAL8 path byte-identical (guard every change with `is_pal8`). This is the delicate step — small, heavily-commented, and every non-PAL8 cycle must be unchanged (Task 1.3 mixed-format TB + all existing `tb_blitter_*` must still pass).

- [ ] **Step 4: Run, verify pass** — `run_sims.sh --only tb_pal8_fill_8bpp` PASS; then the **full** suite (`run_sims.sh`) PASS (no regression in RGB565/ARGB4444 TBs).

- [ ] **Step 5: Commit** — `git commit -m "feat(pal): comp_pipeline 8bpp source fill (1:2 expand, byte-addressed) + golden TB"`.

### Task 3.2: Host — stage indices at 8bpp; assert the halving

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp` (staging width + `src_stride`/`src_off` for PAL8); extend `tests/pal_restage_test.c`.

- [ ] **Step 1: Update the regression** to assert the paletted perm footprint is **≈ half** the 16bpp baseline for the same ≥6 surfaces (the #84 headroom win). Run → FAIL (still 16bpp).
- [ ] **Step 2: Implement** — stage the index plane at 1 B/px; set `src_stride` in bytes for PAL8 (`w`), `src_off` byte-addressed. Confirm the emit `src_x`/`src_stride` semantics match Task 3.1's `>>3` geometry.
- [ ] **Step 3: Run, verify pass** — regression green (footprint halved, offsets in-range).
- [ ] **Step 4: Build gate** — armhf build clean.
- [ ] **Step 5: Commit** — `git commit -m "feat(pal): stage index planes at 8bpp (half perm footprint) + halving assertion"`.

---

# PHASE 4 — Bake integration

### Task 4.1: bgplane bake reads PAL8 sources, resolves to RGB565 plane

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp` (bake source path, `:2903-3018` region); add a bake golden case to `tests/pal_restage_test.c` or a focused host test.

**Interfaces:** The bake's **source read** goes through the CLUT (PAL8), but the **output plane stays resolved-colour** (RGB565, or ARGB4444 for the one blended water layer) — unchanged plane format, so scanout/replay are untouched. Per-layer occlusion (binary alpha) and water (A4 127/191→nearest) both carried by the plane's A4 as today.

- [ ] **Step 1: Write the check** — a bake over a PAL8 layer with a transparent index + an opaque index → assert the resolved plane pixels equal `CLUT[index]` for opaque and remain background for transparent. (If the bake isn't unit-testable in isolation, add a `tb`-level bake case; otherwise gate this on a host harness that exercises `res_arm_`/bake with a stub.)
- [ ] **Step 2: Fail.** [ ] **Step 3: Implement** — route the bake's source sampler through the same `pal_extract`-derived index+CLUT; resolve to RGB565 at bake time. [ ] **Step 4: Pass** + full sim suite still green.
- [ ] **Step 5: Commit** — `git commit -m "feat(pal): bgplane bake resolves PAL8 sources to RGB565 planes"`.

---

# PHASE 5 — Migration flag flip + HW validation

### Task 5.1: STA gate + flag flip to default-ON

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp` (flag default), RBF build.

- [ ] **Step 1: STA** — build the RBF (CI or local Quartus per repo recipe) and confirm the added CLUT read stage closes timing on the core clock (the Phase-1 STA note). If it fails, register-retime the CLUT read (it is latency-tolerant). Record the slack.
- [ ] **Step 2: Flip default** — change `SOLARUS_PALETTE` to default-ON only after §5.2 HW validation passes; keep `SOLARUS_PALETTE=0` as the revert. (This step's commit lands AFTER Task 5.2.)
- [ ] **Step 3: Commit** — `git commit -m "chore(pal): SOLARUS_PALETTE default-ON after HW validation"`.

### Task 5.2: HW validation (objective + human visual)

**Not a code step — a validation protocol. Never self-declare visual correctness.**

- [ ] **Step 1: Build + deploy** the RBF (Task 5.1) + the paletted engine to `192.168.20.81` (`deploy.py`; refresh `deploy/` from `build/armhf` first).
- [ ] **Step 2: Objective probes** (with `SOLARUS_BLITTER_DIAG=1` in a diag session, NOT pristine): tileset gameplay `cold_upload MB → ~0`; perm high-water ≈ **half** the pre-paletted baseline; no `perm_overflow`.
- [ ] **Step 3: Human visual** — the §2-brief cumulative teleport route (≥6 distinct tilesets, through Roc's Cavern) with the **user** confirming tiles + water (the 127/191 translucent shades) render correctly, and menus/text/`ts9` (direct-colour) are unaffected. Compare colour fidelity vs the ARGB4444 baseline (should be equal-or-better).
- [ ] **Step 4:** On PASS, land Task 5.1 Step 2 (default-ON) and update memory (`solarus-tileset-alpha-census-paletted`, a new `solarus-paletted-composition-shipped`).

---

## Self-Review

**Spec coverage:** §3 contract → Task 0.1; §4.1a CLUT+lookup → Tasks 1.1–1.3; §4.1b 8bpp packing → Tasks 3.1–3.2; §4.2 comp_burst/linebuf untouched → asserted by Task 1.3 + full-suite gate in 3.1; §5 host pipeline (index recovery/packing/stage/emit) → Tasks 2.1–2.4; §6 bake → Task 4.1; §7 migration flag → Task 2.4 (gate) + 5.1 (flip); §8 testing (cumulative regression + RTL TBs) → 2.4, 3.2, 1.1–1.3, 3.1; §9 risks (fill, STA, reverse-map, bank overflow, alpha rounding) → mitigations in 3.1, 5.1, 2.1, 2.2, 4.1. **Deferred per §2:** dedup, disk cache (Phase 2, not planned here). No gaps.

**Placeholder scan:** RTL edit-tasks specify signal-level contracts + exact reference lines + golden TBs (not reproduced full modules) — intentional for surgical edits to large existing HDL the implementer reads; all NEW code (defs, host header, tests, emitter) is complete. No TBD/TODO.

**Type consistency:** `pal_id`(4b)/`base_off`(8b) in `color[11:8]/[7:0]` consistent across 0.1/1.2/2.3/2.4; CLUT entry `{A4,R5,G6,B5}` (20b) consistent 0.1/1.1/1.2/2.2; `pal_extract`/`pal_pack`/`pal_bankset_bytes` signatures consistent 2.1/2.2/2.4; `BLT_OP_CLUT_UPLOAD` uses `{h,w}`=qw count consistent 1.1/2.3.
