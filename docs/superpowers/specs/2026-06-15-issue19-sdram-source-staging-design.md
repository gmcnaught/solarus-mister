# #19 — SDRAM source staging (per-source VRAM-upload) design

**Date:** 2026-06-15. **Status:** designed, not started. **Issue:** #19.
**Builds on:** the merged controller/read-path work (PR #29: `sdram_psx`, `sdram_src_arb`,
`C_SRCSEL` source mux) and `docs/superpowers/specs/2026-06-15-issue19-psx-sdram-controller-design.md`.

## Why

PR #29 gives the blitter a runtime-selectable SDRAM source READ path (`C_SRCSEL=1`),
and HW-validated that the new fabric is analog-clean at baseline (+0.308 ns margin).
But `C_SRCSEL=1` currently renders garbage: **nothing writes the SDRAM.** The engine
uploads source surfaces by ARM `memcpy` straight into the DDR3 heap, and the ARM
**cannot write the FPGA's SDRAM** (it is outside the HPS memory map). So source data
must be moved DDR3→SDRAM **through the fabric**.

This spec adds that staging path so `C_SRCSEL=1` renders the real game from the SDRAM
second bus — making the feature end-to-end verifiable (rendering correctness + the
analog roll-under-load check) and delivering the actual DDR3-offload benefit.

## Model: per-source VRAM upload (chosen)

Like dedicated graphics RAM (CV1000 / PSX VRAM): when the engine uploads/changes a
source surface, that surface is copied into SDRAM at its heap-relative offset. Only
changed sources are staged (reuses the renderer's existing upload/dirty tracking);
at render time `C_SRCSEL=1` reads come entirely off the SDRAM bus (true DDR3 offload).

(Alternatives considered and rejected: a transparent write-through cache — first use
still hits DDR3, most complex RTL; and a bulk heap mirror — re-copies unchanged data.)

## Addressing (the invariant the whole design rests on)

- DDR3 source bytes live at `0x3B008000 (SRC_QW) + src_off`.
- SDRAM holds each source at the **heap-relative `src_off`** (0-based in SDRAM) —
  this is exactly what the read path already uses (`src_sdram_addr` = raw
  `src_byte_cur`, no `SRC_QW` base).
- **Stage copy:** `DDR3[SRC_QW + off ..+size]  →  SDRAM[off ..+size]`.

## Architecture

Three coordinated pieces:

### 1. RTL — fabric DDR3→SDRAM copy (the new primitive)
A copy engine in `blitter_top` that, on a `STAGE` ring command, reads the source
region from DDR3 (existing `mem_*` burst-read master) and writes it into SDRAM via
the `sdram_psx` **write port** (currently dead: `.din(0)`, `.we(<vestigial>)`).
- Read DDR3 in 64-bit beats (4×16-bit words) at `SRC_QW + off`.
- Write SDRAM as 16-bit single-access words (`NO_WRITE_BURST=1`) at `off`, same
  column-low address map, 4 words per DDR3 beat.
- Loop `size` bytes; then signal command complete (advance the ring).
- One-time per source (not per frame), so the word-at-a-time write rate is fine.

### 2. RTL — SDRAM write routing
`sdram_psx` has a single `addr/rd/we/din` interface. Route blitter SDRAM **writes**
(staging) and **reads** (rendering) to it without contention. Reads and writes never
overlap in time (staging runs during command processing; reads during blit), so:
extend `sdram_src_arb` to carry `we`/`din` (a write passthrough on the existing
port), OR mux read/write in `blitter_top` ahead of the controller. Wire
`sdram_psx.we`/`.din` to the staging FSM (remove the dead `.din(0)`/`.we(<vestigial>)`).

### 3. Engine — emit STAGE on upload
In the emitter (`blt_upload` / `blt_upload_argb4444` in `blt_emitter.c`), after the
DDR3 heap `memcpy`, append a `BLT_OP_STAGE` ring command `{off, size}` so the fabric
copies that surface into SDRAM. Gate it on a staging-enabled flag (so the DDR3-default
path emits nothing extra). The renderer already calls `blt_upload` only on fresh/dirty
uploads → only changed sources are staged. STAGE precedes the dependent blit in the
ring (uploads happen before the draw that uses them), so ordering is correct.

`BLT_OP_STAGE` encoding: a new opcode in the `blt_wire` format (opcode byte 0);
`src_off` in the existing src-offset field; `size` (bytes or qwords) in a dst/dim
field. END/cmd_count handling unchanged.

## Enabling / safety

- A staging-enable bit (tie to `C_SRCSEL`, or a sibling control bit) so that with
  SDRAM source OFF (default) **no STAGE commands are emitted and the write port stays
  idle** — the shipping DDR3 path is byte-identical and untouched.
- SDRAM content persists across frames; when `blt_alloc` frees+reuses a heap slot, the
  new source's `blt_upload` re-stages that offset → SDRAM stays coherent with DDR3.

## Validation

### Sim (iverilog, autonomous)
- `tb_sdram_psx` (or a new `tb_sdram_stage`): issue a STAGE (write a known region into
  SDRAM via the controller write port), then READ it back through the read path; assert
  the read returns the written bytes (round-trip through SDRAM). This is the first test
  of the controller's **write** path.
- `tb_blitter_system`: extend the equivalence test — instead of pre-seeding SDRAM by
  hand, drive a STAGE command to copy the DDR3 source into SDRAM, then blit with
  `C_SRCSEL=1`, and assert pixels match the DDR3 (`C_SRCSEL=0`) render. This proves the
  full upload→stage→render path bit-for-bit.
- Host: `blt_alloc`/emitter unit coverage that `blt_upload` appends a STAGE with the
  right `{off,size}` when staging is enabled, and none when disabled.

### CI (gated)
RBF builds; timing still closes with margin > +0.076 ns (the staging FSM adds clk_sys
logic — watch the worst-slack path, pipeline if needed).

### On-device (user-gated — the real verification)
With staging enabled and `C_SRCSEL=1`: the **real game renders correctly from the
SDRAM bus** (proves the write path + read-capture clock timing on silicon — the one
thing sim can't validate), and the analog output is checked for roll **under realistic
read+write SDRAM load**. Falls back to `C_SRCSEL=0` (DDR3) at any time.

## Acceptance criteria
- [ ] RTL DDR3→SDRAM copy primitive driven by a `BLT_OP_STAGE` ring command; `sdram_psx`
      write port properly wired (no more dead `.din(0)`).
- [ ] SDRAM write routing (arbiter or mux) — reads + writes both reach the controller,
      no contention, read-after-stage returns staged data in sim.
- [ ] Emitter appends `BLT_OP_STAGE {off,size}` on upload when staging is enabled; none when disabled.
- [ ] `tb_blitter_system` equivalence via STAGE (no hand-seeding) passes bit-exact.
- [ ] `C_SRCSEL=0` path remains byte-identical (no STAGE emitted, write port idle).
- [ ] RBF builds, timing margin > +0.076 ns.
- [ ] On HW: real game renders from SDRAM at `C_SRCSEL=1`; analog roll checked under load (user gate).

## Out of scope
- The cycles/pixel read pipeline / wide-line consumption (#19 AC#1) — separate follow-on.
- Eviction/coherence beyond the existing `blt_alloc` free+reupload behavior.
