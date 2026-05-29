library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity trig_tb is end entity;
architecture sim of trig_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk      : std_logic := '0';
    signal done     : boolean := false;
    signal rst      : std_logic := '1';
    signal ang_deg  : unsigned(15 downto 0) := (others => '0');
    signal z_edge   : std_logic := '0';
    signal decim    : unsigned(15 downto 0) := to_unsigned(1, 16);
    signal pw       : unsigned(15 downto 0) := to_unsigned(3, 16);
    signal trig_p   : std_logic;
    signal trig_cnt : unsigned(31 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.trig port map(clk=>clk, rst=>rst, ang_deg=>ang_deg, z_edge=>z_edge,
        trig_decimation=>decim, trig_pulse_width=>pw, trig_pulse=>trig_p, trig_pulse_count=>trig_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: decimation=1, every increment fires a pulse
        ang_deg <= to_unsigned(1, 16); wait for CLK_PERIOD;
        assert trig_p = '1' report "FAIL T1: pulse not fired on increment" severity failure;
        wait for 4 * CLK_PERIOD;
        assert trig_p = '0' report "FAIL T1: pulse not ending after pulse_width" severity failure;
        report "T1: PASS";

        -- T2: decimation=3, pulse every 3 increments
        decim <= to_unsigned(3, 16);
        ang_deg <= to_unsigned(2, 16); wait for 2 * CLK_PERIOD;
        assert trig_p = '0' report "FAIL T2: pulse fired at decim 1/3" severity failure;
        ang_deg <= to_unsigned(3, 16); wait for 2 * CLK_PERIOD;
        assert trig_p = '0' report "FAIL T2: pulse fired at decim 2/3" severity failure;
        ang_deg <= to_unsigned(4, 16); wait for 2 * CLK_PERIOD;
        assert trig_p = '1' report "FAIL T2: pulse not fired at decim 3/3" severity failure;
        report "T2: PASS";

        -- T3: trig_pulse_count resets on z_edge
        wait for 5 * CLK_PERIOD;
        assert to_integer(trig_cnt) > 0 report "FAIL T3: count is 0" severity failure;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        assert to_integer(trig_cnt) = 0 report "FAIL T3: count not reset on z_edge" severity failure;
        report "T3: PASS";

        report "All trig tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
