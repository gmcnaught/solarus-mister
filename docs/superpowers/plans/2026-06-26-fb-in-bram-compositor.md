# FB-in-BRAM compositor — implementation plan (single-buffer)

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement task-by-task. Steps use
> checkbox (`- [ ]`) syntax. Every RTL task is TDD: extend the testbench, watch it FAIL,
> then implement until green. Commit after each green task.

**Goal:** Make the compositor's destination framebuffer **resident on-chip in M10K**
(`comp_fbram`) instead of the off-chip SDRAM FB. Eliminate the WB (44–66% of compositor
cycles) + LOAD phases — they exist only to evict/refill the band to SDRAM. Sources stay in
SDRAM (ch5/P_SRC, untouched). Net predicted ~3–4× compositor throughput (COPY 4.56→~1.5,
FILL 3.06→~1.0 cyc/px) and removal of the FB cache-coherency machinery (#39/#40/#44 wedge
class). **Single-buffer first** (tears on motion, clean on static — a bring-up increment to
validate datapath + timing + scanout-from-BRAM on HW); double-buffer is a separate follow-up.

**Design sketch / rationale:** `docs/superpowers/specs/2026-06-26-fb-in-bram-compositor.md`,
memory `fpga-fb-in-bram-feasibility`. **Budget de-risked:** trial-synth (synth-probe.yml,
run 28211362792) = `comp_fbram` is **160 M10K/buffer**, FB R/W paths close at +1.7–6.1 ns;
single-buffer total ≈ 244/553 (44%), double ≈ 404/553 (73%). Both fit.

**Architecture.** `comp_fbram` = 4 lane-banks × 16-bit × 19200 (qword `= y*80 + x>>2`, lane
`= x[1:0]`), simple-dual-port M10K per bank. It is owned by the **integration layer**
(`Solarus.sv`), exactly like `vram_demux`/`sdram_fb_cache`. `comp_pipeline` exposes new
`fb_wr_*`/`fb_rd_*` ports (composite write + blend read) threaded up through `blitter_top`
**mirroring the existing `p0_*` source ports**. The scanout reader reads `comp_fbram` (HBlank
burst into its existing `linebuf`) instead of SDRAM ch4/P_SCAN. The dest no longer touches
`mem_*` at all (mem_* becomes ring/ctrl/clear traffic only).

## Background the engineer must know (load-bearing)

- **Mixer boundary is the cut point** (`comp_pipeline.sv`): `comp_mixer u_mixer` takes
  `mx_in_dst` (16-bit dest pixel for RMW blend) and emits `mx_out_pix`/`mx_out_we`. Today
  `mx_in_dst` comes from `comp_dest_band`'s band read and `mx_out_pix` goes to the band `cw`
  port. **The cutover = feed `mx_in_dst` from `fb_rd` and route `mx_out_pix` to `fb_wr`.**
  Everything between (band buffer, flush FIFO, comp_burst-write, the `P_LOAD_*`/`P_FLUSH_*`/
  `P_WB_*` states) is deleted.
- **Opaque-skip already exists** (`comp_opaque = (mix_mode==COMP_COPY)&&!b_palpha`): for COPY/
  FILL the blend read is skipped, so `fb_rd` is only needed for ALPHA/ADD/MUL/KEY/PALPHA. This
  is what lets one M10K read port serve both composite-read and (HBlank) scanout-read.
- **`comp_pipeline` is `blitter_top`'s `u_pipe`**; `blitter_top` is edited in this repo
  (perf counters, 34a8142) despite the "edit upstream" header — port-plumbing for `fb_*`
  follows the `p0_*` precedent (`comp_pipeline`→`blitter_top` ports→`Solarus.sv`).
- **Bit-exact gate = `tb_blitter_system_pipe`** (drives `blitter_top` + `vram_demux` +
  behavioral mem). The new tb wires `comp_fbram` to `blitter_top.fb_*`, runs the same blits,
  and reads `comp_fbram` back to compare against the current SDRAM-FB golden. This is the
  correctness bar; do not proceed to HW until it is pixel-exact for COPY/ALPHA/ADD/MUL/
  colormod/PALPHA.
