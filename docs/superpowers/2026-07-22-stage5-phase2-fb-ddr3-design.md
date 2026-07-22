# Stage 5 Phase 2 — Framebuffer → DDR3 (scan-only), design

**Date:** 2026-07-22
**Status:** Design approved; ready for implementation planning.
**Branch (proposed):** `feat/stage5-phase2-fb-ddr3` off `master` (`9a55f71`).
**Predecessor:** Stage 5 Phase 1 (P_SRC cache `SRC_BLOCKS=128`, PR #136, merged;
ships in `Solarus_20260722.rbf`).

---

## 1. Goal & success criteria

**Goal:** relieve on-chip BRAM pressure by moving the framebuffer's *scanout copy*
off-chip to DDR3, **without regressing fabric throughput**.

The current design is at **493/553 M10K (89%)**, which is why the fitter seed is
pinned (`Solarus.qsf:64`, currently `SEED 3` from Stage 3b B2; the pin
originated in the FB-in-BRAM double-buffer work, PR #49) — placement is tight
enough that an unpinned seed risks negative slack. `comp_fbram` is the single
largest BRAM consumer on the die.

**Success criteria (all must hold):**

1. **Perf-neutral.** The compositor's per-frame fabric/comp cycle counts on the
   fabric-bound scene (map 119 parallax) and a mixed scene (map 1) are unchanged
   vs the `Solarus_20260722` baseline (within measurement noise). This is not a
   tuning target — see the invariant in §4, it is structural.
2. **~160 M10K freed.** Fit report drops from ~89% to roughly ~60% BRAM.
3. **Tear-free.** No scanout tearing under standing play, scrolling, or fade
   transitions (operator visual gate).
4. **Fit/STA clean.** RBF fits with non-negative slack on the shipping clocks.

**Bonus (not required to ship):** with ~160 M10K freed, attempt to **unpin the
fitter seed** (remove the pinned `SEED 3` at `Solarus.qsf:64`) and confirm a clean,
non-negative-slack fit. If it doesn't come clean, keep the pin — unpinning is not a
gate on Phase 2.

## 2. Non-goals

- **Not** moving the WORK (compositing) buffer off-chip. Doing so would reintroduce
  per-pixel dest RMW over a bus — exactly the cost PR #49 was built to eliminate
  (writeback was 44–66% of compositor cycles pre-#49). That is a separate future
  project ("Approach F") with its own dest-cache/band design and its own
  perf-validation. Phase 2 deliberately keeps WORK on-chip.
- **Not** reinvesting the freed ~160 M10K. Phase 2 banks the headroom; how it is
  later spent (larger source cache, future features) is a separate decision.
- **Not** touching `comp_pipeline` or the compositor datapath.
- **Not** adopting `MISTER_FB`/ascal. ascal adds ~1–2 frames (~33 ms); the whole
  point is to keep the OpenBOR-style direct reader with no ascal
  (`solarus-scanout-avoid-ascal-direct-path`).

## 3. Background — current architecture

One real render path (see `CLAUDE.md`, `docs/frame-dataflow.md`):

- `comp_pipeline` (issue-interval-1 compositor) composites into `comp_fbram`, an
  on-chip M10K framebuffer. `comp_fbram` is **double-buffered**: a **WORK** buffer
  (`bank0-3`) that the compositor RMWs at 1-cyc BRAM speed and that *persists*
  across frames (Solarus's incremental/retained-scene model needs no
  carry-forward), and a **SCAN** buffer (`sbank0-3`) refreshed once per frame
  during vblank by a WORK→SCAN snapshot (`fbram_snapshot`, driven by `blitter_top`
  `S_SNAP_*`). Decoupling the two makes scanout tear-free.
- The scanout reader (`openbor_video_reader.sv`, our OpenBOR fork origin) fetches
  each scanline through a `scn_addr`/`scn_rd`/`scn_ok` cache-ok handshake. Today
  that handshake is served from `comp_fbram`'s SCAN port by `fbram_scan_adapter`
  (the "bridge"). The reader still contains its **native DDR3 line-fetch** path
  (`BUF0_ADDR`/`BUF1_ADDR` at `0x3A000040`/`0x3A040040`, per-line burst,
  read-ahead FIFO) plus a live `ddr_*` master used for control-word / joystick /
  audio-ring / ioctl housekeeping.
- `comp_fbram` costs **~320 M10K** (its own header, `comp_fbram.sv:17`): 8 banks ×
  16-bit × 19200, i.e. WORK (4 banks) + SCAN (4 banks). **SCAN is exactly half →
  ~160 M10K.**

Why this matters: Phase 1 established the compositor is **fetch-stall-bound** (source
atlas reads), not writeback-bound — FB-in-BRAM already drove writeback/RMW-load to
0% of cycles. So the SCAN buffer is pure BRAM cost with no bearing on the
compositor's throughput. It is the ideal thing to move off-chip.

### DDR3 (f2h) topology today

A single `DDRAM_*` f2h port, `use_nv = NATIVE_VID` (always on), routed through
`ddr_blitter_arb` — a **2-master priority arbiter**:

- **rdr (default owner):** the reader's `nv_ddr_*` master (control word, joystick,
  audio, ioctl).
- **blt (borrows idle gaps):** blitter DDR3 traffic via `vram_demux` (`bd_*`) —
  command-ring reads (`0x3A0E0000`), `BLT_OP_STAGE` atlas DDR3→SDRAM staging,
  GRID_BUF, TL_BUF.

`vram_demux` routes `blitter mem_*` by address: the **FB region → SDRAM** (`dst_*`,
the old P_DST path, now **dead** since FB moved on-chip); everything else → DDR3
(`bd_*`). Source atlases live on the **separate SDRAM chip**, so FB traffic and
source-fetch traffic are already on different physical buses.

## 4. Design — split the framebuffer by access pattern

Keep the random-order RMW on-chip; move only the linear-scan copy to DDR3.

```
comp_pipeline ── RMW (1-cyc BRAM) ──► comp_fbram WORK banks (on-chip, ~160 M10K, persistent)
                                              │
                                vblank snapshot: burst-write the whole frame
                                              ▼
                                      DDR3 double-buffer   (0x3A000040 / 0x3A040040)
                                              │            + control word {frame_ctr, active_buf} @ 0x3A000000
                                      OpenBOR reader: per-line DDR3 burst → read-ahead FIFO
                                              ▼
                                      VGA_R/G/B/HS/VS/DE    (no ascal)
```

**The invariant (why this is perf-neutral by construction):** the composite hot
loop reads and writes *only* on-chip WORK. Nothing the compositor does per pixel
ever reaches DDR3. The only new DDR3 traffic is (a) one sequential frame-sized
burst write during vblank, and (b) the reader's line reads during active scan —
neither is on the compositor's critical path. Perf-neutrality is therefore a
structural property, not a tuning outcome.

This is the "OpenBOR reader un-bridge" the prior research scoped
(`.superpowers/sdd/research-fb-scanout.md`, `research-scanout-survey.md`): the
reader returns to reading a DDR3 double-buffer, exactly the pattern it was born
doing; we were the ones who inserted the on-chip indirection.

## 5. Concrete changes (mostly deletions)

1. **`comp_fbram.sv`** — delete the SCAN banks (`sbank0-3`), the `scan_*` read
   port, and the `snap_*` write port. Keep WORK banks (`bank0-3`) + the compositor
   RMW read/write. **Frees ~160 M10K.** The `#110` SCAN read-during-write SVA goes
   with the SCAN port.

2. **Snapshot retarget (`fbram_snapshot` / `blitter_top` `S_SNAP_*`)** — the vblank
   snapshot already streams WORK qword-by-qword. Instead of writing
   `comp_fbram.snap_*`, drive the **existing blitter `mem_*` master** to burst-write
   the frame into the DDR3 *inactive* buffer. No new arbiter client: the compositor
   is idle during vblank, so the snapshot borrows its own bus. Sizing: writes are
   full 64-bit qwords, 80 qwords/line × 240 lines = 19200 qwords; use the blitter's
   real `mem_burstcnt` (do **not** send `8'd1` for a multi-beat access — that is the
   known `#1` wiring-review wedge class).

3. **`vram_demux`** — point the FB address region at DDR3 (`bd_*`) so the snapshot
   writes land in DDR3, and **delete the dead SDRAM FB path** (`dst_*`/P_DST) and
   its now-unused ports on the arbiter/demux. Bonus reclaim + fewer modules.

4. **Reader un-bridge (restore existing code — chosen mechanism)** — delete
   `fbram_scan_adapter`; restore the reader's dormant native DDR3 line-fetch so its
   scanout reads come from the DDR3 double-buffer via its own read-ahead FIFO. The
   reader's scanout reads rejoin the `rdr` arbiter port (which it already owns for
   housekeeping). **Planning-time audit (first task):** confirm how much of the
   reader's native `BUF0/BUF1` line-fetch + FIFO path survived the fork intact. If
   it is fully present (expected — the ports and address constants are still in the
   file), restoring it is the minimal diff. Only if the audit finds it too gutted do
   we fall back to a thin new `ddr_scan_adapter` serving `scn_*` from DDR3 with a
   read-ahead FIFO. Preference is explicitly to reuse existing code.

