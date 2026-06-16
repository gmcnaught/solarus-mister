# SDRAM VRAM source pre-load — design

**Date:** 2026-06-16. **Status:** designed, not started.
**Builds on:** PR #29 (`sdram_psx`, `sdram_src_arb`, `C_SRCSEL` source mux), the #19
staging machinery (`BLT_OP_STAGE` DDR3→SDRAM copy FSM + `src_sdram_*` ports), and
`docs/superpowers/specs/2026-06-15-issue19-sdram-source-staging-design.md`.
**Supersedes** the per-source-on-upload staging trigger from the #19 staging spec
(keeps its fabric primitives; changes *when* and *where* sources are staged).

## Problem

DDR starvation between scanout and the blitter's source reads. Scanout streams the
framebuffer from DDR3 over the shared HPS f2h bus on a hard per-scanline deadline.
During dynamic scenes (scrolling overworld, bg-cache recomposite) the blitter issues
heavy DDR3 **source-read** bursts on the same bus → scanout underflows → the game
image black-screens while the BRAM-generated OSD stays up (the classic
DDR3/scanout-path localization). Two prior fixes are blocked:

- **Per-frame staging (#19 as-specced)** copies sources DDR3→SDRAM on upload, which
  during gameplay happens *while scanout is live* → the copy's DDR3-read side is itself
  the starvation source. Chunking helped but per-tile staging still starved scanout.
- **Scanout-strict arbiter (#30)** — the "make scanout preempt the blitter" fix — is
  **un-sim-able**: the command-level `tb_ddr_blitter_arb` model does not capture the
  real scanout FIFO depth / per-scanline deadline, so a change that passed every sim
  stalled the fabric entirely on HW. Iterating it means iterating blind on silicon.

## Thesis

Eliminate the contention by **relocation, not prioritization**. The fitted DE10-Nano
SDRAM is **128MB** — far larger than a whole quest's decoded image set (Mystery of
Solarus DX is a ~20MB *zip* of compressed PNG + ogg + Lua; decoded to RGB565 the
tileset + sprite atlas is realistically tens of MB). So pre-load **every** static blit
source into SDRAM **once, at quest boot, under the black loading screen**, and read all
sources from the dedicated SDRAM bus at runtime. The f2h DDR3 bus then carries only
scanout reads + framebuffer writes — the source-read bursts that starved scanout are
gone. This **sidesteps #30 entirely** (no arbiter priority change needed) and confines
all DDR3→SDRAM staging traffic to a moment when there is no live scanout deadline.

## Architecture — the memory split

Two-tier "**SDRAM = read-only texture VRAM, DDR3 = scanout + scratch**":

| Memory | Holds | Runtime access |
|---|---|---|
| **SDRAM (128MB, 2nd bus)** | All static blit **sources**: every tileset atlas, sprite sheet, font — decoded to RGB565 | Fabric **read-only** (blit source reads via `C_SRCSEL=1`) |
| **DDR3 (f2h @ 0x3A/0x3B)** | Command ring, control block, framebuffers (BUF0/BUF1), bg-cache region, a small fixed **boot bounce buffer** | Fabric writes (composite), scanout reads, ring fetch |

Consequences:
- At runtime the f2h DDR3 bus carries only **scanout reads + framebuffer writes**. The
  heavy per-tile / per-layer source-read bursts move entirely to the SDRAM bus.
- SDRAM is **written only during boot** → no SDRAM read/write contention during
  gameplay (the second bus does pure reads once the game is live).
- Dynamic render targets (camera/root surfaces, the bg-cache compose region) are blit
  **destinations**, not static sources → they stay in DDR3, unchanged.

**Staging eligibility rule (the correctness crux):** a surface is staged to SDRAM
**only if it is upload-once and never written by the engine after upload** — i.e.
tileset atlases and sprite sheets loaded from PNG. Any surface the engine *renders into*
at runtime (camera/root surfaces, the bg-cache region, and **runtime-rendered text**
from TTF/bitmap fonts) is a dynamic target and stays in DDR3. Fonts are therefore *not*
blanket-staged: only a font's static glyph atlas (if one exists as an upload-once image)
qualifies; rendered text surfaces do not.

## Boot pre-stage sequence

1. **Enumerate** every staging-eligible static image source (tileset atlases, sprite
   sheets, and any static glyph atlases — see the eligibility rule above) from the
   quest's resource DB (`project_db.dat`) at quest mount, without running each map.
2. **Decode** each image to RGB565 and assign it an **SDRAM offset** from a dedicated
   SDRAM bump allocator (independent of the 16MB DDR3 heap). Record
   `{sdram_off, w, h, stride}` in a host-side table keyed by the source surface handle.
3. **Stage** each source via the existing fabric primitive: ARM `memcpy` the decoded
   pixels into a small fixed **DDR3 bounce region**, emit
   `BLT_OP_STAGE {bounce_ddr_off, sdram_dst_off, size}`, fabric copies DDR3→SDRAM,
   reuse the bounce slot for the next source.
4. All of this runs under the **boot black/loading screen** → zero contention with a
   live scanout deadline.

The bounce region only ever holds one source at a time; the DDR3 heap is no longer the
home for source pixels.

## Addressing decouple (the one real change to the #19 read path)

The #19 read path sets `src_sdram_addr = src_byte_cur`, where `src_byte_cur` is the
**DDR3-heap-relative** offset (`SRC_QW + off`). That invariant only holds while the
whole source set fits the 16MB DDR3 heap. A whole-quest resident set is larger, so:

- The blit command carries the source's **SDRAM offset** (from the SDRAM allocator),
  not the DDR3 heap offset.
- When `C_SRCSEL=1`, `src_byte_cur` (and the row/pixel addressing derived from it) is
  computed against the **SDRAM base** from the command, not `SRC_QW`.
- The DDR3 source heap no longer needs to hold source pixels at all; the host emitter
  resolves a source handle → its SDRAM offset via the boot-built table.

The 27-bit `src_sdram_addr` port already addresses a full 128MB byte space, so no port
width change is needed — only the controller's row/bank geometry (below).

## Runtime path

Unchanged from today except that sources resolve to SDRAM. Engine emits blit commands →
fabric reads source line from SDRAM (`C_SRCSEL=1`, page-open burst reads) → composites
into the DDR3 framebuffer → scanout streams the framebuffer. `C_SRCSEL` remains a
runtime mux, but the DDR3 source path can now hold only a transient subset (DDR3 cannot
hold the whole atlas) → it is demoted from a whole-quest safety net to a
**bring-up/debug aid** (single-source equivalence checks, A/B during validation).

## SDRAM controller reconfig (128MB)

Widen `sdram_psx`'s address map from the MT48LC16M16 (32MB: row=`addr[24:12]`,
bank=`addr[11:10]`, col=`addr[9:1]`) to the fitted 128MB module, keeping the v3.0
burst-friendly **column-low** mapping (so a 64-bit beat's 4 words stay in one row across
4 consecutive columns). This is the one fabric change requiring analog-safety + timing
closure care. Confirm the fitted module's geometry (rows/banks) and update the row/bank
slice accordingly; the refresh-at-boundary and BL=2×N burst logic are unchanged.

