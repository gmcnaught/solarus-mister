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

# clk_sys (general[0]) and clk_sdram (general[3], the SDRAM_CLK source — #34
# fallback C) share ONE group: they must be SYNCHRONOUS so the SDRAM DQ-capture
# path (SDRAM_CLK -> clk_sys) is actually analyzed by STA. Together they are async
# to clk_pix (general[2]) and pll_audio.
set_clock_groups -asynchronous \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
                        emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
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
# FALLBACK C 2026-06-19 (#34): SDRAM_CLK is now sourced from a DEDICATED,
# phase-shiftable PLL output `clk_sdram` (general[3], 98.4375 MHz, phase swept) —
# NOT the altddio-invert of clk_sys. Phase-shifting the chip's clock slides the
# read-data eye so the (fixed) clk_sys capture edge lands inside the valid window
# after the unpackable ~5.2 ns dout64 demux route. Because the capture is now timed
# against a REAL center-aligned clock, we model it HONESTLY: drop the masking
# keeper->keeper MULTICYCLE-2 (it HID the path) and use a real set_input_delay so
# STA reports the TRUE single-cycle capture margin. Capture stays on clk_sys (zero
# RTL/latency change). clk_sdram (general[3]) is grouped WITH clk_sys in the
# clock-groups command above so the two are SYNCHRONOUS and the DQ capture path
# (SDRAM_CLK -> clk_sys) is actually analyzed.
set sdram_clk_src \
    {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
# clk_sys (general[0]) launches command/address/data toward the chip.
set clk_sys_src \
    {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

create_generated_clock -name SDRAM_CLK \
    -source [get_pins $sdram_clk_src] -invert [get_ports SDRAM_CLK]

# DQ read-capture: honest source-synchronous input delay relative to SDRAM_CLK.
# Numbers are AS4C32M16 SDR SDRAM datasheet-derived (clock-to-DQ access tAC max
# plus a small board allowance; output-hold tOH min) — validate against the actual
# module datasheet. With SDRAM_CLK center-aligned via the clk_sdram phase, STA
# reports the TRUE single-cycle capture margin on SDRAM_DQ -> sdram_psx|dout64[*].
set_input_delay -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# Command/address/data driven out toward the chip (setup/hold at the chip pins).
set sdram_out_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
                     SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS \
                     SDRAM_nWE SDRAM_CKE}
set_output_delay -clock SDRAM_CLK -max 1.6  [get_ports $sdram_out_ports]
set_output_delay -clock SDRAM_CLK -min -0.9 [get_ports $sdram_out_ports]

# Read/capture direction (SDRAM_CLK -> clk_sys): multicycle-2 setup, hold-1.
# The earlier "center-align via phase, single-cycle" assumption is FALSE here:
# SDRAM_CLK is a DDIO-forwarded clock that takes ~12 ns to reach the chip pin,
# so DQ arrival lands ~one full period (~10.16 ns) past the single-cycle latch
# edge — STA showed a structural -10.449 ns that NO phase can recover (#44). The
# data is launched on SDRAM_CLK edge N and captured on clk_sys edge N+2; the
# jtframe burst controller's read pipeline does not consume dout until well after
# that, so the 2-cycle setup is honest. hold-1 keeps the hold edge at N+1 so the
# (already +11 ns) hold margin is unaffected.
set_multicycle_path -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks $clk_sys_src] -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks $clk_sys_src] -hold  -end 1

# Write/command-out direction (clk_sys -> SDRAM_CLK): keep the 2-cycle relaxation —
# the drive-out side has margin and the CAS pipeline round trip spans >1 cycle.
set_multicycle_path -to [get_clocks {SDRAM_CLK}] \
    -from [get_clocks $clk_sys_src] -setup -end 2
set_multicycle_path -to [get_clocks {SDRAM_CLK}] \
    -from [get_clocks $clk_sys_src] -hold  -end 2
