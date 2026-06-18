# Pipelined Compositor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blitter's multi-cycle per-pixel FSM with a streaming, issue-interval-1 compositor fed/drained by bursts from on-chip buffers, selectable alongside the proven FSM, bit-exact to the existing `blitter_ref` golden.

**Architecture:** A second datapath inside `blitter_top` (chosen by a new `C_PIPE` control-word bit) replaces only the inner pixel loop: a span setup unit emits row-spans → a fresh burst master fills an on-chip source line buffer → an issue-interval-1 `comp_mixer` composites one pixel per clock into a full-width on-chip dest band → the band is burst-flushed to the framebuffer. The front-end (ring walk, handshake, scanout, double-buffer flip) is reused verbatim.

**Tech Stack:** SystemVerilog (`-g2012`), Icarus Verilog + `vvp` for sim, `fpga/sim/run_sims.sh` as the test runner, Quartus Prime 17.0.x for synthesis/STA, the C `blitter_ref` model as golden.

## Global Constraints

- **Bit-exact to golden:** semantics must match `patches/mister/blitter/blitter_ref.h` / `blitter_ref.c` exactly. No new pixel semantics in this plan (rects only).
- **Frozen contract:** `blt_cmd_t`, opcodes, blend modes, formats, flags, the 32-byte ring entry, and the `submit_seq`/`done_seq` handshake do not change.
- **Selector default OFF:** the new path is gated by control-block word `C_PIPE` (next free offset after `C_SRCSEL=7`, i.e. **`C_PIPE=8`**). Host writes `0` (legacy FSM) until HW-proven. `C_PIPE=0` behaviour must be byte-identical to today.
- **Pixel model:** 320×240 RGB565 framebuffer; sources RGB565 or ARGB4444. Channel widths R5/G6/B5.
- **Divide-free /255 blend (verbatim, verified):** for channel total `t = src_c*a + dst_c*(255-a)`, the reduced channel is `div(t) = (t + 128 + ((t+128)>>8)) >> 8`. `a` is 8-bit (const = `c_alpha`; PALPHA = `{A4,A4}`).
- **Arbiter is a guest:** the video reader keeps default ownership of the f2h DDR port; the blitter only fills genuine reader-idle gaps. No per-pixel DDR beats — only burst fills/flushes of on-chip buffers.
- **Module = file name:** every `*.sv` is found by `run_sims.sh` via `-y ../rtl` with module name == file name. New RTL goes in `fpga/rtl/`, new testbenches in `fpga/sim/`.
- **Test runner:** `cd fpga/sim && ./run_sims.sh <tb_name>` builds + runs one testbench; a pass prints `RESULT: PASS` with no `FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|TIMEOUT`.
- **License header:** new files start with `// <file> — <one-line purpose>` and `// Copyright (C) 2026 — GPL-3.0` (match existing `fpga/rtl` files).
- **Commit after each task.** End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File structure

| File | Responsibility | Phase |
|---|---|---|
| `fpga/rtl/comp_defs.vh` | shared params for the pipeline (BAND_H, blend-mode/format mirrors of `blitter_defs`) + the reference blend function macro | 1 |
| `fpga/rtl/comp_mixer.sv` | issue-interval-1 blend pipeline: (src,dst,params)→composited pixel, 1/clock | 1 |
| `fpga/rtl/comp_src_linebuf.sv` | on-chip source line buffer + in-order flip-aware texel serve | 1 |
| `fpga/rtl/comp_dest_band.sv` | full-width (320px × BAND_H) on-chip dest band: RMW serve + write-coalesce + flush descriptors | 1 |
| `fpga/rtl/comp_span_setup.sv` | per-blit clip/flip → row-span descriptors | 1 |
| `fpga/rtl/comp_pipeline.sv` | wires the four units into one datapath; exposes a blit-request / done handshake | 1 |
| `fpga/rtl/blitter_top.sv` (modify) | decode `C_PIPE`; route blit execution to `comp_pipeline` when set, legacy FSM when clear | 1 |
| `fpga/rtl/comp_burst.sv` | fresh aligned sequential burst read/write master | 2 |
| `fpga/rtl/ddr_blitter_arb.sv` (modify) | hold blitter grant across a whole burst | 2 |
| `fpga/sim/tb_comp_mixer.sv` | mixer equivalence vs the reference blend function | 1 |
| `fpga/sim/tb_comp_src_linebuf.sv` | line-buffer ordering/flip test | 1 |
| `fpga/sim/tb_comp_dest_band.sv` | band RMW/coalesce/flush test | 1 |
| `fpga/sim/tb_comp_span_setup.sv` | clip/flip span-decomposition test | 1 |
| `fpga/sim/tb_profile.sv` (modify) | add `C_PIPE=1` cyc/px measurement | 1 |
| `fpga/sim/tb_comp_burst.sv` | burst master vs burst-capable behavioural DDR | 2 |
| `fpga/sim/tb_arb_blitter_burst.sv` | reader-never-starves under blitter bursts | 2 |

