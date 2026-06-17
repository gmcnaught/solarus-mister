# Line-Buffered Scanout — Design Spec

**Status:** approved direction (2026-06-17); ready to turn into an implementation plan.
**Owner area:** `fpga/rtl/openbor_video_reader.sv` (scanout video read path) + sims.
**Related:** issue #34 SDRAM-source scanout contention; supersedes the write-throttle
band-aid (kept as a complementary lever). Memory: `fpga-sdram-source-f2h-scanout-contention`,
`fpga-jtframe-reference`, `fpga-osd-stable-localizes-video-bugs`.

---

## 1. Problem & root cause

On the SDRAM-source path the displayed image **scrolls/rolls** (vertically unstable),
while the OSD stays clean and the DDR3 path is rock-steady. OSD-clean localizes the fault
to the **scanout reading the game framebuffer from DDR**, not the analog/DAC stage.

Root cause (confirmed by reading the RTL): `openbor_video_reader.sv` is a **whole-frame
FIFO reader**. Each display frame it resets `display_line=0`, briefly clears a single
dual-clock FIFO (`line_fifo`, 64-bit × N), then bursts framebuffer lines 0..239 into that
FIFO while the pixel side drains it (`ce_pix`/`de`, 4 RGB565 px per 64-bit word via
`pixel_sub`). **The data→screen-pixel mapping is coupled to FIFO occupancy, not to screen
position.** So when the DDR reader falls behind under f2h contention and the FIFO
underflows, *every remaining pixel of the frame shifts*; because the contention recurs
each frame the shift varies frame-to-frame → perceived steady scroll. The per-frame reset
cannot prevent it.

Why the SDRAM path triggers it: moving blit *source* reads to SDRAM un-throttled the
blitter's f2h *writes* (it no longer waits on slow f2h source reads), so its write bursts
saturate the f2h bus and the scanout underflows. The DDR3 path survives only because its
lighter, interleaved load rarely underflows — i.e. the current scanout has **no margin**,
not actual robustness.

The write-throttle (RBF `Solarus_20260617.rbf`, runtime-tunable via `C_SRCSEL[15:8]` /
`SOLARUS_BLT_THROTTLE`) only lowers the underflow *probability* — non-monotonic on HW
(throttle 32 reduced the scroll, 96 was worse once fps collapsed). It is a band-aid, not a
fix.

## 2. Goals / non-goals

**Goals**
- The scanout must be **robust to f2h contention**: an underflow must degrade to at most a
  **single-line glitch on the affected line**, never a cumulative scroll.
- Keep the proven DDR3 path working (no regression) and make the SDRAM-source path display
  a stable image.
- Surgical change: touch only the **video pixel read path**; leave the control-word read,
  buffer-select, VSYNC writeback, joystick, audio, and cart paths byte-for-byte.

**Non-goals**
- No OpenBOR-example compatibility (we own the RBF now — explicit decision 2026-06-17).
- No scaling/line-doubling/HQ filtering (source 320×240 = display, as today).
- Not removing the write-throttle / per-command mux / Option-2 demote — they remain as
  complementary f2h-load reducers, just no longer load-bearing for stability.

## 3. Architecture

Replace the single whole-frame FIFO with a **ping-pong pair of position-addressed line
buffers** (jtframe `lfbuf`/`linebuf` discipline):

```
  DDR (f2h) --burst--> [ back line buffer ]      (write side, ddr_clk, addressed by column)
                              | swap at line boundary
  display  <--hcount-- [ front line buffer ]      (read side, clk_vid, addressed by hcount)
```

- While the display scans line N out of the **front** buffer (read by pixel column), the
  DDR reader burst-fetches line **N+1** into the **back** buffer.
- At each line boundary (`new_line`/HBlank) the buffers **swap**.
- The pixel output reads `front[hcol]` for the current pixel **regardless of fill state**.
  Position is anchored to the display every line → an underflow leaves the tail of one
  line stale but the next line re-anchors. **No cumulative drift.**

This gives a full line (~80 qword-beats of slack) to absorb f2h jitter, versus today's
per-pixel coupling.

## 4. Detailed design

### 4.1 Line buffers
- Two buffers, each **320 × 16-bit** (one display line of RGB565). Tiny (640 B each) —
  inferred BRAM, simple dual-port (one write port @ddr_clk, one read port @clk_vid).
- Implement as a 2-deep set selected by a `wr_buf` / `rd_buf = ~wr_buf` toggle, OR a single
  `[1:0][319:0]` dual-port array indexed by `{buf, col}`. Plan task picks the exact form
  that infers clean dual-clock BRAM on Cyclone V (verify in the fit log: M10K, no regs).
- **CDC:** write side ddr_clk, read side clk_vid → true dual-clock BRAM handles the data
  CDC. The only cross-domain control is the buffer-swap toggle (see 4.4).

### 4.2 Fill side (ddr_clk) — reuse the existing state machine
- Keep the existing master FSM (ctrl read, joystick/audio/cart, VSYNC writeback). Only the
  `ST_READ_LINE` / `ST_WAIT_LINE` beat-capture changes: instead of `fifo_wr` into
  `line_fifo`, write each beat's 4 pixels into the **back** line buffer at the running
  column index (`col`, 0..319; advance by 4 per 64-bit beat).
