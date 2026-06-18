// comp_defs.vh — shared params + golden blend function for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
`ifndef COMP_DEFS_VH
`define COMP_DEFS_VH
`define COMP_BAND_H 16                 // dest band height (rows); BRAM/throughput knob (Task 3)
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
