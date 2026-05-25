// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2024.1 (lin64) Build 5076996 Wed May 22 18:36:09 MDT 2024
// Date        : Mon May 25 11:36:26 2026
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
module pynq_z2_top_0_0(clk, rst_n, crank_raw, cam_raw, digital_inputs, 
  xadc_do, xadc_channel, xadc_eoc, xadc_eos, xadc_busy, xadc_convst, xadc_dclk, xadc_den, xadc_dwe, 
  xadc_daddr, xadc_di, s_axi_aclk, s_axi_aresetn, s_axi_awaddr, s_axi_awvalid, s_axi_awready, 
  s_axi_wdata, s_axi_wstrb, s_axi_wvalid, s_axi_wready, s_axi_bresp, s_axi_bvalid, 
  s_axi_bready, s_axi_araddr, s_axi_arvalid, s_axi_arready, s_axi_rdata, s_axi_rresp, 
  s_axi_rvalid, s_axi_rready, m_axis_tdata, m_axis_tvalid, m_axis_tready, m_axis_tlast, 
  debug_out)
/* synthesis syn_black_box black_box_pad_pin="rst_n,crank_raw,cam_raw,digital_inputs[7:0],xadc_do[15:0],xadc_channel[4:0],xadc_eoc,xadc_eos,xadc_busy,xadc_convst,xadc_den,xadc_dwe,xadc_daddr[6:0],xadc_di[15:0],s_axi_aresetn,s_axi_awaddr[6:0],s_axi_awvalid,s_axi_awready,s_axi_wdata[31:0],s_axi_wstrb[3:0],s_axi_wvalid,s_axi_wready,s_axi_bresp[1:0],s_axi_bvalid,s_axi_bready,s_axi_araddr[6:0],s_axi_arvalid,s_axi_arready,s_axi_rdata[31:0],s_axi_rresp[1:0],s_axi_rvalid,s_axi_rready,m_axis_tdata[31:0],m_axis_tvalid,m_axis_tready,m_axis_tlast,debug_out[11:0]" */
/* synthesis syn_force_seq_prim="clk" */
/* synthesis syn_force_seq_prim="xadc_dclk" */
/* synthesis syn_force_seq_prim="s_axi_aclk" */;
  input clk /* synthesis syn_isclock = 1 */;
  input rst_n;
  input crank_raw;
  input cam_raw;
  input [7:0]digital_inputs;
  input [15:0]xadc_do;
  input [4:0]xadc_channel;
  input xadc_eoc;
  input xadc_eos;
  input xadc_busy;
  output xadc_convst;
  output xadc_dclk /* synthesis syn_isclock = 1 */;
  output xadc_den;
  output xadc_dwe;
  output [6:0]xadc_daddr;
  output [15:0]xadc_di;
  input s_axi_aclk /* synthesis syn_isclock = 1 */;
  input s_axi_aresetn;
  input [6:0]s_axi_awaddr;
  input s_axi_awvalid;
  output s_axi_awready;
  input [31:0]s_axi_wdata;
  input [3:0]s_axi_wstrb;
  input s_axi_wvalid;
  output s_axi_wready;
  output [1:0]s_axi_bresp;
  output s_axi_bvalid;
  input s_axi_bready;
  input [6:0]s_axi_araddr;
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
  output [11:0]debug_out;
endmodule
