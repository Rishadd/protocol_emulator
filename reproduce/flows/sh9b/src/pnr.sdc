# Timing constraints for place-and-route and signoff.
# Same as LibreLane's scripts/base.sdc, except that the clock uncertainty is split:
#   setup: CLOCK_UNCERTAINTY_CONSTRAINT (0.25 ns, covers jitter and skew)
#   hold:  HOLD_UNCERTAINTY (0.1 ns; same-edge check, jitter cancels, only skew margin is needed)
# With 0.25 ns on hold as well, about 1,900 flop-to-flop paths (shift registers, FIFOs, ALU registers) failed
# hold in the fast corner and the resizer inserted 4,260 hold buffers (+20 % cell area), which congested routing.

set hold_uncertainty 0.1
if { [info exists ::env(HOLD_UNCERTAINTY)] } { set hold_uncertainty $::env(HOLD_UNCERTAINTY) }

set clock_port [lindex $::env(CLOCK_PORT) 0]
create_clock [get_ports $clock_port] -name $clock_port -period $::env(CLOCK_PERIOD)
set clocks [get_clocks $clock_port]

set io_delay [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set clk_input [get_port $clock_port]
set clk_indx [lsearch [all_inputs] $clk_input]
set all_inputs_wo_clk [lreplace [all_inputs] $clk_indx $clk_indx ""]
set_input_delay $io_delay -clock $clocks $all_inputs_wo_clk
set_output_delay $io_delay -clock $clocks [all_outputs]

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } { set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design] }
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } { set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design] }

set drv [split $::env(SYNTH_DRIVING_CELL) "/"]
set_driving_cell -lib_cell [lindex $drv 0] -pin [lindex $drv 1] $all_inputs_wo_clk
if { [info exists ::env(SYNTH_CLK_DRIVING_CELL)] && $::env(SYNTH_CLK_DRIVING_CELL) != "" } { set drv [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] }
set_driving_cell -lib_cell [lindex $drv 0] -pin [lindex $drv 1] $clk_input
set_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0] [all_outputs]

puts "\[INFO] Clock uncertainty: setup $::env(CLOCK_UNCERTAINTY_CONSTRAINT) ns, hold $hold_uncertainty ns"
set_clock_uncertainty -setup $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks
set_clock_uncertainty -hold $hold_uncertainty $clocks
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks
set_timing_derate -early [expr 1 - $::env(TIME_DERATING_CONSTRAINT) / 100.0]
set_timing_derate -late [expr 1 + $::env(TIME_DERATING_CONSTRAINT) / 100.0]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}
