# Yosys area/cell-count estimate against the real IHP sg13cmos5l standard-cell library.
# Mimics the LibreLane synthesis steps (synth, latch map, dfflibmap, abc -liberty) closely
# enough for area and cell-count planning. It is NOT the sign-off netlist: no CTS, no
# resizing, no hold buffers, no tie/fill cells.
#
#   yosys -c synth/synth_cmos5l.tcl            (see synth/run_synth.sh for the wrapper)
#
# Environment variables (all optional):
#   SYNTH_TOP    top module                      default tt_um_protocol_emulator
#   SYNTH_FLAT   1 = flatten, 0 = keep hierarchy default 0 (per-module area table)
#   SYNTH_CLK_PS clock period handed to abc, ps default 20000 (the template's 20 ns)
#   SYNTH_OUT    output prefix                   default build/synth/<top>
#   SYNTH_DEFS   extra +define+ list, space-separated
#   SYNTH_SKIP   src/ basenames to leave out (e.g. instr_mem.v), space-separated
#   SYNTH_EXTRA  extra source files to read (experiments), space-separated
#   SYNTH_NOSRC  1 = read only SYNTH_EXTRA (synthesise an experiment module on its own)
#   SYNTH_MACROS macro liberty files: read as black boxes, areas added to the report
#                default: the 1P 64x16 SRAM instantiated by src/instr_mem.v
#   SYNTH_CHPARAM  "module:PARAM=value" list passed to chparam
#   CMOS5L_PDK   dir holding typ.lib + maps      default C:/tools/ihp-cmos5l
proc envdef {name def} { if {[info exists ::env($name)]} { return $::env($name) } else { return $def } }

set top   [envdef SYNTH_TOP  tt_um_protocol_emulator]
set flat  [envdef SYNTH_FLAT 0]
set clkps [envdef SYNTH_CLK_PS 20000]
set pdk   [envdef CMOS5L_PDK C:/tools/ihp-cmos5l]
set out   [envdef SYNTH_OUT  build/synth/$top]
set defs  [envdef SYNTH_DEFS ""]
set skip  [envdef SYNTH_SKIP ""]
set extra [envdef SYNTH_EXTRA ""]
set nosrc [envdef SYNTH_NOSRC 0]
set macros [envdef SYNTH_MACROS C:/tools/ihp-sram/RM_IHPSG13_1P_64x16_c2_typ_1p20V_25C.lib]
set chp   [envdef SYNTH_CHPARAM ""]
set lib   $pdk/sg13cmos5l_stdcell_typ_1p20V_25C.lib

file mkdir [file dirname $out]

set srcs {}
if {!$nosrc} {
    foreach f [lsort [glob src/*.v]] { if {[lsearch $skip [file tail $f]] < 0} { lappend srcs $f } }
}
foreach f $extra { lappend srcs $f }
set dargs {}
foreach d $defs { lappend dargs -D$d }
set statlibs "-liberty $lib"
yosys read_liberty -lib -overwrite $lib
foreach m $macros { yosys read_liberty -lib -overwrite $m; append statlibs " -liberty $m" }
foreach f $srcs { yosys read_verilog -sv -Isrc {*}$dargs $f }
foreach c $chp {
    lassign [split $c :] mod pv
    lassign [split $pv =] pn pval
    yosys chparam -set $pn $pval $mod
}
yosys hierarchy -check -top $top

if {$flat} { yosys synth -top $top -flatten } else { yosys synth -top $top }
yosys opt -purge

# latches and flops. The library only has async-reset flops (dfrbp*), so plain and enable
# flops are legalised to reset-flop (reset tied inactive) + feedback mux before mapping.
yosys techmap -map $pdk/latch_map.v
yosys dfflegalize -cell {$_DFF_PN0_} 01
yosys dfflibmap -liberty $lib -dont_use sg13cmos5l_dfrbp_2 -dont_use sg13cmos5l_dfrbp_1
yosys opt_clean -purge

yosys abc -liberty $lib -D $clkps -dont_use sg13cmos5l_sighold -dont_use sg13cmos5l_lgcp_1 \
          -dont_use sg13cmos5l_slgcp_1 -dont_use sg13cmos5l_sdfbbp_1 -dont_use sg13cmos5l_dfrbp_2
yosys opt_clean -purge
yosys hilomap -singleton -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO

yosys tee -o $out.stat.txt stat {*}$statlibs -width
yosys write_verilog -noattr $out.netlist.v