- **Coherency that DISAPPEARS** (`Solarus.sv` + `sdram_fb_cache.sv`): `dst_barrier`, the vsync
  ch0 flush, `INVAL_MASK0`, ch0/P_DST cache, ch4/P_SCAN. **Coherency that STAYS:** ch1 STAGE +
  ch5 P_SRC (atlas upload + source reads, `stage_barrier`, `INVAL_MASK1`).
- **`comp_fbram` is already written + trial-synthed** in `synth_probe/comp_fbram.sv`. Task 0
  promotes it to `fpga/rtl/`.

## File structure

- **Move** `synth_probe/comp_fbram.sv` → `fpga/rtl/comp_fbram.sv` (Task 0).
- **Modify** `fpga/rtl/comp_pipeline.sv` — add `fb_wr_*`/`fb_rd_*` ports; route mixer
  dst/result to them; delete `comp_dest_band`, the flush FIFO (`f_qw/f_be/f_idx`),
  `comp_burst` **write** path, and states `P_LOAD_*`/`P_FLUSH_*`/`P_WB_*`.
- **Modify** `fpga/rtl/blitter_top.sv` — thread `fb_*` ports out (mirror `p0_*`); `mem_*`
  dest-writeback usage removed.
- **Modify** `fpga/Solarus.sv` — instantiate `comp_fbram` (1 buffer); wire `blitter_top.fb_*`
  + reader scan-read to it; delete ch0/P_DST + ch4/P_SCAN cache wiring, `vram_demux` dest
  routing, FB coherency barriers.
- **Modify** `fpga/rtl/openbor_video_reader.sv` — line-fetch from `comp_fbram` (HBlank burst
  → `linebuf`) instead of the SDRAM read master; delete the SDRAM master + ch4 use.
- **Modify** `fpga/rtl/sdram_fb_cache.sv` — drop ch0/P_DST (r/w) + ch4/P_SCAN + `dst_barrier`
  + `INVAL_MASK0` + vsync ch0 flush; keep ch1 STAGE + ch5 P_SRC.
- **Modify** `fpga/rtl/vram_demux.sv` — remove the FB-region→SDRAM dest decode (dest no longer
  goes to SDRAM); non-FB DDR routing stays.
- **Create** `fpga/sim/tb_fbram.sv` — `comp_fbram` unit test.
- **Modify** `fpga/sim/tb_blitter_system_pipe.sv` — dest → `comp_fbram`, pixel-exact gate.
- **Modify** `fpga/sim/tb_profile.sv` — dest model → `comp_fbram`; confirm WB/LOAD→0.
- **Modify** `fpga/sim/tb_scanout_linebuf.sv` (or clone) — scanout sources `comp_fbram`.
- **Delete (end)** `synth_probe/`, `.github/workflows/synth-probe.yml` (throwaway probe).

---

## Phase A — sim bit-exact (correctness, no top/scanout/HW changes)

### Task 0: Promote `comp_fbram` to RTL + unit test

- [ ] **Step 1:** `git mv synth_probe/comp_fbram.sv fpga/rtl/comp_fbram.sv`. Strip the
  "TRIAL location" note; keep the param/port contract identical (trial-synthed at 160 M10K).
- [ ] **Step 2:** Create `fpga/sim/tb_fbram.sv` — write a known pattern (per-lane, per-qword),
  read it back, assert qword-exact; check a write to lane L does not disturb lanes ≠L; check
  the registered 1-cyc read latency. Add to `fpga/sim/run_sims.sh` as a GATING tb.
- [ ] **Step 3:** `cd fpga/sim && ./run_sims.sh tb_fbram` → `RESULT: PASS`. Commit.

### Task 1: `comp_pipeline` dest-port abstraction + bit-exact tb (TDD — capture the contract)

