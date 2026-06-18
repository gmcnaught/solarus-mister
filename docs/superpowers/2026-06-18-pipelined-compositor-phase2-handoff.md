# Pipelined Compositor — Phase 2 Handoff

> **Audience:** a fresh agent starting Phase 2 with no prior context. Read this top to bottom
> first. It is self-contained; the "Authoritative artifacts" section points to the full detail.

## 0. TL;DR

Phase 1 (a streaming, issue-interval-1 2D compositor that offloads the MiSTer blitter's
per-pixel work, selectable behind a `C_PIPE` control bit, **bit-exact** to the legacy path) is
**done and reviewed** on branch `spec/pipelined-compositor`. Phase 2 must make it actually
**fast and complete on real hardware**: add a burst memory engine, add SDRAM source/dest
support, close timing in Quartus, and validate on the DE10-Nano. **Start Phase 2 with a fresh
brainstorm → spec → plan** (the original plan's Phase-2 tasks are a starting point but the
scope has grown — see §5).

## 1. Why this project exists

The Solarus (and later gmloader/OpenBOR) MiSTer port offloads 2D compositing from the Cortex-A9
to a CV1000-style fabric blitter. On the heavy overworld the **fabric is the bottleneck**:
~10.5 Mpix/s, ~44 ms/frame (6× overdraw), because the blitter (`fpga/rtl/blitter_top.sv`) is a
**multi-cycle per-pixel FSM** (~7–10 cyc/px). The Beasley et al. 2020 paper's transferable lever
is an **issue-interval-1 pipelined compositor** (1 px/clock; ~179 Mpix/s on the same Cyclone V).
Phase 1 built that compositor; Phase 2 makes its throughput real (it is memory-bound until
bursts land) and brings it to feature-parity for the live workload.

Full rationale: `docs/superpowers/specs/2026-06-17-pipelined-compositor-design.md` (Spec A).

## 2. Where everything lives

- **Branch:** `spec/pipelined-compositor`, checked out in the git worktree
  `.claude/worktrees/pipelined-compositor/`. The **main checkout is on
  `feature-sdram-64mb-geometry` and must stay undisturbed** — do Phase 2 work in this worktree.
- **Design spec (Spec A):** `docs/superpowers/specs/2026-06-17-pipelined-compositor-design.md`
- **Implementation plan (with an "Execution status" addendum):**
  `docs/superpowers/plans/2026-06-17-pipelined-compositor.md`
- **Durable progress ledger (READ THIS):** `.git/sdd/progress.md` — the `PCOMP` section has the
  per-task history, decisions, deferrals, root causes, and carried minor findings. (Note: the
  same file also contains an older unrelated "VRAM relocation" effort above the PCOMP section.)
- **Per-task briefs/reports/review diffs:** `.git/sdd/pcomp/` (`task-N-report.md`, etc.).
- **The paper:** `../../openGL-FPGA/reference/3410357.md` (relative to repo root may differ; it's
  the Beasley ACM TRETS 2020 GPU-on-FPGA paper).

## 3. What Phase 1 delivered (the code you build on)

New RTL in `fpga/rtl/`, all selectable behind `C_PIPE`; tests in `fpga/sim/`.

| Module | Responsibility | Key facts |
|---|---|---|
| `comp_defs.vh` | shared params + `COMP_DIV255` macro | `COMP_BAND_H=16`; modes COPY/KEY/CA/PA |
| `comp_mixer.sv` | issue-interval-1 blend: (src,dst,params)→pixel, 1/clk | **LAT=3** (3 registered stages); bit-exact divide-free /255 |
| `comp_src_linebuf.sv` | on-chip source row; flip-aware texel serve | 1-cycle read latency; **serve_hflip is held 0** (see below) |
| `comp_dest_band.sv` | full-width band 320×`BAND_H` (16) rows | RMW serve (`rd_*`), coalesced writes (`cw_*`), flush dirty qwords (`fl_*`); `\`include`s comp_defs.vh |
| `comp_span_setup.sv` | per-blit clip/flip → row spans | reproduces `blitter_top.sv` clip math; **omits c_src_x/c_src_y** (origin 0) |
| `comp_pipeline.sv` | per-blit band-chunked RMW; ties the four together | FSM: P_IDLE→P_CHUNK_INIT→P_LOAD→P_COMP/P_PIXEL→P_FLUSH→P_WB→P_DONE |
| `blitter_top.sv` (mod) | routes FILL/BLIT to `comp_pipeline` when `pipe_en` | `mem_*` owner-muxed: `bm_*` (FSM) vs `p_*` (pipe), gated by `pipe_busy` |

