# Solarus MiSTer core project-level timing constraints.
# Forked from the MiSTer_OpenBOR core (shared DDR3 video/audio/joystick RTL).
#
# Background: same hybrid-architecture pattern as PICO-8 / OpenBOR.
# The user PLL (emu|pll|pll_inst) produces clk_sys (~100 MHz, DDR3)
# and clk_pix (53.693 MHz, exact Genesis MCLK / 8). A separate
# pll_audio drives the audio output domain. CDC paths between these
# domains are correctly handled by 2-FF synchronizers and dcfifos in
# the reader, but without explicit asynchronous-group declarations
# Quartus tries to time them as synchronous and reports phantom
# -2 to -3 ns setup failures. The bitstream may still work by silicon
# luck, but any RTL change or recompile risks tripping past the lucky
# margin into actual data corruption.
#
# Fix: declare each user PLL output (and pll_audio) as its own
# asynchronous clock group. Same pattern that fixed PICO-8 v1.0
# (clk_pix slack -4.4 ns -> +35.6 ns).

set_clock_groups -asynchronous \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]

# ============================================================================
# SDRAM physical-interface timing (#34)
# ----------------------------------------------------------------------------
# The SDRAM bus was added by the VRAM-relocation work (framebuffer moved off
# DDR3 onto the dedicated SDRAM chip). It inherited NO I/O constraints: there is
# no create_clock for SDRAM_CLK and no set_input/output_delay on SDRAM_DQ/A/ctrl.
# Consequently STA never analyzed the external read-capture path at all — a core
# can report fully-clean clk_sys setup/hold (it did: +0.075 / +0.246) while the
# SDRAM_DQ -> controller capture has zero/negative margin, invisible to STA.
#
# Topology: clk_sys = PLL general[0] (~98.44 MHz, phase 0). sdram_psx generates
# SDRAM_CLK via altddio_out (datain_h=0, datain_l=1) => SDRAM_CLK = ~clk_sys
# (180-deg / half-cycle shifted), the standard Sorgelig MiSTer SDRAM clocking.
# Model that as a generated clock so STA knows the chip's clock and can time the
# DQ round-trip. Structure mirrors jtframe's validated mister/sdram_clk96.sdc
# (generated SDRAM_CLK + clock-to-clock multicycle for the >1-cycle round trip).
#
# CORRECTED 2026-06-19 (#34): the DQ read-capture model now mirrors jtframe's
# silicon-validated sdram_clk96.sdc EXACTLY. The earlier version added
# `set_input_delay -clock SDRAM_CLK 6.4/3.2` on SDRAM_DQ — but SDRAM_CLK is the
# INVERTED clk_sys, so that imposed a HALF-CYCLE chip-relative window on the
# DQ->dout64 capture (a 1->4 demux that can't pack into the I/O input register and
# carries ~5.2 ns of fabric routing) => a false -2.7 ns setup "violation" that no
# RTL change could meet without adding read latency (the dq_in attempt, reverted
# 66f852b, broke the blitter write-coalesce). jtframe does NOT set_input_delay on
# SDRAM_DQ; it constrains the capture with a keeper->keeper MULTICYCLE-2 from the
# DQ pins to the capture flop, correctly modeling the inverted-clock round trip
# (the capture edge is ~1.5 cycles away, not the default 0.5) and giving the
# unpackable-demux routing 2 cycles to settle. Zero RTL/latency change.
set sdram_clk_src \
    {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

create_generated_clock -name SDRAM_CLK \
    -source [get_pins $sdram_clk_src] -invert [get_ports SDRAM_CLK]

# DQ read-capture: keeper->keeper multicycle from the SDRAM_DQ pins to the
# sdram_psx capture flop dout64 (the assembled beat; `data`/`dout` is unconnected
# in emu so it's optimized away — dout64[*] is exactly the reported violated path).
# Mirrors jtframe: `-setup -end -from {SDRAM_DQ[*]} -to {...dq_ff[*]} 2`.
# (jtframe sets ONLY -setup -end 2 for the DQ->capture input; the default hold
# relationship for a setup-multicycle-2 path is -hold -end 1, which is correct —
# adding a hold multicycle here would mis-model and risk a false hold violation.)
set sdram_dq_capture {emu:emu|sdram_psx:sps|dout64[*]}
set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] \
    -to [get_keepers $sdram_dq_capture] 2

# Command/address/data driven out toward the chip (setup/hold at the chip pins).
set sdram_out_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
                     SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS \
                     SDRAM_nWE SDRAM_CKE}
set_output_delay -clock SDRAM_CLK -max 1.6  [get_ports $sdram_out_ports]
set_output_delay -clock SDRAM_CLK -min -0.9 [get_ports $sdram_out_ports]

# The chip's clock is the inverse of clk_sys, so a launch-to-latch edge is half a
# clk_sys period; the SDRAM round trip (CAS pipeline) spans multiple clk_sys
# cycles. Relax the SDRAM_CLK <-> clk_sys paths to 2 cycles (jtframe pattern) so
# STA models the real multi-cycle relationship instead of an impossible 0.5-cycle.
set_multicycle_path -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks $sdram_clk_src] -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks $sdram_clk_src] -hold  -end 2
set_multicycle_path -to [get_clocks {SDRAM_CLK}] \
    -from [get_clocks $sdram_clk_src] -setup -end 2
set_multicycle_path -to [get_clocks {SDRAM_CLK}] \
    -from [get_clocks $sdram_clk_src] -hold  -end 2
