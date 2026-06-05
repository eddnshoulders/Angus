-- (c) Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- (c) Copyright 2022-2026 Advanced Micro Devices, Inc. All rights reserved.
-- 
-- This file contains confidential and proprietary information
-- of AMD and is protected under U.S. and international copyright
-- and other intellectual property laws.
-- 
-- DISCLAIMER
-- This disclaimer is not a license and does not grant any
-- rights to the materials distributed herewith. Except as
-- otherwise provided in a valid license issued to you by
-- AMD, and to the maximum extent permitted by applicable
-- law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
-- WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
-- AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
-- BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
-- INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
-- (2) AMD shall not be liable (whether in contract or tort,
-- including negligence, or under any other theory of
-- liability) for any loss or damage of any kind or nature
-- related to, arising under or in connection with these
-- materials, including for any direct, or any indirect,
-- special, incidental, or consequential loss or damage
-- (including loss of data, profits, goodwill, or any type of
-- loss or damage suffered as a result of any action brought
-- by a third party) even if such damage or loss was
-- reasonably foreseeable or AMD had been advised of the
-- possibility of the same.
-- 
-- CRITICAL APPLICATIONS
-- AMD products are not designed or intended to be fail-
-- safe, or for use in any application requiring fail-safe
-- performance, such as life-support or safety devices or
-- systems, Class III medical devices, nuclear facilities,
-- applications related to the deployment of airbags, or any
-- other applications that could lead to death, personal
-- injury, or severe property or environmental damage
-- (individually and collectively, "Critical
-- Applications"). Customer assumes the sole risk and
-- liability of any use of AMD products in Critical
-- Applications, subject only to applicable laws and
-- regulations governing limitations on product liability.
-- 
-- THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
-- PART OF THIS FILE AT ALL TIMES.
-- 
-- DO NOT MODIFY THIS FILE.

-- IP VLNV: xilinx.com:module_ref:top:1.0
-- IP Revision: 1

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY pynq_z2_top_0_0 IS
  PORT (
    clk : IN STD_LOGIC;
    s_axi_aclk : IN STD_LOGIC;
    s_axi_aresetn : IN STD_LOGIC;
    s_axi_awaddr : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    s_axi_awvalid : IN STD_LOGIC;
    s_axi_awready : OUT STD_LOGIC;
    s_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    s_axi_wvalid : IN STD_LOGIC;
    s_axi_wready : OUT STD_LOGIC;
    s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    s_axi_bvalid : OUT STD_LOGIC;
    s_axi_bready : IN STD_LOGIC;
    s_axi_araddr : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    s_axi_arvalid : IN STD_LOGIC;
    s_axi_arready : OUT STD_LOGIC;
    s_axi_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    s_axi_rvalid : OUT STD_LOGIC;
    s_axi_rready : IN STD_LOGIC;
    m_axis_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axis_tvalid : OUT STD_LOGIC;
    m_axis_tready : IN STD_LOGIC;
    m_axis_tlast : OUT STD_LOGIC;
    cam_raw : IN STD_LOGIC;
    crank_raw : IN STD_LOGIC;
    a_raw : IN STD_LOGIC;
    b_raw : IN STD_LOGIC;
    z_raw : IN STD_LOGIC;
    adc_ch0 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    adc_ch1 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    adc_ch2 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    adc_ch3 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    adc_ch4 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    adc_ch5 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    adc_ch6 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
    di_ch : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    debug_out : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    ila_ab_edge : OUT STD_LOGIC;
    ila_z_edge : OUT STD_LOGIC;
    ila_ab_count : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    ila_ppr_conf : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
    ila_ab_period : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_angle_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_angle_nco_ab_inc : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_angle_nco_clk_inc : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_angle_nco_clk_inc_valid : OUT STD_LOGIC;
    ila_ref_edge : OUT STD_LOGIC;
    ila_phase_ref_det : OUT STD_LOGIC;
    ila_phase_ref_found : OUT STD_LOGIC;
    ila_phase_eng : OUT STD_LOGIC;
    ila_phase_ref_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_phase_ref_det_cnt : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    ila_sync_state : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    ila_sync_full : OUT STD_LOGIC;
    ila_pll_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_pll_nco_accum : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_pll_err_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_pll_p_term : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_pll_i_term : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_pll_pi_corr : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_pll_div_valid : OUT STD_LOGIC;
    ila_ang_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_tdc_deg : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    ila_trig_pulse : OUT STD_LOGIC;
    ila_trig_count : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    ila_fault_cam_tooth : OUT STD_LOGIC;
    ila_fault_crank_tooth : OUT STD_LOGIC;
    ila_fault_crank_ab : OUT STD_LOGIC;
    ila_fault_pll_phase : OUT STD_LOGIC;
    ila_fault_speed_calc : OUT STD_LOGIC
  );
END pynq_z2_top_0_0;

ARCHITECTURE pynq_z2_top_0_0_arch OF pynq_z2_top_0_0 IS
  ATTRIBUTE DowngradeIPIdentifiedWarnings : STRING;
  ATTRIBUTE DowngradeIPIdentifiedWarnings OF pynq_z2_top_0_0_arch: ARCHITECTURE IS "yes";
  COMPONENT top IS
    PORT (
      clk : IN STD_LOGIC;
      s_axi_aclk : IN STD_LOGIC;
      s_axi_aresetn : IN STD_LOGIC;
      s_axi_awaddr : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
      s_axi_awvalid : IN STD_LOGIC;
      s_axi_awready : OUT STD_LOGIC;
      s_axi_wdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
      s_axi_wstrb : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
      s_axi_wvalid : IN STD_LOGIC;
      s_axi_wready : OUT STD_LOGIC;
      s_axi_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
      s_axi_bvalid : OUT STD_LOGIC;
      s_axi_bready : IN STD_LOGIC;
      s_axi_araddr : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
      s_axi_arvalid : IN STD_LOGIC;
      s_axi_arready : OUT STD_LOGIC;
      s_axi_rdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      s_axi_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
      s_axi_rvalid : OUT STD_LOGIC;
      s_axi_rready : IN STD_LOGIC;
      m_axis_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      m_axis_tvalid : OUT STD_LOGIC;
      m_axis_tready : IN STD_LOGIC;
      m_axis_tlast : OUT STD_LOGIC;
      cam_raw : IN STD_LOGIC;
      crank_raw : IN STD_LOGIC;
      a_raw : IN STD_LOGIC;
      b_raw : IN STD_LOGIC;
      z_raw : IN STD_LOGIC;
      adc_ch0 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      adc_ch1 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      adc_ch2 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      adc_ch3 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      adc_ch4 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      adc_ch5 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      adc_ch6 : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
      di_ch : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
      debug_out : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
      ila_ab_edge : OUT STD_LOGIC;
      ila_z_edge : OUT STD_LOGIC;
      ila_ab_count : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
      ila_ppr_conf : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
      ila_ab_period : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_angle_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_angle_nco_ab_inc : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_angle_nco_clk_inc : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_angle_nco_clk_inc_valid : OUT STD_LOGIC;
      ila_ref_edge : OUT STD_LOGIC;
      ila_phase_ref_det : OUT STD_LOGIC;
      ila_phase_ref_found : OUT STD_LOGIC;
      ila_phase_eng : OUT STD_LOGIC;
      ila_phase_ref_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_phase_ref_det_cnt : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
      ila_sync_state : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
      ila_sync_full : OUT STD_LOGIC;
      ila_pll_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_pll_nco_accum : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_pll_err_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_pll_p_term : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_pll_i_term : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_pll_pi_corr : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_pll_div_valid : OUT STD_LOGIC;
      ila_ang_angfac : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_tdc_deg : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
      ila_trig_pulse : OUT STD_LOGIC;
      ila_trig_count : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
      ila_fault_cam_tooth : OUT STD_LOGIC;
      ila_fault_crank_tooth : OUT STD_LOGIC;
      ila_fault_crank_ab : OUT STD_LOGIC;
      ila_fault_pll_phase : OUT STD_LOGIC;
      ila_fault_speed_calc : OUT STD_LOGIC
    );
  END COMPONENT top;
  ATTRIBUTE X_CORE_INFO : STRING;
  ATTRIBUTE X_CORE_INFO OF pynq_z2_top_0_0_arch: ARCHITECTURE IS "top,Vivado 2024.1";
  ATTRIBUTE CHECK_LICENSE_TYPE : STRING;
  ATTRIBUTE CHECK_LICENSE_TYPE OF pynq_z2_top_0_0_arch : ARCHITECTURE IS "pynq_z2_top_0_0,top,{}";
  ATTRIBUTE CORE_GENERATION_INFO : STRING;
  ATTRIBUTE CORE_GENERATION_INFO OF pynq_z2_top_0_0_arch: ARCHITECTURE IS "pynq_z2_top_0_0,top,{x_ipProduct=Vivado 2024.1,x_ipVendor=xilinx.com,x_ipLibrary=module_ref,x_ipName=top,x_ipVersion=1.0,x_ipCoreRevision=1,x_ipLanguage=VHDL,x_ipSimLanguage=VHDL}";
  ATTRIBUTE IP_DEFINITION_SOURCE : STRING;
  ATTRIBUTE IP_DEFINITION_SOURCE OF pynq_z2_top_0_0_arch: ARCHITECTURE IS "module_ref";
  ATTRIBUTE X_INTERFACE_INFO : STRING;
  ATTRIBUTE X_INTERFACE_PARAMETER : STRING;
  ATTRIBUTE X_INTERFACE_PARAMETER OF clk: SIGNAL IS "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF m_axis:s_axi, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN pynq_z2_processing_system7_0_0_FCLK_CLK0, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF clk: SIGNAL IS "xilinx.com:signal:clock:1.0 clk CLK";
  ATTRIBUTE X_INTERFACE_PARAMETER OF m_axis_tdata: SIGNAL IS "XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 1, FREQ_HZ 100000000, PHASE 0.0, CLK_DOMAIN pynq_z2_processing_system7_0_0_FCLK_CLK0, LAYERED_METADATA undef, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF m_axis_tdata: SIGNAL IS "xilinx.com:interface:axis:1.0 m_axis TDATA";
  ATTRIBUTE X_INTERFACE_INFO OF m_axis_tlast: SIGNAL IS "xilinx.com:interface:axis:1.0 m_axis TLAST";
  ATTRIBUTE X_INTERFACE_INFO OF m_axis_tready: SIGNAL IS "xilinx.com:interface:axis:1.0 m_axis TREADY";
  ATTRIBUTE X_INTERFACE_INFO OF m_axis_tvalid: SIGNAL IS "xilinx.com:interface:axis:1.0 m_axis TVALID";
  ATTRIBUTE X_INTERFACE_PARAMETER OF s_axi_aclk: SIGNAL IS "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN pynq_z2_processing_system7_0_0_FCLK_CLK0, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_aclk: SIGNAL IS "xilinx.com:signal:clock:1.0 s_axi_aclk CLK";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_araddr: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi ARADDR";
  ATTRIBUTE X_INTERFACE_PARAMETER OF s_axi_aresetn: SIGNAL IS "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_aresetn: SIGNAL IS "xilinx.com:signal:reset:1.0 s_axi_aresetn RST";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_arready: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi ARREADY";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_arvalid: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi ARVALID";
  ATTRIBUTE X_INTERFACE_PARAMETER OF s_axi_awaddr: SIGNAL IS "XIL_INTERFACENAME s_axi, DATA_WIDTH 32, PROTOCOL AXI4LITE, FREQ_HZ 100000000, ID_WIDTH 0, ADDR_WIDTH 9, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, CLK_DOMAIN pynq_z2_processing_system7_0_0_FCLK_CLK0, NUM_READ_THREADS 1," & 
" NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_awaddr: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi AWADDR";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_awready: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi AWREADY";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_awvalid: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi AWVALID";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_bready: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi BREADY";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_bresp: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi BRESP";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_bvalid: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi BVALID";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_rdata: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi RDATA";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_rready: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi RREADY";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_rresp: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi RRESP";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_rvalid: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi RVALID";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_wdata: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi WDATA";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_wready: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi WREADY";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_wstrb: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi WSTRB";
  ATTRIBUTE X_INTERFACE_INFO OF s_axi_wvalid: SIGNAL IS "xilinx.com:interface:aximm:1.0 s_axi WVALID";
BEGIN
  U0 : top
    PORT MAP (
      clk => clk,
      s_axi_aclk => s_axi_aclk,
      s_axi_aresetn => s_axi_aresetn,
      s_axi_awaddr => s_axi_awaddr,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata => s_axi_wdata,
      s_axi_wstrb => s_axi_wstrb,
      s_axi_wvalid => s_axi_wvalid,
      s_axi_wready => s_axi_wready,
      s_axi_bresp => s_axi_bresp,
      s_axi_bvalid => s_axi_bvalid,
      s_axi_bready => s_axi_bready,
      s_axi_araddr => s_axi_araddr,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata => s_axi_rdata,
      s_axi_rresp => s_axi_rresp,
      s_axi_rvalid => s_axi_rvalid,
      s_axi_rready => s_axi_rready,
      m_axis_tdata => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tlast => m_axis_tlast,
      cam_raw => cam_raw,
      crank_raw => crank_raw,
      a_raw => a_raw,
      b_raw => b_raw,
      z_raw => z_raw,
      adc_ch0 => adc_ch0,
      adc_ch1 => adc_ch1,
      adc_ch2 => adc_ch2,
      adc_ch3 => adc_ch3,
      adc_ch4 => adc_ch4,
      adc_ch5 => adc_ch5,
      adc_ch6 => adc_ch6,
      di_ch => di_ch,
      debug_out => debug_out,
      ila_ab_edge => ila_ab_edge,
      ila_z_edge => ila_z_edge,
      ila_ab_count => ila_ab_count,
      ila_ppr_conf => ila_ppr_conf,
      ila_ab_period => ila_ab_period,
      ila_angle_angfac => ila_angle_angfac,
      ila_angle_nco_ab_inc => ila_angle_nco_ab_inc,
      ila_angle_nco_clk_inc => ila_angle_nco_clk_inc,
      ila_angle_nco_clk_inc_valid => ila_angle_nco_clk_inc_valid,
      ila_ref_edge => ila_ref_edge,
      ila_phase_ref_det => ila_phase_ref_det,
      ila_phase_ref_found => ila_phase_ref_found,
      ila_phase_eng => ila_phase_eng,
      ila_phase_ref_angfac => ila_phase_ref_angfac,
      ila_phase_ref_det_cnt => ila_phase_ref_det_cnt,
      ila_sync_state => ila_sync_state,
      ila_sync_full => ila_sync_full,
      ila_pll_angfac => ila_pll_angfac,
      ila_pll_nco_accum => ila_pll_nco_accum,
      ila_pll_err_angfac => ila_pll_err_angfac,
      ila_pll_p_term => ila_pll_p_term,
      ila_pll_i_term => ila_pll_i_term,
      ila_pll_pi_corr => ila_pll_pi_corr,
      ila_pll_div_valid => ila_pll_div_valid,
      ila_ang_angfac => ila_ang_angfac,
      ila_tdc_deg => ila_tdc_deg,
      ila_trig_pulse => ila_trig_pulse,
      ila_trig_count => ila_trig_count,
      ila_fault_cam_tooth => ila_fault_cam_tooth,
      ila_fault_crank_tooth => ila_fault_crank_tooth,
      ila_fault_crank_ab => ila_fault_crank_ab,
      ila_fault_pll_phase => ila_fault_pll_phase,
      ila_fault_speed_calc => ila_fault_speed_calc
    );
END pynq_z2_top_0_0_arch;
