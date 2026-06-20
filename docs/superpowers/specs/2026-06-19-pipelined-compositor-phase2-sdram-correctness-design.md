# Pipelined Compositor — Phase 2 (SDRAM Correctness Cycle) Design

> **Status:** approved design, pre-implementation.
> **Branch / worktree:** `spec/pipelined-compositor` in `.claude/worktrees/pipelined-compositor/`
> (main checkout stays on `feature-sdram-64mb-geometry`, undisturbed).
> **Predecessors:**
> - Phase 1 (`docs/superpowers/specs/2026-06-17-pipelined-compositor-design.md`, Spec A) — the
>   `C_PIPE`-selectable, bit-exact, issue-interval-1 compositor.
> - Phase 2a Burst Performance (`docs/superpowers/specs/2026-06-18-pipelined-compositor-phase2-burst-design.md`)
>   — `comp_burst` + `ddr_blitter_arb` burst-grant; G1 met (6.04 < 7.47 cyc/px, N=16). That spec
>   **explicitly deferred** SDRAM-source routing, the `vram_demux` partial-BE fix, and re-enabling
>   `tb_blitter_system_pipe -DP2_SDRAM_SYS` to *this* cycle.

## 0. TL;DR

Phase 2a made the II=1 pipe fast on the **DDR `mem_*`** path. But the real overworld blits write the
framebuffer to **SDRAM** (the VRAM relocation) and read sprite sources from **SDRAM**
(`C_SRCSEL=1`). Two correctness gaps block that live path and are currently fenced off behind
`-DP2_SDRAM_SYS`:

1. **SDRAM-dest writes.** `comp_pipeline` now drives `comp_burst`'s per-beat `mem_*` write master.
   `vram_demux`'s SDRAM-dest write path — designed against the *legacy* `blitter_top` FSM — does not
   stay in lockstep with that master, and its partial-byte-enable serialization (`S_WLANES`) is
   unverified under burst-cadence backpressure. This deferred **PHASE1-pipe / 2A / 2B** to this cycle.
2. **SDRAM-source reads.** `comp_pipeline` only fills `comp_src_linebuf` from DDR; it has no
   `C_SRCSEL=1` route. This deferred **PHASE3 / 4** to this cycle.

This cycle closes both **on the existing single-beat SDRAM controller** (`sdram_psx` stays
`BURST_BEATS=1`) — it is a correctness cycle, not an SDRAM-throughput cycle. It exits sim-green across
all `tb_blitter_system_pipe` phases under `-DP2_SDRAM_SYS` **plus Quartus synth + STA** (gate **G5**).
Live hardware (gate **G2**) and SDRAM-side burst throughput remain out of scope.

## 1. Goals & success bar

### In scope (this cycle)

1. **SDRAM-dest write correctness** — make `vram_demux`'s SDRAM-dest path correct against
   `comp_burst`'s per-beat `mem_*` write master: the `blt_busy`/accept handshake across consecutive
   beats, and the partial-byte-enable (`S_WLANES`) serialization under `sd_busy` backpressure.
2. **SDRAM-source routing into `comp_pipeline`** — add read-only `src_sdram_*` ports to
   `comp_pipeline`; route source-row fetch to SDRAM when `C_SRCSEL=1`; owner-mux those ports in
   `blitter_top` between the legacy FSM and `u_pipe`, reusing the existing `sdram_src_arb` P_SRC port.
3. **Re-enable the deferred system phases** in `tb_blitter_system_pipe.sv` under `-DP2_SDRAM_SYS`:
   PHASE1-pipe-via-SDRAM-dest, PHASE2A, PHASE2B (dest); PHASE3, PHASE4 (source).
4. **Quartus 17.0.x synthesis + STA** on the combined RTL — worst-case setup slack ≥ 0 at the f2h
   clock, and confirm the `comp_defs.vh` include path resolves authoritatively under Quartus
   (gate **G5**).

### Success bar (definition of done)

