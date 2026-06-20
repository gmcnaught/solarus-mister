# SDRAM 64MB Geometry Reconfig (Task #31) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconfigure the `sdram_psx` controller from a 32MB (9-bit column) address map to the fitted Alliance **AS4C32M16SB** chip's 64MB (10-bit column) geometry, so the whole-quest texture atlas fits on the SDRAM second bus.

**Architecture:** The controller uses a v3.0 "column-low" address map so a burst beat's 4 words land in one open row across 4 consecutive columns. AS4C32M16 has a 10-bit column (1024) vs the current 9-bit (512). The change is purely the address slicing: column `addr[9:1]→addr[10:1]`, bank `addr[11:10]→addr[12:11]`, row `addr[24:12]→addr[25:13]`, and the page-wrap row-cross boundary 512→1024. The SDRAM controller and its sim chip model define the map jointly, so both change together; a new testbench scenario that exercises an address **past the 32MB boundary** (`addr[25]` set) is the red test — it aliases under the old map and round-trips under the new one.

**Tech Stack:** SystemVerilog (`-g2012`), Icarus Verilog (`iverilog`/`vvp`, installed at `/opt/homebrew/bin`), run from `fpga/sim/`. A sim passes when it prints `errors=0` and no `PROTO`/`DEADLOCK` lines. Quartus timing-closure (CI) and the analog vsync gate (on-device, user's CRT) are gated tail tasks.

**Why 64MB and not 128MB:** the board has two AS4C32M16 chips (128MB total), but this
analog-video core can only reach one. The 2nd chip lives on the `SDRAM2_*` pins, which
`sys_top` multiplexes with the analog VGA pins (`ifdef MISTER_DUAL_SDRAM`); this core
uses VGA (resistor-DAC YPbPr) and does not define `MISTER_DUAL_SDRAM`, so SDRAM2 is
unavailable. 64MB (single primary chip) is the usable max and is ample for the atlas.

**Scope note:** This plan covers ONLY task #31 (the controller geometry). The SDRAM-offset *source addressing* decouple is #32; the engine boot pre-stage is #33; on-device no-starvation validation is #34. The RBF build + analog gate at the end here are the same physical RBF those later tasks also ride, so the on-device gate may be deferred until #32 lands to avoid an extra RBF spin (noted in the final task).

**Conventions (read once):** `fpga/sim/README.md` shows the iverilog idiom. Compile + run each sim with `iverilog -g2012 -o X.vvp <tb.sv> ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp X.vvp`, always from `fpga/sim/`. `.vvp` artifacts are throwaway (gitignored or just not committed).

---

## File Structure

- `fpga/rtl/sdram_psx.sv` — **modify**: the address map (STATE_IDLE ACTIVE slicing, STATE_OPEN_2 column packing, STATE_READ_WAIT next-beat column, the page-wrap detection), `col_base`/`next_col_full` widths, and the header/inline comments describing the map.
- `fpga/sim/sdram_chip_model.sv` — **modify**: widen the column to 10-bit (`A[9:0]`) and de-alias the flat storage key so the testbench can touch distinct rows including the top row bit (`row[12]`).
- `fpga/sim/tb_sdram_psx.sv` — **modify**: add the past-32MB round-trip scenario (the red test) and update the existing page-wrap scenario from the 512- to the 1024-column boundary.
- Other SDRAM sims (`tb_sdram_ctrl.sv`, `tb_sdram_src_arb.sv`, `tb_sdram_stage.sv`, `tb_sdram_sweep.sv`, `tb_blitter_system.sv`) — **verify / fix fallout**: they feed addresses and assert round-trips; any that hard-code the old map's row/col decode or the 512-col page-wrap boundary must be updated.

---

## Task 1: Add the failing past-32MB testbench scenario

**Files:**
- Modify: `fpga/sim/tb_sdram_psx.sv` (insert a scenario before the final `proto_errors`/`$display`/`$finish` block, after line 89)

- [ ] **Step 1: Write the failing test**

In `fpga/sim/tb_sdram_psx.sv`, immediately AFTER the existing wrap-scenario assertions (the line `if (beat[1] !== 64'h6003_6002_6001_6000) ...`, currently line 89) and BEFORE the `if (chip.proto_errors !== 0)` line, insert:

```systemverilog
    // Scenario 4 (Task #31): prove the 64MB map reaches PAST the 32MB boundary.
    // 64MB column-low map: col=addr[10:1] (10b/1024), bank=addr[12:11], row=addr[25:13]
    //   byte_addr = (row<<13) | (bank<<11) | (col<<1)
    // 4a — TOP ROW BIT (addr[25]): write distinct values at row0 and at the address
    // with addr[25]=1 (row 0x1000, bank0, col0). Under the OLD 32MB map row=addr[24:12]
    // IGNORES addr[25], so 0x000_0000 and 0x200_0000 would ALIAS to the same cell -> the
    // second read returns the first's value (this is the RED failure on the old map).
    wr(27'h000_0000, 16'h1111);            // 64MB map: row0    bank0 col0
    wr(27'h200_0000, 16'h2222);            // 64MB map: row4096 bank0 col0 (addr[25]=1)
    rd_line(27'h000_0000, 1);
    if (beat[0][15:0] !== 16'h1111) begin errors=errors+1; $display("s4a lo bad: %h", beat[0][15:0]); end
    rd_line(27'h200_0000, 1);
    if (beat[0][15:0] !== 16'h2222) begin errors=errors+1; $display("s4a hi bad: %h", beat[0][15:0]); end

    // 4b — 10TH COLUMN BIT (col[9], addr[10]): within one row/bank, col0 vs col512 must
    // be distinct cells. 64MB map: row1=addr[25:13]=1 -> base 1<<13 = 0x2000;
    // col512 -> +(512<<1)=+0x400. Proves the new column bit is decoded.
    wr(27'h00_2000, 16'hC0C0);             // row1 bank0 col0
    wr(27'h00_2400, 16'hC512);             // row1 bank0 col512
    rd_line(27'h00_2000, 1);
    if (beat[0][15:0] !== 16'hC0C0) begin errors=errors+1; $display("s4b col0 bad: %h", beat[0][15:0]); end
    rd_line(27'h00_2400, 1);
    if (beat[0][15:0] !== 16'hC512) begin errors=errors+1; $display("s4b col512 bad: %h", beat[0][15:0]); end
```

(`rd_line(a,1)` reads one 64-bit beat; `beat[0][15:0]` is word0 = the value written at `a`. The dut is instantiated `BURST_BEATS=2`, so the controller emits a 2nd beat at col+4 which we don't capture — harmless; `wait_ready` inside `rd_line` still drains the line.)

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && vvp tb_sdram_psx.vvp
```
Expected: NON-zero errors — specifically `s4a hi bad: 1111` (the old 32MB map aliases `addr[25]`, so reading `0x200_0000` returns the value written at `0x000_0000`). The final line shows `errors=` with a count ≥ 1. This confirms the red test detects the missing high-address reach.

> If scenario 4a does NOT fail here, STOP — the test is not discriminating. Re-check that `wr`/`rd_line` use the same address and that the dut is the unmodified controller.

---

## Task 2: De-alias the sim chip model and widen its column to 10-bit

**Files:**
- Modify: `fpga/sim/sdram_chip_model.sv` (storage key, column width, header comment)

- [ ] **Step 1: Widen the storage key and column**

In `fpga/sim/sdram_chip_model.sv`:

(a) Replace the `store` declaration + key comment (currently lines 45-49):
```systemverilog
    // Flat storage keyed by {row[12], row[3:0], bank[1:0], col[9:0]} = 17 bits (no
    // associative arrays — this Icarus build lacks them). 10-bit column (1024) for the
    // AS4C32M16. The tb must keep touched rows DISTINCT in {row[12], row[3:0]} (the key
    // includes the TOP row bit so a past-32MB address (row[12]=1) never aliases row 0).
    reg [15:0] store [0:131071];
```

(b) Replace the `wr_col` declaration (currently line 67):
```systemverilog
    reg [9:0]  wr_col;        // running column for the burst (10-bit, AS4C32M16)
```

(c) Replace the `key` function (currently lines 75-77):
```systemverilog
    function [16:0] key(input [1:0] b, input [12:0] r, input [9:0] c);
        key = {r[12], r[3:0], b, c};      // 1+4+2+10 = 17 bits
    endfunction
```

(d) In the `initial` block, fix the store-clear loop bound (currently line 104 `for (i=0;i<8192;i=i+1)`):
```systemverilog
        for (i=0;i<131072;i=i+1) store[i]=16'd0;
```

(e) Update the read-burst column indexing (currently line 172, inside `CMD_READ`):
```systemverilog
                        dq_pipe[RD_LAT+i] <= store[key(BA, open_row[BA], A[9:0] + i[9:0])];
```

(f) Update the write column latch (currently lines 182-189, inside `CMD_WRITE`):
```systemverilog
                    cur = store[key(BA, open_row[BA], A[9:0])];
                    nw  = cur;
                    if (!DQML) nw[7:0]  = DQ[7:0];
                    if (!DQMH) nw[15:8] = DQ[15:8];
                    store[key(BA, open_row[BA], A[9:0])] = nw;
                    wr_bank <= BA;
                    wr_row  <= open_row[BA];
                    wr_col  <= A[9:0] + 10'd1;     // next sequential column
                    wr_cnt  <= 3;                  // 3 trailing words (BL=4)
```

(g) Update the trailing-word capture (currently lines 155-160, inside `if (wr_cnt > 0 ...)`):
```systemverilog
            cur = store[key(wr_bank, wr_row, wr_col)];
            nw  = cur;
            if (!DQML) nw[7:0]  = DQ[7:0];
            if (!DQMH) nw[15:8] = DQ[15:8];
            store[key(wr_bank, wr_row, wr_col)] = nw;
            wr_col  <= wr_col + 10'd1;
            wr_cnt  <= wr_cnt - 1;
```

(h) Update the header comment (lines 9-12) to reflect the AS4C32M16 + 17-bit key:
```systemverilog
//  Storage is a FLAT array keyed by {row[12],row[3:0],bank,col[9:0]}=17 bits so we
//  don't allocate the full 64 MB; the tb must keep touched rows distinct in
//  {row[12],row[3:0]} (this Icarus build lacks associative arrays). 10-bit column
//  (1024) matches the AS4C32M16.
```

- [ ] **Step 2: Recompile to verify the model still elaborates (test still red)**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && vvp tb_sdram_psx.vvp
```
Expected: still compiles; `errors=` still ≥ 1. Scenario 4 stays red because the **controller** still drives the old 9-bit-column map (Task 3 fixes that). The model change alone does not fix the address reach; it only enables distinct storage. The pre-existing scenarios (1-3) should still pass for now because they touch low rows distinct in `{row[12],row[3:0]}`.

> NOTE: do not commit yet — the suite is intentionally red between Tasks 1-3 (model + controller are one coupled unit).

---

## Task 3: Reconfigure the controller address map to 10-bit column / 64MB

**Files:**
- Modify: `fpga/rtl/sdram_psx.sv` (ACTIVE slicing, column packing, page-wrap, widths, comments)

- [ ] **Step 1: Widen `col_base` and `next_col_full`**

(a) `col_base` declaration (currently line 169 `reg [8:0] col_base;`):
```systemverilog
reg [9:0] col_base;          // column origin of current row's first beat (10-bit, AS4C32M16)
```

(b) `next_col_full` declaration inside the `always` block (currently line 222 `reg [9:0] next_col_full;`):
```systemverilog
	reg [10:0] next_col_full;   // 11-bit next-beat column; bit[10] = page wrap (1024 cols)
```

- [ ] **Step 2: Update the ACTIVE address slicing (STATE_IDLE)**

Replace the row/bank/col latch + ACTIVE drive (currently lines 375-384) with the 64MB map:
```systemverilog
				cur_row     <= addr[25:13];
				cur_bank    <= addr[12:11];
				col_base    <= addr[10:1];
				state       <= STATE_OPEN_1;
				command     <= CMD_ACTIVE;
				// column-low map (AS4C32M16, 64MB): row = addr[25:13], bank = addr[12:11]
				SDRAM_A     <= addr[25:13];
				SDRAM_BA    <= addr[12:11];
				chip        <= 1'b0;          // single AS4C32M16 chip (64MB <= addr[25:0])
```

- [ ] **Step 3: Update the column packing (STATE_OPEN_2)**

Replace the burst/single/read column drive (currently lines 408-414). For 10-bit columns the column occupies `SDRAM_A[9:0]`, auto-precharge is `A[10]`, and DQM is `A[12:11]`:
```systemverilog
		if (save_burst)
			SDRAM_A <= {2'b00, 1'b1, col_base};                  // DQM=00, AP=1, col[9:0]
		else
			SDRAM_A <= {save_we & (new_wtbt ? ~new_wtbt[1] : ~save_addr[0]),
			            save_we & (new_wtbt ? ~new_wtbt[0] :  save_addr[0]),
			            save_we | (reads_issued == BURST_BEATS-1), col_base};
```
(Each brace group: `{DQM_H, DQM_L, AP, col[9:0]}` = 1+1+1+10 = 13 bits = `SDRAM_A` width. The old `1'b0` filler at A[9] is removed — A[9] is now the column MSB.)

- [ ] **Step 4: Update the page-wrap detection + same-row next-beat column (STATE_READ_WAIT)**

(a) The next-beat column computation (currently line 442-443):
```systemverilog
						next_col_full = {1'b0, col_base} + {reads_in_row, 2'b00};
						if (next_col_full[10]) begin
```
(`{1'b0, col_base}` is 11-bit; wrap is now bit[10] = the 1024-column boundary.)

(b) The same-row next-beat `SDRAM_A` drive (currently lines 457-459):
```systemverilog
							SDRAM_A <= {2'b00, (reads_issued == BURST_BEATS-1),
							            next_col_full[9:0]};
```
(`{DQM=00, AP, col[9:0]}` = 2+1+10 = 13 bits.)

- [ ] **Step 5: Update the header + inline map comments**

In the file header (around lines 32-34) replace the column-low map description:
```systemverilog
//            column[9:0] = addr[10:1]   (beat words = col, col+1, col+2, col+3)
//            bank[1:0]   = addr[12:11]
//            row[12:0]   = addr[25:13]   (AS4C32M16, 512Mbit/64MB, 10-bit column)
```
And the STATE_OPEN_2 comment block (around line 393-394) — change "A[9]=0 (unused, 9-col chip)" / "512" references to note A[9:0]=column (10-bit, 1024) for the AS4C32M16. Keep the auto-precharge/DQM explanation intact.

- [ ] **Step 6: Run tb_sdram_psx to verify it now passes**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && vvp tb_sdram_psx.vvp
```
Expected: `errors=0`, a `refresh_seen=N` (N≥1) line, and no `PROTO`/`s4a`/`s4b` failure lines.

> If scenario 3 (the page-wrap) now fails, its addresses still target the OLD 512-col boundary — Task 4 fixes them.

---

## Task 4: Update the existing page-wrap scenario to the 1024-column boundary

**Files:**
- Modify: `fpga/sim/tb_sdram_psx.sv` (scenario 3, currently lines 77-89)

- [ ] **Step 1: Rewrite scenario 3 for 1024-column rows**

Replace the scenario-3 block (the comment + the two `for` loops + the `rd_line`/asserts at lines 77-89) with the 1024-boundary version. Under the 64MB map `byte = (row<<13)|(bank<<11)|(col<<1)`; the line must START in the last 4 columns of a row (cols 1020..1023) so its 2nd beat falls in cols 0..3 of the next row:
```systemverilog
    // Scenario 3: PAGE-WRAP line read crossing a ROW boundary at the 1024-col boundary.
    // 64MB map: byte = (row<<13) | (bank<<11) | (col<<1).
    //   row5 col 1020+k -> (5<<13) | ((1020+k)<<1) = 0xA000 | (0x7F8 + 2k) = 0xA7F8 + 2k
    //   row6 col 0+k     -> (6<<13) | (k<<1)        = 0xC000 + 2k
    // rows 5 & 6 differ in {row[12],row[3:0]} (00101 / 00110), so the chip model's
    // 17-bit storage key keeps them separate.
    for (w=0; w<4; w=w+1) wr(27'h00_A7F8 + (w<<1), 16'h5000 + w[15:0]); // row5 cols1020..1023
    for (w=0; w<4; w=w+1) wr(27'h00_C000 + (w<<1), 16'h6000 + w[15:0]); // row6 cols0..3
    rd_line(27'h00_A7F8, 2);
    if (beat[0] !== 64'h5003_5002_5001_5000) begin errors=errors+1; $display("wrap beat0 bad: %h", beat[0]); end
    if (beat[1] !== 64'h6003_6002_6001_6000) begin errors=errors+1; $display("wrap beat1 bad: %h", beat[1]); end
```

- [ ] **Step 2: Run tb_sdram_psx — full green**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv && vvp tb_sdram_psx.vvp
```
Expected: `errors=0`, `refresh_seen=N` (N≥1), no `PROTO`/`wrap`/`s4` failures.

- [ ] **Step 3: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_psx.sv fpga/sim/sdram_chip_model.sv fpga/sim/tb_sdram_psx.sv
git commit -m "feat(#31): AS4C32M16 64MB geometry (10-bit column) in sdram_psx

Extend the column-low map from 9-bit column (32MB) to 10-bit column (64MB):
col=addr[10:1], bank=addr[12:11], row=addr[25:13]; page-wrap boundary 512->1024.
Sim chip model widened to a 17-bit de-aliased key incl. row[12]. New tb_sdram_psx
scenario round-trips past the 32MB boundary (addr[25]); the old map aliases it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Run the full SDRAM sim suite and fix any map-dependent fallout

**Files:**
- Verify (modify only if red): `fpga/sim/tb_sdram_ctrl.sv`, `fpga/sim/tb_sdram_src_arb.sv`, `fpga/sim/tb_sdram_stage.sv`, `fpga/sim/tb_sdram_sweep.sv`, `fpga/sim/tb_blitter_system.sv`

- [ ] **Step 1: Run every sim that instantiates `sdram_psx` / `sdram_chip_model`**

Run each (from `fpga/sim/`); each must end `errors=0` with no `PROTO`/`DEADLOCK`:
```bash
cd fpga/sim
for tb in tb_sdram_ctrl tb_sdram_src_arb tb_sdram_stage tb_sdram_sweep; do
  echo "== $tb =="
  iverilog -g2012 -o $tb.vvp $tb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv ../rtl/sdram_src_arb.sv 2>/dev/null \
    || iverilog -g2012 -o $tb.vvp $tb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv altddio_out_stub.sv
  vvp $tb.vvp 2>&1 | tail -5
done
```
(Some tbs need extra sources — `tb_sdram_src_arb`/`tb_sdram_stage` pull in `../rtl/sdram_src_arb.sv`; the `||` fallback covers tbs that don't. If a tb needs other files, add them — check the tb's top-of-file comment for its source list.)

- [ ] **Step 2: Diagnose and fix fallout**

For any tb that prints `errors>0`, the cause is almost always one of:
- Hard-coded address→row/col decode assuming the old map (e.g. expecting `addr 0x1000` → a specific row/bank). Recompute the expected row/bank/col under `col=addr[10:1]`, `bank=addr[12:11]`, `row=addr[25:13]`.
- A page-wrap test pinned to the 512-col boundary — move it to 1024 (as in Task 4).
- Touched rows that now alias in the model's `{row[12],row[3:0]}` key — pick rows distinct in those bits.

Fix the **test expectations / addresses**, not the controller (the controller is now correct per Task 4). Keep edits minimal and commented.

- [ ] **Step 3: Re-run the full suite to confirm green**

Re-run the Step 1 loop plus `tb_blitter_system` (it composites through the source path):
```bash
cd fpga/sim
iverilog -g2012 -o tb_blitter_system.vvp tb_blitter_system.sv ../rtl/*.sv sdram_chip_model.sv altddio_out_stub.sv 2>&1 | tail -3
vvp tb_blitter_system.vvp 2>&1 | tail -5
```
Expected: every sim `errors=0`. (If `tb_blitter_system`'s source list differs, follow the file's header comment for the exact `iverilog` arguments — do not guess at `../rtl/*.sv` if it causes duplicate-module errors; list the needed RTL explicitly.)

- [ ] **Step 4: Commit any fallout fixes**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/sim/
git commit -m "test(#31): update SDRAM sims for the 64MB 10-bit-column map"
```
(If no fallout, skip this commit.)

---

## Task 6: RBF build + timing closure (gated) and on-device analog gate

**Files:** none (CI + hardware)

- [ ] **Step 1: Trigger the RBF build (CI) on the branch**

Push the branch and let the FPGA CI build the RBF. Confirm Quartus **timing closes** — pay attention to the SDRAM address-decode path (`addr → SDRAM_A`), which now feeds one more column bit. If worst-slack regresses below the project's prior margin, pipeline the column slice or revisit; do not ship a negative-slack RBF (memory: RBF builds even with negative slack — check the report, don't trust "build succeeded").

- [ ] **Step 2: On-device analog gate (USER-GATED) — defer/batch with #32**

The 64MB map alone changes only the address bits the controller drives; nothing reads SDRAM source data until #32 wires the SDRAM-offset addressing and #33 stages real pixels. So a standalone on-device run of THIS RBF only proves "analog still clean with the new controller compiled in" (a regression guard), not end-to-end rendering. To avoid an extra analog-gate RBF spin, **batch the on-device validation with #32** (when the source path actually exercises SDRAM reads) unless the user wants an isolated analog check now. Either way: VISUAL validation is mandatory — load the core, confirm the game image + OSD are both stable and the frame counter advances (`busybox devmem 0x3A000000`); counters lie about analog.

> This task's checkboxes stay open until the RBF + analog gate are actually run; the sim-level work (Tasks 1-5) is independently complete and committed.

- [ ] **Step 3: SDRAM signal-integrity checklist (jtframe physical findings)**

If the 64MB RBF mis-loads or shows SDRAM read corruption on the board (distinct from the f2h scanout-contention bug — this is *physical*, module-dependent), work this checklist before touching the map. Source: jtframe `doc/sdram.md` (jotego/jtcores), captured in `docs/reference/jtframe-sdram-scanout.md` (on master). The existing controller was HW-validated at 32MB in #19, so the `.qsf/.sdc` is presumably already sane — but the 64MB map drives more of the address bus, so re-confirm:

  - **Slowest slew rate on all SDRAM pins.** Fast slew drove VDD ripple >4V and A-line undershoot to −0.9V; `Contra` failed to load on 6/7 modules at fast slew, 0/7 at slow. Check `set_instance_assignment -name CURRENT_STRENGTH_NEW "...SLOW"` / slew settings on `SDRAM_*` in `fpga/Solarus.qsf`.
  - **DQ at CAS, not RAS** for writes (the staging burst-write path) — fewer module failures.
  - **Clock-shift window** is ~2.5–8.75ns per module; the MiSTer 128MB (2× AS4C32M16) batch has severe VDD ripple. If reads are marginal, adjust the SDRAM clock phase (`JTFRAME_SHIFT`-equivalent in our PLL/`.sdc`), or add `JTFRAME_SDRAM_REPACK`-style extra DQ latch (pad flip-flop, +1 cycle latency) to cure `SDRAM_DQ` setup violations.
  - **DQM/A-line short costs efficiency** (the MiSTer 128MB wiring shorts A-lines to DQM): budget ~53% efficiency @96MHz, ~72% <64MHz — not a correctness issue, just throughput when sizing the boot-stage time (#34).

These are physical/timing levers for the on-device gate, NOT map changes — only reach for them if the board shows SDRAM load/read trouble.

---

## Self-Review notes (author)

- **Spec coverage:** the spec's "SDRAM controller reconfig" section (10-bit column, col=addr[10:1]/bank=addr[12:11]/row=addr[25:13], 512→1024 page-wrap, AS4C32M16 64MB) maps to Tasks 1-4; the spec's "RBF builds; timing closes with margin" + on-device analog AC map to Task 6; the suite-green AC maps to Task 5.
- **Out of scope (correctly deferred):** SDRAM-offset source addressing (#32), engine boot pre-stage (#33), end-to-end no-starvation validation (#34).
- **Type/width consistency:** `col_base` is 10-bit and `next_col_full` is 11-bit (Task 3) everywhere they appear; the model's `key` is 17-bit with `store[0:131071]` and `wr_col` is 10-bit (Task 2); `SDRAM_A` stays 13-bit and every column drive packs to exactly 13 bits.
