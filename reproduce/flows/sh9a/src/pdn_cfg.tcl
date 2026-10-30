# Metal4-only power grid for Tiny Tapeout CMOS5L with IHP SRAM macros.
#
# Why this file exists
#  * The TT CMOS5L precheck forbids drawn TopMetal1 (forbidden-layer, pin-layer and layer checks), so the grid is
#    Metal1 follow-pin rails + Metal4 vertical stripes only (FP_PDN_MULTILAYER = 0 in src/config.json).
#  * The SRAM macro (RM_IHPSG13_1P_256x32_c2_bm_bist) has its power pins on Metal4 and a Metal1-4 obstruction over
#    its whole area, so LibreLane's default macro grid (Metal4 <-> TopMetal1) finds nothing to connect (PDN-0232/0233),
#    and a Metal4 <-> Metal4 connect rule is illegal (PDN-0003).
#  * Instead there is NO macro grid: the stripes run straight over the macro and land on the macro's own power
#    columns. Those columns are 2.81 um wide on an 11.24 um pitch, alternating VDD!/VSS! (centre distance 5.62 um).
#    With PDN_VPITCH = 4 x 11.24 = 44.96, PDN_VWIDTH = 2.1, PDN_VSPACING = 3.52 and PDN_VOFFSET chosen for the macro
#    x position in src/config.json, every stripe over the macro overlaps a column of the same net (VPWR on VDD!/
#    VDDARRAY!, VGND on VSS!). Same-layer overlap = electrical connection. PDN_SKIPTRIM keeps the stripes from being
#    cut at the macro.
# Pitch/offset must be kept consistent with the macro instance locations (see docs/TT_FLOW_RESULTS.md).

source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd

        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }

    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd

        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary

set arg_list [list]
if { $::env(PDN_ENABLE_PINS) } {
    lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
}

define_pdn_grid \
    -name stdcell_grid \
    -starts_with POWER \
    -voltage_domain CORE \
    {*}$arg_list

add_pdn_stripe \
    -grid stdcell_grid \
    -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) \
    -pitch $::env(PDN_VPITCH) \
    -offset $::env(PDN_VOFFSET) \
    -spacing $::env(PDN_VSPACING) \
    -starts_with POWER

if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}