- Under `-DP2_SDRAM_SYS`: **PHASE1-pipe / 2A / 2B / 3 / 4 all PASS** in `tb_blitter_system_pipe`.
- The four `C_PIPE=1` equivalence variants (`tb_blitter_{copy,blend,coalesce,palpha}_pipe`) stay
  **bit-exact** to golden; `tb_comp_pipeline` passes; the legacy `C_PIPE=0` suite shows **no
  regression**.
- New unit coverage at the changed boundaries: `tb_vram_demux` exercises write burst-cadence, N-beat
  read streaming, and partial-BE SDRAM-dest writes; `comp_pipeline`/`tb_comp_pipeline` exercises the
  `C_SRCSEL=1` source fetch.
- **G5:** Quartus STA reports worst-case setup slack ≥ 0 at the f2h clock; `comp_defs.vh`
  (`COMP_DIV255`, `COMP_BAND_H`, `COMP_MAXBURST`) confirmed authoritative for every `comp_*` file
  under Quartus synthesis.
- **No live HW run** (gate G2) is required to close this cycle.

### Out of scope (own gates)

- **SDRAM-side burst throughput.** `sdram_psx` stays `BURST_BEATS=1`; `vram_demux` decomposes the
  pipe's `mem_*` write burst into per-qword SDRAM transactions. Making the SDRAM controller itself
  burst-capable is a separate performance cycle.
- **T6 cyc/px perf gate (G1)** — already met by Phase 2a on the DDR path; not re-litigated here.
- **Live DE10-Nano hardware validation (gate G2)** and making `C_PIPE=1` the default.
- The engine-side overdraw cache (orthogonal, as in Phase 1/2a).

## 2. Architecture & components

```
  C_PIPE=1 blit (blitter_top owns the ports, u_pipe drives them while pipe_busy)

  DEST write path:
    comp_pipeline → comp_burst → mem_* (per-beat write burst) → vram_demux ─┬─ FB range → sdram_psx (BURST_BEATS=1, per-qword)
                                                                            └─ else     → ddr_blitter_arb → f2h DDR

  SOURCE read path (C_SRCSEL=1):
    comp_pipeline.src_sdram_* ─(owner mux in blitter_top, gated by pipe_busy)─ src_sdram_* → sdram_src_arb (P_SRC) → sdram_psx
                       ▲ legacy blitter_top FSM is the other mux input (C_PIPE=0)
```

Both changes **extend existing mux/infrastructure** rather than add subsystems: the `mem_*` owner mux
(`pipe_busy`) and the `sdram_src_arb` P_SRC port already exist from Phase 1 + the VRAM relocation.

### 2.1 `vram_demux.sv` — SDRAM-dest burst correctness (no new ports)

`comp_burst` is now the producer/consumer on both directions of the FB path, and it streams beats:
- **Writes:** one qword/beat (Avalon-style write burst — `mem_wr=1` + `mem_burstcnt` on the first
  beat, each beat held until `!mem_busy`).
- **Reads:** `mem_rd=1` + `mem_burstcnt=N`, then it expects **N** beats streamed back on
  `mem_dout_ready`/`mem_dout`.

`sdram_psx` is `BURST_BEATS=1` (one qword per request), so `vram_demux` must **decompose** each
direction into N single-beat SDRAM transactions while presenting `comp_burst` the streaming `mem_*`
contract it expects. The demux does not buffer a multi-beat payload; it sequences per-qword. The defect
class is that the demux's busy/accept FSM was tuned against the *legacy* `blitter_top` FSM, not against
`comp_burst` (the Task-5 FIX A/A'/B lineage predates `comp_burst` entirely). Three things to
root-cause **via failing tests first**:

1. **Write burst-cadence handshake.** Across consecutive write beats, `vram_demux`'s `blt_busy` and
   state return must accept the *next* beat without a lost-beat or double-write, while `sd_busy`
   toggles. The risk is `S_BWAIT`/`S_WWAIT` busy-hold desyncing from `comp_burst`'s
   `S_WRLOAD → S_WRARM → S_WRWAIT` per-beat advance (it samples `!mem_busy` to fire `wr_take`).
2. **Read burst streaming.** A band-LOAD read burst of N beats must return exactly N
   `mem_dout_ready` strobes in order, each from one `sdram_psx` single-beat read, without merging or
   dropping a beat under `sd_busy` backpressure. (Task 5's read-hold fixes were single-beat; the
   N-beat streaming case is new with `comp_burst`.)
3. **Partial-byte-enable serialization.** A sub-qword write (`blt_be ≠ 0xFF`, e.g. a 4px-wide fill)
   takes the `S_WLANES` 16-bit-word loop with `sd_busy` backpressure. Verify `blt_busy` does not drop
   mid-serialization and that `comp_burst` does not advance `beat_ix` until the whole qword commits.

The fix stays entirely on the `vram_demux ↔ comp_burst` boundary. `sdram_psx`, `sdram_src_arb`, and
`ddr_blitter_arb` are untouched on the dest side.

### 2.2 `comp_pipeline.sv` — SDRAM-source fetch (new read-only ports)

- Add read-only `src_sdram_*` ports mirroring `blitter_top`'s read side: `src_sdram_addr` (qword-
  aligned byte address), `src_sdram_rd` (held until granted), `src_sdram_dout64`,
  `src_sdram_dout_ready`, `src_sdram_busy`. No write/STAGE ports — the pipe never stages.