5. **Tear-free control-word protocol** — on snapshot completion: **fence the DDR3 FB
   write to full drain, then** bump `{frame_counter++, active_buffer}` at
   `0x3A000000`. The reader polls the control word once per vblank
   (`ST_POLL_CTRL`/`ST_WAIT_CTRL`/`ST_CHECK_CTRL`) and latches `active_buffer` for
   the whole frame, so a frame is always read start-to-finish from one buffer. This
   write-completion fence is the one genuinely new correctness obligation (see
   Risks). `blitter_top` already writes the video control word as the frame-complete
   producer; the change is to gate that write behind the FB-write drain and to
   alternate `active_buffer` between BUF0/BUF1.

**Net effect:** `fbram_scan_adapter` deleted, SCAN banks deleted, dead SDRAM FB path
deleted — module count goes *down*, ~160 M10K freed, DDR3 topology simplified.

## 6. Memory map (DDR3, f2h)

| Addr | Use | Status |
|---|---|---|
| `0x3A000000` | Control word `{frame_counter[31:2], active_buffer[1:0]}` | reused |
| `0x3A000008` / `0x3A000030` / `0x3A000038` | Joystick / audio ring ptrs | unchanged |
| `0x3A000040` | FB buffer 0 (320×240 RGB565, 256 KB region) | **already reserved** (`BUF0_ADDR`) |
| `0x3A040040` | FB buffer 1 (256 KB region) | **already reserved** (`BUF1_ADDR`) |
| `0x3A080000`+ | Cart/atlas staging, command ring `0x3A0E0000`, GRID_BUF, TL_BUF | unchanged |

