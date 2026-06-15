# SDRAM source staging (per-source VRAM upload) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (or executing-plans). Steps use checkbox (`- [ ]`).

**Goal:** Stage source surfaces DDR3→SDRAM via a `BLT_OP_STAGE` ring command + a fabric copy engine, so `C_SRCSEL=1` renders the real game from the SDRAM bus.

**Architecture:** The engine `blt_upload` appends a `STAGE {off,size}` command (when staging enabled) after the DDR3 heap memcpy. The blitter executes STAGE by reading the source region from DDR3 (existing `mem_*` master) and writing it to SDRAM via the `sdram_psx` write port (read/write muxed onto the single controller port). The controller write path is already sim-validated (existing `wr()` round-trips). `C_SRCSEL=0` emits no STAGE and leaves the write port idle — shipping DDR3 path byte-identical.

**Tech Stack:** SystemVerilog (`-g2012`, iverilog), C (emitter), Quartus (CI). Spec: `docs/superpowers/specs/2026-06-15-issue19-sdram-source-staging-design.md`.

**Branch:** continue on `issue19-psx-sdram-controller` (extends PR #29). Sims run from `fpga/sim/`; pass = `errors=0`/`RESULT: PASS`. Host tests via `tests/run_tests.sh`.

---

## Task 1: BLT_OP_STAGE opcode + emitter blt_stage() (host, TDD)

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.h` (or wherever `BLT_OP_*` live) — add `BLT_OP_STAGE`.
- Modify: `patches/mister/blitter/blt_emitter.c` / `.h` — add `int blt_stage(blt_emitter_t*, uint32_t off, uint32_t size)`.
- Modify: `tests/blt_alloc_test.c` (or a new `tests/blt_stage_test.c`) + `tests/run_tests.sh`.

- [ ] **Step 1: Find the opcode enum + a free value.** Grep `BLT_OP_` in `patches/mister/blitter/*.h`; pick the next unused opcode for `BLT_OP_STAGE`. Confirm it doesn't collide.

- [ ] **Step 2: Write the failing host test** (in the test file): build an emitter bound to a scratch ring+heap, call `blt_stage(&e, 0x40, 0x100)`, then decode the last ring command via `blt_wire` and assert `opcode==BLT_OP_STAGE`, the off field==0x40, the size field==0x100, and `cmd_count` incremented by 1.

- [ ] **Step 3: Run → fail** (`bash tests/run_tests.sh` — undefined `blt_stage`/`BLT_OP_STAGE`).

- [ ] **Step 4: Implement** `BLT_OP_STAGE` + `blt_stage()`: encode opcode in u0 byte0, `off` in the src-offset field, `size` in a dst/dim field (match the `blt_wire` layout; reuse existing fields, document which). Bump `cmd_count`, advance the ring like other emit funcs, set `overflow` on ring-cap exceed.

- [ ] **Step 5: Run → pass.** **Step 6: Commit** `fpga(#19): BLT_OP_STAGE opcode + blt_stage() emitter (TDD)`.

---

## Task 2: RTL — DDR3→SDRAM copy FSM + SDRAM write routing

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (decode `BLT_OP_STAGE`; copy FSM; drive SDRAM write).
- Modify: `fpga/rtl/sdram_src_arb.sv` (carry `we`/`din` write passthrough) OR mux in `blitter_top`.
- Modify: `fpga/Solarus.sv` (wire `sdram_psx.we`/`.din` to the blitter; remove dead `.din(0)`/`.we(<vestigial>)`).
- Modify/Create: `fpga/sim/tb_sdram_stage.sv` (or extend `tb_blitter_system.sv` in Task 4).

- [ ] **Step 1: Write a failing RTL round-trip test** `fpga/sim/tb_sdram_stage.sv`: drive `blitter_top` with a ring containing a `BLT_OP_STAGE {off,size}` whose DDR3 source region (in the tb's DDR model) holds known bytes; after the command completes, read those SDRAM offsets back through the read path (or via the chip model) and assert they equal the DDR3 source bytes. (Model both DDR3 (existing `ddr_blitter_arb`/mem model used by `tb_blitter_system`) and SDRAM (`sdram_chip_model`).)

- [ ] **Step 2: Run → fail** (no STAGE handling / write port unwired).

- [ ] **Step 3: Implement the copy FSM** in `blitter_top`: on decoding `BLT_OP_STAGE`, loop reading 64-bit DDR3 beats at `SRC_QW + off` and writing each as 4×16-bit SDRAM words at `off` (column-low map), `size` bytes total, then complete the command. Reuse the existing DDR3 read master; add SDRAM write outputs (`src_sdram_we`, `src_sdram_din`, `src_sdram_waddr`).

- [ ] **Step 4: Route SDRAM writes** — extend `sdram_src_arb` with `p0_we`/`p0_din` (and `c_we`/`c_din`) passthrough, or mux read vs write onto `sdram_psx.addr/rd/we/din` in `blitter_top` (reads and writes are temporally disjoint). Wire `sdram_psx.we`/`.din` in `Solarus.sv` (delete dead `.din(0)`).

- [ ] **Step 5: Run → pass** (round-trip: staged DDR3 bytes read back from SDRAM). Re-run all prior sims (tb_sdram_ctrl/psx/src_arb/sweep, tb_blitter_copy/blend/palpha/coalesce) → still green; confirm `C_SRCSEL=0` path unaffected.

- [ ] **Step 6: Commit** `fpga(#19): BLT_OP_STAGE DDR3->SDRAM copy FSM + SDRAM write routing`.

---

## Task 3: Engine — emit STAGE on upload (gated)

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.c` (`blt_upload`, `blt_upload_argb4444`) — append `blt_stage(e, h.off, h.size)` after the heap memcpy, gated by a `stage_enabled` flag on the emitter.
- Modify: `patches/mister/mister_blitter_renderer.cpp` — set `em.stage_enabled` from the runtime SDRAM-source flag (the same condition that sets `C_SRCSEL`); ensure C_SRCSEL is published to DDR (the host currently never writes C_SRCSEL — add `ddr_w32(C_SRCSEL, sdram_src?1:0)` in the per-frame control publish, so the toggle is engine-driven, not a devmem poke).
- Modify: `tests/…` host test — assert `blt_upload` appends a STAGE when `stage_enabled`, none when not.

- [ ] **Step 1: Failing host test:** upload a surface with `stage_enabled=1` → assert the ring contains a STAGE with `{off,size}` matching the returned handle; with `stage_enabled=0` → no STAGE appended.
- [ ] **Step 2: Run → fail. Step 3: Implement** the gated emit + the `C_SRCSEL` publish in the renderer (new env e.g. `SOLARUS_SDRAM_SRC=1` → sets the flag + writes C_SRCSEL=1; default 0). **Step 4: Run → pass.**
- [ ] **Step 5: Build the engine** (`docker run … scripts/build_engine.sh`) → confirm it compiles. **Step 6: Commit** `fpga(#19): emit BLT_OP_STAGE on upload + engine-driven C_SRCSEL publish`.

---

## Task 4: Sim — full upload→stage→render equivalence

**Files:**
- Modify: `fpga/sim/tb_blitter_system.sv`.

- [ ] **Step 1:** Replace the PHASE2 hand-seed of SDRAM with the real path: build a ring that (a) STAGEs the source DDR3→SDRAM, then (b) blits it with `C_SRCSEL=1`; capture output and assert byte-identical to the `C_SRCSEL=0` (DDR3) render of the same blit. Failing first (until Tasks 2–3 land it passes).
- [ ] **Step 2: Run → pass.** Re-run the full sim suite green. **Step 3: Commit** `fpga(#19): tb_blitter_system upload->stage->render equivalence (no hand-seed)`.

---

## Task 5: CI build + timing (gated)
- [ ] Push branch → RBF build. **Gate:** timing closes, worst-case setup slack > +0.076 ns (the staging FSM adds clk_sys logic; capture worst-slack, pipeline if it regresses). Record on PR #29.

## Task 6: On-device validation (USER-gated — the real verification)
- [ ] Deploy RBF + the staging-enabled engine. With `SOLARUS_SDRAM_SRC=1` (C_SRCSEL=1 + staging): confirm the **real game renders correctly from SDRAM** on HW (proves write path + read-capture clock timing on silicon), and check the **analog for roll under read+write load**. `C_SRCSEL=0` remains the safe fallback. Do NOT flip default-on until this passes.

---

## Notes for the executor
- The controller WRITE path is already sim-proven (existing `wr()` round-trips) — Task 2 is about *wiring + the copy FSM*, not the controller's write logic.
- `C_SRCSEL=0` MUST stay byte-identical: no STAGE emitted, SDRAM write port idle, DDR3 source path unchanged. Verify via the 4 corner sims each task.
- Address invariant: DDR3 `SRC_QW+off` ↔ SDRAM `off` (heap-relative). Don't add `SRC_QW` to the SDRAM side.
- Benign verible warnings (task lifetimes, `16'bZ`) are not errors.