- In `P_SRCFILL_ISS/WAIT`, route the source-row fetch to `src_sdram_*` when `C_SRCSEL=1`, else keep
  the DDR `comp_burst` request. The existing `c_src_off / c_src_stride / c_src_x / c_src_y`
  addressing (already flip-resolved in `comp_pipeline`) computes the SDRAM byte address; HFLIP stays
  applied exactly once (the existing `serve_x` cursor) — do **not** introduce a second flip.
- `comp_src_linebuf` fill is agnostic to the source: it just receives `ld_*` qwords. Only the *issuer*
  (`P_SRCFILL`) selects DDR vs SDRAM.

### 2.3 `blitter_top.sv` — source owner mux

`blitter_top` already owns the `src_sdram_*` ports (legacy FSM drives them in `S_BLIT_RD`/`S_RD`-wait)
and already has the `pipe_busy` owner mux for `mem_*`. Extend that pattern: mux `src_sdram_rd`/`addr`
out to either the legacy FSM or `u_pipe`, and route `src_sdram_dout64`/`dout_ready`/`busy` back to the
active owner, gated by `pipe_busy`. One P_SRC port, shared; exactly one master active per `C_PIPE`
selection. No new arbiter port.

## 3. Data flow

| Path | Producer/consumer | Route when | Mechanism |
|---|---|---|---|
| Dest band FLUSH (write) | `comp_pipeline` → FB in SDRAM | FB-range address | `comp_burst` per-beat `mem_*` → `vram_demux` → per-qword `sdram_psx` |
| Dest band LOAD (read) | FB in SDRAM → `comp_dest_band` | FB-range address | `comp_burst` N-beat read → `vram_demux` decomposes to N per-qword `sdram_psx` reads, streams N `mem_dout_ready` back |
| Source-row fetch (read) | sprite atlas in SDRAM → `comp_src_linebuf` | `C_SRCSEL=1` | `comp_pipeline.src_sdram_*` → `sdram_src_arb` P_SRC → `sdram_psx` |

Painter order across blits is preserved exactly as Phase 1 (per-chunk LOAD → COMPOSITE → FLUSH DDR/
SDRAM round-trip). This cycle changes only *which memory* the LOAD/FLUSH/source beats target, not the
ordering.

## 4. Verification (TDD)

Re-enable, root-cause, and green the deferred phases **in dependency order** — dest before source,
since a correct SDRAM-dest write path is a precondition for the source phases that also write results
back:

1. **PHASE1-pipe-via-SDRAM-dest** (single `C_PIPE=1` FILL → SDRAM FB) — the minimal dest reproduction.
2. **PHASE2A** (tall multi-chunk fill via SDRAM-dest) and **PHASE2B** (multi-cmd painter via SDRAM-
   dest) — the partial-BE + multi-beat coalesced-run cases.
3. **PHASE3** (per-command source mux, `C_SRCSEL=1`) and **PHASE4** (carry-forward FB1→FB0).

