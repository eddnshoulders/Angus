library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity enc_tb is end entity;
architecture sim of enc_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal a_clean    : std_logic := '0';
    signal b_clean    : std_logic := '0';
    signal z_clean    : std_logic := '0';
    signal ab_sel     : unsigned(1 downto 0) := "00";  -- rising
    signal z_sel      : std_logic := '0';
    signal n_ppr      : unsigned(15 downto 0) := to_unsigned(100, 16);
    signal ab_edge    : std_logic;
    signal z_edge     : std_logic;
    signal ppr_conf   : unsigned(7 downto 0);
    signal ab_period  : unsigned(31 downto 0);
    signal ab_count   : unsigned(7 downto 0);
    signal a_count    : unsigned(7 downto 0);
    signal b_count    : unsigned(7 downto 0);
    signal sig_ok     : std_logic;
    signal fault_cnt  : unsigned(7 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.enc port map(clk=>clk, rst=>rst, a_clean=>a_clean,
        b_clean=>b_clean, z_clean=>z_clean, enc_ab_edge_sel=>ab_sel,
        enc_z_edge_sel=>z_sel, enc_n_ppr=>n_ppr, enc_ab_edge=>ab_edge,
        enc_z_edge=>z_edge, enc_ppr_conf=>ppr_conf, enc_ab_period=>ab_period,
        enc_ab_count=>ab_count, enc_a_count=>a_count, enc_b_count=>b_count,
        enc_signal_ok=>sig_ok, enc_fault_count=>fault_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: ppr_conf is lower 8 bits of enc_n_ppr
        assert ppr_conf = to_unsigned(100, 8) report "FAIL T1: ppr_conf" severity failure;
        report "T1: PASS";

        -- T2: rising edge on A fires ab_edge
        a_clean <= '1'; wait until rising_edge(clk); wait for 1 ns;
        assert ab_edge = '1' report "FAIL T2: ab_edge not fired on A rising" severity failure;
        a_clean <= '0'; wait until rising_edge(clk); wait for 1 ns;
        assert ab_edge = '0' report "FAIL T2: ab_edge not 1-clock pulse" severity failure;
        report "T2: PASS";

        -- T3: B edge also fires ab_edge
        b_clean <= '1'; wait until rising_edge(clk); wait for 1 ns;
        assert ab_edge = '1' report "FAIL T3: ab_edge not fired on B" severity failure;
        b_clean <= '0'; wait until rising_edge(clk);
        report "T3: PASS";

        -- T4: a_count and ab_count tracking
        a_clean <= '1'; wait until rising_edge(clk); a_clean <= '0'; wait until rising_edge(clk);
        assert to_integer(a_count) = 2 report "FAIL T4: a_count wrong" severity failure;
        assert to_integer(ab_count) = 3 report "FAIL T4: ab_count wrong" severity failure;
        report "T4: PASS";

        -- T5: z_edge resets counts
        z_clean <= '1'; wait until rising_edge(clk); wait for 1 ns;
        assert z_edge = '1' report "FAIL T5: z_edge not fired" severity failure;
        z_clean <= '0'; wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(ab_count) = 0 report "FAIL T5: ab_count not reset on z" severity failure;
        report "T5: PASS";

        report "All enc tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
