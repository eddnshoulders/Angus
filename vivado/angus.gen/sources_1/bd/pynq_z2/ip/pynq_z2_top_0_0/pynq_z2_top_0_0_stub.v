// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2024.1 (lin64) Build 5076996 Wed May 22 18:36:09 MDT 2024
// Date        : Fri May 29 23:23:02 2026
// Host        : yocto running 64-bit Ubuntu 22.04.5 LTS
// Command     : write_verilog -force -mode synth_stub
//               /mnt/hgfs/yocto/angus/vivado/angus.gen/sources_1/bd/pynq_z2/ip/pynq_z2_top_0_0/pynq_z2_top_0_0_stub.v
// Design      : pynq_z2_top_0_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z020clg400-1
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* x_core_info = "top,Vivado 2024.1" *)
module pynq_z2_top_0_0(clk, s_axi_aclk, s_axi_aresetn, s_axi_awaddr, 
  s_axi_awvalid, s_axi_awready, s_axi_wdata, s_axi_wstrb, s_axi_wvalid, s_axi_wready, 
  s_axi_bresp, s_axi_bvalid, s_axi_bready, s_axi_araddr, s_axi_arvalid, s_axi_arready, 
  s_axi_rdata, s_axi_rresp, s_axi_rvalid, s_axi_rready, m_axis_tdata, m_axis_tvalid, 
  m_axis_tready, m_axis_tlast, cam_raw, crank_raw, a_raw, b_raw, z_raw, adc_ch0, adc_ch1, adc_ch2, 
  adc_ch3, adc_ch4, adc_ch5, adc_ch6, di_ch, debug_out)
/* synthesis syn_black_box black_box_pad_pin="s_axi_aresetn,s_axi_awaddr[8:0],s_axi_awvalid,s_axi_awready,s_axi_wdata[31:0],s_axi_wstrb[3:0],s_axi_wvalid,s_axi_wready,s_axi_bresp[1:0],s_axi_bvalid,s_axi_bready,s_axi_araddr[8:0],s_axi_arvalid,s_axi_arready,s_axi_rdata[31:0],s_axi_rresp[1:0],s_axi_rvalid,s_axi_rready,m_axis_tdata[31:0],m_axis_tvalid,m_axis_tready,m_axis_tlast,cam_raw,crank_raw,a_raw,b_raw,z_raw,adc_ch0[11:0],adc_ch1[11:0],adc_ch2[11:0],adc_ch3[11:0],adc_ch4[11:0],adc_ch5[11:0],adc_ch6[11:0],di_ch[7:0],debug_out[13:0]" */
/* synthesis syn_force_seq_prim="clk" */
/* synthesis syn_force_seq_prim="s_axi_aclk" */;
  input clk /* synthesis syn_isclock = 1 */;
  input s_axi_aclk /* synthesis syn_isclock = 1 */;
  input s_axi_aresetn;
  input [8:0]s_axi_awaddr;
  input s_axi_awvalid;
  output s_axi_awready;
  input [31:0]s_axi_wdata;
  input [3:0]s_axi_wstrb;
  input s_axi_wvalid;
  output s_axi_wready;
  output [1:0]s_axi_bresp;
  output s_axi_bvalid;
  input s_axi_bready;
  input [8:0]s_axi_araddr;
  input s_axi_arvalid;
  output s_axi_arready;
  output [31:0]s_axi_rdata;
  output [1:0]s_axi_rresp;
  output s_axi_rvalid;
  input s_axi_rready;
  output [31:0]m_axis_tdata;
  output m_axis_tvalid;
  input m_axis_tready;
  output m_axis_tlast;
  input cam_raw;
  input crank_raw;
  input a_raw;
  input b_raw;
  input z_raw;
  input [11:0]adc_ch0;
  input [11:0]adc_ch1;
  input [11:0]adc_ch2;
  input [11:0]adc_ch3;
  input [11:0]adc_ch4;
  input [11:0]adc_ch5;
  input [11:0]adc_ch6;
  input [7:0]di_ch;
  output [13:0]debug_out;
endmodule
