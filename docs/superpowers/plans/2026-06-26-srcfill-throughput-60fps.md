# SRCFILL throughput → 60fps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status update (2026-07-07, 60fps campaign Phase 3a):** Tasks 1-5 (lever B warm
> P_SRC cache, lever A two-bank linebuf + prefetch sub-FSM + overlap, overlap TB,
> docs) shipped on master via PR #51 (`a9a4703` lever B, `713d704`/`a5f1af2`/`2dfb8a6`
> lever A, `34df679` overlap TB) — retroactively checked off below. **Task 6 (STA
> gate) was NOT clean**: the SEED-1 pin (`e7fe0a2`) closed timing right after this
> work landed, but the STA report from the latest successful RBF build (headSha
> `7ffb648`, includes the later 128MB XL SDRAM growth) shows **negative** setup
> slack again — clk_sys -0.265 ns, HDMI PLL -1.099 ns. Resuming at Task 6 with a
> fresh seed sweep before any HW validation (Task 7).

**Goal:** Cut the FB-in-BRAM compositor's SRCFILL bottleneck — warm the persistent P_SRC atlas cache across frames (lever B) and overlap each span's source fetch with the previous span's composite via a double-buffered line buffer (lever A) — toward 60fps on source-blit-heavy scenes.

**Architecture:** Two fabric-only levers. **B**: drop the redundant per-vsync ch5 (P_SRC) invalidation in `sdram_fb_cache` so the once-uploaded atlas stays cached; `stage_barrier` remains the sole (correct) ch5 invalidation. **A**: give `comp_src_linebuf` two banks and add a decoupled prefetch sub-FSM in `comp_pipeline` that fills bank `!b` for span N+1 over the idle P_SRC port while the existing II=1 composite pipeline serves bank `b` for span N. The mixer datapath is untouched, so bit-exactness is preserved by construction and proven by the equivalence TBs.

**Tech Stack:** SystemVerilog (Verilog-2012), Icarus Verilog (`iverilog`/`vvp`), the `fpga/sim/run_sims.sh` gating runner, `tb_profile.sv` cycle profiler. RBF via CI Quartus 17.0.x (manual); HW = DE10-Nano at 192.168.20.81 (manual, user-relaunch).

## Global Constraints

- All sims run from `fpga/sim/`; build/run idiom: `iverilog -g2012 -o /tmp/x.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v <tb>.sv && vvp /tmp/x.vvp`.
- Gating gate after every RTL change: `cd fpga/sim && ./run_sims.sh` → **`gating-failures=0`** required; non-gating failures are the 2 known slow TBs (`tb_comp_replay`, `tb_blitter_system_pipe`).
- **Bit-exactness is non-negotiable:** `tb_comp_pipeline` + the seven `tb_blitter_{copy,blend,palpha,add,mul,colormod,coalesce}_pipe` equivalence TBs must stay PASS. The mixer datapath must not change.
- `comp_src_linebuf` must infer M10K, not flip-flops: **one write port + one registered read port per bank** (the existing single-bank file documents why — 4-write-port arrays drop to ~16k regs).
- clk_sys ≈ 100 MHz; core is on **pinned SEED 7** with thin slack (`fpga/Solarus.qsf:58`). STA slack ≥ 0 on the pinned seed is the ship gate (`general[0]…divclk`).
- Branch base: `perf/fb-bram-rebaseline-cleanup`. End commit messages with the repo's Co-Authored-By + Claude-Session trailers.
- Do NOT run the RBF build / deploy / HW steps automatically — they are manual, gated, and HW needs the user to relaunch (ssh-launch dies on disconnect).

---

### Task 1: Lever B — stop the per-vsync P_SRC invalidation

**Files:**
- Modify: `fpga/rtl/sdram_fb_cache.sv` (the `INVAL_MASK0` localparam, ~line 155)
- Test: `fpga/sim/tb_sdram_fb_cache.sv` (existing; extend), `fpga/sim/tb_stage_psrc.sv` + `tb_stage_psrc_sameframe.sv` (existing; must still pass — they prove stage_barrier coherency)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `INVAL_MASK0` now invalidates ch0 only (no ch5). No port/signal changes — purely a mask-bit change visible to later tasks as "P_SRC is not invalidated on vsync."

- [x] **Step 1: Add the failing test — P_SRC survives a vsync**

