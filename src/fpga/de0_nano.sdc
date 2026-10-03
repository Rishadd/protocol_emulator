# 50 MHz oscillator; everything else is asynchronous (buttons, UART line).
create_clock -name clk_50M -period 20.000 [get_ports clk_50M]
derive_clock_uncertainty

set_false_path -from [get_ports {reset_n start_n bt_rx_pin}]
set_false_path -to   [get_ports {bt_tx_pin led[*]}]
