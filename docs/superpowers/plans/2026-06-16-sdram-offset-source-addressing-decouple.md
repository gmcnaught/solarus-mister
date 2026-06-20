# SDRAM-offset Source Addressing Decouple (Task #32) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a staged source live at *any* 64MB SDRAM offset that is **independent of its DDR3 location**, so the whole-quest atlas (larger than the 16MB DDR3 heap) can be staged via a small DDR3 bounce buffer.

**Architecture (refined from the spec after reading the RTL):** The blit SDRAM read path is *already* decoupled — `src_sdram_addr` derives from `src_byte_cur = c_src_off + subrect` with **no `SRC_QW` base** (blitter_top.sv ~L408/L432), and `c_src_off` is a 32-bit field that already reaches 64MB. The real coupling is in **`BLT_OP_STAGE`**: `stage_off <= c_src_off` is used as *both* the DDR3 read base (`SRC_QW + stage_off`) and the SDRAM write offset (`stage_off + stage_byte`). So #32 = give STAGE a **separate SDRAM-destination offset** (decoupled from the DDR3 read offset), gated by a new flag so the #19 wire format and all existing `blt_stage` callers stay byte-identical. The blit side needs **no fabric change**; the host simply sets a blit's `c_src_off` to the source's SDRAM offset when `C_SRCSEL=1`.

