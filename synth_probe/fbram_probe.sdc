# clk_sys target (~98.4 MHz). The probe is RAM-dominated; this just lets STA report
# a slack number for the FB read/write path as a sanity check alongside the M10K count.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