In `fpga/sim/tb_sdram_fb_cache.sv`, add a test sequence: stage one qword into the atlas region (ch1) + pulse `stage_barrier`; read it via P_SRC (`p0_rd`) and record the read latency/`p0_ok` timing; pulse `vs` (a full vsync flush, wait for `coh_busy` to fall); read the SAME P_SRC address again and assert the second read is served WITHOUT a cold block-fill (i.e. the cache line was retained — same fast latency as a warm hit, not a miss-refill). Use the bench's existing mt48 model so the miss-vs-hit timing is real.

```systemverilog
// after staging atlas[A]=DATA and a stage_barrier:
warm_lat = time_p0_read(A);          // first read after stage (cold→warm)
pulse_vs_and_wait_coh();             // full vsync flush+invalidate
post_vs_lat = time_p0_read(A);       // EXPECT: warm (line retained), not a refill
if (post_vs_lat > warm_lat + MISS_SLACK) begin
  $display("FAIL: P_SRC invalidated by vsync (post_vs_lat=%0d warm_lat=%0d)", post_vs_lat, warm_lat);
  fail = 1;
end
```

- [x] **Step 2: Run it to verify it FAILS on current RTL**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/t.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_sdram_fb_cache.sv && vvp /tmp/t.vvp`
Expected: FAIL (current `INVAL_MASK0 = 8'b0010_0001` invalidates ch5 on vsync → post-vs read refills).

- [x] **Step 3: Make the change**

In `fpga/rtl/sdram_fb_cache.sv`, drop the ch5 bit from the vsync mask:

```systemverilog
// INVAL_MASK0: after ch0's flush commits, invalidate ch0(bit0) ONLY. ch5 (P_SRC) is
// NOT invalidated on vsync — the atlas is staged once and persists; the sole correct
// ch5 invalidation is stage_barrier (INVAL_MASK1), fired after a STAGE batch. (Was
// 8'b0010_0001; the ch5 bit forced a cold atlas refetch every frame.)
localparam [7:0] INVAL_MASK0 = 8'b0000_0001;
```

Update the adjacent header comments (lines ~149–154) to match: vsync flush0 commits ch0 + invalidates ch0 only; ch5 coherency is stage_barrier-only.

- [x] **Step 4: Run the new test + the stage-coherency TBs**

Run: `cd fpga/sim && for t in tb_sdram_fb_cache tb_stage_psrc tb_stage_psrc_sameframe; do iverilog -g2012 -o /tmp/$t.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v $t.sv && echo "== $t ==" && vvp /tmp/$t.vvp | grep RESULT; done`
Expected: all three `RESULT: PASS` (new warm-cache assertion holds; stage_barrier still invalidates ch5 so freshly-staged atlas is still seen → sameframe coherency intact).

- [x] **Step 5: Full gating suite**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`.

- [x] **Step 6: Commit**

```bash
git add fpga/rtl/sdram_fb_cache.sv fpga/sim/tb_sdram_fb_cache.sv
git commit -m "perf(fb-cache): keep P_SRC warm across frames (drop ch5 from vsync INVAL_MASK0)

