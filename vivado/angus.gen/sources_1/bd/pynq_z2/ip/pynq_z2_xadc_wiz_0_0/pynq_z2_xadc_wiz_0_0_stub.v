// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2024.1 (lin64) Build 5076996 Wed May 22 18:36:09 MDT 2024
// Date        : Thu May 21 01:48:20 2026
// Host        : yocto running 64-bit Ubuntu 22.04.5 LTS
// Command     : write_verilog -force -mode synth_stub
//               /mnt/hgfs/yocto/angus/vivado/angus.gen/sources_1/bd/pynq_z2/ip/pynq_z2_xadc_wiz_0_0/pynq_z2_xadc_wiz_0_0_stub.v
// Design      : pynq_z2_xadc_wiz_0_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z020clg400-1
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module pynq_z2_xadc_wiz_0_0(daddr_in, den_in, di_in, dwe_in, do_out, drdy_out, 
  dclk_in, reset_in, convst_in, vauxp0, vauxn0, vauxp1, vauxn1, vauxp2, vauxn2, vauxp3, vauxn3, vauxp4, 
  vauxn4, vauxp5, vauxn5, busy_out, channel_out, eoc_out, eos_out, alarm_out, vp_in, vn_in)
/* synthesis syn_black_box black_box_pad_pin="daddr_in[6:0],den_in,di_in[15:0],dwe_in,do_out[15:0],drdy_out,reset_in,convst_in,vauxp0,vauxn0,vauxp1,vauxn1,vauxp2,vauxn2,vauxp3,vauxn3,vauxp4,vauxn4,vauxp5,vauxn5,busy_out,channel_out[4:0],eoc_out,eos_out,alarm_out,vp_in,vn_in" */
/* synthesis syn_force_seq_prim="dclk_in" */;
  input [6:0]daddr_in;
  input den_in;
  input [15:0]di_in;
  input dwe_in;
  output [15:0]do_out;
  output drdy_out;
  input dclk_in /* synthesis syn_isclock = 1 */;
  input reset_in;
  input convst_in;
  input vauxp0;
  input vauxn0;
  input vauxp1;
  input vauxn1;
  input vauxp2;
  input vauxn2;
  input vauxp3;
  input vauxn3;
  input vauxp4;
  input vauxn4;
  input vauxp5;
  input vauxn5;
  output busy_out;
  output [4:0]channel_out;
  output eoc_out;
  output eos_out;
  output alarm_out;
  input vp_in;
  input vn_in;
endmodule
