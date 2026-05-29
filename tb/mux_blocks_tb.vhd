library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity mux_blocks_tb is end entity;
architecture sim of mux_blocks_tb is
    -- src_sel
    signal sel_s       : std_logic := '0';
    signal crank_ab    : std_logic := '1';
    signal crank_z     : std_logic := '0';
    signal crank_ppr   : unsigned(7 downto 0)  := to_unsigned(60, 8);
    signal crank_per   : unsigned(31 downto 0) := to_unsigned(12345, 32);
    signal crank_cnt   : unsigned(7 downto 0)  := to_unsigned(42, 8);
    signal enc_ab      : std_logic := '0';
    signal enc_z       : std_logic := '1';
    signal enc_ppr     : unsigned(7 downto 0)  := to_unsigned(36, 8);
    signal enc_per     : unsigned(31 downto 0) := to_unsigned(67890, 32);
    signal enc_cnt     : unsigned(7 downto 0)  := to_unsigned(18, 8);
    signal ab_edge_o   : std_logic;
    signal z_edge_o    : std_logic;
    signal ppr_o       : unsigned(7 downto 0);
    signal ab_per_o    : unsigned(31 downto 0);
    signal ab_cnt_o    : unsigned(7 downto 0);
    -- ref_sel
    signal ref_sel_s   : std_logic := '0';
    signal cam_edge    : std_logic := '1';
    signal peak_edge   : std_logic := '0';
    signal ref_edge_o  : std_logic;
    -- ang_sel
    signal ang_sel_s   : std_logic := '0';
    signal angle_deg   : unsigned(15 downto 0) := to_unsigned(1234, 16);
    signal pll_hires   : unsigned(15 downto 0) := to_unsigned(5678, 16);
    signal ang_deg_o   : unsigned(15 downto 0);
begin
    u_src : entity work.src_sel port map(
        sel=>sel_s, crank_ab_edge=>crank_ab, crank_z_edge=>crank_z,
        crank_ppr_conf=>crank_ppr, crank_tooth_period=>crank_per, crank_ab_count=>crank_cnt,
        enc_ab_edge=>enc_ab, enc_z_edge=>enc_z, enc_ppr_conf=>enc_ppr,
        enc_ab_period=>enc_per, enc_ab_count=>enc_cnt,
        ab_edge=>ab_edge_o, z_edge=>z_edge_o, ppr_conf=>ppr_o,
        ab_period=>ab_per_o, ab_count=>ab_cnt_o);

    u_ref : entity work.ref_sel port map(
        sel=>ref_sel_s, cam_edge=>cam_edge, peak_edge=>peak_edge, ref_edge=>ref_edge_o);

    u_ang : entity work.ang_sel port map(
        sel=>ang_sel_s, angle_deg_in=>angle_deg, pll_ang_hires=>pll_hires, ang_deg=>ang_deg_o);

    p_stim : process
    begin
        wait for 10 ns;

        -- src_sel sel=0: crank
        sel_s <= '0'; wait for 10 ns;
        assert ab_edge_o = crank_ab  report "FAIL src_sel sel=0 ab_edge" severity failure;
        assert z_edge_o  = crank_z   report "FAIL src_sel sel=0 z_edge"  severity failure;
        assert ppr_o     = crank_ppr report "FAIL src_sel sel=0 ppr"     severity failure;
        assert ab_per_o  = crank_per report "FAIL src_sel sel=0 ab_period" severity failure;
        assert ab_cnt_o  = crank_cnt report "FAIL src_sel sel=0 ab_count" severity failure;
        report "src_sel sel=0: PASS";

        -- src_sel sel=1: encoder
        sel_s <= '1'; wait for 10 ns;
        assert ab_edge_o = enc_ab  report "FAIL src_sel sel=1 ab_edge" severity failure;
        assert z_edge_o  = enc_z   report "FAIL src_sel sel=1 z_edge"  severity failure;
        assert ppr_o     = enc_ppr report "FAIL src_sel sel=1 ppr"     severity failure;
        assert ab_per_o  = enc_per report "FAIL src_sel sel=1 ab_period" severity failure;
        assert ab_cnt_o  = enc_cnt report "FAIL src_sel sel=1 ab_count" severity failure;
        report "src_sel sel=1: PASS";

        -- ref_sel
        ref_sel_s <= '0'; wait for 10 ns;
        assert ref_edge_o = '1' report "FAIL ref_sel sel=0" severity failure;
        ref_sel_s <= '1'; wait for 10 ns;
        assert ref_edge_o = '0' report "FAIL ref_sel sel=1" severity failure;
        report "ref_sel: PASS";

        -- ang_sel
        ang_sel_s <= '0'; wait for 10 ns;
        assert ang_deg_o = to_unsigned(1234, 16) report "FAIL ang_sel sel=0" severity failure;
        ang_sel_s <= '1'; wait for 10 ns;
        assert ang_deg_o = to_unsigned(5678, 16) report "FAIL ang_sel sel=1" severity failure;
        report "ang_sel: PASS";

        report "All mux block tests PASS";
        std.env.stop; wait;
    end process;
end architecture sim;