The atlas uploads once and persists; the per-vsync ch5 invalidation forced a cold
refetch every frame. stage_barrier (INVAL_MASK1) remains the sole, correct ch5
invalidation, so freshly-staged atlas is still coherent (tb_stage_psrc[_sameframe]
green). New tb_sdram_fb_cache assertion proves a P_SRC line survives a vsync flush."
```

---

### Task 2: `comp_src_linebuf` — two banks

**Files:**
- Modify: `fpga/rtl/comp_src_linebuf.sv` (add bank select on fill + serve)
- Test: `fpga/sim/tb_comp_src_linebuf.sv` (existing; extend for 2 banks)

**Interfaces:**
- Consumes: nothing.
- Produces: new ports on `comp_src_linebuf` — `input wire fill_bank` (selects the bank the fill writes) and `input wire serve_bank` (selects the bank the serve reads). Two independent banks (`line0`, `line1`), each one-write/one-read M10K. Default behavior with both banks tied to 0 is identical to today. Serve latency unchanged (1 cycle). `serve_pix`/`serve_valid` semantics unchanged.

- [x] **Step 1: Write the failing test — banks are independent**

In `fpga/sim/tb_comp_src_linebuf.sv`, add: fill bank 0 idx 0 with qword `Q0`; fill bank 1 idx 0 with a different qword `Q1` (same cycle pattern as the real fill); serve bank 0 x=0 → expect `Q0`'s lane 0; serve bank 1 x=0 → expect `Q1`'s lane 0. Assert no cross-bank bleed.

```systemverilog
do_fill(/*bank=*/0, /*idx=*/0, 64'hAAAA_BBBB_CCCC_DDDD);
do_fill(/*bank=*/1, /*idx=*/0, 64'h1111_2222_3333_4444);
if (serve(/*bank=*/0,/*x=*/0,/*w=*/4,/*hf=*/0) !== 16'hDDDD) fail=1;  // lane0 of Q0
if (serve(/*bank=*/1,/*x=*/0,/*w=*/4,/*hf=*/0) !== 16'h4444) fail=1;  // lane0 of Q1
```

- [x] **Step 2: Run it to verify it FAILS**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/lb.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_comp_src_linebuf.sv && vvp /tmp/lb.vvp`
Expected: FAIL/compile-error (`fill_bank`/`serve_bank` ports don't exist yet).

- [x] **Step 3: Add the two banks**

In `fpga/rtl/comp_src_linebuf.sv`, add the two bank-select inputs and split the single `line` array into `line0`/`line1`, each with its own one-write/one-read always-block (preserve the "one write port + one registered read port → inferred M10K" property — do NOT add a second write port to either array):

```systemverilog
  input  wire        fill_bank,   // [overlap] bank the fill writes (0/1)
  input  wire        serve_bank,  // [overlap] bank the serve reads (0/1)
  ...
  reg [63:0] line0 [0:255];
  reg [63:0] line1 [0:255];
  always @(posedge clk) if (fill_we && !fill_bank) line0[fill_idx[7:0]] <= fill_qw;
  always @(posedge clk) if (fill_we &&  fill_bank) line1[fill_idx[7:0]] <= fill_qw;
  // serve: registered read of the selected bank's qword, then combinational lane select
  reg [63:0] serve_qw_q;
  always @(posedge clk) begin
    serve_valid  <= serve_req;
    serve_lane_q <= xa[1:0];
    if (serve_req) serve_qw_q <= serve_bank ? line1[xa[9:2]] : line0[xa[9:2]];
  end
```

(Keep the existing `xa` hflip address math and the combinational `serve_pix` lane mux exactly as-is.)

- [x] **Step 4: Run the linebuf test**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/lb.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_comp_src_linebuf.sv && vvp /tmp/lb.vvp`
Expected: `RESULT: PASS` (banks independent; single-bank legacy cases still pass).

- [x] **Step 5: Wire `comp_pipeline`'s existing instance with both selects tied to 0 (no behavior change yet)**

In `fpga/rtl/comp_pipeline.sv` at the `u_linebuf` instantiation (~line 148), add `.fill_bank(1'b0), .serve_bank(1'b0)`. This keeps the compositor single-bank/identical until Task 3 drives the banks.

- [x] **Step 6: Full gating suite (bit-exact must hold)**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0` — especially `tb_comp_pipeline` + the 7 `tb_blitter_*_pipe` equivalence TBs PASS (compositor still single-bank).

- [x] **Step 7: Commit**

```bash
git add fpga/rtl/comp_src_linebuf.sv fpga/sim/tb_comp_src_linebuf.sv fpga/rtl/comp_pipeline.sv
git commit -m "feat(comp): comp_src_linebuf gains a 2nd bank (ping-pong seam for fetch/composite overlap)

Two independent one-write/one-read M10K banks selected by fill_bank/serve_bank.
comp_pipeline instance ties both to 0 → byte-identical single-bank behavior (all
equivalence TBs green). Task 3 drives the banks to overlap SRCFILL(N+1) with comp(N)."
```

---

### Task 3: `comp_pipeline` — decoupled prefetch sub-FSM (the overlap)

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv` (add a prefetch sub-FSM owning `p0_rd`/`lb_fill_*`; drive `fill_bank`/`serve_bank`; gate span advance on both composite-done and prefetch-done)
- Test: `fpga/sim/tb_comp_pipeline.sv` + the 7 equivalence TBs (bit-exact, existing); `tb_profile.sv` (cyc/px improvement); new `tb_comp_overlap_pipe.sv` (Task 4)

**Interfaces:**
- Consumes: `comp_src_linebuf.fill_bank`/`serve_bank` (Task 2); the existing span table (`sp_*`/`sp_q_*`), `gpix`/`fill_qw`/`sf_*` source-addressing, and the `P_PIXEL` composite pipeline.
- Produces: no port changes on `comp_pipeline` (P_SRC/fb_*/mixer ports unchanged). Internally: a `fstate` sub-FSM (`F_IDLE`/`F_ISS`/`F_WAIT`) that, given a span's `(gpix_lo,gpix_hi,fill_bank)`, fills that bank over P_SRC; a `serve_bank` register toggled per span; a `prefetch_busy` flag the main FSM waits on.

**Approach (incremental, test-gated).** The composite pipeline and mixer are NOT modified — only the *control* around source fill changes. Build it in three commits, each ending green:

#### 3a — Extract source fill into a concurrent sub-FSM (still sequential timing)

Move the `P_SRCFILL_ISS`/`P_SRCFILL_WAIT` logic out of the main FSM into an independent `fstate` always-block that owns `p0_addr`/`p0_rd`/`lb_fill_we`/`lb_fill_qw`/`lb_fill_idx`/`sf_idx`/`sf_nqw`. The main FSM kicks it via a `fill_start` pulse + a `fill_req` record (`{fill_lo, fill_hi, fill_bank_sel}`) and waits for `!prefetch_busy` before compositing. **At this stage the main FSM still waits for the fill to finish before P_PIXEL — behavior and timing identical, just restructured.** This isolates the risky extraction with a pure-refactor gate.

- [x] **Step 1: Snapshot the cyc/px baseline (for the 3c improvement gate)**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/p.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_profile.sv && vvp /tmp/p.vvp | grep cyc/px`
Record: COPY wide ≈ 2.55, COPY sprite ≈ 2.76 (these must DROP in 3c).

- [x] **Step 2: Add the `fstate` sub-FSM + handshake regs**

Add localparams `F_IDLE=2'd0, F_ISS=2'd1, F_WAIT=2'd2`, regs `fstate`, `prefetch_busy`, `fill_start`, `fill_lo[31:0]`, `fill_hi[31:0]`, `fill_bank_sel`, and move the qword-walk (the current `P_SRCFILL_ISS`/`P_SRCFILL_WAIT` bodies) into a dedicated `always @(posedge clk)` driving `p0_*`/`lb_fill_*` from `fill_lo/fill_hi/fill_bank_sel`, raising `prefetch_busy` from `fill_start` until the last qword lands. Drive `comp_src_linebuf.fill_bank(fill_bank_sel)`.

- [x] **Step 3: Rewire the main FSM to use the sub-FSM (sequential)**

Replace `P_COMP_RD2 → P_SRCFILL_ISS/WAIT → P_PIXEL` with: `P_COMP_RD2` computes `gpix_*`, sets `fill_lo/fill_hi`, `fill_bank_sel=serve_bank` (fill the bank we are about to serve), pulses `fill_start`; a new `P_FILL_WAIT` state waits `!prefetch_busy` then enters `P_PIXEL`. `serve_bank` is left constant for now. Remove the old `P_SRCFILL_ISS/WAIT` states from the main FSM.

- [x] **Step 4: Bit-exact gate (pure refactor)**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`; `tb_comp_pipeline` + 7 equivalence TBs PASS. `tb_profile` cyc/px UNCHANGED vs Step 1 (still sequential).

- [x] **Step 5: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv
git commit -m "refactor(comp): extract source fill into a concurrent fstate sub-FSM (no timing change)

P_SRCFILL_* moves into an independent always-block owning p0_*/lb_fill_*, kicked by
fill_start with a {fill_lo,fill_hi,fill_bank} request; main FSM waits !prefetch_busy
before P_PIXEL. Behavior + cyc/px identical (equivalence TBs + tb_profile unchanged);
isolates the extraction before enabling overlap."
```

#### 3b — Ping-pong the banks (serve vs fill on opposite banks)

- [x] **Step 6: Toggle `serve_bank` per span; fill the opposite bank**

Drive `comp_src_linebuf.serve_bank(serve_bank)`. In `P_COMP_RD2`, set `fill_bank_sel = ~serve_bank` (prefetch the NEXT span into the other bank). After P_PIXEL completes a span, toggle `serve_bank <= ~serve_bank`. Add a one-time **prologue**: the first span of a blit must fill its OWN serve bank before compositing (no prior prefetch exists). Track with a `first_span` flag set at `P_CHUNK_RD`/blit start.

- [x] **Step 7: Bit-exact gate (still sequential, but banked)**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`; equivalence TBs PASS (serving the correct bank yields identical pixels). `tb_profile` cyc/px still ≈ baseline (overlap not enabled yet — fill and comp still sequential).

- [x] **Step 8: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv
git commit -m "feat(comp): ping-pong serve_bank/fill_bank per span (no overlap yet, bit-exact)

serve_bank toggles per span; the fill targets the opposite bank with a first-span
prologue fill. Still sequential (fill then composite) so cyc/px is unchanged; sets up
the concurrent prefetch in the next commit. Equivalence TBs green."
```

#### 3c — Enable the overlap (prefetch span N+1 during composite of span N)

- [x] **Step 9: Kick the next span's prefetch at the START of P_PIXEL**

When `P_COMP_RD2` of span N finishes, instead of waiting for the fill then compositing, compute span **N+1**'s `(gpix_lo,gpix_hi)` (reuse the `P_COMP_RD`/`P_COMP_RD2` address math via the registered span read at `chunk_first+chunk_si+1`), pulse `fill_start` with `fill_bank_sel = ~serve_bank`, and enter `P_PIXEL` for span N immediately (serving `serve_bank`, already filled). Advance to the next span only when BOTH `P_PIXEL` drain is done AND `!prefetch_busy`. Guard the **last span** in a chunk/blit (no N+1 → skip the prefetch kick). The prefetch (P_SRC) and the composite (linebuf serve) touch disjoint banks and disjoint ports, so they run concurrently.

- [x] **Step 10: Bit-exact gate — overlap must not change pixels**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`; `tb_comp_pipeline` + 7 equivalence TBs PASS (overlap is a timing change only; pixels identical).

- [x] **Step 11: Throughput gate — cyc/px must drop on multi-row source blits**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/p.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_profile.sv && vvp /tmp/p.vvp | grep cyc/px`
Expected: COPY wide 2.55 → ≈1.5–1.7 (toward `max(fill,comp)`); COPY sprite 2.76 → lower; FILL wide 1.05 UNCHANGED (no source). Record the new numbers.

- [x] **Step 12: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv
git commit -m "perf(comp): overlap SRCFILL(span N+1) with composite(span N) via ping-pong linebuf

The fstate prefetch fills the next span's bank over the idle P_SRC port while P_PIXEL
composites the current span from the other bank; span advance gates on both. Per-span
time goes fill+comp -> max(fill,comp): COPY wide <BEFORE>->​<AFTER> cyc/px (record).
Pixels bit-identical (equivalence TBs green); FILL unchanged."
```

---

### Task 4: Overlap proof TB

**Files:**
- Create: `fpga/sim/tb_comp_overlap_pipe.sv`
- Modify: `fpga/sim/run_sims.sh` (it auto-globs `tb_*.sv`; add a positive marker only if non-default)

**Interfaces:**
- Consumes: the full `comp_pipeline` + `comp_src_linebuf` from Task 3 (drive a multi-row source BLIT through the command/span path like `tb_comp_pipeline` does).
- Produces: a gating assertion that the fetch of span N+1 temporally overlaps the composite of span N.

- [x] **Step 1: Write the overlap assertion TB**

Drive a multi-row (e.g. 8×8) source BLIT. Monitor: the first `p0_rd` belonging to span N+1 (a P_SRC read issued by the prefetch) must occur while span N is still compositing (between span N's first `lb_serve_req` and its `fb_wr` drain). Assert at least one such overlap occurs over the blit; FAIL if every `p0_rd` falls strictly between composites (i.e. no overlap → sequential).

```systemverilog
// instrument: comp.fstate, comp.prefetch_busy, comp.lb_serve_req, comp.fb_wr_en
// record cycle of (a) span-N composite window and (b) span-(N+1) p0_rd burst start;
// assert (b) starts before (a) ends for at least one N.
if (!saw_overlap) begin $display("FAIL: no fetch/composite overlap observed"); fail=1; end
$display("RESULT: %s", fail ? "FAIL" : "PASS");
```

- [x] **Step 2: Run it — expect PASS on Task 3 RTL**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/ov.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_comp_overlap_pipe.sv && vvp /tmp/ov.vvp`
Expected: `RESULT: PASS` (overlap observed). If FAIL, the prefetch isn't concurrent — revisit Task 3c Step 9.

- [x] **Step 3: Full gating suite (new TB is gating)**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`, `tb_comp_overlap_pipe PASS`.

- [x] **Step 4: Commit**

```bash
git add fpga/sim/tb_comp_overlap_pipe.sv
git commit -m "test(comp): gate the SRCFILL/composite overlap (span N+1 fetch during span N composite)

Drives a multi-row source BLIT and asserts at least one span's P_SRC prefetch is issued
while the previous span is still compositing — guards against a regression back to
sequential fill-then-composite."
```

---

### Task 5: Update profiler header + memory/docs

**Files:**
- Modify: `fpga/sim/tb_profile.sv` (banner note that source blits are now overlap-bound), `docs/frame-dataflow.md` (SRCFILL overlap + warm P_SRC), memory `fpga-comp-pipeline-cycle-profile.md` (new cyc/px)

- [x] **Step 1: Record the post-overlap cyc/px in the profiler banner + memory**

Update `tb_profile.sv`'s banner to state SRCFILL is now overlapped with composite (per-span time = max, not sum). Update `docs/frame-dataflow.md` and memory `fpga-comp-pipeline-cycle-profile.md` with the Task 3c numbers and that P_SRC stays warm across frames (Task 1).

- [x] **Step 2: Commit**

```bash
git add fpga/sim/tb_profile.sv docs/frame-dataflow.md
git commit -m "docs(comp): record SRCFILL overlap + warm-cache in profiler banner and dataflow"
```

---

### Task 6: RBF build + STA gate (MANUAL — do not auto-run)

- [ ] **Step 1:** Push `fpga/**` → CI (`build-rbf.yml`). `gh run download <id> -n quartus-reports`.
- [ ] **Step 2: STA gate.** Check `Solarus.sta.summary` clk_sys (`general[0]…divclk`) slack **≥ 0** on the pinned SEED 7. The new serve-path bank mux + the prefetch control are the timing concern.
  - If **negative**: register the `serve_bank`/`fill_bank` select (add a pipeline stage on the linebuf address mux, same technique as the colormod s3 split) and re-confirm bit-exact in sim, then rebuild. Do NOT ship negative slack. If it still won't close, STOP and reassess with the user (a seed-independent fix vs. backing out lever A).
- [ ] **Step 3:** Confirm M10K total still fits (was ~77%; +1 linebuf bank is ~1 M10K).

---

### Task 7: HW validation (MANUAL, user-relaunch — do not auto-run)

- [ ] **Step 1:** Refresh `deploy/` from `build/armhf` (engine unchanged this plan — fabric-only — but keep it in sync), `./deploy.py --host 192.168.20.81`; activate `echo "load_core …Solarus_YYYYMMDD.rbf" > /dev/MiSTer_cmd`. **User relaunches** the engine via OSD/Scripts.
- [ ] **Step 2:** Read perf counters before/after on a heavy overworld (input-injected if needed): `busybox devmem 0x3B00002C` (fabric cyc) / `0x3B000034` (pipe cyc) / `0x3A070000` (vsync). Confirm: lever B → lower fabric cyc/frame (warm atlas, fewer SRCFILL misses); lever A → lower pipe cyc/frame; **fps up toward 60** on the heavy scene. Screenshot clean (no atlas garbage → coherency still correct on silicon).
- [ ] **Step 3:** Update memory `fpga-fb-in-bram-feasibility` / `fpga-throughput-optimization-arc` with the HW fps result.

---

## Self-Review

**Spec coverage:** Lever B → Task 1. Lever A linebuf → Task 2; pipeline overlap → Task 3 (3a extract, 3b ping-pong, 3c overlap). Verification: bit-exact (every task's gating gate), throughput (Task 3c Step 11), overlap proof (Task 4), HW (Task 7). Risk/timing → Task 6 STA gate with the register-the-select fallback. Out-of-scope items (ch0/ch4 deletion, SOLARUS_SW, engine changes) are excluded. All spec sections covered.

**Placeholder scan:** Code shown for B (mask), linebuf banks, sub-FSM structure, ping-pong, overlap kick, and both new TBs' assertions. Task 3's exact final FSM emerges under the bit-exact + overlap gates (RTL restructure is test-driven by design); the `<BEFORE>->​<AFTER>` token in the 3c commit message is a fill-in-the-measured-numbers marker, not a code placeholder.

**Type/name consistency:** `fill_bank`/`serve_bank` (Task 2 ports) used consistently in Task 3. `fstate`/`prefetch_busy`/`fill_start`/`fill_lo`/`fill_hi`/`fill_bank_sel` introduced in 3a and reused through 3c. `INVAL_MASK0` value `8'b0000_0001` matches the spec's "ch0-only." Profiler grep `cyc/px` matches `tb_profile.sv` output.