**Architecture = per-blit, band-chunked RMW** (user-chosen). One blit at a time; a blit taller
than `BAND_H`=16 rows loops in ≤16-row chunks: per chunk **LOAD** the framebuffer rows from DDR
into `comp_dest_band` → **COMPOSITE** (span_setup → src_linebuf → mixer; dst from the band) →
**FLUSH** dirty qwords back to DDR. Painter order across blits is preserved via the DDR
round-trip. FILL writes `c_color` with no source/blend.

**Two correctness invariants to preserve:**
- **hflip is applied exactly once** — in `comp_pipeline`'s source-fetch `serve_x` cursor
  (`c_src_x + span_src_x0`, walked ±1); `comp_src_linebuf.serve_hflip` is hardwired 0. Do NOT
  also flip in the linebuf.
- **`c_src_x`/`c_src_y` are added in `comp_pipeline`'s source addressing**
  (`src_byte = c_src_off + (c_src_y+span_src_y)*stride + (c_src_x+span_src_x0±k)*2`), because
  `comp_span_setup` deliberately omits them.

**`C_PIPE` selector (a plan correction):** the original plan said `C_PIPE = 29'd8`, but offset 8
from `BLTCTRL_QW` is the **first command-ring word** (`RING_QW = BLTCTRL_QW + 8`). C_PIPE is
therefore carried in a **spare bit of the C_SRCSEL control word (offset 7), bit 1**
(`C_PIPE = 29'd7`, `C_PIPE_BIT = 1`; C_SRCSEL uses bit 0). `pipe_en = word[1]`. With `pipe_en=0`
the path is **byte-identical** to the shipping FSM (verified).

**Verified (all green):** `tb_comp_pipeline` (COPY/ALPHA/KEY/PALPHA/FILL/HFLIP + **tall 2-chunk**
COPY + painter order), four C_PIPE=1 equivalence variants (`tb_blitter_{copy,blend,coalesce,
palpha}_pipe`) **bit-exact** vs golden, `tb_blitter_system_pipe` PHASE1 (single FILL through the
full arbiter+vram_demux+SDRAM-dest system with a concurrent reader), and **no regression** to the
legacy C_PIPE=0 suite (`tb_blitter_*`, `tb_blitter_system`).

## 4. How to build & test (do this first to confirm a green baseline)

- Toolchain: Icarus Verilog 13 + `vvp` (installed); Quartus Prime **17.0.x** for synthesis.
- Run one testbench: `cd fpga/sim && ./run_sims.sh <tb_name>` → PASS prints `RESULT: PASS`;
  failure prints `BUILD!` or any of `FAIL|Assertion failed|DEADLOCK|STARV|WEDGE|TIMEOUT`.