FB bandwidth: 153,600 B × 60 fps ≈ **9.2 MB/s** vs DDR3 >1000 MB/s — trivial. Source
atlases are on the **separate SDRAM chip**, so FB reads/writes never contend with
source fetches. DDR3 is shared with the HPS (A9), but the bandwidth headroom makes
that a latency-not-bandwidth question, handled by the reader's line read-ahead.

## 7. Validation

**Simulation (iverilog `-DFABRIC_ASSERT`, PR-tier gate):**
- Adapt `tb_scanout_sdram` → a DDR3-FB scanout TB (reader reading a DDR3
  double-buffer model), pixel-exact against a known frame.
- Snapshot-writer TB: WORK → DDR3 burst write is complete and correctly addressed
  (BUF0/BUF1 alternation, qword layout `y*80 + x>>2`).
- **SVA: control word must not bump before the FB write drains** (the fence).
- **Line-FIFO underrun check:** during vblank the snapshot write and the reader's
  2-line preload both use DDR3; confirm the reader's read-ahead FIFO never
  underruns (OpenBOR's 2-line preload margin should cover it; verify under the
  arbiter's reader-priority policy).

**Hardware (2-RBF A/B, per Phase 1's harness style):**
- Fit/STA gate: expect **~60% BRAM**; non-negative slack on shipping clocks.
- Fabric/comp cycle counters (`0x3B00002C`/`0x3B000034`) A/B vs `Solarus_20260722`
  on map 119 (fabric-bound) and map 1 — **must be unchanged** (perf-neutral proof).
- **Operator visual gate:** standing, scrolling, and **fade transitions**, with
  explicit attention to **tearing**. (Per `solarus-no-self-declared-visual-validation`,
  visual correctness is the operator's call, not self-declared.)
- **Bonus:** unpin SEED 7 in `Solarus.qsf`, re-fit, confirm clean. Keep the pin if
  not.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Tear** from bumping the control word before the DDR3 FB write drains | Explicit write-completion fence (§5.5) + the SVA (§7). Double-buffer means the reader reads the *previous* stable buffer until the bump. |
| **Line-FIFO underrun** — snapshot write starves the reader's preload in vblank | OpenBOR's 2-line preload + reader-priority arbiter; verified in sim (§7) and on HW (visual + no dropped lines). Bandwidth is ~1% of DDR3, so this is latency scheduling, not saturation. |
| **Reader native path more gutted than expected** | First planning task is the audit; fallback is a thin `ddr_scan_adapter` (still small). Either way the reader FSM contract (`scn_*` or native) is well-understood. |
| **`mem_burstcnt` = 1 on a multi-beat FB write** (the `#1` wedge class) | Thread the real burst count through the demux → arbiter, as the existing STAGE/command-ring reads already do. |
| **DDR3/HPS contention jitter** during scanout | Latency, not bandwidth; the read-ahead FIFO exists precisely to absorb it. This is the pattern OpenBOR/PICO-8/PSX all ship. |

None of these risks touch the composite hot loop, so none can violate criterion 1.

## 9. Resolved open items

- **Unpin SEED 7:** bonus validation step, not a gate. (User-approved.)
- **Reader un-bridge mechanism:** restore existing native DDR3 path, contingent on
  the planning-time audit; thin adapter only as fallback. (User-approved: "prefer
  existing code".)
- **Snapshot write master:** reuse the blitter's existing `mem_*` master via the
  retargeted demux; no 3rd arbiter client. (User-approved.)

## 10. References

- Research: `.superpowers/sdd/research-fb-scanout.md`,
  `.superpowers/sdd/research-scanout-survey.md`
- RTL: `fpga/rtl/comp_fbram.sv`, `fpga/rtl/fbram_snapshot.sv`,
  `fpga/rtl/fbram_scan_adapter.sv`, `fpga/rtl/openbor_video_reader.sv`,
  `fpga/rtl/blitter_top.sv`, `fpga/Solarus.sv` (DDR3 arbiter/demux ~L525–730)
- Phase 1: `docs/superpowers/2026-07-22-stage5-source-cache-hw-validation.md`,
  `docs/superpowers/plans/2026-07-22-stage5-source-cache.md`
- FB-in-BRAM history: memory `fpga-fb-in-bram-feasibility` (PR #49, ~320 M10K
  double-buffer; seed pin originated here, now `SEED 3` after Stage 3b B2)
- Prior decision to avoid ascal: memory `solarus-scanout-avoid-ascal-direct-path`
