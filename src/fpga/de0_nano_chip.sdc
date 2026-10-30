# 50 MHz oscillator; the SPI inputs, HOLD/trigger inputs, protocol pads and reset are asynchronous to it (the chip synchronises them itself).
create_clock -name clk_50M -period 20.000 [get_ports clk_50M]
derive_clock_uncertainty
set_false_path -from [get_ports {reset_n gpio2_in[*] gpio2[*]}]
set_false_path -to   [get_ports {gpio2[*] led[*]}]
