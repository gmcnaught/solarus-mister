# 416×240 framebuffer widening — design

**Goal:** raise the compositor framebuffer from 320×240 to **416×240** so quests that
declare `min_quest_size == max_quest_size == 416x240` can render at all.

**Why now.** Both named targets are gated on this and only this:

| Quest | `solarus_version` | quest size | Blocked by |
|---|---|---|---|
| Ocean's Heart (retail) | **1.6** — runs on the ship engine | `min = max = normal = 416x240` | framebuffer only |
| Zelda: Book of Mudora (`zbom`) | 2.0 — needs the opt-in 2.x line | `min = max = normal = 416x240` | framebuffer **and** engine line |

`min == max` means `-quest-size` cannot negotiate either down; this is the `TOO_LARGE`
rung that `docs/quest-compatibility.md` marked NO-GO when 0 of 7 corpus quests needed
it. Shader offload — the work this displaced — buys these two games one real effect
(`heatwave`) and two pieces of polish, and none of it is visible until the raster is
wide enough to draw into. See `docs/shader-offload-census.md`.

## Geometry

416 is friendly to every alignment the datapath already relies on:

| Quantity | 320×240 | 416×240 |
|---|---|---|
| pixels | 76,800 | 99,840 |
| qwords (4 px/qw) | 19,200 | **24,960** (416/4 = 104 exactly) |
| row stride, qwords | 80 | **104** |
| row stride, bytes | 640 | **832** |
| bytes per DDR3 FB buffer | 153,600 (0x25800) | **199,680 (0x30C00)** |
| qword index width | 15 bits | 15 bits (max 24,959 < 32,768) — unchanged |

The DDR3 FB double-buffer at `0x3A000040` / `0x3A040040` has a 0x40000 bank stride, so
0x30C00 still fits with room to spare. **No address-map change.**

## Video retiming

This is the part that touches the analog signal, so it is derived rather than guessed.

The current generator (`fpga/Solarus.sv:189-227`) spends exactly **3420 MCLK per line**
at `CLK_VIDEO = 53.693 MHz` — the exact Genesis figure — using a mixed `/8, /9, /10`
schedule (320 active @/8 = 2560, plus 860 MCLK of blanking). That yields
H = 53,693,182 / 3420 = **15,700 Hz** and V = 15,700 / 262 = **59.92 Hz**.

**Keep 3420 MCLK/line and 262 lines; change only how the line is divided into pixels.**
A uniform **/6** gives 3420 / 6 = **570 pixels per line**, exactly, with no remainder —
so `ce_pix` becomes a plain constant-rate 8.949 MHz enable and the mixed schedule goes
away entirely. H and V rates are **bit-identical to what ships today**.

```
H_ACTIVE 416 + H_FP 26 + H_SYNC 51 + H_BP 77 = H_TOTAL 570
V unchanged: 240 + 2 + 3 + 17 = 262
```

Porch derivation — the constraint that matters is sync *width in microseconds*, since
that is what a display's PLL locks to:

| | ships today (@/8) | this design (@/6) |
|---|---|---|
| H sync | 38 px = **5.66 µs** | 51 px = **5.70 µs** |
| H front porch | 17 px = 2.53 µs | 26 px = 2.91 µs |
| H back porch | 45 px = 6.71 µs | 77 px = 8.60 µs |
| H active | 320 px = 47.68 µs | 416 px = **46.48 µs** |
| H blanking total | 16.02 µs | 17.21 µs |

Sync width is held at the value already proven on the operator's displays. Active time
*shrinks* slightly (46.48 µs vs 47.68 µs) because 416 narrower pixels occupy marginally
less of the line than 320 wider ones; the surplus lands in the back porch, which shifts
the image right by roughly 1.4 µs. The existing OSD H-position control (`h_adj`) is the
trim for that, and the final porch split is an **operator-gated** number — it must be
judged on a real display, not asserted here.

`VIDEO_ARX/ARY` becomes **26:15** (416×240 with square pixels), replacing the fixed 4:3.

## Smaller quests: pillarbox

Every quest shipped today is 320×240, and the engine sizes its surfaces from
`Video::get_quest_size()` — the quest's own declaration — not from our framebuffer. A
320-wide root drawn into a 416-wide FB would sit hard left with 96 columns of whatever
was there before.

