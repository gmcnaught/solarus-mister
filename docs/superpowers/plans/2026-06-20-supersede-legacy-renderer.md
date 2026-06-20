# Supersede the Legacy Renderer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the legacy per-pixel renderer in `blitter_top.sv` so `comp_pipeline` is the sole render datapath, performed as the resolution of the in-progress #35 merge.

**Architecture:** Delete the legacy FSM render states, src/dst caches, and the SDRAM-source read path + its owner mux from `blitter_top.sv`; route FILL/BLIT unconditionally to `comp_pipeline`; keep the command ring, screen-clear, atlas-STAGE, vctrl/status, the mem_\* owner mux, and the bus-helper/throttle states. Remove the legacy-render testbenches (each has a `_pipe` twin). Commit as one merge commit that also lands #34/#35 shared-module fixes.

**Tech Stack:** SystemVerilog (Cyclone V), iverilog sim via `fpga/sim/run_sims.sh`, Quartus fit/STA via CI (`build-rbf.yml`).

## Global Constraints

- One always-block per reg/array (Quartus Error 10028); iverilog won't catch it.
- Quartus synth/STA is CI-only — arm64 host cannot run x86 Quartus. Local gate is iverilog `run_sims.sh`.
- Discipline is **zero regression in the retained suite**: deletion + routing simplification only, no new render behavior. Verify retained sims green after each cut.
- Commit bodies end with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and the `Claude-Session:` line.
- This is a merge resolution: the final commit finalizes the in-progress #35 merge (no conflict markers, `git add` the resolved files).

## File Structure

