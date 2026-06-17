# VRAM Framebuffer Relocation — Design Spec

**Status:** IMPLEMENTED in RTL + C++; all sims green (2026-06-17). HW validation pending
(Task 7). Plan: `docs/superpowers/plans/2026-06-17-vram-framebuffer-relocation.md`.
Implementation note: the dst→SDRAM regression uncovered + fixed three integration
deadlocks the per-module unit tests missed (vram_demux `S_BWAIT` burst-hold-until-accept
and `blt_rd` hold; arbiter `dst_busy`), and a multi-lane partial-write test caught an
`S_WLANES` lane-index wrap that would have hung the demux on the first blend RMW on HW.
The deadlock fixes are protocol-correct vs the behavioral `sdram_psx`; real f2h↔SDRAM
timing vs the scanout deadline is HW-proven (per #30).
**Owner area:** `fpga/Solarus.sv` (integration demux + arbiter wiring),
`fpga/rtl/sdram_src_arb.sv` (3-client arbiter), `fpga/rtl/openbor_video_reader.sv`
(scanout dual-bus), the SDRAM memory map, and the C++ renderer / `blt_emitter`
(relocate the persistence carry-forward to fabric, §4.6). **Supersedes** the issue #34
line-buffer §5 (writer-gating) / §9 (deeper
buffer) levers — those mitigate f2h contention; this **dissolves** it.
**Related:** issue #19 (SDRAM second-bus controller), #34 (SDRAM-source scanout
contention), `fpga-sdram-source-f2h-scanout-contention`, `fpga-jtframe-reference`,
`fpga-osd-stable-localizes-video-bugs`, `mister-ddr-and-sdram-hw-access`.
**Source design conversation:** 2026-06-17 (this branch, `feature-sdram-64mb-geometry`).

---

## 1. Problem & root cause

On the hardware-blitter path the displayed image is unstable under motion. Issue #34
chased this as a *scanout* problem and built a position-addressed line-buffer reader
(kills the cumulative scroll) plus contention band-aids (write-throttle, per-command
source mux). HW (2026-06-17) showed the SDRAM-source path still fails: the scanout
hard-stalls (frozen vsync writeback, garbage on screen) under sustained f2h contention.

Diagnostic work this cycle (new `tb_scanout_contention.sv`, sweeping sustained
inter-beat contention to 4× over the per-scanline budget) proved the **reader FSM does
not hard-wedge** — `vsync_count` keeps advancing and the arbiter only ever lends the
blitter one transaction. So the failure is **not** a logic deadlock; it is raw f2h
**bandwidth contention** plus the line buffer's reduced slack (1 line vs the old
256-qword / ~3.2-line FIFO).

**The actual root cause is architectural:** the hardware blitter composites the frame
*in fabric*, then writes it **back out to the f2h DDR framebuffer**, and the scanout
**reads that same framebuffer back in over f2h**. Two heavy users — blitter dest-writes
and scanout reads — share one bus that is also shared with the HPS/Linux. The
framebuffer-in-DDR location is a legacy of the (now-dead) pure-software-render path,
where the ARM was the producer and *had* to use DDR (SDRAM is not HPS-addressable). With
the blitter as the in-fabric producer, the DDR round-trip is a pointless trip across the
one contended bus, and its non-deterministic (HPS-shared) latency is what blows the
per-scanline scanout deadline.

Issue #19 already moved the blitter's *source* reads to a dedicated SDRAM bus but left
the *destination* writes (the heavy traffic) on f2h — that asymmetry is what unthrottled
the write storm that breaks scanout.

## 2. Goals / non-goals

**Goals**
- Take the framebuffer **off the f2h bus entirely**: the blitter composites into an
  SDRAM framebuffer and the scanout reads it from SDRAM. f2h then carries only the
  command ring, control words, and texture uploads (all light, HPS-visible).
- The scanout deadline is served by the dedicated, HPS-free, deterministic SDRAM bus —
  removing the contention class #34 fought, rather than mitigating it.
- Reuse the proven #34 position-addressed line-buffer scanout datapath unchanged (only
  its fill *source* changes from DDR to SDRAM).
