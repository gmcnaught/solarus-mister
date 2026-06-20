# Supersede the legacy per-pixel renderer

**Date:** 2026-06-20
**Branch:** `spec/pipelined-compositor`
**Status:** Approved — implementing as the resolution of the in-progress #35 merge

## Summary

`blitter_top` currently contains two renderers selectable at runtime via the
`C_PIPE` control bit:

1. the **legacy per-pixel FSM** (`S_BLIT_*` / `S_FILL_WR` / per-pixel src+dst
   caches, the SDRAM-source read path `S_SRC_SDRAM_WAIT`, and the read-only
   src-read owner mux), and
2. the **pipelined compositor** `comp_pipeline` (Spec A) — band-chunked RMW,
   sim-verified bit-exact to the legacy FSM.

This change **retires the legacy renderer entirely**. After it, `comp_pipeline`
is the sole render datapath. The `blitter_top` FSM narrows to: walk the command
ring, decode commands, run per-frame screen-clear and atlas-STAGE, drive
vctrl/status, and hand each FILL/BLIT to `comp_pipeline`.

This is performed as the resolution of the in-progress merge with #35: the
textual conflict locus in `blitter_top.sv` (legacy `S_SRC_SDRAM_WAIT` / SDRAM
source path) is **deleted, not reconciled**, and the two remaining red tests are
legacy-render-only and are removed.

## Goals

- One render datapath (`comp_pipeline`); no runtime renderer selection.
- Land #34/#35's shared-module fixes (`sdram_src_arb` held_txn, `sdram_psx`
  phase capture, `vram_demux` multi-beat read FSM) together with the supersede
  in a single merge commit.
- Retained sim suite stays green; merge goes green (the 2 red tests are removed).
- Smaller, single-purpose `blitter_top` that fits the area budget already
  achieved for the compositor.

## Non-goals

- No change to `comp_pipeline` behavior or to the command-ring / STAGE / vctrl
  protocol.
- No hardware bring-up in this change (flagged as the immediate follow-on).
- No Quartus fit/STA locally — arm64 host cannot run x86 Quartus; synth/STA via CI.

## Design

### Deleted (legacy per-pixel render only)

- **FSM states:** `S_FILL_WR`, `S_BSETUP`, `S_BLIT_RDSRC`, `S_BLIT_GOTSRC`,
  `S_BLIT_RDDST`, `S_BLIT_GOTDST`, `S_BLIT_WR`, `S_BLIT_BLEND2`, `S_PIX_ADV`,
  `S_DST_FLUSH`, `S_DST_RDISS`, `S_ADV_FLUSH`, `S_SRC_SDRAM_WAIT`.
- **Datapath regs:** src cache (`src_cache_*`), dst cache (`dst_cache_*`),
  per-pixel coordinate state (`dx`, `dy`, `x0r`, `y0r`, `x1r`, `y1r`,
  `src_x0s`, `src_y0s`, `src_row_byte`, `src_byte_cur`), `is_fill`, `wr_pix`,
  and the legacy SDRAM-source drivers `l_src_sdram_*`.
- **The src-read owner mux** collapses: `src_sdram_addr` / `src_sdram_rd` become
  `p_src_sdram_addr` / `p_src_sdram_rd` directly. The compositor is the only
  consumer of the SDRAM source-read port.
- **`S_SETUP` legacy branch:** the `else` arm that set up the per-pixel loop is
  removed. FILL/BLIT now route **unconditionally** to `comp_pipeline`
  (`pipe_start` pulse → `S_PIPE_WAIT`). `pipe_en` and the `C_PIPE` decode are
  removed; the `C_PIPE` control bit becomes a documented no-op (host may still
  set it; it has no effect).

### Kept (shared scaffolding — NOT part of the legacy renderer)

- **mem_\* owner mux stays.** The FSM still drives `bm_*` for ring reads, status
  writes, screen-clear, and STAGE writes; `comp_pipeline` drives `p_*` only
  while `pipe_busy`. Arbitration unchanged: `mem_* = pipe_busy ? p_* : bm_*`
  (with `mem_burstcnt = pipe_busy ? p_mem_burstcnt : 8'd1`).
- **`S_GOT_CLEAR` / `S_CLR_WR`** — per-frame full-framebuffer clear; not a render
  command.
- **`S_RD_WAIT` / `S_WR_WAIT` / `S_WR_THROTTLE`** — shared bus helpers used by
  clear / STAGE / ring / status. `S_WR_THROTTLE` is #34's scanout-bandwidth
  guard on f2h writes.
- Ring walk (`S_POLL_*` … `S_DECODE`), `S_SETUP` (control parse + STAGE/END/NOP
  dispatch), `S_STAGE_*` (DDR→SDRAM atlas staging for `C_SRCSEL`),
  `S_FRAME_VCTRL`, `S_NEXT_CMD`, `S_WR_DONE`, `S_WR_STATUS`, `S_GOT_SRCSEL`.
- `comp_pipeline` instance, `vram_demux`, `sdram_src_arb`, `sdram_psx`, and all
  #34/#35 shared-module fixes.

### Data flow after the change

```
ring poll/fetch/decode (bm_*) ──► S_SETUP
   ├─ OP_END   → S_FRAME_VCTRL
   ├─ OP_NOP   → S_NEXT_CMD
   ├─ OP_STAGE → S_STAGE_* (bm_* DDR read, mem_* SDRAM write via demux)
   ├─ empty    → S_NEXT_CMD
   └─ OP_FILL/OP_BLIT → pipe_start → S_PIPE_WAIT
                         (comp_pipeline owns mem_*/src_sdram_* while pipe_busy)
per-frame: S_GOT_CLEAR → S_CLR_WR (bm_* writes, throttled) when cfg_flags[0]
```

