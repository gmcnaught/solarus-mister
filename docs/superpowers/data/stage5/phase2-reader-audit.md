# Stage 5 Phase 2 — Task 1: Reader scanout audit + un-bridge mechanism decision

Audit only, no RTL changed. Branch `feat/stage5-phase2-fb-ddr3`.

## (a) Current pixel-scan datapath — exact signals + line numbers

File: `fpga/rtl/openbor_video_reader.sv`.

Reader ports (module decl, lines 38-98):
- `output reg [26:0] scan_addr` (line 52) — byte address, 27-bit.
- `output reg        scan_rd`   (line 53) — request pulse/hold.
- `input  wire [63:0] scan_dout` (line 54) — return data.
- `input  wire        scan_ok`   (line 55) — one-cycle accept/valid pulse.
- Separately, the native DDR3 Avalon-MM master (`ddr_addr[28:0]`/`ddr_burstcnt`/`ddr_rd`/`ddr_we`/`ddr_din`/`ddr_dout`/`ddr_dout_ready`/`ddr_busy`, lines 40-49) is **still present** but, per the FSM trace below, is now used only for `CTRL_ADDR` polling (0x3A000000, line 663) and cart/joystick/audio-ring/vsync housekeeping (lines 564-908) — **not** for pixel-scan fetch.

FSM states (lines 293-315): `ST_IDLE, ST_POLL_CTRL, ST_WAIT_CTRL, ST_CHECK_CTRL, ST_READ_LINE, ST_WAIT_LINE, ST_LINE_DONE, ST_WAIT_DISPLAY, ST_WRITE_JOY0..3, ST_WRITE_CART, ST_WRITE_CART_SIZE, ST_POLL_AUDIO_WR, ST_WAIT_AUDIO_WR, ST_PLAN_AUDIO, ST_READ_AUDIO_RING, ST_WAIT_AUDIO_RING, ST_WRITE_AUDIO_RD, ST_PAINT, ST_WRITE_VSYNC`. (Brief expected `ST_WAIT_DISPLAY`/`ST_READ_LINE` only — `ST_WAIT_LINE`/`ST_LINE_DONE` also exist between them and matter for the handshake, see below.)

Pixel-scan sequence, confirmed by direct read:
- `ST_READ_LINE` (line 725): `scan_addr <= buf_base_addr + (display_line * `SDRAM_FB_STRIDE`)` (line 733); `scan_rd <= 1'b1` (line 734). **No `ddr_addr`/`ddr_burstcnt` write here.**
- `ST_WAIT_LINE`: captured in the `always` block at lines 469-490 (state-gated, not a separate labeled `always` per state) — `if (state == ST_WAIT_LINE && scan_ok && !scan_ok_d)` (line 480) latches `lb_we/lb_waddr/lb_wdata <= scan_dout` (lines 481-483). `scan_ok_d` (line 332) is a registered delay of `scan_ok` used to act only on `scan_ok`'s **rising edge**, because the serving cache (historically P_SCAN, now `fbram_scan_adapter`) can hold `scan_ok` for more than one cycle (issue #44, comment lines 325-330).
- Beat loop (lines 742-766): advances `scan_addr <= scan_addr + 27'd8` per accepted beat, holds `scan_rd` across `LINE_BURST` (=80, line 163) qwords, then `state <= ST_WAIT_DISPLAY` (line 791) which re-arms `ST_READ_LINE` for line N+1 while line N is displayed (double-buffered by parity, see below).
- `BUF0_ADDR`/`BUF1_ADDR` (localparams, lines 146-147, `29'h07400008`/`29'h07408008` = `0x3A000040`/`0x3A040040` >> 3) are declared but **never referenced anywhere else in the file** — `grep -n "BUF0_ADDR\|BUF1_ADDR"` returns only the two declaration lines. `buf_base_addr` (line 322, the register actually used in `ST_READ_LINE`) is driven only from `27'd0` (line 701, single-buffer, base 0) — never from `BUF0_ADDR`/`BUF1_ADDR`. **These two localparams are dead code today**, but they already encode the exact future DDR3 double-buffer qword addresses byte-identical to the `` `FB_DDR0_QW ``/`` `FB_DDR1_QW `` macros (see (c) below) — i.e. someone already pre-wired the target addresses for this Phase 2 in anticipation, and left them unused since Task 5 (comp_fbram) repointed the fetch elsewhere.

