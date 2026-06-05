# =============================================================================
# angus.xdc
# Constraints for Angus combustion analyser on PYNQ-Z2
#
# Note: avoid MRCC pins (V16/W16, Pi pins 31/26) when XADC is in the design
# as they conflict with XADC internal clock routing.
# =============================================================================

# =============================================================================
# Sensor inputs - Arduino header
# =============================================================================
set_property PACKAGE_PIN T14 [get_ports crank_raw_0]
set_property IOSTANDARD LVCMOS33 [get_ports crank_raw_0]

set_property PACKAGE_PIN U12 [get_ports cam_raw_0]
set_property IOSTANDARD LVCMOS33 [get_ports cam_raw_0]

# =============================================================================
# Digital inputs - Arduino header AR2-AR9
# =============================================================================
set_property IOSTANDARD LVCMOS33 [get_ports {digital_inputs_0[*]}]

# =============================================================================
# CAN - Arduino header AR12/AR13
# =============================================================================
set_property IOSTANDARD LVCMOS33 [get_ports CAN0_PHY_TX_0]
set_property IOSTANDARD LVCMOS33 [get_ports CAN0_PHY_RX_0]

# =============================================================================
# Debug outputs - Pi header
# Avoid Pi pins 26 (W16) and 31 (V16) - MRCC, conflicts with XADC
#
# debug_out[0]  crank_clean     Pi pin 3   W18  RPIO_02_R
# debug_out[1]  cam_clean       Pi pin 5   W19  RPIO_03_R
# debug_out[2]  edge_pulse_out  Pi pin 7   Y18  RPIO_04_R
# debug_out[3]  cam_edge_pulse  Pi pin 29  Y19  RPIO_05_R
# debug_out[4]  ab              Pi pin 15  U8   RPIO_22_R
# debug_out[5]  z               Pi pin 16  W6   RPIO_23_R
# debug_out[6]  gap_detected    Pi pin 32  B20  RPIO_12_R
# debug_out[7]  ref_detected    Pi pin 33  W8   RPIO_13_R
# debug_out[8]  sample_pulse    Pi pin 22  W10  RPIO_25_R
# debug_out[9]  div_valid       Pi pin 36  B19  RPIO_16_R
# debug_out[10] signal_present  Pi pin 11  U7   RPIO_17_R
# debug_out[11] synced          Pi pin 12  C20  RPIO_18_R
# =============================================================================
set_property PACKAGE_PIN W18 [get_ports {debug_out_0[0]}]
set_property PACKAGE_PIN W19 [get_ports {debug_out_0[1]}]
set_property PACKAGE_PIN Y18 [get_ports {debug_out_0[2]}]
set_property PACKAGE_PIN V6 [get_ports {debug_out_0[3]}]
set_property PACKAGE_PIN C20 [get_ports {debug_out_0[4]}]
set_property PACKAGE_PIN U8 [get_ports {debug_out_0[5]}]
set_property PACKAGE_PIN W6 [get_ports {debug_out_0[6]}]
set_property PACKAGE_PIN V8 [get_ports {debug_out_0[7]}]
set_property PACKAGE_PIN F20 [get_ports {debug_out_0[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {debug_out_0[*]}]
set_false_path -to [get_ports {debug_out_0[*]}]

set_property PACKAGE_PIN U13 [get_ports a_raw_0]
set_property PACKAGE_PIN V13 [get_ports b_raw_0]
set_property PACKAGE_PIN V15 [get_ports z_raw_0]
set_property PACKAGE_PIN T15 [get_ports {digital_inputs_0[0]}]
set_property PACKAGE_PIN R16 [get_ports {digital_inputs_0[1]}]
set_property PACKAGE_PIN U17 [get_ports {digital_inputs_0[2]}]
set_property PACKAGE_PIN V17 [get_ports {digital_inputs_0[3]}]
set_property PACKAGE_PIN V18 [get_ports {digital_inputs_0[4]}]
set_property PACKAGE_PIN T16 [get_ports {digital_inputs_0[5]}]
set_property PACKAGE_PIN R17 [get_ports {digital_inputs_0[6]}]
set_property PACKAGE_PIN P18 [get_ports {digital_inputs_0[7]}]
set_property PACKAGE_PIN T11 [get_ports CAN0_PHY_RX_0]
set_property PACKAGE_PIN T10 [get_ports CAN0_PHY_TX_0]
set_property IOSTANDARD LVCMOS33 [get_ports a_raw_0]
set_property IOSTANDARD LVCMOS33 [get_ports b_raw_0]
set_property IOSTANDARD LVCMOS33 [get_ports z_raw_0]

set_multicycle_path -setup -from [get_cells -hierarchical -filter {NAME =~ *u_pll/phase_err_int*}] 4
set_multicycle_path -hold -from [get_cells -hierarchical -filter {NAME =~ *u_pll/phase_err_int*}] 3


set_property PACKAGE_PIN Y17 [get_ports {debug_out_0[14]}]
set_property PACKAGE_PIN V10 [get_ports {debug_out_0[8]}]
set_property PACKAGE_PIN W10 [get_ports {debug_out_0[10]}]
set_property PACKAGE_PIN F19 [get_ports {debug_out_0[11]}]
set_property PACKAGE_PIN W16 [get_ports {debug_out_0[12]}]
set_property PACKAGE_PIN Y16 [get_ports {debug_out_0[13]}]
set_property PACKAGE_PIN Y19 [get_ports {debug_out_0[15]}]