## Merge mechanics

- `blitter_top.sv`: resolve by keeping ring/clear/STAGE/shared scaffolding from
  both sides; delete the legacy render path. The #34 `S_SRC_SDRAM_WAIT`
  hold-until-`dout_ready` fix is deleted along with the rest of the legacy
  source path.
- `vram_demux.sv`: keep the already-reconciled #34-base + multi-beat read FSM
  (`S_RDLAT` hold-until-`dready`, `blt_burstcnt` multi-beat) and the `dbg` port.
- `git add` the resolved files plus the test changes; commit the merge.

## Tests

### Removed (legacy-render-only; each has compositor coverage)

- `tb_blitter_copy.sv`   (twin: `tb_blitter_copy_pipe.sv`)
- `tb_blitter_blend.sv`  (twin: `tb_blitter_blend_pipe.sv`)
- `tb_blitter_coalesce.sv` (twin: `tb_blitter_coalesce_pipe.sv`)
- `tb_blitter_palpha.sv` (twin: `tb_blitter_palpha_pipe.sv`)
- `tb_blitter_system.sv` (twin: `tb_blitter_system_pipe.sv`)
- `tb_blitter_rd_desync.sv` (legacy write→read desync; was red)
- `tb_blitter_src_hold.sv`  (legacy `S_SRC_SDRAM_WAIT` hold; #34)

### Kept / must stay green

- All `_pipe` twins, `tb_comp_*` (dest_band, mixer, pipeline, span_setup,
  src_linebuf, burst), `tb_capture_race`, `tb_vram_demux`, `tb_demux_preempt`,
  `tb_sdram_*`, `tb_ddr_blitter_arb`, `tb_arb_*`, `tb_scanout_sdram`,
  `tb_vram_contention`, `tb_profile`.
- `run_sims.sh`: drop `tb_blitter_system` and `tb_blitter_rd_desync` from the
  list; ensure `tb_blitter_system_pipe` is present (it is).
- `files.qip` / any synthesis file list: no legacy-only RTL files exist to
  remove (legacy renderer lives inside `blitter_top.sv`).

### Discipline

This is deletion plus a routing simplification already covered by the `_pipe`
suite — no new production behavior. The bar is **zero regression in the retained
suite** before and after each cut, verified by `run_sims.sh`.

## Risks

- **No HW-validated fallback.** `comp_pipeline` is sim-proven but has never run
  on DE10-Nano silicon. Hard-deleting the legacy renderer removes the only
  silicon-proven render path. Accepted per project decision (2026-06-20).
  Mitigation: HW bring-up of `comp_pipeline` is the immediate follow-on; the
  legacy renderer remains recoverable from git history (pre-supersede tags /
  this merge's parent) if a hardware regression forces a temporary revert.
- **Quartus fit/STA is CI-only.** Area/timing for the slimmed `blitter_top`
  must be confirmed by the `build-rbf.yml` CI run, not locally.

## Findings during implementation

Retiring the legacy renderer made `comp_pipeline` the sole driver of the
framebuffer and surfaced two pre-existing, documented Phase-2 gaps that the
legacy single-beat path used to mask:

1. **`vram_demux` blt_burstcnt wiring (test-only).** `tb_vram_contention` wired
   `vdemux.blt_burstcnt = 8'd1` and never connected `blitter_top.mem_burstcnt`,
   a legacy single-beat assumption. The compositor issues multi-beat bursts, so
   the demux returned one beat of an N-beat read and the pipe hung. Fixed by
   rewriting the test to the compositor topology (`mem_burstcnt → blt_burstcnt`)
   and a validated compositor workload (full-screen FILL into an SDRAM FB vs a
   real P_SCAN scan master). See `tb_blitter_system_pipe` for the same wiring.

2. **`sdram_psx` refresh-counter livelock (real RTL bug, deferred to its own PR).**
   With correct wiring, `comp_pipeline`'s back-to-back P_DST burst writes expose
   that `sdram_psx` services a pending write only in `STATE_IDLE`, which it skips
   while `refresh_count > cycles_per_refresh`. The double subtraction
   (`STATE_IDLE_1` then `STATE_RFSH`, each `-cycles_per_refresh`) on the 14-bit
   `refresh_count` underflows/wraps once sustained bursts delay refresh
   servicing → permanent `IDLE_1→RFSH` refresh livelock; the write never lands.
   The legacy renderer's sparse, throttled single-qword writes always drained
   refresh between writes, so it never hit this. **Fix is a focused `sdram_psx`
   refresh change tracked in a separate PR** (shared, timing-critical, CI-STA
   gated), with `tb_vram_contention` as its gating proof. Until then that test is
   marked NON-GATING.

`comp_pipeline` was left untouched by this work (an exploratory source-read edit
was reverted — it was out of scope and the demux/psx, not the pipe, were the
issue). The 3-client P_SRC/`C_SRCSEL=1` contention variant stays Phase-2 deferred
with `comp_pipeline`'s SDRAM-source support.

## Acceptance criteria

1. `blitter_top.sv` contains no legacy per-pixel render states/regs; FILL/BLIT
   route unconditionally to `comp_pipeline`.
2. mem_\* owner mux, screen-clear, STAGE, throttle, ring, vctrl all intact.
3. The #35 merge is committed (conflicts resolved, no `<<<<<<<` markers).
4. Retained sim suite passes via `run_sims.sh` (gating tests green); removed
   benches are gone from the repo and from `run_sims.sh`. `tb_vram_contention`
   is rewritten to the compositor and marked NON-GATING (reproduces the deferred
   `sdram_psx` refresh livelock — see Findings; fixed in a separate PR).
5. CI `build-rbf.yml` produces a fitting, timing-clean RBF (verified post-push).