- [ ] **Step 1:** Add ports to `comp_pipeline` (unused yet): `fb_wr_en, fb_wr_qw[14:0],
  fb_wr_lane[1:0], fb_wr_pix[15:0]`, `fb_rd_en, fb_rd_qw[14:0]`, input `fb_rd_qword[63:0]`.
  Leave the internal band path intact for now (ports dangle).
- [ ] **Step 2:** Clone `tb_blitter_system_pipe.sv` → it instantiates `blitter_top`; add a
  `comp_fbram` wired to the (about-to-be-threaded) `fb_*` ports. For THIS task, since the
  cutover isn't done, the tb still validates the SDRAM golden — establish the golden capture:
  run COPY/ALPHA/ADD/MUL/colormod/PALPHA blits, snapshot the SDRAM-FB result as the reference
  array `gold[]`. Assert it matches the existing expected (regression guard, passes now).
- [ ] **Step 3:** Add the **failing** assertion that will pass after Task 2: read `comp_fbram`
  back and compare to `gold[]`. It FAILS now (fb_* not driven internally). Commit the tb
  (captures the contract; documents the FAIL).

### Task 2: `comp_pipeline` cutover (make the bit-exact tbs green) — DONE

Done as one atomic commit (backing-store swap must be atomic to keep every commit green).

- [x] **Step 1:** Mixer dst read: `s3_dst` ← `fb_rd_qword[s2_cw_x[1:0]]` (lane-select). `fb_rd_*`
  registered at ISSUE exactly like the old `db_rd_x`, so the 1-cycle `comp_fbram` read lands at
  T+2 aligned with the old band read. **Note:** drive `fb_rd_en` on EVERY issue (always read) —
  on-chip BRAM reads are free, and always-read removes the stale-lane failure mode. The
  `comp_opaque` read-skip is deferred to Task 5 (where the scanout read-port mux makes it matter).
- [x] **Step 2:** Mixer result write: on `mx_out_we`, `fb_wr_qw = cur_dst_y*80 + (x>>2)`,
  `fb_wr_lane = x[1:0]`, `fb_wr_pix = mx_out_pix`. `cur_dst_y` is constant per span (one span =
  one dst row) so dst_y need not be piped.
- [x] **Step 3:** Deleted `comp_dest_band u_band` (+ `comp_dest_band.sv` + `tb_comp_dest_band.sv`),
  the flush FIFO, the `comp_burst` instance + `mem_*` dest driving (tied `mem_*` idle), and states
  `P_LOAD_*`/`P_FLUSH_*`/`P_WB_*`. Kept the chunk loop as plain ≤16-row span grouping (no
  preload/flush). `comp_burst.sv` itself is now dead RTL but LEFT in place (still passes
  `tb_comp_burst`); its removal is a Task 3 cleanup.
- [x] **Step 4:** `mem_*` tied idle in `comp_pipeline` (ports kept; dropped in Task 3).
- [x] **Step 5 (the gate):** Bit-exact across COPY/ALPHA/KEY/PALPHA/FILL/HFLIP/TALL/SDRAM-COPY/
  ADD/MUL/colormod/coalesce — `tb_comp_pipeline` + all seven `tb_blitter_*_pipe` adapted to read
  `comp_fbram` (BG seeded directly, since CLEAR runs on the FSM `mem_*` path which no longer
  reaches the FB). **DEVIATION from plan:** the gate vehicle is `tb_comp_pipeline` (direct
  comp_pipeline, per-pixel goldens for all modes), NOT `tb_blitter_system_pipe`. The system tb is
  an integration test (CLEAR + `vram_demux`→SDRAM dest) and is DEFERRED to Task 4 (see below),
  along with `tb_comp_banding` (band/flush-path banding — premise deleted) and
  `tb_fbcopy_dst2src_sameframe` (FB→SDRAM-source carry-forward — unsupported by an on-chip FB; the
  engine does full-redraw, carryfwd=0). All three marked non-gating in `run_sims.sh` with TODOs.

### Task 3: `blitter_top` port threading + drop dest `mem_*`

- [ ] **Step 1:** Thread `comp_pipeline`'s `fb_*` ports out of `blitter_top` (new top-level
  ports), mirroring the existing `p0_*` plumbing.
