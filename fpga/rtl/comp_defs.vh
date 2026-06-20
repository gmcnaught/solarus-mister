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
`define COMP_RGB565   8'd0
`define COMP_ARGB4444 8'd1
// divide-free /255 reduction of a channel total t (Global Constraints)
`define COMP_DIV255(t) ((( (t) + 17'd128 + (((t)+17'd128) >> 8) ) >> 8))
`endif