Existing `tb_blitter_copy/blend/coalesce/palpha/system` are reused unchanged as the integration oracle (Task 6): they must pass identically with `C_PIPE=1`.

---

## Phase 1 — pipelined compositor (behavioural DDR model)

### Task 1: `comp_mixer` — issue-interval-1 blend pipeline

**Files:**
- Create: `fpga/rtl/comp_defs.vh`
- Create: `fpga/rtl/comp_mixer.sv`
- Test: `fpga/sim/tb_comp_mixer.sv`

**Interfaces:**
- Produces: `comp_mixer` with ports
  - in: `clk`, `in_valid`, `in_src[15:0]`, `in_dst[15:0]`, `in_mode[7:0]` (0 COPY,1 COLORKEY,2 CONST_ALPHA,3 PALPHA), `in_fmt[7:0]` (0 RGB565,1 ARGB4444), `in_key[15:0]`, `in_alpha[7:0]`
  - out: `out_valid`, `out_pix[15:0]`, `out_we` (0 = skip-write this pixel)
  - Fixed latency `LAT` (a localparam, expected 3); `out_valid` is `in_valid` delayed `LAT`. One pixel may enter every clock (issue interval 1).

- [ ] **Step 1: Write `comp_defs.vh` with the reference blend function**

```systemverilog
// comp_defs.vh — shared params + golden blend function for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
`ifndef COMP_DEFS_VH
`define COMP_DEFS_VH
`define COMP_BAND_H 16                 // dest band height (rows); BRAM/throughput knob (Task 3)
// modes / formats mirror blitter_ref.h
`define COMP_COPY 8'd0
`define COMP_KEY  8'd1
`define COMP_CA   8'd2
`define COMP_PA   8'd3
`define COMP_RGB565   8'd0
`define COMP_ARGB4444 8'd1
// divide-free /255 reduction of a channel total t (Global Constraints)
`define COMP_DIV255(t) ((( (t) + 17'd128 + (((t)+17'd128) >> 8) ) >> 8))
`endif
```

- [ ] **Step 2: Write the failing test `tb_comp_mixer.sv`**

```systemverilog
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
module tb_comp_mixer;
  reg clk=0; always #5 clk=~clk;
  reg in_valid=0; reg [15:0] in_src, in_dst, in_key; reg [7:0] in_mode, in_fmt, in_alpha;
  wire out_valid, out_we; wire [15:0] out_pix;
  comp_mixer dut(.clk(clk), .in_valid(in_valid), .in_src(in_src), .in_dst(in_dst),
    .in_mode(in_mode), .in_fmt(in_fmt), .in_key(in_key), .in_alpha(in_alpha),
    .out_valid(out_valid), .out_pix(out_pix), .out_we(out_we));

  // GOLDEN: pure-function reference per the frozen semantics.
  function [16:0] gref; // {we, pix16}
    input [15:0] s, d, key; input [7:0] mode, fmt, alpha;
    reg [4:0] sr,dr; reg [5:0] sg,dg; reg [4:0] sb,db; reg [7:0] a; reg [3:0] a4;
    reg [16:0] tr,tg,tb_;
    begin
      sr=s[15:11]; sg=s[10:5]; sb=s[4:0]; dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      a4 = s[15:12];
      if (mode==`COMP_COPY)      gref = {1'b1, s};
      else if (mode==`COMP_KEY)  gref = (s==key) ? 17'h0_0000 : {1'b1, s};
      else begin // CONST_ALPHA or PALPHA
        a = (mode==`COMP_PA) ? {a4,a4} : alpha;
        if (mode==`COMP_PA && a4==4'd0) gref = 17'h0_0000;       // fully transparent → skip
        else begin
          tr = sr*a + dr*(8'd255-a); tg = sg*a + dg*(8'd255-a); tb_ = sb*a + db*(8'd255-a);
          gref = {1'b1, `COMP_DIV255(tr)[4:0], `COMP_DIV255(tg)[5:0], `COMP_DIV255(tb_)[4:0]};
        end
      end
    end
  endfunction

  integer i; integer errs=0; reg [16:0] g; reg [16:0] q [0:7]; integer qh=0,qt=0; // pipeline shadow
  // push golden into a delay queue so we compare against the LAT-delayed output
  task drive; input [15:0] s,d,key; input [7:0] mode,fmt,alpha; begin
    in_valid<=1; in_src<=s; in_dst<=d; in_key<=key; in_mode<=mode; in_fmt<=fmt; in_alpha<=alpha;
    q[qt]<=gref(s,d,key,mode,fmt,alpha); qt<=(qt+1)%8;
  end endtask

  initial begin
    @(negedge clk);
    // back-to-back stream across all modes proves issue-interval 1 + correctness
    drive(16'hF800,16'h001F,16'h07E0,`COMP_COPY,`COMP_RGB565,8'd0);  @(negedge clk);
    drive(16'h07E0,16'h0000,16'h07E0,`COMP_KEY ,`COMP_RGB565,8'd0);  @(negedge clk); // keyed → skip
    drive(16'hFFFF,16'h0000,16'h0000,`COMP_CA  ,`COMP_RGB565,8'd128);@(negedge clk);
    drive(16'h8ABC,16'h1234,16'h0000,`COMP_PA  ,`COMP_ARGB4444,8'd0);@(negedge clk);
    in_valid<=0;
    // drain + compare each emitted pixel to the queued golden
    for (i=0;i<8;i=i+1) begin
      @(negedge clk);
      if (out_valid) begin
        g = q[qh]; qh=(qh+1)%8;
        if (out_we !== g[16] || (g[16] && out_pix !== g[15:0])) begin
          errs=errs+1; $display("MISMATCH i=%0d we=%b/%b pix=%h/%h", i, out_we, g[16], out_pix, g[15:0]);
        end
      end
    end
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d", errs);
    $finish;
  end
endmodule
```

- [ ] **Step 3: Run the test, verify it fails (no module yet)**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_mixer`
Expected: `BUILD!` (comp_mixer not found) — counts as fail.

- [ ] **Step 4: Implement `comp_mixer.sv` as a fixed-latency pipeline**

Structure: stage A latches inputs + computes `a`, channel splits, key/transparent compare; stage B computes the three channel totals `t` (3 small multiplies, parallel); stage C applies `COMP_DIV255`, packs RGB565, resolves `out_we`. Each stage is registered; `out_valid` is `in_valid` shifted through `LAT=3` registers. COPY/KEY bypass the blend into the pack stage. Use `comp_defs.vh`'s `COMP_DIV255`. Channel multiplies are `[4:0]*[7:0]`→fits 13 bits; totals fit 17 bits.

- [ ] **Step 5: Run the test, verify it passes**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_mixer`
Expected: `RESULT: PASS`

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/comp_defs.vh fpga/rtl/comp_mixer.sv fpga/sim/tb_comp_mixer.sv
git commit -m "feat(comp): issue-interval-1 blend mixer + golden equivalence test"
```

---

### Task 2: `comp_src_linebuf` — on-chip source line buffer

**Files:**
- Create: `fpga/rtl/comp_src_linebuf.sv`
- Test: `fpga/sim/tb_comp_src_linebuf.sv`

**Interfaces:**
- Produces: `comp_src_linebuf` with
  - fill side: `fill_we`, `fill_qw[63:0]`, `fill_idx` (qword index within the row) — written by the burst master / behavioural model
  - serve side: `serve_req`, `serve_x[15:0]` (source-local pixel x), `serve_hflip`, `serve_w[15:0]` → `serve_valid`, `serve_pix[15:0]` next cycle
  - one row of up to 1024 px (2048 B) in BRAM; serve reads one 16-bit texel given x, applying horizontal flip (`x' = w-1-x`).

- [ ] **Step 1: Write the failing test `tb_comp_src_linebuf.sv`**

```systemverilog
`timescale 1ns/1ps
`default_nettype none
module tb_comp_src_linebuf;
  reg clk=0; always #5 clk=~clk;
  reg fill_we=0; reg [63:0] fill_qw; reg [9:0] fill_idx;
  reg serve_req=0; reg [15:0] serve_x, serve_w; reg serve_hflip;
  wire serve_valid; wire [15:0] serve_pix;
  comp_src_linebuf dut(.clk(clk), .fill_we(fill_we), .fill_qw(fill_qw), .fill_idx(fill_idx),
    .serve_req(serve_req), .serve_x(serve_x), .serve_w(serve_w), .serve_hflip(serve_hflip),
    .serve_valid(serve_valid), .serve_pix(serve_pix));
  integer i, errs=0;
  initial begin
    @(negedge clk);
    // fill 8 px (px value = 0x100+x), packed 4/qword
    for (i=0;i<2;i=i+1) begin
      fill_we<=1; fill_idx<=i[9:0];
      fill_qw<={16'h0103+(i*4),16'h0102+(i*4),16'h0101+(i*4),16'h0100+(i*4)};
      @(negedge clk);
    end
    fill_we<=0;
    // serve x=0..7 unflipped
    for (i=0;i<8;i=i+1) begin
      serve_req<=1; serve_x<=i[15:0]; serve_w<=16'd8; serve_hflip<=0; @(negedge clk);
      @(negedge clk);
      if (serve_pix !== (16'h0100+i)) begin errs=errs+1; $display("UNFLIP x=%0d got %h",i,serve_pix); end
    end
    // serve flipped: x=0 should read px w-1=7
    serve_req<=1; serve_x<=16'd0; serve_w<=16'd8; serve_hflip<=1; @(negedge clk); @(negedge clk);
    if (serve_pix !== 16'h0107) begin errs=errs+1; $display("FLIP got %h",serve_pix); end
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run, verify fail**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_src_linebuf`
Expected: `BUILD!`

- [ ] **Step 3: Implement `comp_src_linebuf.sv`**

BRAM `reg [15:0] line [0:1023]`. On `fill_we`, write the 4 packed pixels at `fill_idx*4 .. +3`. On `serve_req`, compute `xa = serve_hflip ? (serve_w-1-serve_x) : serve_x`, register `serve_pix <= line[xa]`, `serve_valid <= serve_req` (1-cycle read latency). Vertical flip is handled upstream by row selection (Task 4), not here.

- [ ] **Step 4: Run, verify pass**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_src_linebuf`
Expected: `RESULT: PASS`

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_src_linebuf.sv fpga/sim/tb_comp_src_linebuf.sv
git commit -m "feat(comp): source line buffer with flip-aware texel serve"
```

---

### Task 3: `comp_dest_band` — full-width on-chip dest band

**Files:**
- Create: `fpga/rtl/comp_dest_band.sv`
- Test: `fpga/sim/tb_comp_dest_band.sv`

**Interfaces:**
- Produces: `comp_dest_band` with
  - load side: `ld_we`, `ld_qw[63:0]`, `ld_idx` (qword index within the band) — preload current DDR contents for blend RMW
  - composite side: `cw_we` (write-enable from mixer `out_we`), `cw_x[15:0]`, `cw_row[3:0]` (row within band), `cw_pix[15:0]`; and `rd_x`,`rd_row` → `rd_dst[15:0]` (RMW dst read, 1-cyc latency)
  - flush side: `flush_req`, then streams `fl_valid`, `fl_qw[63:0]`, `fl_be[7:0]`, `fl_idx` for every dirty qword; `flush_done`
  - band = 320 px × `COMP_BAND_H` rows = `80*COMP_BAND_H` qwords BRAM; per-qword dirty + accumulated byte-enable.

- [ ] **Step 1: Write the failing test `tb_comp_dest_band.sv`** (composite two pixels into row 0, flush, assert only their lanes are dirty with correct values)

```systemverilog
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
module tb_comp_dest_band;
  reg clk=0; always #5 clk=~clk;
  reg ld_we=0; reg [63:0] ld_qw; reg [12:0] ld_idx;
  reg cw_we=0; reg [15:0] cw_x, cw_pix; reg [3:0] cw_row;
  reg flush_req=0; wire fl_valid, flush_done; wire [63:0] fl_qw; wire [7:0] fl_be; wire [12:0] fl_idx;
  reg [15:0] rd_x; reg [3:0] rd_row; wire [15:0] rd_dst;
  comp_dest_band dut(.clk(clk), .ld_we(ld_we), .ld_qw(ld_qw), .ld_idx(ld_idx),
    .cw_we(cw_we), .cw_x(cw_x), .cw_row(cw_row), .cw_pix(cw_pix),
    .rd_x(rd_x), .rd_row(rd_row), .rd_dst(rd_dst),
    .flush_req(flush_req), .fl_valid(fl_valid), .fl_qw(fl_qw), .fl_be(fl_be), .fl_idx(fl_idx),
    .flush_done(flush_done));
  integer errs=0; reg seen=0;
  initial begin
    @(negedge clk);
    // composite px @ x=1,row0 = 0xAAAA and x=2,row0=0xBBBB (same qword 0, lanes 1 and 2)
    cw_we<=1; cw_x<=16'd1; cw_row<=4'd0; cw_pix<=16'hAAAA; @(negedge clk);
    cw_x<=16'd2; cw_pix<=16'hBBBB; @(negedge clk);
    cw_we<=0; @(negedge clk);
    flush_req<=1; @(negedge clk); flush_req<=0;
    repeat (20) begin
      @(negedge clk);
      if (fl_valid && fl_idx==13'd0) begin
        seen=1;
        if (fl_be !== 8'b0011_1100) begin errs=errs+1; $display("BE got %b",fl_be); end
        if (fl_qw[31:16] !== 16'hAAAA || fl_qw[47:32] !== 16'hBBBB) begin errs=errs+1; $display("QW %h",fl_qw); end
      end
      if (flush_done) ;
    end
    if (!seen) errs=errs+1;
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run, verify fail**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_dest_band`
Expected: `BUILD!`

- [ ] **Step 3: Implement `comp_dest_band.sv`**

BRAM `data[0:80*COMP_BAND_H-1]` (64-bit), `be[...]` (8-bit), `dirty[...]`. `cw`: `qw = cw_row*80 + (cw_x>>2)`, `lane = cw_x[1:0]`; on `cw_we` merge `cw_pix` into that 16-bit lane, OR `2'b11<<(lane*2)` into `be[qw]`, set `dirty[qw]`. `rd`: combinational `rd_qw = rd_row*80+(rd_x>>2)`, registered `rd_dst <= data[rd_qw][rd_x[1:0]*16 +:16]`. `ld`: write preload qword + clear dirty/be (holds real DDR contents so blend RMW reads are valid). `flush`: walk all qwords, emit those with `dirty`, clearing dirty as it goes; assert `flush_done` at the end.

- [ ] **Step 4: Run, verify pass**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_dest_band`
Expected: `RESULT: PASS`

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_dest_band.sv fpga/sim/tb_comp_dest_band.sv
git commit -m "feat(comp): full-width dest band with RMW serve, coalesce, flush"
```

---

### Task 4: `comp_span_setup` — clip/flip → row spans

**Files:**
- Create: `fpga/rtl/comp_span_setup.sv`
- Test: `fpga/sim/tb_comp_span_setup.sv`

**Interfaces:**
- Produces: `comp_span_setup` with
  - in (start): `start`, decoded fields `c_dst_x[15:0]`(signed), `c_dst_y[15:0]`(signed), `c_w[15:0]`, `c_h[15:0]`, `c_flags[7:0]`
  - out (per row): `span_valid`, `span_dst_x[15:0]` (clipped, 0..319), `span_dst_y[15:0]` (0..239), `span_len[15:0]`, `span_src_x0[15:0]`, `span_src_y[15:0]` (flip-resolved source coords), `span_last`; `done`
  - Reproduces the existing `clip_x0/x1/y0/y1` math (`blitter_top.sv` `S_SETUP`) and the flip-aware `src_x0s/src_y0s` (`blitter_top.sv:429-430`). Fully-offscreen → `done` with zero spans.

- [ ] **Step 1: Write the failing test `tb_comp_span_setup.sv`** — three cases: (a) on-screen 8×4 at (20,10) → 4 spans len 8, src_x0=0; (b) negative origin (−3,5) w=10 → clipped dst_x=0,len=7,src_x0=3; (c) fully offscreen (400,10) → 0 spans, `done`. Assert span count/first-span fields and `done`.

```systemverilog
`timescale 1ns/1ps
`default_nettype none
module tb_comp_span_setup;
  reg clk=0; always #5 clk=~clk;
  reg start=0; reg signed [15:0] c_dst_x, c_dst_y; reg [15:0] c_w,c_h; reg [7:0] c_flags;
  wire span_valid, span_last, done; wire [15:0] span_dst_x, span_dst_y, span_len, span_src_x0, span_src_y;
  comp_span_setup dut(.clk(clk), .start(start), .c_dst_x(c_dst_x), .c_dst_y(c_dst_y),
    .c_w(c_w), .c_h(c_h), .c_flags(c_flags),
    .span_valid(span_valid), .span_dst_x(span_dst_x), .span_dst_y(span_dst_y),
    .span_len(span_len), .span_src_x0(span_src_x0), .span_src_y(span_src_y),
    .span_last(span_last), .done(done));
  integer nspan, errs=0;
  task run_case; input signed [15:0] dx,dy; input [15:0] w,h; input [7:0] fl;
    begin
      c_dst_x<=dx; c_dst_y<=dy; c_w<=w; c_h<=h; c_flags<=fl; nspan=0;
      @(negedge clk); start<=1; @(negedge clk); start<=0;
      while (!done) begin @(negedge clk); if (span_valid) nspan=nspan+1; end
    end
  endtask
  initial begin
    @(negedge clk);
    run_case(16'sd20,16'sd10,16'd8,16'd4,8'd0); if (nspan!==4) begin errs=errs+1; $display("A nspan=%0d",nspan); end
    run_case(-16'sd3,16'sd5,16'd10,16'd1,8'd0);
      if (nspan!==1 || span_dst_x!==16'd0 || span_len!==16'd7 || span_src_x0!==16'd3)
        begin errs=errs+1; $display("B nspan=%0d dx=%0d len=%0d sx0=%0d",nspan,span_dst_x,span_len,span_src_x0); end
    run_case(16'sd400,16'sd10,16'd8,16'd4,8'd0); if (nspan!==0) begin errs=errs+1; $display("C nspan=%0d",nspan); end
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run, verify fail**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_span_setup`
Expected: `BUILD!`

- [ ] **Step 3: Implement `comp_span_setup.sv`** — port the clip arithmetic and flip-resolved source-start from `blitter_top.sv` `S_SETUP` (lines ~392–436), iterating `dy` over `clip_y0..clip_y1` emitting one span/row; per row set `span_src_y` with VFLIP per `blitter_top.sv:430`. Empty (offscreen) → assert `done` immediately.

- [ ] **Step 4: Run, verify pass**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_span_setup`
Expected: `RESULT: PASS`

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_span_setup.sv fpga/sim/tb_comp_span_setup.sv
git commit -m "feat(comp): span setup (clip + flip-aware source) reproducing FSM math"
```

---

### Task 5: `comp_pipeline` + `C_PIPE` integration

**Files:**
- Create: `fpga/rtl/comp_pipeline.sv`
- Modify: `fpga/rtl/blitter_defs.vh` (add `C_PIPE`), `fpga/rtl/blitter_top.sv` (decode + route)
- Test: reuse `fpga/sim/tb_blitter_copy.sv`, `tb_blitter_blend.sv`, `tb_blitter_coalesce.sv`, `tb_blitter_palpha.sv`, `tb_blitter_system.sv`

**Interfaces:**
- Consumes: `comp_mixer`, `comp_src_linebuf`, `comp_dest_band`, `comp_span_setup` (their port lists above). In Phase 1, `comp_pipeline` fills source rows and loads the dest band via **single-beat** reads on the existing `mem_*` master (same behavioural model as the FSM) so it is verifiable before the burst engine exists; Phase 2 swaps those for `comp_burst`.
- Produces: `comp_pipeline(clk, rst, blit_start, <decoded c_* fields>, target_base, mem_* master share, blit_done)` driving the framebuffer identically to the FSM.

- [ ] **Step 1: Add `C_PIPE` to `blitter_defs.vh`**

```systemverilog
// Pipelined-compositor select (Spec A). bit0=1 -> route blit execution through
// comp_pipeline; 0 (DEFAULT) -> legacy per-pixel FSM. Next free offset after C_SRCSEL=7.
`define C_PIPE  29'd8
```

- [ ] **Step 2: Write a failing integration check** — extend `tb_blitter_copy.sv` to set the control word `mem[BLTCTRL+C_PIPE]=1` and assert the same four-corner result. Run it; it fails because `blitter_top` ignores `C_PIPE` and the pipeline isn't wired.

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_copy`
Expected: FAIL (pipeline path absent / corners wrong).

- [ ] **Step 3: Implement `comp_pipeline.sv` and wire it in `blitter_top.sv`** — in `S_GOT_SRCSEL`/decode add a `pipe_en` reg read from `C_PIPE`; in `S_SETUP`, when `pipe_en` and opcode is FILL/BLIT, hand the decoded `c_*` to `comp_pipeline` via `blit_start` and wait for `blit_done` instead of entering `S_BSETUP`. `comp_pipeline` connects span_setup → (per span) linebuf fill via `mem_*` reads → mixer (dst from `comp_dest_band.rd_dst`) → `cw_*` into the band; on `span_last` for the band's rows, `flush_req` → write dirty qwords via `mem_*`. Arbitrate the shared `mem_*` master between FSM-idle and pipeline with a simple owner mux (pipeline owns it only while `pipe_en` blit runs).

- [ ] **Step 4: Run the full blitter equivalence suite with the pipeline path**

Run:
```bash
cd fpga/sim
for t in tb_blitter_copy tb_blitter_blend tb_blitter_coalesce tb_blitter_palpha; do ./run_sims.sh $t; done
./run_sims.sh tb_blitter_system
```
Expected: each prints `RESULT: PASS` (system tb is non-gating but must not print a FAIL marker). Also re-run with `C_PIPE=0` to confirm the legacy path is unchanged.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv fpga/rtl/blitter_defs.vh fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_copy.sv
git commit -m "feat(comp): wire pipelined datapath behind C_PIPE; passes blitter equivalence suite"
```

---

### Task 6: cyc/px gate (G1)

**Files:**
- Modify: `fpga/sim/tb_profile.sv`

**Interfaces:**
- Consumes: the `C_PIPE` control word; the existing profiler's cycle/DDR-wait counters.

- [ ] **Step 1: Add a `C_PIPE=1` run to `tb_profile.sv`** — duplicate each blend-mode single-blit run with `mem[...C_PIPE]=1`, print `cyc/px` for legacy vs pipeline side by side (the tb already derives cyc/px).

- [ ] **Step 2: Run the profiler**

Run: `cd fpga/sim && ./run_sims.sh tb_profile` (it is SKIP in the gating suite; run directly)
Expected output line per mode showing pipeline **cyc/px ≈ 1–2** vs legacy ≈ 7–10. (This is the G1 gate — record the numbers in the commit message.)

- [ ] **Step 3: Commit**

```bash
git add fpga/sim/tb_profile.sv
git commit -m "test(comp): profile pipeline cyc/px vs FSM (G1: ~1-2 vs ~7-10)"
```

---

## Phase 2 — fresh burst engine + arbiter / timing closure

### Task 7: `comp_burst` — fresh aligned burst master

**Files:**
- Create: `fpga/rtl/comp_burst.sv`
- Test: `fpga/sim/tb_comp_burst.sv`

**Interfaces:**
- Produces: `comp_burst` with a request side (`req_rd`/`req_wr`, `req_addr[28:0]`, `req_len[7:0]` qwords, `req_wdata` stream + `req_wbe`) and a DDR-master side (`burstcnt`, `addr`, `rd`, `we`, `din`, `be`, `busy`, `dout`, `dout_ready`) matching `ddr_blitter_arb`'s blitter port. Reads return a `beat_valid`/`beat_data` stream; writes consume a `beat_data`/`beat_be` stream. Address generation: one sequential burst of `req_len` qwords from `req_addr`.

- [ ] **Step 1: Write failing `tb_comp_burst.sv`** — a burst-capable behavioural DDR (returns `req_len` sequential beats after a latency, honours `busy`) — request an 80-qword read (one 320px row), assert all 80 beats arrive in order and address increments correctly; then an 80-qword write with byte-enables, assert memory contents.

- [ ] **Step 2: Run, verify fail**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_burst`
Expected: `BUILD!`

- [ ] **Step 3: Implement `comp_burst.sv`** — a small FSM: latch `req_addr/req_len`, drive `burstcnt=req_len`, hold `rd`/`we` until accepted (`!busy`), stream beats, assert `done`. Keep burst-control logic shallow (off the mixer's critical path — Global Constraint).

- [ ] **Step 4: Run, verify pass**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_burst`
Expected: `RESULT: PASS`

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_burst.sv fpga/sim/tb_comp_burst.sv
git commit -m "feat(comp): fresh aligned sequential burst master"
```

---

### Task 8: arbiter burst-grant + burst path integration

**Files:**
- Modify: `fpga/rtl/ddr_blitter_arb.sv`, `fpga/rtl/comp_pipeline.sv`
- Test: Create `fpga/sim/tb_arb_blitter_burst.sv`; reuse the blitter equivalence suite + `tb_ddr_blitter_arb`

**Interfaces:**
- Consumes: `comp_burst` master side; the arbiter's existing reader-priority borrow protocol.
- Produces: arbiter holds the blitter grant for a full burst (generalising the reader's "hold grant until all beats returned").

- [ ] **Step 1: Write failing `tb_arb_blitter_burst.sv`** — drive continuous reader requests + a blitter burst; assert (a) reader is never denied a beat it asked for (no `STARV`), (b) the blitter burst completes. Print `RESULT: PASS`.

- [ ] **Step 2: Run, verify fail**

Run: `cd fpga/sim && ./run_sims.sh tb_arb_blitter_burst`
Expected: `BUILD!` or `STARV`/`FAIL`.

- [ ] **Step 3: Implement the burst grant in `ddr_blitter_arb.sv`** and swap `comp_pipeline`'s single-beat `mem_*` source-fill/band-flush for `comp_burst` requests. Reader keeps default ownership; blitter borrows for one whole burst in an idle gap then yields.

- [ ] **Step 4: Run arbiter + full equivalence suite**

Run:
```bash
cd fpga/sim
./run_sims.sh tb_arb_blitter_burst
./run_sims.sh tb_ddr_blitter_arb
for t in tb_blitter_copy tb_blitter_blend tb_blitter_coalesce tb_blitter_palpha; do ./run_sims.sh $t; done
```
Expected: all `RESULT: PASS` (equivalence still bit-exact through the burst path).

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/ddr_blitter_arb.sv fpga/rtl/comp_pipeline.sv fpga/sim/tb_arb_blitter_burst.sv
git commit -m "feat(comp): arbiter burst-grant + burst-fed pipeline; reader never starves"
```

---

### Task 9: synthesis, timing closure (G5) + HW handoff (G2)

**Files:**
- Modify: `fpga/files.qip` (add the new `comp_*.sv`), `fpga/Solarus.sdc` if a new constraint is needed.

**Interfaces:** none (build/gate task).

- [ ] **Step 1: Add the new RTL to the project**

Add `comp_defs.vh`, `comp_mixer.sv`, `comp_src_linebuf.sv`, `comp_dest_band.sv`, `comp_span_setup.sv`, `comp_pipeline.sv`, `comp_burst.sv` to `fpga/files.qip`.

- [ ] **Step 2: Build the RBF**

Run: `cd fpga && ./build_solarus.sh` (Quartus 17.0.x)
Expected: build completes; capture the fit (BRAM usage incl. dest band + line buffer) and STA.

- [ ] **Step 3: Check timing (G5)**

Inspect the STA report for the f2h clock domain. Expected: worst-case setup slack ≥ 0. If negative, add pipeline registers **only in `comp_mixer`** / shorten the band-flush address path (Global Constraint: protect the mixer, keep burst-control shallow); if BRAM over budget, reduce `COMP_BAND_H` in `comp_defs.vh`. Re-run Step 2.

- [ ] **Step 4: Commit the buildable core**

```bash
git add fpga/files.qip fpga/Solarus.sdc
git commit -m "build(comp): add pipelined compositor to project; STA slack >= 0 at f2h clock"
```

- [ ] **Step 5: HW validation handoff (G2 — needs the user's eyes)**

This step is **deferred to the user** (visual validation; counters can lie about render health — established 2026-06-14). Hand off with: flash the RBF, run the heavy overworld with `C_PIPE=1`, read `[blitter timing]` (expect fabric ≤ ~16.67 ms, ~60 fps, `escape=0`), and confirm the video is visually correct vs the `C_PIPE=0` legacy RBF. Do not make `C_PIPE=1` the default until this passes.

---

## Self-review

**Spec coverage:** §4 architecture → Tasks 1–5 (the five modules + integration); §5 Phase 1 mixer/buffers → Tasks 1–3; span/clip → Task 4; selector + equivalence → Task 5; G1 cyc/px → Task 6; §6 Phase 2 fresh burst + arbiter + timing → Tasks 7–9; §7 contract frozen / `C_PIPE=8` → Global Constraints + Task 5 Step 1; §8 verification (refmodel equivalence, tb_profile, arbiter starvation, HW) → Tasks 5/6/8/9; §9 risks (timing, BRAM, blend mismatch, starvation) → Tasks 6/8/9 mitigations; full-width band + fresh burst decisions → Tasks 3/7. No uncovered spec section.

**Placeholder scan:** no TBD/TODO; every test has concrete self-checking SV; RTL steps give port lists + the specific algorithm and the exact existing line references to port from (`blitter_top.sv:429-430`, `S_SETUP`). The blend math is given verbatim in `comp_defs.vh`.

**Type consistency:** module/port names are consistent across tasks — `comp_mixer(in_src,in_dst,in_mode,in_fmt,in_key,in_alpha → out_valid,out_pix,out_we)`, `comp_src_linebuf(fill_*/serve_*)`, `comp_dest_band(ld_*/cw_*/rd_*/fl_*)`, `comp_span_setup(span_*)`, `C_PIPE=8`, `COMP_BAND_H`, `COMP_DIV255`. `comp_pipeline` consumes exactly those. The mixer's `out_we` feeds `comp_dest_band.cw_we`; band `rd_dst` feeds mixer `in_dst` — consistent.

---

## Execution status (2026-06-18)

**Phase 1 (Tasks 1–5): COMPLETE and reviewed (Approved).** On branch `spec/pipelined-compositor`.
- T1 `comp_mixer` (issue-interval-1, LAT=3) · T2 `comp_src_linebuf` · T3 `comp_dest_band` ·
  T4 `comp_span_setup` · T5 `comp_pipeline` + `C_PIPE` routing.
- Verified: `tb_comp_pipeline` (incl. tall 2-chunk + painter), four C_PIPE=1 equivalence variants
  **bit-exact**, `tb_blitter_system_pipe` PHASE1; no regression to the legacy C_PIPE=0 path.
- Plan correction during execution: `C_PIPE` is **offset 7 bit 1** (in the C_SRCSEL word), NOT
  offset 8 — offset 8 aliases the command ring's first word (`RING_QW = BLTCTRL_QW + 8`).

**Deferred to Phase 2 (revised scope):**
- **Task 6 (cyc/px gate, G1):** end-to-end cyc/px is memory-bound on the Phase-1 single-beat path;
  the ~1–2 cyc/px headline is only meaningful once the burst engine lands. (Compute is already
  1 px/clock by construction.) Measure in Phase 2.
- **Tasks 7–8 (burst engine + arbiter) GROWN:** also add **SDRAM-source (C_SRCSEL=1)** routing to
  `comp_pipeline`, and **fix `vram_demux` partial-byte-enable SDRAM-dest writes** (root cause of the
  deferred `tb_blitter_system_pipe` PHASE2A/2B, behind `-DP2_SDRAM_SYS`).
- **Task 9 (synth/STA + HW)** unchanged; plus a final whole-branch review of Phase 1 before merge.

Phase 2 will be planned as a fresh spec/plan. See the PCOMP progress ledger for the detailed backlog
and carried final-review minors.