- `fpga/rtl/blitter_top.sv` — MODIFY: delete legacy render path; unconditional comp_pipeline routing; collapse src-read owner mux.
- `fpga/rtl/vram_demux.sv` — KEEP as-resolved (#34-base + multi-beat read FSM + `dbg`); already conflict-free in tree.
- `fpga/sim/run_sims.sh` — MODIFY: drop removed benches.
- `fpga/sim/tb_blitter_{copy,blend,coalesce,palpha,system,rd_desync,src_hold}.sv` — DELETE.
- `docs/superpowers/specs/2026-06-20-supersede-legacy-renderer-design.md` — already written; commit with merge.

---

### Task 1: Establish the pre-cut sim baseline

**Files:**
- Test: `fpga/sim/run_sims.sh`

**Interfaces:**
- Produces: a known-good list of which retained benches pass now (so regressions are attributable to the cut, not pre-existing).

- [ ] **Step 1: Run the full retained suite, expect only legacy benches red**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: all `_pipe`, `tb_comp_*`, `tb_capture_race`, `tb_vram_demux`, `tb_demux_preempt`, `tb_sdram_*`, arb/scanout PASS; `tb_blitter_system` and `tb_blitter_rd_desync` (in the removal set) may FAIL. Record the pass set.

---

### Task 2: Delete the legacy render path from `blitter_top.sv`

**Files:**
- Modify: `fpga/rtl/blitter_top.sv`

**Interfaces:**
- Consumes: `comp_pipeline` instance (`u_pipe`), `pipe_start`/`pipe_busy`/`p_blit_done`, `p_mem_*`, `p_src_sdram_*`, the mem_\* owner mux.
- Produces: a `blitter_top` whose only render path is `comp_pipeline`; FILL/BLIT route via `pipe_start`→`S_PIPE_WAIT`; `src_sdram_addr/rd` driven directly by `p_src_sdram_*`.

- [ ] **Step 1: Remove the legacy `S_SETUP` else-branch; make routing unconditional**

In `S_SETUP`, replace the `else if (pipe_en) … else (legacy setup)` block so that after the `empty` check, FILL/BLIT always do `pipe_start <= 1'b1; state <= S_PIPE_WAIT;`. Delete the legacy `else` arm (`x0r/y0r/x1r/y1r/dx/dy/is_fill/src_x0s/src_y0s/dst_cache_*` loads and `state<=(OP_FILL)?S_FILL_WR:S_BSETUP`). Remove `pipe_en` reg + its `C_PIPE` decode in `S_GOT_FLAGS`.

- [ ] **Step 2: Delete legacy render state arms**

Delete the case arms for `S_FILL_WR`, `S_BSETUP`, `S_BLIT_RDSRC`, `S_BLIT_GOTSRC`, `S_BLIT_RDDST`, `S_BLIT_GOTDST`, `S_BLIT_WR`, `S_BLIT_BLEND2`, `S_PIX_ADV`, `S_DST_FLUSH`, `S_DST_RDISS`, `S_ADV_FLUSH`, `S_SRC_SDRAM_WAIT`. Remove their localparam declarations. Keep `S_RD_WAIT`, `S_WR_WAIT`, `S_WR_THROTTLE`, `S_CLR_WR`, `S_GOT_CLEAR`, `S_STAGE_*`, ring/decode/vctrl/status states.

- [ ] **Step 3: Delete legacy datapath regs**

Remove declarations + all assignments of: `src_cache_data/qw/vld/hit`-family, `dst_cache_*`, `dx`, `dy`, `x0r`, `y0r`, `x1r`, `y1r`, `src_x0s`, `src_y0s`, `src_row_byte`, `src_byte_cur`, `is_fill`, `wr_pix`, `src_from_cache`, `l_src_sdram_addr`, `l_src_sdram_rd`. Keep `clr_idx`, `clear_color`, `throttle_cnt`, `rd_ret`, `wr_ret`, STAGE regs, `bm_*`.

- [ ] **Step 4: Collapse the src-read owner mux**

Replace `assign src_sdram_addr = pipe_busy ? p_src_sdram_addr : l_src_sdram_addr;` (and `_rd`) with `assign src_sdram_addr = p_src_sdram_addr;` / `assign src_sdram_rd = p_src_sdram_rd;`. Leave the mem_\* owner mux unchanged (`mem_* = pipe_busy ? p_* : bm_*`, `mem_burstcnt = pipe_busy ? p_mem_burstcnt : 8'd1`).

- [ ] **Step 5: Lint-compile blitter_top in isolation**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/blt_lint.vvp -I ../rtl ../rtl/blitter_top.sv ../rtl/comp_*.sv ../rtl/vram_demux.sv ../rtl/sdram_*.sv 2>&1 | head -40`
Expected: no errors for undeclared identifiers (any remaining reference to a deleted reg/state shows here). Fix any dangling references. (If extra deps are missing, prefer running the compositor bench in Step 6 instead.)

- [ ] **Step 6: Run the compositor + system_pipe benches**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system_pipe tb_blitter_copy_pipe tb_blitter_blend_pipe tb_blitter_coalesce_pipe tb_blitter_palpha_pipe tb_comp_pipeline tb_capture_race`
Expected: all PASS (compositor render unchanged; routing now unconditional). If `run_sims.sh` takes no args, run the full suite and confirm these PASS.

- [ ] **Step 7: Stage blitter_top (do NOT commit yet — merge finalized in Task 4)**

Run: `git add fpga/rtl/blitter_top.sv`

---

### Task 3: Remove legacy testbenches and prune the runner

**Files:**
- Delete: `fpga/sim/tb_blitter_copy.sv`, `tb_blitter_blend.sv`, `tb_blitter_coalesce.sv`, `tb_blitter_palpha.sv`, `tb_blitter_system.sv`, `tb_blitter_rd_desync.sv`, `tb_blitter_src_hold.sv`
- Modify: `fpga/sim/run_sims.sh`

**Interfaces:**
- Consumes: the `_pipe` twins remain as coverage for each removed bench.
- Produces: a runner listing only retained benches; no reference to removed files.

- [ ] **Step 1: Delete the legacy benches**

Run:
```bash
cd fpga/sim
git rm tb_blitter_copy.sv tb_blitter_blend.sv tb_blitter_coalesce.sv \
       tb_blitter_palpha.sv tb_blitter_system.sv tb_blitter_rd_desync.sv \
       tb_blitter_src_hold.sv
```
(`tb_blitter_rd_desync.sv` / `tb_capture_race.sv` had un-staged edits — `git rm` the desync one; keep capture_race.)

- [ ] **Step 2: Prune `run_sims.sh`**

Remove `tb_blitter_system` and `tb_blitter_rd_desync` from the bench list in `fpga/sim/run_sims.sh`. Confirm `tb_blitter_system_pipe` is present. Grep to be sure nothing else references a removed bench: `grep -nE "tb_blitter_(copy|blend|coalesce|palpha|system|rd_desync|src_hold)\b" run_sims.sh` (excluding `_pipe`) → no matches.

- [ ] **Step 3: Run the full retained suite**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: ALL listed benches PASS; no "file not found" for removed benches.

- [ ] **Step 4: Stage the runner change**

Run: `git add fpga/sim/run_sims.sh` (the `git rm` already staged the deletions).

---

### Task 4: Finalize the merge commit

**Files:**
- All staged: `blitter_top.sv`, `vram_demux.sv`, test deletions, `run_sims.sh`, spec/plan docs, and the rest of the in-progress merge.

**Interfaces:**
- Produces: a single merge commit on `spec/pipelined-compositor` integrating #34/#35 shared-module fixes + the supersede.

- [ ] **Step 1: Stage remaining resolved/merge files**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor
git add fpga/rtl/vram_demux.sv fpga/sim/tb_capture_race.sv fpga/sim/tb_vram_demux.sv
git add docs/superpowers/specs/2026-06-20-supersede-legacy-renderer-design.md
git add docs/superpowers/plans/2026-06-20-supersede-legacy-renderer.md
```

- [ ] **Step 2: Verify no conflict markers, no unmerged paths remain**

Run: `grep -rnE "^(<<<<<<<|=======|>>>>>>>)" fpga/ ; git diff --name-only --diff-filter=U`
Expected: no output from either (all conflicts resolved).

- [ ] **Step 3: Final full sim run (gate before commit)**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: ALL PASS.

- [ ] **Step 4: Commit the merge**

Run:
```bash
git commit
```
Message:
```
Merge #35; supersede legacy renderer (comp_pipeline sole render path)

Resolve the #35 merge by retiring the legacy per-pixel renderer:
delete S_BLIT_*/S_FILL_WR/S_SRC_SDRAM_WAIT + src/dst caches + the
src-read owner mux from blitter_top; route all FILL/BLIT to
comp_pipeline unconditionally. Keep ring/decode/STAGE/screen-clear/
vctrl, the mem_* owner mux, throttle, and #34/#35 shared-module fixes
(sdram_src_arb held_txn, sdram_psx phase capture, vram_demux multi-beat).
Remove legacy-render benches (each has a _pipe twin); the two formerly
red legacy tests are in the removed set so the suite goes green.

Risk: comp_pipeline is sim-proven but not yet silicon-validated; HW
bring-up is the immediate follow-on. See
docs/superpowers/specs/2026-06-20-supersede-legacy-renderer-design.md.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpTCVxaYXyhnSKcHFkuMky
```

- [ ] **Step 5: Push to trigger CI fit/STA**

Run: `git push origin spec/pipelined-compositor`
Expected: push succeeds; `build-rbf.yml` (Quartus) + `sim.yml` (iverilog) trigger. Confirm the RBF fits and STA is clean from CI artifacts (cannot verify locally on arm64).

---

## Self-Review

**Spec coverage:** Deleted-list (Task 2 steps 1–4) = spec "Deleted" section. Kept-list verified by not touching those states + Step-6/full-suite passes = spec "Kept" section. Test removal (Task 3) = spec "Tests/Removed". Runner prune + green suite = "Tests/Kept". Merge commit (Task 4) = "Merge mechanics" + acceptance criteria 1–4. CI push (Task 4 Step 5) = acceptance criterion 5. Risk recorded in spec + commit body.

**Placeholder scan:** none — exact states, regs, file paths, and commands given.

**Type/name consistency:** `pipe_start`/`pipe_busy`/`p_blit_done`/`p_src_sdram_*`/`p_mem_*` match `blitter_top.sv` (verified lines 781–825). State names match the localparam block (lines 87–110). Bench names match `ls fpga/sim`.