For each: enable the failing phase first (it should fail for the predicted reason), add a focused
**unit** test at the changed boundary (`tb_vram_demux` for write burst-cadence, N-beat read
streaming, and partial-BE; `tb_comp_pipeline` for `C_SRCSEL=1` fetch), fix, then green both unit and
system levels.

**Regression gate (must stay green after every change):** `tb_comp_pipeline`, the four `C_PIPE=1`
equivalence variants (bit-exact), `tb_blitter_system_pipe` PHASE1 legacy, and the full legacy
`C_PIPE=0` suite (`tb_blitter_*`, `tb_blitter_system`). Runner: `fpga/sim/run_sims.sh` (Icarus `-y`
library mode). Carry the Phase-1/2a toolchain gotchas: `-y` single-compilation-unit include-guard
interactions, Icarus-13 unsized-integer-in-concat casts, and `initial`-block power-on state (no reset
port) for the `comp_*` family.

## 5. G5 — Quartus synthesis + STA

After sim-green, synth the combined RTL (Phase-2a burst + this cycle's dest/source changes) under
Quartus Prime 17.0.x via the existing flow (`Dockerfile.solarus-build` / `deploy`; `comp_*` +
`comp_burst` already added to `fpga/files.qip` in Phase 2a). Two exit checks:

- **Timing:** worst-case setup slack ≥ 0 at the f2h clock. If tight, the carried fallback levers
  (in order): pipeline only the mixer, then shrink `COMP_BAND_H` for BRAM relief. The new
  `vram_demux`/source-mux logic is shallow control by design; watch it does not become the critical
  path (the `burst-dma` −0.385 ns cautionary tale).
- **`comp_defs.vh` authority:** confirm Quartus picks up the authoritative `COMP_DIV255`,
  `COMP_BAND_H`, `COMP_MAXBURST` for **every** `comp_*` file (the cross-cutting include-path /
  first-include-wins hazard flagged in the Phase-1 ledger and Phase-2a §5). Once confirmed, consider
  dropping `comp_dest_band`'s `` `ifndef `` fallback (or making it `` `error ``) so a missing include
  can't silently diverge.

**Environment note:** the Quartus toolchain reachability from this workspace is confirmed at planning
time; if synth must run on a separate host/container, the plan captures the exact invocation and the
slack/`comp_defs` evidence to paste back.

## 6. Hard constraints (carried from Spec A / Phase 2a — unchanged)

- **Bit-exact to the golden** (`patches/mister/blitter/blitter_ref.h`/`.c`); the host/fabric contract
  (`blt_cmd_t`, opcodes, blend modes, 32-byte ring entry, submit/done handshake) is **frozen**.
- The blitter is a **guest** on both the f2h DDR port and the SDRAM controller: the video reader keeps
  default ownership of f2h and **must never starve**; SDRAM access goes through `sdram_src_arb` with
  the reader/scanout priority unchanged.
- New/changed RTL: `module == file name`, in `fpga/rtl/`; headers `// <file> — <purpose>` +
  `// Copyright (C) 2026 — GPL-3.0`.
- Worktree commits are safe — commit early/often for resilience. End commit bodies with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## 7. Carried review findings to fold in opportunistically

- Phase-1/2a minors still open: `*_pipe` tb header staleness (mostly addressed in `e811dc3`), the
  `comp_mixer` div255 inline-vs-macro DRY (tie off with the §5 `comp_defs` work), and the
  `comp_dest_band` `` `ifndef `` fallback decision (resolve once G5 confirms the Quartus include path).
- Full list: `PCOMP-T1..T5` in `.git/sdd/progress.md` and the Phase-2a final-review notes.

## 8. Open items resolved during implementation (not blocking the spec)

- **Exact root cause of the dest desync** (handshake vs partial-BE vs both): determined by the §4
  PHASE1-pipe / 2A reproduction before the fix is written.
- **Source-fetch burst shape:** the source-row run may be issued as a single held `src_sdram_rd` walk
  (mirroring the legacy FSM) rather than a `comp_burst` transfer; the simplest correct form that
  passes PHASE3/4 wins (SDRAM-side burst is explicitly out of scope).