**Tech Stack:** SystemVerilog (`-g2012`, iverilog/vvp, from `fpga/sim/`); C (host emitter `blt_emitter.c` + host test via the project's C test harness). Sims pass on `errors=0` / `RESULT: PASS`, no `PROTO`/`DEADLOCK`.

**Why a flag, not a sentinel:** `BLT_F_STAGE_DST` (0x08, next free flag after COLORKEY=0x04) means "u32[2] carries the SDRAM dest offset." Unset (every existing STAGE command, incl. the #19 bgcache chunks and the current tb) → fabric falls back to `stage_sdram_off = c_src_off` = exact #19 behavior. SDRAM offset 0 stays addressable (no sentinel collision).

**Scope:** ONLY task #32 (STAGE SDRAM-dest decouple + emitter plumbing + sim proof). The SDRAM allocator that *assigns* these offsets and the boot pre-stage live in #33; on-device validation is #34.

**Wire format (STAGE command):** unchanged 32-byte layout. STAGE already uses `u32[0]=opcode|flags`, `u32[1]=src_off` (DDR3 read base), `u32[3]=size(w|h<<16)`. The previously-unused **`u32[2]` = `src_stride|src_x`** slot now carries the 32-bit **SDRAM dest offset** when `BLT_F_STAGE_DST` is set. Fabric reads it as `{c_src_x, c_src_stride}` (= `cmd_qw[1][31:0]`).

**Conventions:** iverilog idiom per `fpga/sim/README.md`; compile with the SDRAM source set + `altddio_out_stub.sv` (+ `-I ../rtl` for tbs that `\`include "blitter_defs.vh"`). Build from `fpga/sim/`.

---

## File Structure

- `fpga/rtl/blitter_top.sv` — **modify**: add `F_STAGE_DST` localparam + `stage_sdram_off` reg; set it in the `OP_STAGE` decode branch; use it in `S_STAGE_WR`. (`S_STAGE_RD` and the blit path are unchanged.)
- `fpga/sim/tb_sdram_stage.sv` — **modify**: add scenario 2 (STAGE with the flag + a distinct SDRAM dest); keep scenario 1 as the #19 backward-compat (flag-off) check.
- `patches/mister/blitter/blitter_ref.h` — **modify**: define `BLT_F_STAGE_DST 0x08`.
- `patches/mister/blitter/blt_emitter.h` / `blt_emitter.c` — **modify**: add `blt_stage_to(e, ddr_off, sdram_off, size)`; `blt_stage` becomes a thin wrapper preserving #19 behavior.
- `tests/blt_stage_test.c` — **modify**: add a case asserting `blt_stage_to` packs `src_off=ddr_off`, `{src_x,src_stride}=sdram_off`, `flags & BLT_F_STAGE_DST`.

---

## Task 1: Add the failing distinct-SDRAM-dest test (fabric)

**Files:**
- Modify: `fpga/sim/tb_sdram_stage.sv` (add scenario 2 before the final `$display("staged ...")` / `RESULT` block, ~L206)

- [ ] **Step 1: Write the failing test**

In `tb_sdram_stage.sv`, after the scenario-1 verify loop + proto check and BEFORE the `$display("staged %0d qwords ...")` line, insert a second staging op that targets a **distinct** SDRAM offset via the new flag. Add these params near the other `localparam`s (after `SRC_QW_IDX`, ~L127):

```systemverilog
  // Scenario 2 (Task #32): decoupled SDRAM dest. Stage from DDR3 bounce offset
  // S2_DDR_OFF to a DISTINCT SDRAM offset S2_SDRAM_OFF (flag BLT_F_STAGE_DST=0x08).
  localparam integer S2_DDR_OFF   = 32'h100;     // DDR3 read (bounce) offset
  localparam integer S2_SDRAM_OFF = 32'h2_0000;  // SDRAM dest (128KB in — != DDR off)
  localparam integer S2_QWS       = 4;
  localparam integer S2_SIZE      = S2_QWS * 8;
  localparam [7:0]   F_STAGE_DST  = 8'h08;
```

Add a second expect buffer with the other declarations (near `expect_qw`, ~L130):
```systemverilog
  reg [63:0] s2_expect [0:S2_QWS-1];
```

Drive scenario 2 by appending a second STAGE command to the ring and re-submitting. Insert this block right after the scenario-1 `if (schip.proto_errors !== 0) ...` check (~L204), before `$display("staged ...")`:

```systemverilog
    // ---- Scenario 2: stage to a DISTINCT SDRAM offset (decoupled) -------------
    // Seed a fresh DDR3 source at the bounce offset S2_DDR_OFF.
    for (q=0; q<S2_QWS; q=q+1) begin
      s2_expect[q] = {16'hE000 + 16'(q*4+3), 16'hE000 + 16'(q*4+2),
                      16'hE000 + 16'(q*4+1), 16'hE000 + 16'(q*4+0)};
      mem[SRC_QW_IDX + (S2_DDR_OFF>>3) + q] = s2_expect[q];
    end
    // Rewrite the ring: cmd0 = STAGE {ddr=S2_DDR_OFF, sdram=S2_SDRAM_OFF, size} with
    // the STAGE_DST flag in u32[0][31:24]; u32[2]={src_x,src_stride}=S2_SDRAM_OFF.
    //   qw0 = {u32[1]=S2_DDR_OFF, u32[0]= flags<<24 | opcode}
    //   qw1 = {u32[3]=size(w|h<<16), u32[2]=S2_SDRAM_OFF}
    wmem(32'h200008, {32'(S2_DDR_OFF), {F_STAGE_DST, 8'h00, 8'h00, 8'h04}});
    wmem(32'h200009, {{16'(S2_SIZE>>16), 16'(S2_SIZE & 16'hFFFF)}, 32'(S2_SDRAM_OFF)});
    wmem(32'h20000C, 64'd1);                       // cmd1 END (unchanged)
    // bump submit_seq so the blitter re-runs the new list
    wmem(32'h200000, 64'd2);                       // submit_seq = 2
    wmem(32'h200005, 64'd0);                       // done_seq = 0 (re-arm)
    t=0;
    while(mem[32'h200005][31:0] !== mem[32'h200000][31:0] && t<4000000) begin @(posedge clk); t=t+1; end
    repeat(20) @(posedge clk);
    // Verify: data landed at S2_SDRAM_OFF...
    for (q=0; q<S2_QWS; q=q+1) begin : verify2
      reg [63:0] got2; reg [26:0] b0,b1,b2,b3;
      b0 = S2_SDRAM_OFF + q*8 + 0; b1 = S2_SDRAM_OFF + q*8 + 2;
      b2 = S2_SDRAM_OFF + q*8 + 4; b3 = S2_SDRAM_OFF + q*8 + 6;
      got2 = {schip.store[schip.key(b3[12:11], b3[25:13], b3[10:1])],
              schip.store[schip.key(b2[12:11], b2[25:13], b2[10:1])],
              schip.store[schip.key(b1[12:11], b1[25:13], b1[10:1])],
              schip.store[schip.key(b0[12:11], b0[25:13], b0[10:1])]};
      if (got2 !== s2_expect[q]) begin
        errors=errors+1; $display("  S2 SDRAM mismatch qw%0d: got=%h expect=%h", q, got2, s2_expect[q]);
      end
    end
    // ...and NOT at the DDR3 read offset S2_DDR_OFF (proves the write was decoupled).
    begin : verify2_neg
      reg [26:0] bn; bn = S2_DDR_OFF;
      if (schip.store[schip.key(bn[12:11], bn[25:13], bn[10:1])] !== 16'd0) begin
        errors=errors+1; $display("  S2 leaked to DDR offset (coupled write): %h",
                                  schip.store[schip.key(bn[12:11], bn[25:13], bn[10:1])]);
      end
    end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd fpga/sim
iverilog -g2012 -I ../rtl -o tb_sdram_stage.vvp tb_sdram_stage.sv ../rtl/blitter_top.sv ../rtl/ddr_blitter_arb.sv ../rtl/sdram_src_arb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && vvp tb_sdram_stage.vvp 2>&1 | grep -iE 'S2|mismatch|leaked|result|errors='
```
Expected: FAIL — `S2 SDRAM mismatch ...` (the current fabric ignores the flag/u32[2] and writes to `stage_off = c_src_off = S2_DDR_OFF`, so nothing lands at `S2_SDRAM_OFF`). `RESULT: FAIL`.

> If S2 passes here, the test isn't discriminating — verify the flag byte and u32[2] are set and that S2_SDRAM_OFF != S2_DDR_OFF.

---

## Task 2: Decouple the STAGE SDRAM-write offset (fabric)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv`

- [ ] **Step 1: Add the flag localparam + the new state reg**

(a) Extend the flags localparam (currently `localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04;`, ~L100):
```systemverilog
    localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04, F_STAGE_DST=8'h08;
```

(b) Add the new stage register next to `stage_off` (after `reg [31:0] stage_off;`, ~L134):
```systemverilog
    reg  [31:0] stage_sdram_off;  // SDRAM dest byte offset (#32: decoupled from the DDR3 read base)
```

- [ ] **Step 2: Set `stage_sdram_off` in the OP_STAGE decode branch**

In the `OP_STAGE` branch (~L376-385), after `stage_off <= c_src_off;` add the decoupled-dest select (when `F_STAGE_DST` set, take u32[2] = `{c_src_x, c_src_stride}`; else fall back to the DDR3 offset = #19 behavior):
```systemverilog
                    stage_off  <= c_src_off;
                    stage_sdram_off <= (c_flags & F_STAGE_DST) ? {c_src_x, c_src_stride}
                                                               : c_src_off;
```

- [ ] **Step 3: Use `stage_sdram_off` for the SDRAM write address**

In `S_STAGE_WR` (~L588), change the SDRAM write address from `stage_off` to `stage_sdram_off`:
```systemverilog
            S_STAGE_WR: begin
                src_sdram_waddr    <= (stage_sdram_off + stage_byte) & 27'h7FFFFF8; // 8-byte align
                src_sdram_din64    <= stage_beat;
                src_sdram_we_burst <= 1'b1;
                state<=S_STAGE_WR_WAIT;
            end
```
(`S_STAGE_RD` keeps reading DDR3 at `\`SRC_QW + ((stage_off + stage_byte) >> 3)` — `stage_off` is the DDR3 read/bounce base, unchanged.)

- [ ] **Step 4: Run tb_sdram_stage — expect green**

```bash
cd fpga/sim
iverilog -g2012 -I ../rtl -o tb_sdram_stage.vvp tb_sdram_stage.sv ../rtl/blitter_top.sv ../rtl/ddr_blitter_arb.sv ../rtl/sdram_src_arb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && vvp tb_sdram_stage.vvp 2>&1 | grep -iE 'S2|mismatch|leaked|result|errors='
```
Expected: `errors=0`, `RESULT: PASS` — scenario 1 (flag-off, #19 behavior) AND scenario 2 (distinct dest) both pass; no `S2 ... leaked`.

---

## Task 3: Regression — full SDRAM sim suite green

**Files:** none (verification)

- [ ] **Step 1: Run the SDRAM suite**

```bash
cd fpga/sim
for cmd in \
  "tb_sdram_psx tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv" \
  "tb_sdram_ctrl tb_sdram_ctrl.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv" \
  "tb_sdram_sweep tb_sdram_sweep.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv"; do
  set -- $cmd; n=$1; shift
  iverilog -g2012 -I ../rtl -o $n.vvp "$@" 2>/dev/null && echo "$n: $(vvp $n.vvp 2>&1 | grep -iE 'errors=|RESULT' | tail -1)"
done
iverilog -g2012 -I ../rtl -o tb_blitter_system.vvp tb_blitter_system.sv ../rtl/blitter_top.sv ../rtl/ddr_blitter_arb.sv ../rtl/sdram_src_arb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && echo "tb_blitter_system: $(vvp tb_blitter_system.vvp 2>&1 | grep -iE 'RESULT' | tail -1)"
```
(Note: zsh — if `$@` word-split misbehaves, run each `iverilog` line literally.) Expected: every line `errors=0` / `RESULT: PASS`. tb_blitter_system PHASE2 (srcsel equiv) confirms the blit SDRAM read path is intact.

- [ ] **Step 2: Commit the fabric decouple + test**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/blitter_top.sv fpga/sim/tb_sdram_stage.sv
git commit -m "feat(#32): decouple STAGE SDRAM-dest offset from the DDR3 read base

BLT_OP_STAGE can now write SDRAM at a dest offset independent of its DDR3 read
offset, gated by BLT_F_STAGE_DST (u32[2]=SDRAM dest). Flag-off = #19 behavior
(dest=src_off), so existing callers/wire are byte-identical. tb_sdram_stage
scenario 2 stages to a distinct SDRAM offset and asserts no leak to the DDR
offset. Blit SDRAM read already addresses by c_src_off (no SRC_QW) -> no blit
fabric change needed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Emitter plumbing — `blt_stage_to` (host)

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.h` (flag define)
- Modify: `patches/mister/blitter/blt_emitter.h` + `blt_emitter.c` (new fn)
- Modify: `tests/blt_stage_test.c` (host unit test)

- [ ] **Step 1: Define the flag**

In `patches/mister/blitter/blitter_ref.h`, after `#define BLT_F_COLORKEY 0x04u` (~L82):
```c
#define BLT_F_STAGE_DST 0x08u  /* [MiSTer #32] STAGE: u32[2] carries the SDRAM dest offset */
```

- [ ] **Step 2: Add the failing host test**

In `tests/blt_stage_test.c`, add a test asserting the decoupled packing. Append a new case (mirror the style of the existing `blt_stage(&e, 0xDEAD0000u, 0xABCD1234u)` field-packing test):
```c
    /* [#32] blt_stage_to packs ddr off in src_off, sdram off in {src_x,src_stride},
     * and sets BLT_F_STAGE_DST. */
    {
        uint8_t buf[256]; blt_emitter_t e;
        uint8_t heap[256];
        blt_emitter_init(&e, buf, sizeof buf, heap, sizeof heap);
        int rc = blt_stage_to(&e, 0x111u, 0x22220000u, 0x40u);
        assert(rc == 0);
        const blt_cmd_t *c = (const blt_cmd_t *)e.ring;  /* first command */
        assert(c->opcode == BLT_OP_STAGE);
        assert(c->src_off == 0x111u);
        assert(((uint32_t)c->src_x << 16 | c->src_stride) == 0x22220000u);
        assert(c->flags & BLT_F_STAGE_DST);
        assert(c->w == 0x40u && c->h == 0u);
        printf("blt_stage_to packing OK\n");
    }
```
(Match the actual `blt_emitter_init` signature + ring-readback idiom already used in `blt_stage_test.c`; adjust the cast/offset to how that file inspects emitted commands.)

- [ ] **Step 3: Run the host test — expect fail (undeclared `blt_stage_to`)**

Use the project's C test build (see `tests/run_tests.sh` for the exact `cc` line for `blt_stage_test`):
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash tests/run_tests.sh 2>&1 | grep -iE 'blt_stage|error|undefined' | head
```
Expected: compile error — `blt_stage_to` undeclared.

- [ ] **Step 4: Implement `blt_stage_to`**

In `patches/mister/blitter/blt_emitter.h`, declare it next to `blt_stage` (~L120):
```c
/* [MiSTer #32] STAGE with a SDRAM destination offset DECOUPLED from the DDR3
 * read offset. ddr_off -> cmd.src_off (DDR3 SRC_QW+ read base / bounce buffer);
 * sdram_off -> cmd.{src_x,src_stride} (= u32[2]) with BLT_F_STAGE_DST set;
 * size packed as w|h<<16 like blt_stage. Use when the SDRAM resident set exceeds
 * the DDR3 heap (whole-quest atlas). */
int blt_stage_to(blt_emitter_t *e, uint32_t ddr_off, uint32_t sdram_off, uint32_t size);
```
In `patches/mister/blitter/blt_emitter.c`, implement it and refactor `blt_stage` as the flag-off wrapper:
```c
int blt_stage_to(blt_emitter_t *e, uint32_t ddr_off, uint32_t sdram_off, uint32_t size)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode     = BLT_OP_STAGE;
    c.flags      = BLT_F_STAGE_DST;
    c.src_off    = ddr_off;                          /* DDR3 read (bounce) base   */
    c.src_stride = (uint16_t)(sdram_off & 0xFFFFu);  /* u32[2] low  = sdram[15:0] */
    c.src_x      = (uint16_t)((sdram_off >> 16) & 0xFFFFu); /* u32[2] high = sdram[31:16] */
    c.w          = (uint16_t)(size & 0xFFFFu);
    c.h          = (uint16_t)((size >> 16) & 0xFFFFu);
    return emit(e, &c);
}
```
Leave the existing `blt_stage(e, off, size)` UNCHANGED (flags=0 → fabric falls back to `stage_sdram_off = c_src_off`, the #19 behavior). Do not break its callers.

- [ ] **Step 5: Run the host test — expect pass**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash tests/run_tests.sh 2>&1 | tail -20
```
Expected: `blt_stage_to packing OK` and the existing blt_stage cases still pass; overall suite green.

- [ ] **Step 6: Commit the emitter plumbing**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add patches/mister/blitter/blitter_ref.h patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c tests/blt_stage_test.c
git commit -m "feat(#32): blt_stage_to emitter — decoupled SDRAM dest offset

Adds blt_stage_to(ddr_off, sdram_off, size) packing the SDRAM dest into u32[2]
with BLT_F_STAGE_DST. blt_stage stays the #19 flag-off wrapper. Host test in
blt_stage_test.c. NOTE: blt_emitter.* are vendored from mister-fpga-blitter —
re-sync upstream with this change.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: RBF build + on-device gate (batched with #34)

**Files:** none (CI + hardware)

- [ ] **Step 1: CI RBF build + timing closure** on the branch (shares the RBF with #31). The STAGE FSM gains a 32-bit reg + a mux on the decode path; watch worst-slack, pipeline if it regresses.
- [ ] **Step 2: On-device** — the end-to-end no-starvation + render-from-SDRAM proof needs #33 (the engine actually staging real sources to distinct SDRAM offsets). So the hardware gate for #31+#32 is performed under **#34** once #33 lands. This task's RBF/timing checkbox can be satisfied by the shared #31/#32 RBF CI run; the visual/analog gate defers to #34.

---

## Self-Review notes (author)

- **Spec coverage:** spec #32 AC "blit command carries an SDRAM source offset; C_SRCSEL=1 reads address SDRAM by that offset, not SRC_QW" — satisfied by the *existing* `c_src_off` SDRAM base (documented; no fabric change). AC "distinct SDRAM offsets, no DDR-heap coupling" — Task 1/2 (STAGE dest decouple) + Task 4 (emitter). AC "C_SRCSEL=0 byte-identical" — guaranteed by the flag-off fallback (Task 3 regression). AC "RBF builds, timing" — Task 5.
- **Refinement vs spec:** the spec imagined a new *blit* source-offset field; reading the RTL showed the blit SDRAM read is already SRC_QW-free, so the only real coupling (and the only fabric change) is the STAGE dest offset. Recorded in the plan header.
- **Type consistency:** `stage_sdram_off` is `[31:0]` like `stage_off`; `{c_src_x, c_src_stride}` is 16+16=32 bits = u32[2]; `BLT_F_STAGE_DST`/`F_STAGE_DST` = 0x08 in both host and fabric; `src_sdram_waddr` masking `27'h7FFFFF8` unchanged.
- **Caveat to confirm during impl:** Tasks 4 step 2/3 reference `blt_stage_test.c`'s exact init + ring-inspection idiom and `tests/run_tests.sh`'s build line — read those files and match them (the test code shown is illustrative of intent, adjust to the file's real helpers).
