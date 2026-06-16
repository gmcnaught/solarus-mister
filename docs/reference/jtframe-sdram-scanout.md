# jtframe — SDRAM controllers & frame-buffer scanout (deep dive)

Reference knowledge lifted from **jotego/jtcores `modules/jtframe`** (GPLv3) for
this port. jtframe is the most battle-tested open MiSTer framework; it has
already solved two problems we are actively fighting:

1. **SDRAM controller geometry / banking / refresh** — informs issue **#31**
   (SDRAM 64MB geometry reconfig) and the AS4C32M16 part work.
2. **Rendering into off-chip RAM and scanning it out without contention/tearing**
   — informs the [[fpga-sdram-source-f2h-scanout-contention]] problem (#19/#30,
   epic #12 pre-load-atlas approach).

Upstream root (branch `master`):
`https://github.com/jotego/jtcores/tree/master/modules/jtframe`

Companion: [jtframe framework index](./jtframe-index.md).

---

## 1. SDRAM controllers

jtframe ships **three** SDRAM controllers plus a burst variant. All stable; only
`jtframe_sdram64` is wired into `jtframe_board`. Source: `hdl/sdram/`.
Docs: `doc/sdram.md`, `doc/burst_sdram.md`.

| Controller | File | Role |
|---|---|---|
| `jtframe_sdram` | `jtframe_sdram.v` | Generic, CL=2, ≤48 MHz. ROM read-mostly. Legacy. |
| `jtframe_sdram_bank` | `jtframe_sdram_bank*.v` | High-throughput via **bank interleaving**. Legacy-ish. |
| **`jtframe_sdram64`** | `jtframe_sdram64{,_bank,_init,_latch,_rfsh}.v` | **Current** controller, wired to the board. burst=2 (64-bit). 4 banks. |
| `jtframe_burst_sdram` | `jtframe_burst_sdram.v` (+ `jtframe_burst_*`) | Single-consumer sequential burst, **same pinout/programming IF as sdram64**. |

### 1.1 `jtframe_sdram64` — geometry & key parameters

The controller is parameterized; geometry is set by `AW` and the per-bank burst
lengths. From `hdl/sdram/jtframe_sdram64.v`:

```
parameter AW = 22,        // address width (16-bit words) per bank
          HF = 1,         // 1 = high-freq op (insert idle cycles); HF starts >66.6 MHz
          BA0_LEN..BA3_LEN = 64,   // per-bank burst: 1=16b, 2=32b, 4=64b
          PROG_LEN = 64,
          BA0_WEN..BA3_WEN = ...,  // enable write per bank — keep minimal for timing/placement
          BA0_AUTOPRECH.. = 0,     // auto-precharge per bank
          MISTER = 1,              // short DQM onto SDRAM_A[12:11] (MiSTer 128MB module wiring)
          RFSHCNT = 9,             // refresh commands issued per `rfsh` pulse
          BAPRIO  = 1              // bank 0 highest priority, bank 3 lowest
```

**Geometry is set by `AW`** (from `doc/burst_sdram.md`, same address math as sdram64):

| `AW` | Per bank | 4 banks total |
|---|---|---|
| 22 | 8 MB | 32 MB |
| 23 | 16 MB | 64 MB |

> ⮕ **Directly relevant to #31.** Our 64 MB geometry == `AW=23`. The MiSTer
> **128 MB** SDRAM module is **2× AS4C32M16SB** (jtframe SDRAM catalogue IDs
> 1/8/9) — the exact part we corrected to in commit a38ea9e. jtframe reaches the
> upper 64 MB by enabling the larger `AW`; study how `jtframe_sdram64_bank.v`
> forms the row/col/bank split before re-deriving our own.

### 1.2 Refresh — `rfsh` driven by horizontal blank

`RFSHCNT` refresh commands are issued per `rfsh` pulse. jtframe drives `rfsh`
from the **15 kHz horizontal blank**:

> "triggers a distributed cycle of RFSHCNT refresh commands … meant to be the
> horizontal blanking of a 15 kHz video signal. Using HB as rfsh signal also
> prevents having a bank active longer than tRAS_max (120 µs)."

Default cadence: 8192 refresh every 64 ms ≈ 1 per 7.8 µs ≈ 8.2 per line at
15 kHz. The divider constants are emitted by `jtframe cfgstr` as `JTFRAME_RFSH_*`
macros. Refresh fires **once every 64 µs regardless of core clock**.

> ⮕ Insight for our SDRAM-source scanout: tying refresh to HBlank both meets the
> refresh spec *and* keeps banks from exceeding tRAS_max — a free win when the
> scanout reader holds a bank open across a line.

### 1.3 Bank model & arbitration

- 4 independent banks; each has its own request port (`baN_addr`, `rd`/`wr` bit,
  `baN_din`, `baN_dsn` write mask) and its own handshake (`ack`/`dst`/`dok`/`rdy`).
- `BAPRIO=1`: bank 0 served first, bank 3 last — **arbitration is priority-fixed,
  not round-robin.** This is how jtframe makes scanout contention deterministic
  (cf. our un-sim-able arbiter problem in [[fpga-sdram-source-f2h-scanout-contention]]).
- Per-bank `*_WEN` lets read-only banks compile without write logic → eases timing.
- `jtframe_sdram64_bank.v` = per-bank state machine; `_init.v` = power-up/mode-set
  sequence (>150 µs); `_rfsh.v` = distributed refresh; `_latch.v` = DQ capture.

### 1.4 `jtframe_burst_sdram` — single-consumer sequential bursts

Same SDRAM pinout & programming interface as sdram64, but **one runtime port**
instead of four bank ports. Runtime handshake (from `doc/burst_sdram.md`):

```
input  [AW-1:0] addr;  input [1:0] ba;
input  rd, wr;  input [15:0] din;  output [15:0] dout;
output ack;   // request accepted
output dst;   // first valid read word
output dok;   // data transfer in progress
output rdy;   // transfer finished
```

- `AW=22` → 8 MB/bank (32 MB); `AW=23` → 16 MB/bank (64 MB).
- Switches SDRAM to **full-page burst mode**; terminates when the consumer drops
  `rd`/`wr`. Keep `rd` high only for the words you want (short bursts).
- `MISTER=1` mirrors `DQM` onto `A[12:11]`.

> ⮕ **This is the closest fit for our "pre-load whole-quest atlas to SDRAM and
> stream it out" model (epic #12).** A single sequential scanout consumer reading
> full-page bursts is exactly `jtframe_burst_sdram`'s sweet spot — and it reuses
> the sdram64 programmer for the boot-time atlas load.

### 1.5 MiSTer SDRAM electrical gotchas (hard-won, from `doc/sdram.md`)

These are *physical* findings, not RTL — worth keeping:

- **Slowest slew rate fixes loading on every tested module.** Fast slew → VDD
  ripple to >4 V and A-line undershoot to −0.9 V; `Contra` failed to load on 6/7
  modules at fast slew, 0/7 at slow. **Set SDRAM pins to the slowest slew rate.**
- **Set DQ at CAS, not RAS**, for writes — fewer module failures.
- MiSTer 128 MB modules have severe VDD ripple (Dec-2020 batch); 32 MB modules
  are slightly better. Adding 10–33 µF bulk cap improves the clock-shift window.
- **Clock shift window** per module is ~2.5–8.75 ns; wider min↔max = cleaner
  signals. Macros: `JTFRAME_SHIFT` (state-count adjust for large shifts),
  `JTFRAME_180SHIFT` (full 180° via IO primitive — eases routing but reads the
  last burst word with the bus at Hi-Z, more failure-prone).
- `JTFRAME_SDRAM_REPACK`: extra DQ latch stage so the fitter uses pad flip-flops
  (cures `SDRAM_DQ` setup violations); costs one cycle of latency.
- `JTFRAME_NOHOLDBUS`: release the data bus when idle (holding it works better at
  48 MHz; irrelevant at 96 MHz).

### 1.6 Throughput reference (from `doc/sdram.md`, `jtframe_sdram_bank`)

| Freq | Efficiency (MiSTer) | Throughput | Latency min/avg/max |
|---|---|---|---|
| <64 MHz | 72% (A-lines shorted to DQM) | ~92 MB/s | 7 / 9 / 32 cyc |
| 96 MHz | 53.3% | ~102 MB/s | 9 / 12 / 36 cyc |

The DQM/A-line short (the MiSTer 128 MB wiring) costs efficiency — budget for it.

---

## 2. Frame-buffer scanout — `jtframe_lfbuf_*` (line frame buffer)

Source: `hdl/video/jtframe_lfbuf_*`. This is jtframe's answer to **"render into
off-chip memory and scan it out cleanly"** — our exact scanout-contention domain.

### 2.1 The architecture (from `jtframe_lfbuf_line.v` header)

A **frame buffer built on top of two line buffers**, using **4× BRAM lines**, on a
16-bit external memory. Per-line ping-pong:

```
object/render unit ──writes──▶ line buffer A ──dumped──▶ external RAM (one line)
                                                              │
external RAM ──one line read──▶ line buffer B ──dumped──▶ screen (during HBlank)
```

So at any instant: one line being filled by the renderer, the previous line being
written to RAM, one line being read from RAM, the previous read line being shown.
**BRAM line buffers absorb the timing mismatch between render, RAM, and scanout —
the off-chip RAM is only ever touched a line at a time, never randomly during
active scan.** That is precisely the contention discipline we lacked.

It also does **integer/fractional zoom** (`h_step`/`v_step` in `1.FW`
fixed-point) and is the basis of jtframe's rotation path (`hdl/video/rotate/`).

> ⚠ jtframe's own header: *"This module is not fully tested yet."* Treat as a
> design pattern to adapt, not a drop-in.

### 2.2 Swappable storage backend — the key reuse pattern

The generic frontend `jtframe_lfbuf_line.v` is wrapped by a thin **backend**
module that owns only the memory interface. Same `ln_*` core interface; different
RAM behind it:

| Wrapper | Backend memory | Notes |
|---|---|---|
| `jtframe_lfbuf_ddr{,_ctrl}` | **MiSTer DDR3** | `ddram_addr[28:0]`, 64-bit `ddram_din/dout`, `ddram_burstcnt[7:0]`, `ddram_be`, `ddram_rd/we`, `ddram_busy/dout_ready`. |
| `jtframe_lfbuf_sdr{,_ctrl}` | **SDRAM** | raw `SDRAM_A/DQ/BA/nWE/nCAS/nRAS/nCS/CKE/DQML/DQMH`. |
| `jtframe_lfbuf_sram{,_ctrl}` | external SRAM | |
| `jtframe_lfbuf_cram{,_ctrl}` | cellular RAM / PSRAM | |
| `jtframe_lfbuf_bram{,_ctrl}` | on-chip BRAM | smallest; no off-chip traffic. |

Core-facing interface (identical across backends), from `jtframe_lfbuf_ddr.v`:

```
// video status: vrender, hdump, hs, vs, lhbl, lvbl
// zoom: h_step, v_step  [FW:0] fixed point
// core line interface:
input  [HW-1:0] ln_addr;  input [DW-1:0] ln_data;  input ln_we, ln_done;
output ln_hs, ln_vs, ln_lvbl;  output [DW-1:0] ln_dout, ln_pxl;  output [VW-1:0] ln_v;
```

Params: `DW=16` (pixel width), `VW=8` (vcount), `HW=9` (hcount), `FW=8` (zoom frac).
Reset must be held **>150 µs** (SDRAM/DDR init).

> ⮕ **The `jtframe_lfbuf_ddr` interface is our DDR3.** Our blitter writes frames
> to MiSTer DDR at `0x3A000000`; `ddram_addr[28:0]`/64-bit/`burstcnt` is the same
> Avalon-ish DDR port the HPS/scaler uses. If we ever move framebuffer composition
> into fabric, this is the reference scanout reader. See [[mister-ddr-and-sdram-hw-access]].

### 2.3 Why this matters for our scanout-contention bug

Our [[fpga-sdram-source-f2h-scanout-contention]] note: #19 staging black-screened
dynamic scenes because the f2h arbiter between SDRAM source and scanout was
un-sim-able; #30 superseded; new plan = pre-load whole atlas to SDRAM at boot.
jtframe's lfbuf shows the missing discipline:

- **Never random-access off-chip RAM during active scan.** Quantize to whole-line
  read/write bursts, buffered through BRAM.
- **Swap at `vs`** (vertical sync) — `jtframe_lfbuf_line` swaps the frame buffer
  on vsync, giving a clean tear-free boundary.
- **Fixed-priority bank arbitration** (`BAPRIO`) makes worst-case latency bounded
  and analyzable — which is exactly what an un-sim-able arbiter denied us.

---

## 3. `mem.yaml` — declarative memory-map generator (worth adopting)

jtframe lets a core describe its whole SDRAM/BRAM map in `cfg/mem.yaml`; the `jtframe mem`
tool generates the RTL (`game_sdram.v`, `mem_ports.inc`). Docs: `doc/jtframe-mem.md`,
`doc/sdram.md` §"Memory RTL Generator". Two SDRAM modes (mutually exclusive):

- **`banks:`** — 1–4 banks, each a list of buses (`addr_width` in 16-bit words,
  `data_width` 8/16/32, `offset`, optional `latch`, `cache_size`, `rw`,
  `gfx_sort`). Maps a bus to a physical bank.
- **`cache-lanes:`** — 1–8 lanes, widths 8/16/32/64/128, with `blocks{count,size}`
  and an `at{bank,offset,length}` placement; `rw` only on lanes 0–3.

Also generates BRAM blocks (with optional SD-card save/restore via IOCTL), audio
mixing nets, and clock-enable (`cen`) dividers — all from the one file.

> ⮕ We don't use the jtframe core skeleton, so we can't `jtframe mem` directly.
> But the **schema is a good mental model** for documenting our own SDRAM atlas
> layout (banks, offsets, widths, which regions are RW vs RO), and the
> `do_not_erase` / `rw` / `latch` flags name decisions we must make by hand.

---

## 4. What to actually pull vs. just learn from

| Item | Verdict for this port |
|---|---|
| `jtframe_sdram64` geometry math (`AW`, bank split) | **Study & adapt** for #31 — re-derive row/col/bank for AS4C32M16. |
| HBlank-driven refresh (`rfsh`, tRAS_max) | **Adopt the pattern** in our SDRAM source controller. |
| `jtframe_burst_sdram` single-consumer burst | **Closest fit** for boot-load + sequential scanout of the atlas. |
| `jtframe_lfbuf_*` line-buffer ping-pong + vs-swap | **Adopt the discipline**: whole-line bursts through BRAM, swap on vsync. |
| MiSTer slew-rate / DQ-at-CAS / clock-shift findings | **Apply directly** — physical, module-independent. |
| `mem.yaml` schema | **Use as a documentation model**, not the tool. |
| Full lfbuf RTL | Reference only — marked "not fully tested" upstream. |

## Sources

- `modules/jtframe/doc/sdram.md`, `doc/burst_sdram.md`, `doc/jtframe-mem.md`
- `modules/jtframe/hdl/sdram/jtframe_sdram64.v` (+ `_bank/_init/_latch/_rfsh`),
  `jtframe_burst_sdram.v`
- `modules/jtframe/hdl/video/jtframe_lfbuf_line.v`, `jtframe_lfbuf_ddr.v`,
  `jtframe_lfbuf_sdr.v` (+ `_ctrl` variants)
- jtcores is GPLv3 — same license as our engine; reuse is license-compatible but
  attribute jotego if any RTL is lifted.
