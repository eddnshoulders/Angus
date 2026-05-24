
################################################################
# This is a generated script based on design: pynq_z2
#
# Though there are limitations about the generated script,
# the main purpose of this utility is to make learning
# IP Integrator Tcl commands easier.
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2024.1
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   if { [string compare $scripts_vivado_version $current_vivado_version] > 0 } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2042 -severity "ERROR" " This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Sourcing the script failed since it was created with a future version of Vivado."}

   } else {
     catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}

   }

   return 1
}

################################################################
# START
################################################################

# To test this script, run the following commands from Vivado Tcl console:
# source pynq_z2_script.tcl


# The design that will be created by this Tcl script contains the following 
# module references:
# top

# Please add the sources of those modules before sourcing this Tcl script.

# If there is no project opened, this script will create a
# project, but make sure you do not have an existing project
# <./myproj/project_1.xpr> in the current working folder.

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xc7z020clg400-1
}


# CHANGE DESIGN NAME HERE
variable design_name
set design_name pynq_z2

# If you do not already have an existing IP Integrator design open,
# you can create a design using the following command:
#    create_bd_design $design_name

# Creating design if needed
set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
   # USE CASES:
   #    1) Design_name not set

   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1

} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   # USE CASES:
   #    2): Current design opened AND is empty AND names same.
   #    3): Current design opened AND is empty AND names diff; design_name NOT in project.
   #    4): Current design opened AND is empty AND names diff; design_name exists in project.

   if { $cur_design ne $design_name } {
      common::send_gid_msg -ssname BD::TCL -id 2001 -severity "INFO" "Changing value of <design_name> from <$design_name> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_gid_msg -ssname BD::TCL -id 2002 -severity "INFO" "Constructing design in IPI design <$cur_design>..."

} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
   # USE CASES:
   #    5) Current design opened AND has components AND same names.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
   # USE CASES: 
   #    6) Current opened design, has components, but diff names, design_name exists in project.
   #    7) No opened design, design_name exists in project.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2

} else {
   # USE CASES:
   #    8) No opened design, design_name not in project.
   #    9) Current opened design, has components, but diff names, design_name not in project.

   common::send_gid_msg -ssname BD::TCL -id 2003 -severity "INFO" "Currently there is no design <$design_name> in project, so creating one..."

   create_bd_design $design_name

   common::send_gid_msg -ssname BD::TCL -id 2004 -severity "INFO" "Making design <$design_name> as current_bd_design."
   current_bd_design $design_name

}

common::send_gid_msg -ssname BD::TCL -id 2005 -severity "INFO" "Currently the variable <design_name> is equal to \"$design_name\"."

if { $nRet != 0 } {
   catch {common::send_gid_msg -ssname BD::TCL -id 2006 -severity "ERROR" $errMsg}
   return $nRet
}

set bCheckIPsPassed 1
##################################################################
# CHECK IPs
##################################################################
set bCheckIPs 1
if { $bCheckIPs == 1 } {
   set list_check_ips "\ 
xilinx.com:ip:processing_system7:5.5\
xilinx.com:ip:axi_dma:7.1\
xilinx.com:ip:xadc_wiz:3.3\
xilinx.com:ip:smartconnect:1.0\
"

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }

}

##################################################################
# CHECK Modules
##################################################################
set bCheckModules 1
if { $bCheckModules == 1 } {
   set list_check_mods "\ 
top\
"

   set list_mods_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2020 -severity "INFO" "Checking if the following modules exist in the project's sources: $list_check_mods ."

   foreach mod_vlnv $list_check_mods {
      if { [can_resolve_reference $mod_vlnv] == 0 } {
         lappend list_mods_missing $mod_vlnv
      }
   }

   if { $list_mods_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2021 -severity "ERROR" "The following module(s) are not found in the project: $list_mods_missing" }
      common::send_gid_msg -ssname BD::TCL -id 2022 -severity "INFO" "Please add source files for the missing module(s) above."
      set bCheckIPsPassed 0
   }
}

if { $bCheckIPsPassed != 1 } {
  common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
  return 3
}

##################################################################
# DESIGN PROCs
##################################################################



# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell } {

  variable script_folder
  variable design_name

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj


  # Create interface ports
  set DDR_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR_0 ]

  set FIXED_IO_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO_0 ]

  set CAN_0_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:can_rtl:1.0 CAN_0_0 ]

  set Vaux0_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux0_0 ]

  set Vaux1_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux1_0 ]

  set Vaux2_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux2_0 ]

  set Vaux3_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux3_0 ]

  set Vaux4_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux4_0 ]

  set Vaux5_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux5_0 ]


  # Create ports
  set crank_raw_0 [ create_bd_port -dir I crank_raw_0 ]
  set cam_raw_0 [ create_bd_port -dir I cam_raw_0 ]
  set digital_inputs_0 [ create_bd_port -dir I -from 7 -to 0 digital_inputs_0 ]

  # Create instance: processing_system7_0, and set properties
  set processing_system7_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0 ]
  set_property -dict [list \
    CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {666.666687} \
    CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
    CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {50.000000} \
    CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
    CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {10.000000} \
    CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {111.111115} \
    CONFIG.PCW_CAN0_CAN0_IO {EMIO} \
    CONFIG.PCW_CAN0_GRP_CLK_ENABLE {1} \
    CONFIG.PCW_CAN0_GRP_CLK_IO {MIO 0} \
    CONFIG.PCW_CAN0_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_CAN0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_CAN0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_CAN_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_CAN_PERIPHERAL_VALID {1} \
    CONFIG.PCW_CLK0_FREQ {50000000} \
    CONFIG.PCW_CLK1_FREQ {10000000} \
    CONFIG.PCW_CLK2_FREQ {10000000} \
    CONFIG.PCW_CLK3_FREQ {10000000} \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
    CONFIG.PCW_EN_CAN0 {1} \
    CONFIG.PCW_EN_EMIO_CAN0 {1} \
    CONFIG.PCW_EN_GPIO {0} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {0} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_MIO_0_IOTYPE {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_0_PULLUP {enabled} \
    CONFIG.PCW_MIO_0_SLEW {fast} \
    CONFIG.PCW_MIO_TREE_PERIPHERALS {CAN 0#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned}\
\
    CONFIG.PCW_MIO_TREE_SIGNALS {mioclk#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned}\
\
    CONFIG.PCW_NAND_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_NOR_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_SMC_PERIPHERAL_VALID {0} \
    CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ {533.333374} \
    CONFIG.PCW_USE_DMA0 {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
  ] $processing_system7_0


  # Create instance: axi_dma_0, and set properties
  set axi_dma_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0 ]
  set_property -dict [list \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_sg {0} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_micro_dma {0} \
    CONFIG.c_s2mm_burst_size {256} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_sg_length_width {26} \
  ] $axi_dma_0


  # Create instance: axi_interconnect_0, and set properties
  set axi_interconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0 ]

  # Create instance: xadc_wiz_0, and set properties
  set xadc_wiz_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xadc_wiz:3.3 xadc_wiz_0 ]
  set_property -dict [list \
    CONFIG.ACQUISITION_TIME_VAUXP0_VAUXN0 {false} \
    CONFIG.ACQUISITION_TIME_VAUXP8_VAUXN8 {false} \
    CONFIG.AVERAGE_ENABLE_VAUXP0_VAUXN0 {false} \
    CONFIG.CHANNEL_ENABLE_CALIBRATION {false} \
    CONFIG.CHANNEL_ENABLE_TEMPERATURE {false} \
    CONFIG.CHANNEL_ENABLE_VAUXP0_VAUXN0 {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP10_VAUXN10 {false} \
    CONFIG.CHANNEL_ENABLE_VAUXP11_VAUXN11 {false} \
    CONFIG.CHANNEL_ENABLE_VAUXP12_VAUXN12 {false} \
    CONFIG.CHANNEL_ENABLE_VAUXP13_VAUXN13 {false} \
    CONFIG.CHANNEL_ENABLE_VAUXP1_VAUXN1 {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP2_VAUXN2 {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP3_VAUXN3 {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP4_VAUXN4 {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP5_VAUXN5 {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP8_VAUXN8 {false} \
    CONFIG.CHANNEL_ENABLE_VAUXP9_VAUXN9 {false} \
    CONFIG.CHANNEL_ENABLE_VBRAM {false} \
    CONFIG.CHANNEL_ENABLE_VCCAUX {false} \
    CONFIG.CHANNEL_ENABLE_VCCDDRO {false} \
    CONFIG.CHANNEL_ENABLE_VCCINT {false} \
    CONFIG.CHANNEL_ENABLE_VCCPAUX {false} \
    CONFIG.CHANNEL_ENABLE_VCCPINT {false} \
    CONFIG.CHANNEL_ENABLE_VP_VN {false} \
    CONFIG.CHANNEL_ENABLE_VREFP {false} \
    CONFIG.ENABLE_AXI4STREAM {false} \
    CONFIG.ENABLE_CALIBRATION_AVERAGING {true} \
    CONFIG.ENABLE_EXTERNAL_MUX {false} \
    CONFIG.ENABLE_JTAG_ARBITER {false} \
    CONFIG.ENABLE_RESET {true} \
    CONFIG.ENABLE_VCCDDRO_ALARM {false} \
    CONFIG.ENABLE_VCCPAUX_ALARM {false} \
    CONFIG.ENABLE_VCCPINT_ALARM {false} \
    CONFIG.EXTERNAL_MUX_CHANNEL {VP_VN} \
    CONFIG.INTERFACE_SELECTION {ENABLE_DRP} \
    CONFIG.OT_ALARM {false} \
    CONFIG.POWER_DOWN_ADCA {false} \
    CONFIG.POWER_DOWN_ADCB {false} \
    CONFIG.SEQUENCER_MODE {One_Pass} \
    CONFIG.SINGLE_CHANNEL_SELECTION {TEMPERATURE} \
    CONFIG.TIMING_MODE {Event} \
    CONFIG.USER_TEMP_ALARM {false} \
    CONFIG.VCCAUX_ALARM {false} \
    CONFIG.VCCINT_ALARM {false} \
    CONFIG.XADC_STARUP_SELECTION {channel_sequencer} \
  ] $xadc_wiz_0


  # Create instance: top_0, and set properties
  set block_name top
  set block_cell_name top_0
  if { [catch {set top_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $top_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: smartconnect_0, and set properties
  set smartconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0 ]

  # Create interface connections
  connect_bd_intf_net -intf_net Vaux0_0_1 [get_bd_intf_ports Vaux0_0] [get_bd_intf_pins xadc_wiz_0/Vaux0]
  connect_bd_intf_net -intf_net Vaux1_0_1 [get_bd_intf_ports Vaux1_0] [get_bd_intf_pins xadc_wiz_0/Vaux1]
  connect_bd_intf_net -intf_net Vaux2_0_1 [get_bd_intf_ports Vaux2_0] [get_bd_intf_pins xadc_wiz_0/Vaux2]
  connect_bd_intf_net -intf_net Vaux3_0_1 [get_bd_intf_ports Vaux3_0] [get_bd_intf_pins xadc_wiz_0/Vaux3]
  connect_bd_intf_net -intf_net Vaux4_0_1 [get_bd_intf_ports Vaux4_0] [get_bd_intf_pins xadc_wiz_0/Vaux4]
  connect_bd_intf_net -intf_net Vaux5_0_1 [get_bd_intf_ports Vaux5_0] [get_bd_intf_pins xadc_wiz_0/Vaux5]
  connect_bd_intf_net -intf_net axi_dma_0_M_AXI_S2MM [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins smartconnect_0/S00_AXI]
  connect_bd_intf_net -intf_net axi_interconnect_0_M00_AXI [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins top_0/s_axi]
  connect_bd_intf_net -intf_net axi_interconnect_0_M01_AXI [get_bd_intf_pins axi_dma_0/S_AXI_LITE] [get_bd_intf_pins axi_interconnect_0/M01_AXI]
  connect_bd_intf_net -intf_net processing_system7_0_CAN_0 [get_bd_intf_ports CAN_0_0] [get_bd_intf_pins processing_system7_0/CAN_0]
  connect_bd_intf_net -intf_net processing_system7_0_DDR [get_bd_intf_ports DDR_0] [get_bd_intf_pins processing_system7_0/DDR]
  connect_bd_intf_net -intf_net processing_system7_0_FIXED_IO [get_bd_intf_ports FIXED_IO_0] [get_bd_intf_pins processing_system7_0/FIXED_IO]
  connect_bd_intf_net -intf_net processing_system7_0_M_AXI_GP0 [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M00_AXI [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
  connect_bd_intf_net -intf_net top_0_m_axis [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM] [get_bd_intf_pins top_0/m_axis]

  # Create port connections
  connect_bd_net -net axi_dma_0_s2mm_introut [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins processing_system7_0/IRQ_F2P]
  connect_bd_net -net cam_raw_0_1 [get_bd_ports cam_raw_0] [get_bd_pins top_0/cam_raw]
  connect_bd_net -net crank_raw_0_1 [get_bd_ports crank_raw_0] [get_bd_pins top_0/crank_raw]
  connect_bd_net -net digital_inputs_0_1 [get_bd_ports digital_inputs_0] [get_bd_pins top_0/digital_inputs]
  connect_bd_net -net processing_system7_0_FCLK_CLK0 [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] [get_bd_pins smartconnect_0/aclk] [get_bd_pins top_0/clk] [get_bd_pins axi_dma_0/s_axi_lite_aclk] [get_bd_pins axi_interconnect_0/S00_ACLK] [get_bd_pins axi_interconnect_0/M00_ACLK] [get_bd_pins axi_interconnect_0/M01_ACLK] [get_bd_pins top_0/s_axi_aclk] [get_bd_pins axi_interconnect_0/ACLK] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
  connect_bd_net -net processing_system7_0_FCLK_RESET0_N [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins axi_interconnect_0/ARESETN] [get_bd_pins axi_interconnect_0/S00_ARESETN] [get_bd_pins axi_interconnect_0/M00_ARESETN] [get_bd_pins axi_interconnect_0/M01_ARESETN] [get_bd_pins axi_dma_0/axi_resetn] [get_bd_pins xadc_wiz_0/reset_in] [get_bd_pins smartconnect_0/aresetn] [get_bd_pins top_0/rst_n] [get_bd_pins top_0/s_axi_aresetn]
  connect_bd_net -net top_0_xadc_convst [get_bd_pins top_0/xadc_convst] [get_bd_pins xadc_wiz_0/convst_in]
  connect_bd_net -net top_0_xadc_daddr [get_bd_pins top_0/xadc_daddr] [get_bd_pins xadc_wiz_0/daddr_in]
  connect_bd_net -net top_0_xadc_dclk [get_bd_pins top_0/xadc_dclk] [get_bd_pins xadc_wiz_0/dclk_in]
  connect_bd_net -net top_0_xadc_den [get_bd_pins top_0/xadc_den] [get_bd_pins xadc_wiz_0/den_in]
  connect_bd_net -net top_0_xadc_di [get_bd_pins top_0/xadc_di] [get_bd_pins xadc_wiz_0/di_in]
  connect_bd_net -net top_0_xadc_dwe [get_bd_pins top_0/xadc_dwe] [get_bd_pins xadc_wiz_0/dwe_in]
  connect_bd_net -net xadc_wiz_0_busy_out [get_bd_pins xadc_wiz_0/busy_out] [get_bd_pins top_0/xadc_busy]
  connect_bd_net -net xadc_wiz_0_channel_out [get_bd_pins xadc_wiz_0/channel_out] [get_bd_pins top_0/xadc_channel]
  connect_bd_net -net xadc_wiz_0_do_out [get_bd_pins xadc_wiz_0/do_out] [get_bd_pins top_0/xadc_do]
  connect_bd_net -net xadc_wiz_0_eoc_out [get_bd_pins xadc_wiz_0/eoc_out] [get_bd_pins top_0/xadc_eoc]
  connect_bd_net -net xadc_wiz_0_eos_out [get_bd_pins xadc_wiz_0/eos_out] [get_bd_pins top_0/xadc_eos]

  # Create address segments


  # Restore current instance
  current_bd_instance $oldCurInst

  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""


common::send_gid_msg -ssname BD::TCL -id 2053 -severity "WARNING" "This Tcl script was generated from a block design that has not been validated. It is possible that design <$design_name> may result in errors during validation."

