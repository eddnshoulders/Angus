library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- trig_tb.vhd  (v3)
--
-- Unit testbench for trig.vhd.
-- STEP_SIZE = 1_193_324 angfac units = one 0.1-degree step per revolution.
-- At decimation=1: fires 3600 times per revolution.
-- =============================================================================

entity trig_tb is
end entity trig_tb;

architecture sim of trig_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant STEP_SIZE  : integer := 1_193_324;

    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal angfac    : unsigned(31 downto 0) := (others => '0');
    signal z_edge    : std_logic := '0';
    signal decim     : unsigned(15 downto 0) := to_unsigned(1, 16);
    signal trig_p    : std_logic;
    signal trig_cnt  : unsigned(31 downto 0);

    signal sim_done  : boolean := false;
    signal test_num  : integer := 0;
    signal pulse_count : integer := 0;

    procedure fire_z(signal z : out std_logic; signal c : in std_logic) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_z;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.trig
        port map (
            clk             => clk,
            rst             => rst,
            ang_angfac      => angfac,
            z_edge          => z_edge,
            trig_decimation => decim,
            trig_pulse      => trig_p,
            trig_count      => trig_cnt
        );

    -- Count rising edges of trig_pulse
    p_monitor : process(clk)
        variable prev : std_logic := '0';
    begin
        if rising_edge(clk) then
            if trig_p = '1' and prev = '0' then
                pulse_count <= pulse_count + 1;
            end if;
            prev := trig_p;
        end if;
    end process p_monitor;

    p_stim : process
        variable count_start : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset -- no pulse, count = 0
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert trig_p = '0'
            report "FAIL T1: trig_pulse should be low after reset"
            severity failure;
        assert to_integer(trig_cnt) = 0
            report "FAIL T1: trig_count should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Step boundary fires trig_pulse (decimation=1)
        -- Advance ang_angfac past one STEP_SIZE boundary.
        -- --------------------------------------------------------------------
        report "TEST 2: First step boundary fires trig_pulse";
        test_num <= 2;

        decim    <= to_unsigned(1, 16);
        angfac   <= to_unsigned(STEP_SIZE + 1, 32);  -- past first boundary
        wait for 1 * CLK_PERIOD; wait for 1 ns;  -- check at the threshold clock

        assert trig_p = '1'
            report "FAIL T2: trig_pulse should fire when angfac >= STEP_SIZE"
            severity failure;
        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: trig_pulse is a 1-clock strobe
        -- --------------------------------------------------------------------
        report "TEST 3: trig_pulse is a 1-clock strobe";
        test_num <= 3;

        wait until rising_edge(clk); wait for 1 ns;
        assert trig_p = '0'
            report "FAIL T3: trig_pulse should be a 1-clock strobe"
            severity failure;
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: z_edge resets threshold and count
        -- --------------------------------------------------------------------
        report "TEST 4: z_edge resets threshold and trig_count";
        test_num <= 4;

        assert to_integer(trig_cnt) > 0
            report "FAIL T4 setup: trig_cnt should be non-zero"
            severity failure;

        -- Set ang_angfac to 0 before z_edge so no threshold crossing occurs
        -- on the clock immediately after (which would increment count again).
        angfac <= (others => '0');
        wait until rising_edge(clk); wait for 1 ns;
        fire_z(z_edge, clk);
        -- z_edge fires a pulse at 0 deg, so trig_count = 1 immediately
        assert to_integer(trig_cnt) = 1
            report "FAIL T4: trig_count should be 1 after z_edge (0 deg pulse), got " &
                   integer'image(to_integer(trig_cnt))
            severity failure;

        -- Advance past next threshold: trig_count should become 2
        angfac <= to_unsigned(STEP_SIZE + 1, 32);
        wait for 1 * CLK_PERIOD; wait for 1 ns;
        assert to_integer(trig_cnt) = 2
            report "FAIL T4: trig_count should be 2 after one more step"
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: decimation=3 fires every 3rd step
        -- z_edge resets trig_cnt to 1 (the 0-deg pulse).
        -- 9 steps with decim=3 fires at steps 3, 6, 9 = 3 more fires.
        -- Final trig_cnt = 1 (z_edge) + 3 (loop) = 4.
        -- --------------------------------------------------------------------
        report "TEST 5: decimation=3 fires every 3rd step";
        test_num <= 5;

        angfac <= (others => '0');
        wait until rising_edge(clk); wait for 1 ns;
        fire_z(z_edge, clk);
        decim  <= to_unsigned(3, 16);

        for i in 1 to 9 loop
            angfac <= to_unsigned(i * STEP_SIZE + 1, 32);
            wait for 3 * CLK_PERIOD;
        end loop;
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert to_integer(trig_cnt) = 4
            report "FAIL T5: expected trig_cnt=4 (1 z_edge + 3 loop fires), got " &
                   integer'image(to_integer(trig_cnt))
            severity failure;
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: trig_count increments correctly over 5 fires at decim=1
        -- --------------------------------------------------------------------
        report "TEST 6: trig_count increments on each pulse";
        test_num <= 6;

        -- Reset angfac before z_edge to prevent residual T5 value
        -- causing extra threshold crossings on the post-z_edge clock.
        angfac <= (others => '0');
        wait until rising_edge(clk); wait for 1 ns;
        fire_z(z_edge, clk);
        decim <= to_unsigned(1, 16);
        wait for 2 * CLK_PERIOD;

        for i in 1 to 5 loop
            angfac <= to_unsigned(i * STEP_SIZE + 1, 32);
            wait for 3 * CLK_PERIOD;
        end loop;
        wait for 1 ns;

        assert to_integer(trig_cnt) = 6
            report "FAIL T6: trig_count should be 6 (1 from z_edge + 5 from loop), got " &
                   integer'image(to_integer(trig_cnt))
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: No spurious pulse when ang_angfac stays below threshold
        -- --------------------------------------------------------------------
        report "TEST 7: No pulse when ang_angfac below threshold";
        test_num <= 7;

        -- Zero angfac before z_edge so the z='0' extra clock sees
        -- angfac < threshold and does not fire (avoids T6 residual state).
        angfac <= (others => '0');
        wait until rising_edge(clk); wait for 1 ns;
        z_edge <= '1'; wait until rising_edge(clk); wait for 1 ns;
        z_edge <= '0'; wait until rising_edge(clk); wait for 1 ns;  -- 0<STEP, no fire
        -- Now set angfac just below threshold; verify no pulse for 10 clocks
        angfac <= to_unsigned(STEP_SIZE - 1, 32);
        count_start := pulse_count;
        wait for 10 * CLK_PERIOD; wait for 1 ns;

        assert pulse_count = count_start
            report "FAIL T7: pulse fired below STEP_SIZE threshold"
            severity failure;
        report "TEST 7: PASS";

        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All trig tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
