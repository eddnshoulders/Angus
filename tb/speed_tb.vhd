library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity speed_tb is end entity;
architecture sim of speed_tb is
    constant CLK_PERIOD : time := 10 ns;
    -- At 1000 RPM: z_period = 6_000_000_000 / 1000 = 6_000_000 clocks
    -- At 3000 RPM: z_period = 2_000_000 clocks
    -- For sim use 3000 RPM: z_period = 2_000_000 -- too slow
    -- Use 6000 RPM: z_period = 1_000_000 -- still slow
    -- Adjust: use artificial values
    -- z_period = 6000 clocks -> RPM = 6_000_000_000/6000 = 1_000_000 RPM (overflow)
    -- z_period = 60000 -> RPM = 100_000 (overflow)
    -- z_period = 600000 -> RPM = 10_000 (OK for 16-bit)
    -- z_period = 6_000_000 -> RPM = 1000
    -- Let's use 600000 clocks = 10000 RPM and verify

    constant Z_PERIOD_CLOCKS : integer := 600000;
    constant EXPECTED_RPM_SLOW : integer := 10000;

    -- ab_period for 60 teeth at 10000 RPM:
    -- z_period = 600000 clocks per rev
    -- ab_period = 600000/60 = 10000 clocks per tooth
    constant AB_PERIOD_CLOCKS : integer := 10000;
    constant EXPECTED_RPM_FAST : integer := 10000;

    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal ab_edge    : std_logic := '0';
    signal z_edge     : std_logic := '0';
    signal ab_per     : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_CLOCKS, 32);
    signal ppr_s      : unsigned(7 downto 0)  := to_unsigned(60, 8);
    signal rpm_slow   : unsigned(15 downto 0);
    signal rpm_fast   : unsigned(15 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.speed port map(clk=>clk, rst=>rst, ab_edge=>ab_edge, z_edge=>z_edge,
        ab_period=>ab_per, ppr_conf=>ppr_s, speed_rpm_slow=>rpm_slow, speed_rpm_fast=>rpm_fast);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0';

        -- T1: fire 2 z_edges at Z_PERIOD_CLOCKS apart, check rpm_slow
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0';
        wait for (Z_PERIOD_CLOCKS - 1) * CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0';
        -- Wait for divider (16 cycles)
        wait for 20 * CLK_PERIOD;
        assert to_integer(rpm_slow) = EXPECTED_RPM_SLOW
            report "FAIL T1: rpm_slow = " & integer'image(to_integer(rpm_slow)) &
                   " expected " & integer'image(EXPECTED_RPM_SLOW) severity failure;
        report "T1 rpm_slow: PASS";

        -- T2: fire ab_edge, check rpm_fast
        ab_edge <= '1'; wait for CLK_PERIOD; ab_edge <= '0';
        wait for 20 * CLK_PERIOD;
        assert to_integer(rpm_fast) = EXPECTED_RPM_FAST
            report "FAIL T2: rpm_fast = " & integer'image(to_integer(rpm_fast)) &
                   " expected " & integer'image(EXPECTED_RPM_FAST) severity failure;
        report "T2 rpm_fast: PASS";

        report "All speed tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
