library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity filter_tb is end entity;
architecture sim of filter_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk   : std_logic := '0';
    signal done  : boolean := false;
    signal rst   : std_logic := '1';
    signal raw   : std_logic := '0';
    signal dbc   : unsigned(15 downto 0) := to_unsigned(4, 16);
    signal clean : std_logic;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';

    dut : entity work.filter port map(clk=>clk, rst=>rst, raw=>raw,
                                      debounce_cycles=>dbc, clean=>clean);
    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0';

        -- T1: stable input passes through after debounce_cycles
        raw <= '1';
        wait for 5 * CLK_PERIOD;  -- 2FF + part of debounce
        assert clean = '0' report "FAIL T1: clean high before debounce" severity failure;
        wait for 4 * CLK_PERIOD;  -- rest of debounce
        assert clean = '1' report "FAIL T1: clean not high after debounce" severity failure;
        report "T1: PASS";

        -- T2: glitch shorter than debounce is rejected
        raw <= '0'; wait for 2 * CLK_PERIOD;
        raw <= '1';
        wait for CLK_PERIOD;
        assert clean = '1' report "FAIL T2: glitch passed through" severity failure;
        report "T2: PASS";

        -- T3: sustained low passes through after debounce
        raw <= '0';
        wait for 10 * CLK_PERIOD;  -- 2FF + debounce(4) + margin
        assert clean = '0' report "FAIL T3: sustained low not passed" severity failure;
        report "T3: PASS";

        -- T4: reset clears output
        raw <= '1'; wait for 6 * CLK_PERIOD;
        rst <= '1'; wait for CLK_PERIOD;
        assert clean = '0' report "FAIL T4: reset did not clear" severity failure;
        rst <= '0';
        report "T4: PASS";

        report "All filter tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
