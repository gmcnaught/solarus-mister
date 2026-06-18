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
# NOTE: the set_input/output_delay magnitudes below are the MiSTer SDRAM-module
# reference values (DE10-Nano SDRAM, ~-7 grade); they are a STARTING POINT to be
# validated against the reported SDRAM-path slack, not silicon-measured here.
set sdram_clk_src \
    {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

create_generated_clock -name SDRAM_CLK \
    -source [get_pins $sdram_clk_src] -invert [get_ports SDRAM_CLK]

# DQ read-capture: data is driven by the chip relative to SDRAM_CLK and captured
# by clk_sys in sdram_psx. tAC(max) ~6 ns, tOH(min) ~2.5 ns over the half-cycle.
set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 3.2 [get_ports {SDRAM_DQ[*]}]

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