## Relationship to existing work

- **#30 (scanout-strict arbiter):** **no longer needed** for this path — contention is
  removed by relocating source reads off f2h, not by changing arbiter priority. The
  un-sim-able arbiter problem is sidestepped. (Leave `ddr_blitter_arb` as-is.)
- **bg-cache (#18/#21):** **orthogonal** — it cuts *fabric cycles* (6× overdraw), not
  bus contention. Kept as a 60fps lever. Measure whether SDRAM-source alone closes
  enough of the gap that bg-cache becomes optional; do not remove it as part of this
  work.
- **#19 staging spec:** its fabric primitives (`BLT_OP_STAGE` FSM, `src_sdram_*` write
  ports, burst write) are reused as-is; only the trigger (boot bulk vs per-frame upload)
  and the SDRAM addressing (own allocator vs DDR3-heap-relative) change.

## Validation

### Sim (iverilog, autonomous)
- `tb_sdram_psx` (128MB geometry): stage a known region **past the 32MB boundary** and
  read it back through the read path; assert round-trip bytes — proves the widened
  row/bank map.
- `tb_blitter_system`: bulk-stage N sources to **distinct SDRAM offsets** (decoupled
  from any DDR3 heap offset), then blit each with `C_SRCSEL=1`; assert pixels bit-match
  the DDR3 (`C_SRCSEL=0`) reference render. Proves the full enumerate→stage→render path
  with the new addressing.
- Host: the boot enumerator builds the SDRAM offset table for a fixture resource set
  (correct `{sdram_off, w, h, stride}`, no overlap, monotonic bump); the emitter
  resolves a source handle → its SDRAM offset.

### CI (gated)
RBF builds; timing closes with margin (the 128MB row/bank widening is the path to
watch — pipeline if worst-slack regresses).

### On-device (user-gated — the real verification)
- Real game renders correctly from SDRAM in a **dynamic scrolling** scene (the original
  failure mode) with **no black-screen starvation**: frame counter (`0x3A000000`)
  advancing, OSD + game image both stable under motion.
- Measure decoded-atlas size actually staged (confirm << 128MB).
- Measure fps delta vs the readcache baseline.
- Measure boot time (decode + stage of the full atlas).

## Acceptance criteria
- [ ] `sdram_psx` reconfigured for the fitted 128MB module (column-low map preserved);
      round-trip past 32MB passes in `tb_sdram_psx`.
- [ ] Blit command carries an SDRAM source offset; read path addresses SDRAM by that
      offset (decoupled from `SRC_QW`/DDR3 heap) when `C_SRCSEL=1`.
- [ ] Engine enumerates all staging-eligible static image sources (per the eligibility
      rule) at quest mount, decodes to RGB565, and bulk-stages them DDR3(bounce)→SDRAM
      under the boot screen, building the handle→`{sdram_off,w,h,stride}` table.
- [ ] `tb_blitter_system` multi-source equivalence (distinct SDRAM offsets) passes
      bit-exact vs the DDR3 reference.
- [ ] On HW: dynamic scrolling scene renders from SDRAM with no starvation/black screen;
      OSD + game stable; frame counter advancing (user gate).
- [ ] RBF builds; timing margin held.

## Out of scope
- Eviction / LRU residency (128MB holds the whole quest; nothing to evict).
- Per-area / lazy staging (Approach B/C) — not needed at 128MB.
- The cycles/pixel read-pipeline widening (#19 AC#1) and bg-cache changes — separate
  60fps levers.
- Staging non-image data (audio/Lua) into SDRAM — revisit only if atlas-size
  measurement shows headroom pressure (it should not).

## Risks
- **Decoded atlas size** unverified until measured on-device — expected well under
  128MB, but confirm before assuming whole-quest residency.
- **Resource enumeration** — must verify Solarus's resource API exposes the full
  tileset/sprite/font list at mount without instantiating each map.
- **128MB controller geometry** — any RTL/RBF change risks analog vsync; VISUAL
  validation mandatory (counters lie about analog) + timing closure.
- **Boot time** — full decode + stage runs once at boot; acceptable for a retro core
  but measure it.
