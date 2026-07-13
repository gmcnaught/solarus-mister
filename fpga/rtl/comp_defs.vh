// comp_defs.vh — shared params + golden blend function for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
`ifndef COMP_DEFS_VH
`define COMP_DEFS_VH
`define COMP_BAND_H 8                  // dest band height (rows); BRAM/area knob. 8 (was 16)
                                       // halves the band buffer (640 qw) for Cyclone V fit.
`ifndef COMP_MAXBURST                  // -D-overridable for the Phase-2 T6 sweep
`define COMP_MAXBURST 16               // comp_burst sub-burst cap (beats); reader-starve knob
`endif
// modes / formats mirror blitter_ref.h
`define COMP_COPY 8'd0
`define COMP_KEY  8'd1
`define COMP_CA   8'd2
`define COMP_PA   8'd3
// [v2 escape-elim] new comp_mixer arithmetic modes (mirror BLT_BLEND_ADD/MULTIPLY).
// These are the mixer's internal in_mode encoding; comp_pipeline maps the on-wire
// blend_mode (ADD=4, MULTIPLY=5) onto them. The source pixel arrives already color-
// modulated (color-mod is applied upstream in comp_pipeline's source feed).
`define COMP_ADD  8'd4   // per-channel saturating add: out = min(src+dst, chan_max)
`define COMP_MUL  8'd5   // per-channel multiply:       out = round(src*dst / chan_max)
`define COMP_RGB565   8'd0
`define COMP_ARGB4444 8'd1
`define COMP_PAL8     8'd2  // 8bpp palette-indexed source
// divide-free /255 reduction of a channel total t (Global Constraints)
`define COMP_DIV255(t) ((( (t) + 17'd128 + (((t)+17'd128) >> 8) ) >> 8))
// [v2 escape-elim] exact round(p/chan_max) for the MULTIPLY blend. p = src_ch*dst_ch.
// DIVIDE-FREE reduction (same shape as COMP_DIV255, k=5/6): a literal /31,/63
// synthesises a deep reciprocal-multiply network (~18ns on the core clock = the v2
// timing blowup); shifts+adds instead. Bit-exact to round(p/31),round(p/63) (= the
// Workstream C golden blt_mul565, proven exact by exhaustion).
`define COMP_RND31(p) ((( (p) + 12'd16 + (((p)+12'd16) >> 5) ) >> 5))
`define COMP_RND63(p) ((( (p) + 12'd32 + (((p)+12'd32) >> 6) ) >> 6))
`endif
