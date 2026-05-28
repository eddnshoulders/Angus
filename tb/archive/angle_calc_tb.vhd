library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- angle_calc_tb
--
-- Tests new angle_calc interface:
--   - Inputs: ab, z, ab_period, ppr, ab_count, signal_present
--   - No divider, no config_apply
--   - angle_raw 0-7199 over 720 degrees (2 crank revolutions)
--   - degrees_per_edge = 7200 / (ppr * 2)
--   - Both edges of ab counted
--   - First Z sets origin; subsequent Z toggles phase
--   - Every second Z resets angle, checks count_fault
--
-- T1: Reset - outputs zero
-- T2: First Z sets origin, angle stays 0 until ab edges arrive
-- T3: ab edges advance angle by degrees_per_edge each toggle (ppr=60, 60/edge)
-- T4: Interpolation advances angle between ab edges
-- T5: Phase toggles on Z, resets on every second Z
-- T6: Angle resets to 0 at every second Z
-- T7: count_fault increments when ab_count != ppr at second Z
-- T8: signal_present=0 holds angle at 0
-- =============================================================================

entity angle_calc_tb is end entity;

architecture sim of angle_calc_tb is

    constant CLK_PERIOD  : time    := 10 ns;
    constant PPR         : integer := 60;
    constant AB_PERIOD   : integer := 1000;   -- clocks per ab edge
    constant DEG_PER_EDGE: integer := 7200 / (PPR * 2);  -- 60

    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal sim_done      : boolean   := false;
    signal test_num      : integer   := 0;

    -- DUT inputs
    signal ab            : std_logic := '0';
    signal z             : std_logic := '0';
    signal ab_period_s   : unsigned(31 downto 0) := to_unsigned(AB_PERIOD, 32);
    signal ppr_s         : unsigned(7 downto 0)  := to_unsigned(PPR, 8);
    signal ab_count_s    : unsigned(7 downto 0)  := (others => '0');
    signal signal_present: std_logic := '0';

    -- DUT outputs
    signal angle_raw     : unsigned(15 downto 0);
    signal phase         : std_logic;
    signal count_fault   : unsigned(15 downto 0);

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.angle_calc
        port map (
            clk            => clk,
            rst            => rst,
            ab             => ab,
            z              => z,
            ab_period      => ab_period_s,
            ppr            => ppr_s,
            ab_count       => ab_count_s,
            signal_present => signal_present,
            angle_raw      => angle_raw,
            phase          => phase,
            count_fault    => count_fault
        );

    p_stim : process

        -- Toggle ab (both edges count)
        procedure ab_edge(count : integer) is
        begin
            ab_count_s <= to_unsigned(count, 8);
            ab         <= not ab;
            wait for CLK_PERIOD;
        end procedure;

        procedure fire_z is
        begin
            z <= '1'; wait for CLK_PERIOD;
            z <= '0'; wait for CLK_PERIOD;
        end procedure;

        procedure do_reset is
        begin
            rst            <= '1';
            ab             <= '0';
            z              <= '0';
            signal_present <= '0';
            ab_count_s     <= (others => '0');
            wait for 20 * CLK_PERIOD;
            rst <= '0';
            wait for 5 * CLK_PERIOD;
        end procedure;

    begin

        -- ----------------------------------------------------------------
        -- T1: Reset - all outputs zero
        -- ----------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: Reset";
        do_reset;

        assert to_integer(angle_raw) = 0
            report "FAIL T1: angle_raw should be 0" severity failure;
        assert phase = '0'
            report "FAIL T1: phase should be 0" severity failure;
        assert to_integer(count_fault) = 0
            report "FAIL T1: count_fault should be 0" severity failure;
        report "TEST 1: PASS";

        -- ----------------------------------------------------------------
        -- T2: First Z sets origin, angle stays 0
        -- ----------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: First Z sets origin";
        signal_present <= '1';

        -- Before any Z, ab edges should not advance angle
        ab_edge(1);
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = 0
            report "FAIL T2: angle should be 0 before first Z" severity failure;

        -- Fire first Z - sets origin
        fire_z;
        wait for 2 * CLK_PERIOD;
        assert to_integer(angle_raw) = 0
            report "FAIL T2: angle should be 0 after first Z" severity failure;
        assert phase = '0'
            report "FAIL T2: phase should be 0 after first Z" severity failure;
        report "TEST 2: PASS";

        -- ----------------------------------------------------------------
        -- T3: ab edges advance angle by DEG_PER_EDGE each toggle
        -- ppr=60, DEG_PER_EDGE = 7200/120 = 60
        -- ----------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: ab edges advance angle by 60 per edge";

        -- Edge 0 after first Z: angle should be 0
        ab_edge(0);
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = 0
            report "FAIL T3: edge 0 should give angle 0, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        -- Edge 1: angle should be 60
        ab_edge(1);
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = DEG_PER_EDGE
            report "FAIL T3: edge 1 should give angle 60, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        -- Edge 5: angle should be 300
        ab_edge(2); ab_edge(3); ab_edge(4);
        ab_edge(5);
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = 5 * DEG_PER_EDGE
            report "FAIL T3: edge 5 should give angle 300, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        -- Edge 10: angle should be 600
        ab_edge(6); ab_edge(7); ab_edge(8); ab_edge(9);
        ab_edge(10);
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = 10 * DEG_PER_EDGE
            report "FAIL T3: edge 10 should give angle 600, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        report "TEST 3: PASS";

        -- ----------------------------------------------------------------
        -- T4: Interpolation advances angle between ab edges
        -- ----------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: Interpolation between ab edges";
        do_reset;
        signal_present <= '1';
        fire_z;
        wait for 2 * CLK_PERIOD;

        -- Snap to edge 0
        ab_edge(0);
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = 0
            report "FAIL T4 setup: should be 0 at edge 0" severity failure;

        -- Wait half ab_period - should be ~DEG_PER_EDGE/2 = ~30
        wait for (AB_PERIOD / 2) * CLK_PERIOD;
        assert to_integer(angle_raw) >= 25 and to_integer(angle_raw) <= 35
            report "FAIL T4: at half ab_period should be ~30, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        -- Wait full ab_period - should be near DEG_PER_EDGE-1 = 59
        wait for (AB_PERIOD / 2) * CLK_PERIOD;
        assert to_integer(angle_raw) >= 55 and to_integer(angle_raw) <= 59
            report "FAIL T4: at end of ab_period should be ~59, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        report "TEST 4: PASS";

        -- ----------------------------------------------------------------
        -- T5: Phase toggles on Z; resets on every second Z
        -- ----------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: Phase and angle reset on every second Z";
        do_reset;
        signal_present <= '1';

        -- First Z: origin, phase=0
        fire_z;
        wait for 2 * CLK_PERIOD;
        assert phase = '0'
            report "FAIL T5: phase should be 0 after 1st Z" severity failure;

        -- Some ab edges to get non-zero angle
        for i in 0 to 9 loop ab_edge(i); end loop;
        wait for CLK_PERIOD;
        assert to_integer(angle_raw) = 9 * DEG_PER_EDGE
            report "FAIL T5 setup: angle should be 540 before 2nd Z, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        -- Second Z: phase toggles to 1, angle continues (not reset)
        fire_z;
        wait for 2 * CLK_PERIOD;
        assert phase = '1'
            report "FAIL T5: phase should be 1 after 2nd Z" severity failure;

        -- More ab edges in second revolution
        for i in 0 to 9 loop ab_edge(i); end loop;
        wait for CLK_PERIOD;

        -- Third Z: phase back to 0, angle resets to 0
        fire_z;
        wait for 2 * CLK_PERIOD;
        assert phase = '0'
            report "FAIL T5: phase should be 0 after 3rd Z" severity failure;
        assert to_integer(angle_raw) = 0
            report "FAIL T5: angle should reset to 0 at 3rd Z, got " &
                   integer'image(to_integer(angle_raw)) severity failure;

        report "TEST 5: PASS";

        -- ----------------------------------------------------------------
        -- T6: count_fault increments when ab_count != ppr at second Z
        -- ----------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: count_fault on ab_count mismatch";
        do_reset;
        signal_present <= '1';

        assert to_integer(count_fault) = 0
            report "FAIL T6 setup: count_fault should be 0" severity failure;

        -- First Z: origin
        fire_z;
        wait for 2 * CLK_PERIOD;

        -- Drive ab_count to wrong value (not equal to ppr=60)
        ab_count_s <= to_unsigned(45, 8);  -- wrong count
        wait for CLK_PERIOD;

        -- Second Z: phase toggles, no fault check here
        fire_z;
        wait for 2 * CLK_PERIOD;

        -- Drive wrong ab_count again
        ab_count_s <= to_unsigned(45, 8);
        wait for CLK_PERIOD;

        -- Third Z: phase back to 0 - fault check triggers
        fire_z;
        wait for 2 * CLK_PERIOD;

        assert to_integer(count_fault) = 1
            report "FAIL T6: count_fault should be 1 after mismatch, got " &
                   integer'image(to_integer(count_fault)) severity failure;

        -- Now correct ab_count and verify no further fault
        ab_count_s <= to_unsigned(PPR, 8);
        fire_z;  -- 4th Z: phase=1
        wait for 2 * CLK_PERIOD;
        ab_count_s <= to_unsigned(PPR, 8);
        fire_z;  -- 5th Z: phase=0, check passes
        wait for 2 * CLK_PERIOD;

        assert to_integer(count_fault) = 1
            report "FAIL T6: count_fault should still be 1 (no new fault), got " &
                   integer'image(to_integer(count_fault)) severity failure;

        report "TEST 6: PASS";

        -- ----------------------------------------------------------------
        -- T7: signal_present=0 holds angle at 0
        -- ----------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: signal_present=0 holds angle at 0";
        do_reset;
        signal_present <= '1';

        fire_z;
        wait for 2 * CLK_PERIOD;
        for i in 0 to 9 loop ab_edge(i); end loop;
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) > 0
            report "FAIL T7 setup: angle should be non-zero" severity failure;

        signal_present <= '0';
        wait for 2 * CLK_PERIOD;

        assert to_integer(angle_raw) = 0
            report "FAIL T7: angle should be 0 when signal_present=0, got " &
                   integer'image(to_integer(angle_raw)) severity failure;
        assert phase = '0'
            report "FAIL T7: phase should be 0 when signal_present=0" severity failure;

        report "TEST 7: PASS";

        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All angle_calc tests PASS";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;
    end process p_stim;

end architecture sim;
