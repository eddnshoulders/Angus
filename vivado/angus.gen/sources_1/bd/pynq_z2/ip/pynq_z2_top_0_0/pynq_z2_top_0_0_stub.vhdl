-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2024.1 (lin64) Build 5076996 Wed May 22 18:36:09 MDT 2024
-- Date        : Tue May 26 00:37:05 2026
-- Host        : yocto running 64-bit Ubuntu 22.04.5 LTS
-- Command     : write_vhdl -force -mode synth_stub
--               /mnt/hgfs/yocto/angus/vivado/angus.gen/sources_1/bd/pynq_z2/ip/pynq_z2_top_0_0/pynq_z2_top_0_0_stub.vhdl
-- Design      : pynq_z2_top_0_0
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7z020clg400-1
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity pynq_z2_top_0_0 is
  Port ( 
    clk : in STD_LOGIC;
    rst_n : in STD_LOGIC;
    crank_raw : in STD_LOGIC;
    cam_raw : in STD_LOGIC;
    digital_inputs : in STD_LOGIC_VECTOR ( 7 downto 0 );
    xadc_do : in STD_LOGIC_VECTOR ( 15 downto 0 );
    xadc_channel : in STD_LOGIC_VECTOR ( 4 downto 0 );
    xadc_eoc : in STD_LOGIC;
    xadc_eos : in STD_LOGIC;
    xadc_busy : in STD_LOGIC;
    xadc_convst : out STD_LOGIC;
    xadc_dclk : out STD_LOGIC;
    xadc_den : out STD_LOGIC;
    xadc_dwe : out STD_LOGIC;
    xadc_daddr : out STD_LOGIC_VECTOR ( 6 downto 0 );
    xadc_di : out STD_LOGIC_VECTOR ( 15 downto 0 );
    s_axi_aclk : in STD_LOGIC;
    s_axi_aresetn : in STD_LOGIC;
    s_axi_awaddr : in STD_LOGIC_VECTOR ( 6 downto 0 );
    s_axi_awvalid : in STD_LOGIC;
    s_axi_awready : out STD_LOGIC;
    s_axi_wdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axi_wstrb : in STD_LOGIC_VECTOR ( 3 downto 0 );
    s_axi_wvalid : in STD_LOGIC;
    s_axi_wready : out STD_LOGIC;
    s_axi_bresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    s_axi_bvalid : out STD_LOGIC;
    s_axi_bready : in STD_LOGIC;
    s_axi_araddr : in STD_LOGIC_VECTOR ( 6 downto 0 );
    s_axi_arvalid : in STD_LOGIC;
    s_axi_arready : out STD_LOGIC;
    s_axi_rdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axi_rresp : out STD_LOGIC_VECTOR ( 1 downto 0 );
    s_axi_rvalid : out STD_LOGIC;
    s_axi_rready : in STD_LOGIC;
    m_axis_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    m_axis_tvalid : out STD_LOGIC;
    m_axis_tready : in STD_LOGIC;
    m_axis_tlast : out STD_LOGIC;
    debug_out : out STD_LOGIC_VECTOR ( 11 downto 0 )
  );

end pynq_z2_top_0_0;

architecture stub of pynq_z2_top_0_0 is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk,rst_n,crank_raw,cam_raw,digital_inputs[7:0],xadc_do[15:0],xadc_channel[4:0],xadc_eoc,xadc_eos,xadc_busy,xadc_convst,xadc_dclk,xadc_den,xadc_dwe,xadc_daddr[6:0],xadc_di[15:0],s_axi_aclk,s_axi_aresetn,s_axi_awaddr[6:0],s_axi_awvalid,s_axi_awready,s_axi_wdata[31:0],s_axi_wstrb[3:0],s_axi_wvalid,s_axi_wready,s_axi_bresp[1:0],s_axi_bvalid,s_axi_bready,s_axi_araddr[6:0],s_axi_arvalid,s_axi_arready,s_axi_rdata[31:0],s_axi_rresp[1:0],s_axi_rvalid,s_axi_rready,m_axis_tdata[31:0],m_axis_tvalid,m_axis_tready,m_axis_tlast,debug_out[11:0]";
attribute x_core_info : string;
attribute x_core_info of stub : architecture is "top,Vivado 2024.1";
begin
end;
