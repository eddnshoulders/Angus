library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity sync_tb is end entity;
architecture sim of sync_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal ab_edge    : std_logic := '0';
    signal z_edge     : std_logic := '0';
    signal ppr_conf   : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal ab_count   : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal ref_found  : std_logic := '0';
    signal sync_state : unsigned(1 downto 0);
    signal sync_full  : std_logic;
    signal fault_cnt  : unsigned(15 downto 0);

    procedure pulse(signal s : out std_logic; signal c : in std_logic) is
    begin s <= '1'; wait until rising_edge(c); s <= '0'; wait until rising_edge(c); end;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.sync port map(clk=>clk, rst=>rst, ab_edge=>ab_edge, z_edge=>z_edge,
        ppr_conf=>ppr_conf, ab_count=>ab_count, phase_ref_found=>ref_found,
        sync_state=>sync_state, sync_full=>sync_full, sync_fault_count=>fault_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0';

        -- T1: STOPPED -> MOVING on first ab_edge
        assert to_integer(sync_state) = 0 report "FAIL T1: not STOPPED" severity failure;
        pulse(ab_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(sync_state) = 1 report "FAIL T1: not MOVING" severity failure;
        report "T1: PASS";

        -- T2: MOVING -> CRANK_SYNC after 2 z_edges with correct ab_count
        pulse(z_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(sync_state) = 1 report "FAIL T2: left MOVING on 1st z" severity failure;
        pulse(z_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(sync_state) = 2 report "FAIL T2: not CRANK_SYNC after 2nd z" severity failure;
        report "T2: PASS";

        -- T3: CRANK_SYNC -> FULL_SYNC on phase_ref_found
        assert sync_full = '0' report "FAIL T3: sync_full prematurely" severity failure;
        ref_found <= '1'; wait for 2 * CLK_PERIOD;
        assert to_integer(sync_state) = 3 report "FAIL T3: not FULL_SYNC" severity failure;
        assert sync_full = '1' report "FAIL T3: sync_full not high" severity failure;
        report "T3: PASS";

        -- T4: fault_count increments when ab_count wrong at z_edge
        -- ab_count must be set one cycle BEFORE z_edge (sync registers ab_count)
        ab_count <= to_unsigned(45, 8);  -- wrong
        wait for CLK_PERIOD;  -- let ab_count_r register the value
        pulse(z_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(fault_cnt) = 1 report "FAIL T4: fault not counted" severity failure;
        ab_count <= to_unsigned(60, 8);  -- correct
        wait for CLK_PERIOD;  -- let ab_count_r register the value
        pulse(z_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(fault_cnt) = 1 report "FAIL T4: fault counted for correct ab_count" severity failure;
        report "T4: PASS";

        report "All sync tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