- The runner uses iverilog **`-y` library mode** (module name == file name; no file lists).
- `tb_profile` is a benchmark (SKIP in the gating suite); run it directly.
- **Toolchain gotchas (already hit — don't relearn the hard way):**
  - In `-y` mode all files share one compilation unit; if a testbench `\`include`s a guarded
    header first, a library RTL file's own `\`include` is skipped → macros can appear undefined.
    Mitigation used: RTL files `\`include "comp_defs.vh"` AND keep an `\`ifndef` fallback; the
    `COMP_DIV255` macro is inlined in `comp_mixer` with a "must stay bit-identical (contract)"
    comment because it could not be referenced in `-y` mode.
  - Icarus 13 rejects **unsized integer arithmetic inside concatenations** — add `N'(...)` casts.
  - The `comp_*` family uses `initial` blocks for power-on state (no reset port).

## 5. Phase 2 work (the goals) — plan these fresh

The original plan's Phase 2 was "burst engine + arbiter + synth/HW." Phase-1 execution **grew
the scope** with two deferrals. Treat the following as the Phase-2 backlog to brainstorm/spec:

1. **`comp_burst` — fresh aligned sequential burst master** (do NOT resurrect `origin/burst-dma`;
   read it for lessons only — it hit −0.385 ns timing). Long sequential bursts for source-row
   fetch and dest-band flush, through `ddr_blitter_arb`. A full-width band flush is one burst of
   80 qwords/row.
2. **Arbiter burst-grant:** extend `ddr_blitter_arb.sv` to hold the blitter grant for a whole
   burst; the video reader keeps default priority (must never starve — assert it).
3. **GROWN: SDRAM-source (`C_SRCSEL=1`) support in `comp_pipeline`.** Today `comp_pipeline`
   reads sources only via the DDR `mem_*` master. The **real overworld runs `C_SRCSEL=1`**
   (sources live in SDRAM), so the pipe cannot run the live workload until it drives the
   `src_sdram_*` master like the FSM does. This is the gating item for any HW run.
4. **GROWN: fix `vram_demux` partial-byte-enable SDRAM-dest writes.** Root cause (reviewer-
   confirmed): full-qword writes route to SDRAM as a burst and work (proved by
   `tb_blitter_system_pipe` PHASE1, a qword-aligned 64-px-wide fill); **partial-BE writes**
   (e.g. a 4-px-wide fill) take `vram_demux`'s serialized 16-bit word-write path, which fails
   together with `sd_busy` multi-beat backpressure. This is an SDRAM-dest **memory-path** bug,
   NOT a compositor bug (the same tall-chunk + painter logic passes on the behavioral DDR model).
5. **Re-enable the deferred system phases:** `tb_blitter_system_pipe.sv` guards PHASE2A/2B
   (multi-chunk/multi-cmd FILL through SDRAM-dest) behind `\`ifdef P2_SDRAM_SYS`, and PHASE3/4
   (C_SRCSEL=1 source) are deferred. After (3) and (4), build with `-DP2_SDRAM_SYS`, re-enable,
   and make them pass.
6. **Task 6 — cyc/px gate (G1):** extend `tb_profile.sv` to measure the pipe at `C_PIPE=1`. The
   compute path is **already 1 px/clock by construction**; the **end-to-end ~1–2 cyc/px headline
   is only meaningful after the burst engine** (the single-beat Phase-1 path is memory-bound and
   may even measure slower than the FSM). Measure once bursts land. Use a large blit for
   steady-state, and probe `comp_pipeline` compute states to separate compute vs memory cycles.
7. **Task 9 — synthesis & hardware:** add the `comp_*` files to `fpga/files.qip`; Quartus build;
   **STA worst-case setup slack ≥ 0** at the f2h clock (G5; pipeline only the mixer if tight,
   keep burst-control shallow; shrink `COMP_BAND_H` if BRAM-tight). Then **HW validation (G2)** on
   the DE10-Nano heavy overworld: `[blitter timing]` fabric ≤ ~16.67 ms (~60 fps), `escape=0`,
   and **a human visual check** (counters can lie about render health) before making `C_PIPE=1`
   the default.
8. **Final whole-branch review** of the full Phase 1+2 work before merge (use
   `superpowers:requesting-code-review`), then `superpowers:finishing-a-development-branch`.

## 6. Carried findings from Phase-1 reviews (triage during Phase 2 / final review)

- **comp_pipeline (hardening, non-blocking):** `cw_row`/`rd_row` are 4-bit and assume the spans
  in a chunk are exactly consecutive rows `chunk_base_y+i`. The invariant holds today
  (`comp_span_setup` emits consecutive rows); add a range assert to harden the linchpin.
- **Stale header comments** on the `*_pipe` testbenches (copied verbatim from the originals).
- `comp_mixer` div255 inline-vs-macro DRY (toolchain-forced; golden uses the real macro so a
  divergence would surface in test) — consider an explicit filelist or a `comp_div255` function.
- `comp_dest_band` `\`ifndef` fallback can mask a missing `comp_defs.vh` on a synth include path;
  once Quartus include paths are confirmed in Task 9, consider dropping the fallback or `\`error`.
- Minor test-coverage gaps noted per task (single-point flip in T2, flip coverage in T4).
Full list: the `PCOMP-T1..T5` lines in `.git/sdd/progress.md`.

## 7. Hard constraints (unchanged from Spec A — keep honoring)

- **Bit-exact to the golden** (`patches/mister/blitter/blitter_ref.h` / `blitter_ref.c`); the
  host/fabric contract (`blt_cmd_t`, opcodes, blend modes, the 32-byte ring entry, the
  submit/done handshake) is **frozen**.
- The blitter is a **guest on the f2h DDR port**: the video reader keeps default ownership; the
  blitter fills genuine idle gaps. No per-pixel DDR beats — bursts to/from on-chip buffers.
- New RTL: module==file name, in `fpga/rtl/`; headers `// <file> — <purpose>` +
  `// Copyright (C) 2026 — GPL-3.0`. Commit only when asked; end commit bodies with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- The engine-side overdraw cache is **orthogonal**: this work cuts cycles-per-pixel on the
  fabric and generalizes across engines; do not conflate the two.

## 8. Process note

Phase 1 ran via `superpowers:subagent-driven-development`. **Subagent dispatch was unreliable
during that session** (several infra connection drops / watchdog stalls); some Task-5 finishing
work was done by the controller directly. If dispatch is flaky again, have implementers **commit
before composing their final reply** so progress survives a drop, and verify on-disk state (git
log, run the tests) rather than trusting the last message.

## 9. Authoritative artifacts (read for full detail)

- Spec: `docs/superpowers/specs/2026-06-17-pipelined-compositor-design.md`
- Plan + execution status: `docs/superpowers/plans/2026-06-17-pipelined-compositor.md`
- Ledger (decisions/root-causes/minors): `.git/sdd/progress.md` (PCOMP section)
- Task 5 report (architecture, deferrals, root cause): `.git/sdd/pcomp/task-5-report.md`
- Phase-1 commits: `git log --oneline f1b7930..spec/pipelined-compositor`