**Line double-buffer ("read-ahead") mechanism — this is the part worth flagging carefully**, because it is the thing that actually matters for the mechanism decision, not a `dcfifo`:
- `linebuf` (line 384): `(* ramstyle = "no_rw_check, M10K" *) reg [63:0] linebuf [0:255]` — a 256×64-bit on-chip BRAM, **not a Quartus `dcfifo`**.
- Write side (line 983, `ddr_clk` domain): `if (lb_we) linebuf[lb_waddr] <= lb_wdata;`, filled qword-by-qword from `scan_dout` as above.
- Read side (line 946, `clk_vid` domain): `lb_q <= linebuf[{vcount[0], hcol[8:2]}];` — the MSB of the read address is `vcount[0]` (parity), and the write address is `{display_line[0], beat_count}` (line 482) — so this is a **hand-rolled ping-pong double buffer inside one BRAM array**, addressed by line parity, not a dcfifo primitive. It is the mechanism that lets line N+1 fetch overlap with line N display, and it sits **downstream of `scan_addr`/`scan_rd`/`scan_dout`/`scan_ok`** — i.e. it is unchanged no matter what serves that 4-signal protocol.
- **There is exactly one `dcfifo` instantiated in this file** (lines 991-1018): `audio_fifo_inst`, 64-bit×1024-deep, `rdclk=clk_audio`/`wrclk=ddr_clk` — this is the **audio** CDC FIFO, unrelated to video pixel-scan. Confirmed by grepping the pre-fork version of the file (see (b)): the same single audio-only `dcfifo` instance exists there too, at the equivalent line (backed by the same `lpm_type("dcfifo")` block). **Correction to the brief's prior-review note: no `dcfifo`/line-read-ahead FIFO has ever existed in this file's history for the pixel-scan path** — the reusable read-ahead primitive is `linebuf` (a plain BRAM array), not a dcfifo.

## (b) Does the native OpenBOR `ddr_addr`/`LINE_BURST` line-fetch survive in-file, or only in history?

**Only in history.** Confirmed by diffing the reader across its full commit lineage (`git log --oneline --all -- fpga/rtl/openbor_video_reader.sv`, 29 commits):

- The native path — `ST_READ_LINE` driving `ddr_addr <= buf_base_addr + (display_line * LINE_STRIDE)` and `ddr_burstcnt <= LINE_BURST` directly on the DDR3 Avalon-MM master, with `ST_WAIT_LINE` gated on `ddr_dout_ready` — is present verbatim in the reader as of commit **`8e033f3` ("fix(#34): vram_demux review fixes...")**, the parent of `fb459f8`. Verified directly: `git show fb459f8^:fpga/rtl/openbor_video_reader.sv` still has `ddr_addr <= buf_base_addr + (...)` / `ddr_burstcnt <= LINE_BURST` in `ST_READ_LINE`, and `ST_WAIT_LINE` waits on `ddr_dout_ready`.
- **`fb459f8` "feat(#34): scanout reads framebuffer from SDRAM (dual-bus reader)"** (commit message literally: *"Move line fetch (ST_READ_LINE/ST_WAIT_LINE) from DDR to SDRAM master"*) converted it to a separate SDRAM burst master (not yet the cache-ok protocol).
- **`07426f8` "feat(reader): P_SCAN hold-until-ok backpressure recovers from starve (JC-T4)"** is the last commit to touch the interim SDRAM-master form before it became today's `scan_addr`/`scan_rd`-with-`scan_ok` cache-ok handshake.
- **`6fe5ee3` "feat(fb-bram): scanout reads comp_fbram via 2nd read port + adapter (Task 5)"** repointed the (by-then-cache-ok) protocol at `comp_fbram` via the new `fbram_scan_adapter`, and is the commit that **deleted `fpga/sim/tb_scanout_sdram.sv`** ("tb_scanout_sdram (the retired SDRAM-scanout path) is removed — superseded by tb_scanout_fbram").

So: reverting to native `ddr_addr`/`LINE_BURST` is **not a clean single-commit revert** — it would mean undoing three separate architectural commits (`fb459f8` → `07426f8` → `6fe5ee3`) and re-deriving `ddr_dout_ready`-gated bursting against a master that today is also shared with cart/joystick/audio/vsync housekeeping (those uses were added on **top of** the SDRAM/cache-ok conversion, not before it, so a straight revert would conflict with them).

`tb_scanout_sdram.sv`: does **not** exist in the working tree (confirmed: `ls` → No such file). Retrievable from git history: `git show 07426f8:fpga/sim/tb_scanout_sdram.sv` (last commit that touched it before deletion at `6fe5ee3`). It modeled the DDR3 read side including backpressure/underflow-recovery — `tb_scanout_fbram.sv`'s own header comment (lines 6-7) says explicitly: *"comp_fbram is on-chip and never backpressures, so the SDRAM-underflow/recovery phase of tb_scanout_sdram does not apply here."* This means a DDR3-backed adapter reintroduces exactly the backpressure/latency class `tb_scanout_sdram` was built to cover, and that testbench (or a revived form of it) is the natural template for Task 6's new DDR3 testbench, rather than starting from zero.