**Rule: centre it.** Offset by `((FB_W - quest_w)/2, (FB_H - quest_h)/2)` — +48 px
horizontally for a 320-wide quest, 0 vertically. This is the `FITS_SMALLER` rung the
compat survey defined ("smaller than the framebuffer; composite with a border"), and
combined with the 26:15 raster it displays a correct 4:3 picture inside black bars.

**Apply it as a constant qword offset in the fabric, not a per-command bias on the
host.** The on-chip framebuffer address is `qword = y*FB_ROW_QW + (x>>2)`, `lane =
x[1:0]`. A horizontal offset that is a **multiple of 4** is therefore exactly a
constant added to the qword index and leaves the lane untouched: for a 320-wide quest,
+48 px == **+12 qwords**, and x=319 lands at `79+12 = 91`, lane 3 — identical to
computing `(319+48)>>2 = 91`, lane 3. So the whole pillarbox is one addend at the three
`fb_wr_qw`/`fb_rd_qw` sites in `comp_pipeline.sv` plus one field in the control block,
instead of a bias threaded through every host emit site (`blt_blit`, `blt_fill`, tile
lists, the sprite channel, the grid/tilemap commands — there is no single host choke
point).

Clipping still composes: the host clips draws to the **quest** rect (`clip_to_fb`,
which is what stops the title screen's deliberately off-surface clouds at x=320 from
bleeding into the right pillar), and `comp_span_setup` clips to the **FB** rect. Since
quest-space x ∈ [0,320) maps to [48,368) ⊂ [0,416), the offset can never push a clipped
pixel out of the framebuffer. Requires `(FB_W - quest_w)/2` to be a multiple of 4 —
true for 416 vs 320, and asserted rather than assumed.

Quest size is available as engine truth without a new dependency:
`mister_tag_root_surface()` is called from the **MainLoop constructor** immediately
after the root surface is built from `Video::get_quest_size()`
(`patches/series/0037-*.patch`), i.e. before any draw, so the tagged root's dimensions
are the quest size and every guard below can rely on them.

The renderer currently uses `FB_W`/`FB_H` for two different jobs that this change
separates: as the framebuffer extent (clipping, `clip_to_fb`) and as a *proxy for
"is this the full-screen root/camera surface"* in equality guards
(`mister_blitter_renderer.cpp:1651, 2076, 2137, 3198, 3204, 3507, 3531, 3794`). Those
guards must compare against the **quest** size, not the FB size, or every one of them
stops matching the moment the two differ — silently disabling the overlay path, the
camera alias and the scroll fabric path on a 320×240 quest.

## Change set

**RTL**
- `comp_fbram.sv` — `FB_QWORDS` 19200 → 24960 (`AW = 15` unchanged).
- `comp_pipeline.sv` — three `cur_dst_y * 16'd80` sites (847, 922, 947) → `*104`.
- `comp_span_setup.sv` — `FB_W` 320 → 416 (`FB_H` unchanged). `MAX_SPANS = 240` is
  vertical and unchanged.
- `fb_ddr_writer.sv` — `FB_QWORDS` 19200 → 24960, `LINE_BEATS` 80 → 104.
- `ddr3_scan_adapter.sv` — `LINE_QW` 80 → 104.
- `openbor_video_reader.sv` — `LINE_BURST`/`LINE_STRIDE` 80 → 104, buffer stride
  640 → 832 B, and the two-line RGB565 line buffer (`:384`) 80 → 104 words each.
- `openbor_video_timing.sv` — `H_ACTIVE`/`H_TOTAL`/porches as derived above.
- `Solarus.sv` — uniform `/6` `ce_pix`, `pix_in_line` wraps at 569; `VIDEO_ARX/ARY`.

**Host**
- `blitter_ref.h` — `BLT_FB_WIDTH` 320 → 416.
- `mister_blitter_renderer.cpp:611` — `FB_W` 320 → 416; add the centring bias; split
  the FB-extent uses from the is-this-the-root guards.
- Host suite: 47 references across `blitter_ref.c`, `test_spritelist.c`,
  `test_tilemap.c`, `test_grid_walk_equiv.c`, `tests/gridov_equiv_test.c`, plus
  `scripts/tests/test_wire_constants.py`.

