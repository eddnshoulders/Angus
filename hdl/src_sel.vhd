library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- src_sel.vhd
-- Selects between crank and encoder as angle source.
-- sel=0: crank, sel=1: encoder
-- Routes 5 signals: ab_edge, z_edge, ppr_conf, ab_period, ab_count
-- All inputs are edge strobes or values -- purely combinatorial mux.
-- =============================================================================
entity src_sel is
    port (
        sel              : in  std_logic;
        -- Crank inputs
        crank_ab_edge    : in  std_logic;
        crank_z_edge     : in  std_logic;
        crank_ppr_conf   : in  unsigned(7 downto 0);
        crank_tooth_period: in unsigned(31 downto 0);
        crank_ab_count   : in  unsigned(7 downto 0);
        -- Encoder inputs (stub)
        enc_ab_edge      : in  std_logic;
        enc_z_edge       : in  std_logic;
        enc_ppr_conf     : in  unsigned(7 downto 0);
        enc_ab_period    : in  unsigned(31 downto 0);
        enc_ab_count     : in  unsigned(7 downto 0);
        -- Outputs
        ab_edge          : out std_logic;
        z_edge           : out std_logic;
        ppr_conf         : out unsigned(7 downto 0);
        ab_period        : out unsigned(31 downto 0);
        ab_count         : out unsigned(7 downto 0)
    );
end entity src_sel;

architecture rtl of src_sel is
begin
    ab_edge   <= crank_ab_edge    when sel = '0' else enc_ab_edge;
    z_edge    <= crank_z_edge     when sel = '0' else enc_z_edge;
    ppr_conf  <= crank_ppr_conf   when sel = '0' else enc_ppr_conf;
    ab_period <= crank_tooth_period when sel = '0' else enc_ab_period;
    ab_count  <= crank_ab_count   when sel = '0' else enc_ab_count;
end architecture rtl;