## (c) Two candidate mechanisms — concrete diffs

**thin-ddr3-adapter** — reader FSM and its `scan_addr[26:0]`/`scan_rd`/`scan_dout[63:0]`/`scan_ok` port contract untouched (0 lines changed in `openbor_video_reader.sv`). Diff is confined to:
1. New file `fpga/rtl/ddr3_scan_adapter.sv`, sibling to and roughly the same shape as `fpga/rtl/fbram_scan_adapter.sv` (41 lines) — presents the identical `scn_addr`/`scn_rd` → `scn_dout`/`scn_ok` interface, but internally issues reads against a DDR3 master (a new port, since the existing `ddr_addr` master in the reader is already busy with housekeeping and `blt_addr`/`ddr_blitter_arb` is already busy with the blitter — needs its own arbiter leg, following the existing `ddr_blitter_arb.sv` two-master pattern: `rdr_*`/`blt_*` → `ddram_*`, lines 21-58).
2. `fpga/Solarus.sv`: swap the `fbram_scan_adapter u_fbram_scan (...)` instantiation (lines 513-522) for `ddr3_scan_adapter u_ddr3_scan (...)`, feeding it whichever DDR3 base address the new arbiter leg resolves to (the `` `FB_DDR0_QW ``/`` `FB_DDR1_QW `` macros already define this — see below).
3. `blitter_top.sv`: the vblank WORK→SCAN snapshot (`u_snap`, referenced at blitter_top.sv:82/1287-1296) needs to target the new DDR3 double-buffer instead of (or in addition to) `comp_fbram`'s on-chip SCAN banks — this is Task 4's scope, not Task 1's, but it is the dependency this adapter needs on the write side.
4. New sim: a `tb_scanout_ddr3.sv`, structurally close to the retired `tb_scanout_sdram.sv` (git-history template, see (b)) plus `tb_scanout_fbram.sv`'s pixel-exact harness (both already exist/existed and are directly reusable as templates).
- **Reuses:** the entire reader FSM (validated across `tb_scanout_fbram`, HW since 2026-06 per commit history), the entire `linebuf` double-buffer BRAM (unchanged since before the fork), the `ddr_blitter_arb` two-master arbitration pattern (already shipped, HW-validated per issue #34 fixes), the `` `FB_DDR0_QW ``/`` `FB_DDR1_QW `` address macros (already defined, already numerically pre-staged into the reader's own dead `BUF0_ADDR`/`BUF1_ADDR` localparams).
- **New code:** one new adapter module (~40-60 lines, same order as `fbram_scan_adapter.sv`) + one new arbiter leg + one new testbench.

**native-restore** — re-convert `ST_READ_LINE`/`ST_WAIT_LINE` back to driving `ddr_addr`/`ddr_burstcnt`/`ddr_rd` directly with `LINE_BURST=80`, undoing `fb459f8`→`07426f8`→`6fe5ee3` (three commits' worth of interleaved changes, not a clean revert since audio/joystick/cart/vsync housekeeping was layered onto the same `ddr_addr` master afterward and would need re-threading around a now-also-line-fetching master). Would also require either time-division-multiplexing `ddr_addr` between line-fetch bursts and the still-needed housekeeping polls (CTRL/joystick/cart/audio/vsync), or a **second** DDR3 master anyway — at which point it has paid the same "new arbiter leg" cost as the thin adapter while additionally re-deriving burst/backpressure logic that `07426f8`'s cache-ok handshake already replaced for good reason (the code comments at lines 325-330, 749-766 document a real bug class — issue #44's 2-cycle-`scan_ok` double-capture — that the cache-ok protocol's `scan_ok_d` rising-edge fix already closed; native-restore would need to either resurrect that fix against a different handshake shape or risk reintroducing it).
- **Reuses:** nothing currently in-file; everything is git-archaeology reconstruction.
- **New/changed code:** effectively a second historical migration in reverse (3 commits' worth of FSM changes) *plus* a new arbiter leg (housekeeping can no longer share `ddr_addr` uncontested with an active line-burst master) *plus* re-solving the #44 backpressure bug against the reconstructed shape.

## (d) Decision

**`SCANOUT_MECHANISM = thin-ddr3-adapter`.**

Per the "prefer existing code" tie-breaker: thin-ddr3-adapter changes zero lines in the reader's FSM/ports (already HW-validated via `tb_scanout_fbram` + prior HW soak) and zero lines in `linebuf` (already HW-validated, unchanged since before the SDRAM/cache-ok/comp_fbram lineage even started). It adds one small adapter module following the exact shape of the already-shipped `fbram_scan_adapter.sv`, plus one new arbiter leg following the exact shape of the already-shipped `ddr_blitter_arb.sv`. native-restore fails both of the brief's stated pre-conditions for choosing it: the FSM conversion is **not** a clean revert (three interleaved commits, housekeeping now layered on top of the same master), and the thin adapter does **not** duplicate the reader's own FIFO — because the reader's read-ahead mechanism is `linebuf`, a plain BRAM array the adapter never touches, not a `dcfifo` the adapter would be redundantly re-instantiating. There is no dcfifo double-instantiation risk to weigh against thin-ddr3-adapter in the first place.

## (e) Exact reader interface signals for Task 6

Unchanged, to be wired to the new `ddr3_scan_adapter` exactly as they are wired to `fbram_scan_adapter` today (`fpga/Solarus.sv:513-522`, `fpga/rtl/openbor_video_reader.sv:52-55`):

| Signal | Width | Direction (reader's view) | Notes |
|---|---|---|---|
| `scan_addr` | `[26:0]` | out (reader → adapter) | byte address; `buf_base_addr + display_line*`SDRAM_FB_STRIDE`(=640)`, +8/beat |
| `scan_rd` | 1 | out (reader → adapter) | held across the burst; drops per accepted-beat "hold-until-ok" protocol (lines 742-766) |
| `scan_dout` | `[63:0]` | in (adapter → reader) | valid on the rising edge of `scan_ok` only (issue #44 fix, `scan_ok_d`) |
| `scan_ok` | 1 | in (adapter → reader) | may be held >1 cycle by the server; reader samples the **rising edge** (`scan_ok & ~scan_ok_d`) |

Address-space target for the adapter's DDR3 side (already defined, `fpga/rtl/vram_defs.vh:11-13`):
- `` `FB_DDR0_QW `` = `29'h07400008` (= `0x3A000040 >> 3`)
- `` `FB_DDR1_QW `` = `29'h07408008` (= `0x3A040040 >> 3`)
- `` `FB_QWORDS ``  = `29'd19200` (320×240×2 bytes / 8)
- These byte-identical addresses are already baked into the reader itself as the currently-dead `BUF0_ADDR`/`BUF1_ADDR` localparams (`openbor_video_reader.sv:146-147`) — Task 6 can wire the new double-buffer select (whatever selects FB0 vs FB1, e.g. a vblank-toggled bank bit from the Task 4 snapshot write) into `buf_base_addr`'s existing mux point (line 701 today just hardwires `27'd0`) instead of inventing a new address scheme.

**Caveat / context note for whoever picks up `vram_demux.sv`:** the same `` `FB_DDR0_QW ``/`` `FB_DDR1_QW ``/`` `FB_QWORDS `` macros are also consumed by `fpga/rtl/vram_demux.sv`, but that module is **not instantiated anywhere in the current build** (confirmed: `grep -rln "vram_demux ("` across `fpga/rtl` and `fpga/Solarus.sv` finds nothing; it is referenced only in a stale comment at `blitter_top.sv:1323` describing the pre-comp_fbram architecture, and `Solarus.sv:495` explicitly documents "The SDRAM cache's P_DST (ch0) + P_SCAN (ch4) channels above are now DEAD"). Do not assume `vram_demux` is live wiring to copy from — it is dead code from before PR #49 (FB-in-BRAM) that happens to share the same address macros Phase 2 will reuse.

## Sources checked

- `fpga/rtl/openbor_video_reader.sv` (current + `fb459f8^` pre-fork snapshot via `git show`)
- `fpga/rtl/fbram_scan_adapter.sv`
- `fpga/rtl/openbor_video_top.sv` (reader instantiation)
- `fpga/Solarus.sv` (adapter + comp_fbram instantiation, lines ~450-525 and ~985-1001)
- `fpga/rtl/vram_demux.sv`, `fpga/rtl/vram_defs.vh` (dead-code check, `FB_DDR0_QW`/`FB_DDR1_QW`/`FB_QWORDS` macro source)
- `fpga/rtl/ddr_blitter_arb.sv` (existing 2-master arbitration pattern, template for a 3rd leg)
- `fpga/sim/tb_scanout_fbram.sv` (current active testbench, header comment)
- `fpga/sim/tb_scanout_sdram.sv` — absent from working tree; last present at commit `07426f8`, removed at `6fe5ee3`
- `git log --oneline --all -- fpga/rtl/openbor_video_reader.sv` (29 commits, full lineage read)
- `git log --oneline --all -- fpga/sim/tb_scanout_sdram.sv`, `-- fpga/sim/tb_scanout_fbram.sv`