- [ ] **Step 2:** `mem_*` now carries only ring/ctrl/clear/STAGE FSM traffic (the renderer no
  longer drives it). Simplify the `mem_*` mux: drop the `pipe_busy`-gated comp_pipeline dest
  path; `mem_*` = the `bm_*` FSM regs only. Keep `perf_*` counters.
- [ ] **Step 3:** `./run_sims.sh tb_blitter_system_pipe tb_fbram tb_blitter_system` → green
  (the system tb's ring/ctrl path unaffected). Commit.

---

## Phase B — integration (top-level, scanout, cache deletion)

### Task 4: `Solarus.sv` — instantiate `comp_fbram` + CLEAR-as-FILL — DONE (additive)

**DEVIATION (lower-risk additive integration):** rather than DELETE the FB cache/coherency
simultaneously with wiring `comp_fbram` in (a big, HW-only-validated teardown), `comp_fbram` is
wired in as the LIVE FB while the now-dead ch0/ch4 cache + `dst_barrier` coherency are kept
instantiated-but-idle. Their deletion (reclaiming M10K to ~244–404/553) is a follow-up cleanup,
once the new datapath is HW-proven. Budget tolerates both (~462/553 worst-case, feasible).

- [x] **Step 1:** `comp_fbram` (1W2R) instantiated in `Solarus.sv`; `blitter_top.fb_*` →
  composite port; scanout reader → scan port via `fbram_scan_adapter`.
- [~] **Step 2 (deferred cleanup):** ch0/P_DST cache + `vram_demux` SDRAM dest decode are now
  DEAD but still instantiated. Blitter ring/ctrl/STAGE/VCTRL still reach DDR/SDRAM via `bm_*`
  (unchanged). The DDR frame-sync (VCTRL/frame_counter) path is preserved.
- [~] **Step 3 (deferred cleanup):** ch4/P_SCAN tied dead. `dst_barrier`/vsync-ch0-flush kept
  (harmless on dead channels; the engine does full-redraw so `dst_barrier`/F_SRC_FB never fires).
- [x] **Step 4:** Full sim suite gating-green. (Whole-core elaboration is the Quartus RBF build,
  Task 7 — iverilog can't elaborate `Solarus.sv` standalone: `pll_0002`/`lcell`/`cos.sv`.)
- [x] **Step 5 — CLEAR routing DECIDED + done:** CLEAR-before-list now dispatches a full-screen
  FILL(clear_color) through `comp_pipeline` → `comp_fbram` (`blitter_top` states `S_CLR_FILL`/
  `S_CLR_FILL_WAIT`; the old `bm_*` SDRAM clear loop `S_CLR_WR` is dead). Gated by new
  `tb_blitter_clear_pipe` (CLEAR-only + CLEAR+FILL, pixel-exact). The three deferred system/
  banding/carry-forward TBs remain non-gating (full system-tb re-gate is follow-up cleanup;
  carry-forward `tb_fbcopy_dst2src_sameframe` is structurally retired — on-chip FB ≠ SDRAM source).

### Task 5: scanout reads `comp_fbram` — DONE

- [x] **Step 1:** Reader keeps its proven P_SCAN protocol; `fbram_scan_adapter` bridges it to
  `comp_fbram`'s 1-cycle scan port (2nd read port via bank replication). One-line reader change:
  single-buffer addressing (`buf_base=0`), so `scan_addr[17:3]` = the comp_fbram qword.
- [x] **Step 2:** `tb_scanout_fbram` drives the REAL `openbor_video_reader` + adapter +
  `comp_fbram`; pixel-exact scanout across frames. GATING.
- [x] **Step 3:** PASS. (`tb_scanout_sdram` + `tb_scan_qworddup` retired — they tested the
  retired SDRAM scanout path / #44 DQ-capture seam, which FB-in-BRAM eliminates.)

### Task 6: sim regression + profiler confirmation

- [ ] **Step 1:** Re-point `tb_profile.sv`'s dest model to `comp_fbram`; run the profiler.
  Confirm WB/LOAD buckets → ~0 and cyc/px → the SRCFILL/comp floor (~1.5 COPY, ~1.0 FILL).
  Record numbers (this is the predicted-win confirmation, sim-side).
- [ ] **Step 2:** Full `./run_sims.sh` — all GATING green (esp. `tb_vram_contention`,
  `tb_blitter_system`, the v2 escape-elim equivalence tbs). Commit any tb adaptations.

---

## Phase C — build + HW (manual, gated — do NOT auto-run)

### Task 7: RBF build + STA slack gate

- [ ] **Step 1:** Push `fpga/**` → CI (`build-rbf.yml`). Download `quartus-reports`.
- [ ] **Step 2:** **STA gate (the real timing risk):** check `Solarus.sta.summary` clk_sys
  (`general[0]…divclk`) slack ≥ 0. The new `fb_rd_qword → mixer` path under full routing is the
  concern (probe was +1.7 ns in isolation; core baseline is +0.286 ns). If negative, pipeline
  the FB-read→mixer (add a register stage, adjust mixer feed latency — same technique as the
  colormod s3 split) and re-confirm bit-exact in sim. Check M10K total ≈ 244/553.

### Task 8: HW single-buffer validation (hands-on)

- [ ] **Step 1:** Deploy RBF + engine (`./deploy.py`; refresh `deploy/` from `build/armhf`
  first). Activate: `echo "load_core …Solarus_YYYYMMDD.rbf" > /dev/MiSTer_cmd`. **User relaunches**
  the engine (ssh-launch dies on disconnect — [[solarus-ssh-launch-dies-on-disconnect]]).
- [ ] **Step 2:** Expect: **static screens (title/menu) clean**; **motion tears** (single-buffer,
  by design — not a bug). Screenshot via `echo screenshot > /dev/MiSTer_cmd`.
- [ ] **Step 3:** Read perf counters (devmem `0x3B00002C`/`0x3B000034`): confirm WB/LOAD gone
  (compositor cyc/frame dropped toward the SRCFILL floor) and fps up on heavy overworld.

### Task 9: docs + memory + cleanup

- [ ] **Step 1:** Update `docs/frame-dataflow.md` (FB now on-chip BRAM; scanout reads it;
  no FB SDRAM/cache/coherency). Flip the sketch spec status to IMPLEMENTED (single-buffer).
- [ ] **Step 2:** Update memory `fpga-fb-in-bram-feasibility` with the HW result + sim cyc/px.
- [ ] **Step 3:** Delete the throwaway probe: `synth_probe/`, `.github/workflows/synth-probe.yml`.
- [ ] **Step 4:** Commit.

---

## Follow-up (separate plan): double-buffer

Add a 2nd `comp_fbram` (~+160 M10K → ~404/553, fits); `target_buf^=1`, publish-on-present
(reuse C_TARGET logic); carry-forward = BRAM→BRAM frame-start copy. Restores tear-free
variable-fps decoupling. Gate: it must not regress the single-buffer STA slack.

## Self-review notes

- **Cut point is the mixer boundary** (`mx_in_dst`/`mx_out_pix`) — Tasks 1–2 localize the risk
  there; the bit-exact gate (Task 2 Step 5) catches any lane/addr/latency error before HW.
- **Opaque-skip reuse** makes the 2-port M10K sufficient (COPY = write-only; ALPHA read on
  Port B, scanout confined to HBlank) — no 3rd port needed unless Task 6/STA shows contention.
- **Coherency deletion is the robustness payoff** — Task 4 Step 3 removes the exact machinery
  behind the #39/#40/#44 wedge class; sources keep their own STAGE/P_SRC coherency.
- **Timing is the one open HW risk** — Task 7 Step 2 has the explicit fallback (pipeline the
  FB-read→mixer, bit-exact re-check). The probe proved the RAM access itself is not the wall.
- **Single-buffer tearing is by design** — Task 8 expects it; do not "fix" it, ship the 2nd
  buffer (follow-up) instead.