- Fetch is **one display line per `new_line`** (re-anchored), address
  `buf_base_addr + line_to_fetch * LINE_STRIDE` where `line_to_fetch = vcount + 1` (the
  line about to be displayed next), clamped/!wrapped at frame edges. This replaces the
  free-running `display_line` 0..239 sweep with a vcount-anchored fetch.
- First line of a frame: prefetch line 0 during vblank (before active `de`) into the buffer
  that will be front when display starts — same "preloading" idea, but exactly one line.

### 4.3 Read side (clk_vid)
- On `ce_pix` within active `de`: output `front[hcol]` decoded RGB565→RGB888 (reuse the
  existing `cur_pix` decode), advance `hcol`. Reset `hcol=0` at `new_line`/start-of-active.
- On underflow (back buffer for the next line wasn't fully fetched in time) the read side
  is unaffected for the CURRENT line (it reads whatever is in front[]); the *next* line may
  show stale/partial data for one frame, then recovers. No global desync.

### 4.4 Swap & sync
- `wr_buf` toggles at the line boundary once the fetch for the next line has been issued;
  `rd_buf = ~wr_buf`. The toggle is generated in ddr_clk and sampled in clk_vid at
  `new_line` (a single-bit level → 2-FF synchronizer; `new_line` already has a CDC sync in
  the module to copy).
- Frame anchoring stays as today: on a new committed frame (`ctrl_word` frame-counter
  change) latch `buf_base_addr`/`active_buffer`; the line index is driven by `vcount`.

### 4.5 What is removed
- `line_fifo` (dcfifo) and the occupancy-coupled `pixel_word`/`pixel_sub` walker — replaced
  by the position-addressed line buffers. `frame_ready`/`preloading`/`stale_vblank_count`
  semantics are preserved (still gate first-frame display).

## 5. Arbiter interaction
- The line read still goes through `ddr_blitter_arb` (reader = default owner, blitter
  borrows one txn in reader-idle gaps). The **line of slack** is the primary robustness
  win, so the existing reader-priority arbiter should now suffice.
- **Fallback lever (only if HW still marginal):** gate the blitter's f2h writes to the
  active-display window and out of the line-fetch/HBlank window (jtframe's `hcnt<hlim`
  discipline). Keep the runtime write-throttle available too. Document, don't implement
  unless needed.

## 6. Testing

**Simulatable (datapath correctness):**
- New `tb` for the line-buffer scanout datapath: drive timing (hcount/vcount/new_line/de),
  feed a known framebuffer via a behavioral DDR model, assert the pixel output equals
  `fb[vcount][hcount]` for every pixel across several frames.
- **Underflow-robustness test (the key one):** starve the DDR read for one line (model
  returns beats late) and assert ONLY that line is corrupted and the NEXT line is pixel-
  exact — proving no cumulative drift (this is what the old FIFO fails).
- Regression: existing `tb_blitter_system` etc. unaffected (scanout is the reader side).

**Not faithfully simulatable (per #30):** real f2h contention vs the scanout deadline.
→ **HW validation is the real proof:** SDRAM-source path (`SOLARUS_SDRAM_SRC=1`) shows a
stable, non-scrolling image; DDR3 path unchanged; capture via the analog output (camera) +
the `fb_dump` content check. Counters lie about video — trust the screen.

## 7. Risks & mitigations
- **Regresses the proven DDR3 path** (scanout is shared by both). *Mitigation:* the line
  buffer is a strict superset of margin; validate DDR3 path first on HW. Consider a build-
  time `LINEBUF_SCANOUT` define to A/B against the old reader for one RBF if nervous.
- **BRAM inference / CDC** on the dual-clock line buffers. *Mitigation:* confirm M10K
  inference in the fit report; 2-FF sync the swap toggle; data CDC via true dual-port BRAM.
- **Swap-vs-fetch timing race** (swap before the back buffer is fully filled). *Mitigation:*
  only toggle `wr_buf` after the line's last beat is committed; if the fetch didn't finish,
  display stale for that line (acceptable 1-line glitch) — never swap to a buffer mid-fill
  in a way that desyncs position.
- **Tight RBF timing** (currently +0.355ns setup on the Linux build). *Mitigation:* line
  buffer is small/simple; watch the fit timing, keep the read mux shallow.

## 8. Rollout
1. Implement the line-buffer scanout in `openbor_video_reader.sv` (in-place; orthogonal
   paths untouched).
2. Datapath + underflow sims green.
3. Build RBF (CI; Linux dispatch works — `gh workflow run build-rbf.yml -f runner=linux`;
   note the `allowed_actions` repo setting must stay `all`).
4. HW: DDR3 path no-regression, then SDRAM-source path stable (no scroll). Tune the
   write-throttle DOWN (likely toward 0) once the line buffer carries robustness.
5. If marginal, add the writer-gated-to-display-window fallback (§5).

## 9. Decisions made (open points resolved, with rationale)
- **Ping-pong (2 line buffers), not a deeper line FIFO.** One line of slack is ~80 beats —
  far more than the per-pixel coupling it replaces — and minimal BRAM/logic. Deepen only if
  HW shows a single line of slack is insufficient (unlikely).
- **In-place rework of `openbor_video_reader.sv`, not a new module.** The module owns a
  single f2h master shared with ctrl/audio/cart; splitting video out would add a 3rd
  arbiter master. In-place keeps one master + reuses the FSM. (A later clean extraction +
  rename is a non-goal here.)
- **Keep the write-throttle / per-command mux / Option-2 demote.** Complementary; reduce
  f2h load so the line buffer has even more headroom.