## How the pillarbox offset actually reaches the fabric (as built)

No new control-block address. `C_SRCSEL` (0x38) already documents itself as mostly
spare — bit 0 (the DDR3-vs-SDRAM source mux) is dead since the single-source collapse,
and only bits[15:8] are live (the #34 f2h write-throttle). The offset rides in
**bits[31:16]**, latched in `blitter_top`'s `S_GOT_SRCSEL` alongside the throttle, one
control fetch per frame.

The CLEAR fill is the single command addressed in **raster** space rather than quest
space — it has to wipe the pillars too — so `blitter_top` holds a `pillar_suppress` reg
that forces `c_pillar_off` to 0 for it, set in `S_GOT_CLEAR` and released in
`S_CLR_FILL_WAIT`. It is a reg rather than another per-command `c_*` field precisely
because `c_dst_x`/`c_dst_y` are assigned at eight separate sites (ring, TILELIST,
TILELIST_RES, SPRITELIST, TILEMAP, …) and adding a field to each is the "missed one"
failure this change is trying to design out. The clear's own rect also moved from a
hardcoded `16'd320`/`16'd240` to `FB_W`/`FB_H`.

Coverage: `tb_comp_pipeline` BLIT 9 replays BLIT 1's COPY with a non-zero
`c_pillar_off` and asserts both that the pixels land shifted **and** that the unshifted
destination stays background — then the offset was mutated to `16'd0` in the RTL to
confirm the case fails (5 errors), so it is not vacuous.

## Validation plan

Two legs, and the first one is the one that can regress users:

1. **Regression — the shipped 320×240 corpus.** MoSDX must still render correctly,
   now pillarboxed. Objective gate: `shot_capture.sh` + `shot_score.py` footer
   textmatch (the title cycles day/night, so a full-frame match is useless), plus an
   fps A/B against the current ship build. Operator visual gate for the pillarbox
   itself and for the new H timing — neither is self-declarable.
2. **New capability — Ocean's Heart.** 416×240 on the **ship 1.6 engine**. Boots,
   renders, and survives a soak. `zbom` additionally needs the 2.x line and is a
   separate follow-up.

> **The render judge had to be fixed before it could judge this.**
> `scripts/debug/shot_score.py` hardcoded `W, H = 320, 240` and a footer band at rows
> 205–240. At a 416-wide raster that does not fail — it computes every metric over the
> wrong pixel grid, and the period-2 alternation test in particular is meaningless with
> the wrong row stride. It now infers the raster from the capture against a
> `KNOWN_RASTERS` list (416×240 and 320×240, each also accepted pixel-doubled), derives
> the footer band from `H`, and **raises on an unrecognised size rather than guessing**.
> Verified against synthesised captures at 416×240, 320×240, 832×480 (decimates to
> 416×240) and a rejected 300×200.

Deploy engine+RBF **together** — geometry is wire ABI, so they are a matched pair and
the rollback unit is the pair, exactly as for the ring double-buffer.

## Risks, stated up front

1. **BRAM.** `comp_fbram` is 4 banks × 16 bit × FB_QWORDS. At 19,200 that is
   ceil(19200/512) = 38 M10K per bank = **152**; at 24,960 it is 49 per bank = **196**.
   **+44 M10K**, taking the design from ~61 % to roughly **69 %** of 553. Expected to
   fit — Stage 5 Phase 2 freed ~158 M10K precisely to bank headroom like this — but
   unverified until Quartus says so.
2. **The fb address path.** `comp_fbram.sv:54-56` records that the `fb_rd` address mux
   is the placement-sensitive path, held by a pinned fitter seed, and that a previous
   change there regressed the HDMI PLL path into negative slack. `y*104` is a
   three-term shift-add (64+32+8) where `y*80` was two (64+16). Judge timing
   **comparatively** against a master build; `DQCAP_SLACK_NS` is mislabelled and must
   not be used to pick anything.
3. **Display compatibility.** New H timing. Operator visual gate required; this is not
   self-declarable.
4. **Matched pair.** Geometry is wire-ABI. Engine and RBF ship and roll back together,
   exactly as the ring-double-buffer note in `CLAUDE.md` requires.