- No edits to the **vendored** `blitter_top.sv` — redirect its dest writes at the
  integration layer by address decode.

**Non-goals**
- No blitter bandwidth optimization (per-pixel dest writes stay per-pixel — the
  burst-DMA refinement is the separate #004/#005 work).
- No DDR-framebuffer fallback path (explicit full-commit decision, §9).
- No scaling/filtering (source 320×240 = display, unchanged).
- No revival of the pure-software-render path or the SDL escape fallback (both dead —
  the blitter handles all real-quest ops; see §7 assumption).

## 3. Architecture

```
ARM (engine + blt_emitter)  ──f2h──►  DDR: cmd ring, BLTCTRL, VCTRL doorbell,
                                            joy/vsync/audio, texture uploads (light)

blitter_top.mem_* ─┬─ ring/ctrl reads, VCTRL doorbell write ─────────► DDR (unchanged)
                   └─ FB0/FB1 dst RMW-read + pixel write ──┐  (address-decode demux
                                                           │   in Solarus.sv)
                                                           ▼
blitter staged-src reads (per-cmd F_SRC_SDRAM) ►┌──────────────────────────────┐
                                               │   SDRAM (dedicated bus)       │
scanout line fetch ◄────────────────────────────│   • source-texture heap       │
                                               │   • FB0 / FB1 (double-buffer) │
scanout pixel out ──► HDMI / analog            └──────────────────────────────┘
                                          f2h carries ZERO scanout pixels
```

The off-screen bg-cache `CACHE` and un-staged sources stay in DDR (the blitter's
per-command source mux, §4.4, already reads them from DDR). Only the scanout-visible
framebuffers `FB0/FB1` move — that is all the goal requires, since once scanout reads
from SDRAM, the blitter's remaining DDR pixel writes (`CACHE` compose) no longer collide
with scanout at all.

Three logical clients now share the single `sdram_psx` controller via a priority
arbiter: **scanout read** (strict highest — hard per-scanline deadline), **blitter
source** (existing #19 port), **blitter dest** (new, from the demux).

## 4. Detailed design

### 4.1 SDRAM memory map
64 MB `AS4C32M16` geometry (row = `addr[25:13]`, col = `addr[10:1]`; one scanline =
80 qw = 640 B < 2 KB row → a line fits one open row for clean page-mode reads):

```
  0x000000 .. 0x3FFFFF   source-texture heap (existing #19 staging mirror, ~4 MiB)
  0x400000               FB0   (320×240 RGB565 = 153,600 B; 0x40000 slot)
  0x440000               FB1   (double-buffer)
  ... ~60 MB headroom
```
Exact bases are localparams; verify in planning that the source-heap extent (the
`SRC_QW` heap, ~4 MiB today) does not overrun `0x400000`. Leave the map open for growth.
`CACHE` is **not** relocated — it stays in DDR (§4.4).

### 4.2 Three-client SDRAM arbiter (`sdram_src_arb` → priority arbiter)
The arbiter (built to grow a `p1`) becomes a small fixed-priority arbiter over the one
`sdram_psx` command interface:

| Client | Access | Priority | Source |
|---|---|---|---|
| **P_SCAN** scanout line read | read burst | **strict highest** | reader SDRAM master |
| **P_SRC** blitter source read + staging write | read / burst-write | mid | existing #19 p0 |
| **P_DST** blitter dest RMW-read + pixel write | read / 16-bit write | low | `Solarus.sv` demux |

Strict scanout priority cannot starve the blitter: scanout is ~10–15 % of SDRAM
bandwidth (~6 µs of a 62 µs line) and the blitter has a full frame of slack (it
composites the back buffer while scanout reads the front, selected by `active_buffer`
from `VCTRL`). The blitter's `mem_*` is one-outstanding-access, so P_SRC and P_DST
rarely contend in the same cycle. Refresh stays internal to `sdram_psx` and fits the
per-line budget. Keep the existing `c_ready`/`c_busy` handshake; add per-client grant +
a 2-FF-clean priority mux (mirror the existing single-port grant discipline).

### 4.3 Scanout reader becomes dual-bus (`openbor_video_reader.sv`)
- Add a second master: an SDRAM read port (`sdram_addr`, `sdram_rd`, `sdram_dout64`,
  `sdram_dready`, `sdram_busy`) wired to arbiter P_SCAN.
- **Only** the framebuffer line-fetch moves to it: `ST_READ_LINE` / `ST_WAIT_LINE` issue
  to the SDRAM master and the beat-capture writes the line buffer from `sdram_dready`
  beats. `buf_base_addr` becomes the SDRAM FB0/FB1 byte base; line address =
  `base + display_line * 640` (bytes).
- **Everything else stays on the existing DDR master**: `VCTRL` poll
  (`ST_POLL_CTRL`/`ST_WAIT_CTRL`/`ST_CHECK_CTRL` — the frame_counter/active_buffer
  doorbell), joystick writes, vsync writeback, audio ring DMA, cart ioctl. These are the
  small HPS-visible comms and must remain on f2h.
- The position-addressed line-buffer **read side, `active_buffer` sync, `frame_ready` /
  `preloading` / `stale_vblank_count` semantics are unchanged.** The SDRAM controller is
  `clk_sys = ddr_clk`, the same domain as the fill side → **no new CDC**.
- Consequence: the reader's deadline-critical line bursts leave `ddr_blitter_arb`
  entirely; that arbiter now only juggles light DDR traffic (reader control/IO + blitter
  ring/ctrl), so its burst-protection complexity is no longer load-bearing.

### 4.4 Integration demux (`Solarus.sv`)
The blitter `mem_*` master (today wired straight to `ddr_blitter_arb`) gets an
address-decode demux:
- **FB0/FB1 region → SDRAM arbiter P_DST**, with the address remapped to the SDRAM FB
  base: `sdram_byte = SDRAM_FBx_BASE + (blt_qw − FBx_QW) * 8`.
- **All other addresses (RING, BLTCTRL, VCTRL doorbell, CACHE) → `ddr_blitter_arb`,
  unchanged.**
- Read routing: the blitter issues one outstanding `mem_*` access at a time, so the demux
  latches which bus a read went to and routes `dout`/`dout_ready` back from that bus.
- Write routing: a per-pixel 16-bit lane write (qword address + `mem_be` lane) maps to an
  SDRAM 16-bit word write at `col = qword_col*4 + lane`, `din` = that lane's 16 bits —
  the same per-pixel semantics the blitter uses on DDR today. (RMW dst reads for blend
  land in the FB region too, so they route to SDRAM automatically.)
- The vendored `blitter_top.sv` is **not edited** — it still issues "DDR" FB addresses;
  the demux transparently redirects them.
- **Source selection is unchanged**: the existing per-command mux
  (`src_in_sdram = srcsel && (c_flags & F_SRC_SDRAM)`, #34/PR#35) already reads staged
  textures from SDRAM and un-staged sources (e.g. `CACHE`) from DDR. The `C_SRCSEL`
  frame-level master-enable stays 1. This change touches **only the dest**, not the
  source path.

### 4.5 What is removed
- The DDR-framebuffer scanout read path (reader reads FB from DDR) — replaced by §4.3.
- DDR `FB0_QW` / `FB1_QW` pixel usage (the regions go dead; `VCTRL` doorbell stays).
- The ARM-side carry-forward `memcpy` into the DDR framebuffer — relocated to fabric
  (§4.6). (The SDL → `NativeVideoWriter` → DDR-FB escape fallback was *already* removed
  from `MisterBlitterRenderer` as dead weight — escape==0 in practice; see §7 assumption.
  Nothing to delete there now.)
- The #34 f2h write-throttle band-aid stops being load-bearing (may be left inert or
  removed at planning's discretion). **The per-command source mux (`F_SRC_SDRAM`) STAYS**
  — it is the source path, not a band-aid.

### 4.6 Persistence carry-forward (fabric)
The renderer keeps a persistent double-buffer: on a frame Solarus does **not** clear, the
previous committed buffer's pixels must seed the new target buffer before the fabric
composites this frame's incremental draws on top (the title/intro "flashing fix"). Today
that seed is an ARM **DDR→DDR `memcpy`** (`mister_blitter_renderer.cpp` ~L722-727) into
the DDR framebuffer. The ARM cannot write the SDRAM framebuffer, so this **moves to
fabric**:
- On a non-clear frame, the emitter issues a **full-screen `OP_BLIT`** at frame start:
  `src = previous FB (SDRAM)`, `dst = new target FB (SDRAM)`, COPY mode, full 320×240 —
  then the incremental draws composite on top (`clear=0`), exactly as before.
- On a clear frame: hardware-clear as today (no copy).
- The blitter already reads arbitrary SDRAM regions as a source (the bg-cache reads the
  staged `CACHE` from SDRAM), so the previous-FB-as-source is an **emitter/renderer change
  only** — no vendored `blitter_top.sv` RTL edit expected. Planning must confirm the
  emitter can express an FB-region source offset (the bg-cache `blt_blit_copy` handle path
  is the model) and that `src_in_sdram` (`F_SRC_SDRAM`) is set on this copy.
- The bg-cache `BG_ACTIVE` path is unaffected: it already establishes its frame base via a
  *fabric* blit of the staged cache and skips the carry-forward.
- Cost: one 320×240 fabric copy per incremental frame on the dedicated SDRAM bus
  (replacing a 153,600-byte ARM memcpy that was on the HPS f2h bus — a net move toward the
  goal, not new HPS load).

## 5. Components & boundaries (independently testable)
- **3-client SDRAM arbiter** — interface: 3 client request/grant/data ports + the single
  controller-facing port. Testable in isolation against a behavioral controller.
- **Integration demux** — interface: blitter `mem_*` in; DDR `blt_*` + SDRAM `P_DST` out.
  Pure address decode + single-outstanding read routing + be→word write mapping.
- **Reader SDRAM master** — interface: the new `sdram_*` port; drives only the line
  fetch. The rest of the reader is unchanged.
- **Fabric carry-forward** (`mister_blitter_renderer.cpp` + `blt_emitter`) — interface:
  on a non-clear frame, emit a full-screen FB_prev→FB_cur `OP_BLIT` instead of the ARM
  `memcpy`. Boundary: the renderer's persistence decision; the emitter's command stream.

## 6. Testing

**Simulatable (datapath / control correctness):**
- **Arbiter** — extend `tb_sdram_src_arb`: scanout strict-priority honored; scanout
  deadline met under continuous blitter src+dst load; blitter still makes progress
  (no starvation).
- **Demux** — unit test in a small tb: FB → SDRAM, all else (RING/BLTCTRL/VCTRL/CACHE) →
  DDR; `dout`/`dout_ready`
  routed to the right bus for one outstanding access; per-pixel `be`-lane → SDRAM word
  address mapping is correct.
- **Scanout-from-SDRAM datapath** — clone `tb_scanout_linebuf` to source the framebuffer
  from `sdram_chip_model.sv` through P_SCAN; pixel-exact across several frames. (Line
  buffer logic unchanged; this proves the new read master + arbiter + address map.)
- **Regression** — `tb_blitter_system` with dst → SDRAM: blitter composites into the
  SDRAM FB; assert pixel-exact vs the C reference model over the v1 command set.
- **Carry-forward** — verify the full-screen FB_prev→FB_cur `OP_BLIT` produces a target
  buffer pixel-identical to the previous committed buffer before incremental draws (the
  ref-model/`tb_blitter_system` path can assert a copy command's output equals its source).

**Not faithfully simulatable (per #30):** real f2h ↔ SDRAM contention vs the scanout
deadline. → **HW is the real proof**, but the deadline is now served off the contended
bus so it is deterministic. Validate on HW: run a moving-scene quest (`C_SRCSEL=1`
master-enable, per-command SDRAM sources as today); confirm stable scanout from SDRAM —
**no scroll, no
wedge, analog clean**. Counters lie about video — trust the screen (camera capture).

## 7. Risks & assumptions
- **Full commit, no fallback** (user decision §9): scanout-from-SDRAM has never run on
  HW. *Mitigation:* the three sim units above are the pre-HW net; the scanout datapath
  itself is the already-proven #34 line buffer (only its source changed).
- **Assumption: the blitter handles all real-quest ops; live escapes do not occur.** The
  escape→DDR-FB path is deleted. *Consequence (accepted):* if a quest ever triggers an
  escape (per-pixel alpha, RTT, ADD/MULTIPLY, rotate) it shows nothing rather than a
  software-composited frame. Confirm during HW bring-up that target quests never escape;
  if any does, the response is to bring that op onto fabric (extend the blitter), not to
  revive the DDR-FB fallback.
- **Per-pixel SDRAM dest writes** could be slower than DDR for scattered writes (RAS/CAS
  per write). *Mitigation:* the v3.0 column-low map gives page-mode hits for sequential
  in-line writes; the blitter has a full frame of slack; bandwidth optimization is the
  out-of-scope #004/#005 burst-DMA work, applied equally to either bus.
- **Demux read-latency routing** must honor the blitter's `mem_busy`/`mem_dout_ready`
  handshake across two buses with different latencies. *Mitigation:* single outstanding
  access → a 1-deep "which bus" latch suffices; covered by the demux unit test.
- **SDRAM bandwidth headroom** — scanout + blitter src + blitter dst on one 16-bit
  100 MHz bus. *Mitigation:* scanout is ~10–15 %; #19 already proved source reads fit;
  the arbiter test quantifies the worst case.
- **RBF timing** — small added logic (demux, third arbiter port). *Mitigation:* watch the
  fit report; keep the priority mux shallow.
- **FB-as-source addressing for the carry-forward blit** (§4.6): the emitter must express
  a previous-FB source offset in SDRAM, and the per-frame full-screen copy adds blitter
  load. *Mitigation:* the bg-cache `blt_blit_copy` already reads a non-heap SDRAM region as
  a source — reuse that path; the copy fits the frame budget (it replaces an ARM memcpy);
  confirm in planning before assuming no `blitter_top.sv` edit.

## 8. Rollout
1. SDRAM memory map localparams + 3-client arbiter; arbiter sim green.
2. Integration demux in `Solarus.sv`; demux sim green.
3. Reader dual-bus (line fetch → SDRAM); scanout-from-SDRAM datapath sim green.
4. Relocate the carry-forward to a fabric FB_prev→FB_cur blit (§4.6); delete the DDR-FB
   scanout path, DDR FB usage, and the ARM carry-forward memcpy; `tb_blitter_system`
   regression (dst → SDRAM) green.
5. Build RBF (CI: `gh workflow run build-rbf.yml -f runner=linux`; `allowed_actions`
   stays `all`).
6. HW: run a moving-scene quest, confirm stable SDRAM scanout (no scroll/wedge, analog
   clean). No DDR fallback by design.
7. Update memory + flip this spec to HW-VALIDATED.

## 9. Decisions made (with rationale)
- **Full VRAM scope** (not dest-only): leaving sources on DDR would re-introduce the #19
  f2h source-read bottleneck and make every blit cross-bus. Sources are already on SDRAM
  (#19); this just adds dest + scanout.
- **Full commit, no DDR-FB fallback:** user's risk posture — fewer conditionals, one
  path; the three sim units de-risk bring-up instead.
- **Integration demux, not a vendored-blitter dest port:** keeps `blitter_top.sv`
  untouched (it is vendored — edit upstream + re-copy). Address decode is clean because
  FB0/FB1 are distinct regions from the command interface.
- **Carry-forward moves to a fabric full-screen blit** (not single-buffer, not full
  re-render): keeps the proven persistence + anti-tear double-buffer model; the only
  honest way to seed an SDRAM target the ARM can't write. Likely emitter-only (no vendored
  blitter edit) since the bg-cache already sources a non-heap SDRAM region.
- **Reuse the #34 line buffer; only swap its fill source:** the position-addressed
  scanout is correct and proven; the regression was the contended *bus*, not the
  datapath. Same `clk_sys` domain → no new CDC.
- **Escapes deleted (blitter-complete):** user confirmed the software/escape path is a
  dead end; removes the last reason the ARM would write the framebuffer, which is what
  makes full-VRAM possible (SDRAM is not HPS-addressable).
