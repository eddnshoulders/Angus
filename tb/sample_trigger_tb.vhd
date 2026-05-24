library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity sample_trigger_tb is
end entity sample_trigger_tb;

architecture sim of sample_trigger_tb is

    constant CLK_PERIOD    : time := 1000 ns;

    -- Sync states
    constant ST_UNSYNC     : std_logic_vector(2 downto 0) := "000";
    constant ST_SYNC_FULL  : std_logic_vector(2 downto 0) := "011";

    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal engine_angle    : unsigned(15 downto 0) := (others => '0');
    signal sync_state      : std_logic_vector(2 downto 0) := ST_UNSYNC;
    signal decimation      : unsigned(7 downto 0) := to_unsigned(1, 8);
    signal sample_pulse    : std_logic;
    signal sample_angle    : unsigned(15 downto 0);

    signal sim_done        : boolean := false;
    signal test_num        : integer := 0;
    signal pulse_count     : integer := 0;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.sample_trigger
        port map (
            clk          => clk,
            rst          => rst,
            engine_angle => engine_angle,
            sync_state   => sync_state,
            decimation   => decimation,
            sample_pulse => sample_pulse,
            sample_angle => sample_angle
        );

    -- Count pulses
    p_monitor : process(clk)
    begin
        if rising_edge(clk) then
            if sample_pulse = '1' then
                pulse_count <= pulse_count + 1;
            end if;
        end if;
    end process p_monitor;

    p_stim : process
        variable count_start : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: Reset behaviour";
        rst <= '1'; wait for 10 * CLK_PERIOD;
        rst <= '0'; wait for 10 * CLK_PERIOD;

        assert sample_pulse = '0'
            report "FAIL T1: sample_pulse should be low after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: No pulse in UNSYNC
        -- --------------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: No pulse in UNSYNC";

        sync_state   <= ST_UNSYNC;
        decimation   <= to_unsigned(1, 8);
        count_start  := pulse_count;

        -- Step angle several times
        for i in 1 to 10 loop
            engine_angle <= engine_angle + 1;
            wait for CLK_PERIOD;
        end loop;

        assert pulse_count = count_start
            report "FAIL T2: should not pulse in UNSYNC"
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Pulse fires on each angle step in SYNC_FULL
        -- --------------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: Pulse on each angle step in SYNC_FULL";

        sync_state  <= ST_SYNC_FULL;
        decimation  <= to_unsigned(1, 8);
        count_start := pulse_count;

        -- Step angle 10 times
        for i in 1 to 10 loop
            engine_angle <= engine_angle + 1;
            wait for CLK_PERIOD * 2;
        end loop;

        assert pulse_count - count_start = 10
            report "FAIL T3: expected 10 pulses, got " &
                   integer'image(pulse_count - count_start)
            severity failure;
        report "TEST 3: PASS - " &
               integer'image(pulse_count - count_start) & " pulses";

        -- --------------------------------------------------------------------
        -- TEST 4: sample_angle matches engine_angle at pulse
        -- --------------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: sample_angle matches engine_angle";

        engine_angle <= to_unsigned(1234, 16);
        wait for CLK_PERIOD * 2;

        assert to_integer(sample_angle) = 1234
            report "FAIL T4: sample_angle = " &
                   integer'image(to_integer(sample_angle)) &
                   " expected 1234"
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: No pulse when angle unchanged
        -- --------------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: No pulse when angle unchanged";

        count_start := pulse_count;
        wait for 10 * CLK_PERIOD;

        assert pulse_count = count_start
            report "FAIL T5: should not pulse when angle unchanged"
            severity failure;
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: Decimation = 2, pulse every other step
        -- --------------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: Decimation = 2";

        decimation  <= to_unsigned(2, 8);
        count_start := pulse_count;

        -- Step angle 10 times, expect 5 pulses
        for i in 1 to 10 loop
            engine_angle <= engine_angle + 1;
            wait for CLK_PERIOD * 2;
        end loop;

        assert pulse_count - count_start = 5
            report "FAIL T6: expected 5 pulses with decimation=2, got " &
                   integer'image(pulse_count - count_start)
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: Decimation = 5, pulse every 5th step
        -- --------------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: Decimation = 5";

        decimation  <= to_unsigned(5, 8);
        count_start := pulse_count;

        -- Step angle 20 times, expect 4 pulses
        for i in 1 to 20 loop
            engine_angle <= engine_angle + 1;
            wait for CLK_PERIOD * 2;
        end loop;

        assert pulse_count - count_start = 4
            report "FAIL T7: expected 4 pulses with decimation=5, got " &
                   integer'image(pulse_count - count_start)
            severity failure;
        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- TEST 8: Sync loss resets decimation counter
        -- After returning to SYNC_FULL, decimation starts fresh
        -- --------------------------------------------------------------------
        test_num <= 8;
        report "TEST 8: Sync loss resets decimation counter";

        decimation  <= to_unsigned(4, 8);
        count_start := pulse_count;

        -- Step 2 times (mid-decimation)
        engine_angle <= engine_angle + 1; wait for CLK_PERIOD * 2;
        engine_angle <= engine_angle + 1; wait for CLK_PERIOD * 2;

        -- Lose sync
        sync_state <= ST_UNSYNC;
        wait for CLK_PERIOD * 2;

        -- Restore sync
        sync_state <= ST_SYNC_FULL;
        wait for CLK_PERIOD * 2;

        -- Step 4 times - should get 1 pulse (fresh decimation counter)
        for i in 1 to 4 loop
            engine_angle <= engine_angle + 1;
            wait for CLK_PERIOD * 2;
        end loop;

        assert pulse_count - count_start = 1
            report "FAIL T8: expected 1 pulse after sync restore, got " &
                   integer'image(pulse_count - count_start)
            severity failure;
        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- TEST 9: Wraparound at 7199 -> 0
        -- --------------------------------------------------------------------
        test_num <= 9;
        report "TEST 9: Angle wraparound";

        decimation   <= to_unsigned(1, 8);
        engine_angle <= to_unsigned(7199, 16);
        wait for CLK_PERIOD * 2;
        count_start := pulse_count;

        engine_angle <= to_unsigned(0, 16);
        wait for CLK_PERIOD * 2;

        assert pulse_count - count_start = 1
            report "FAIL T9: should pulse on wraparound"
            severity failure;
        assert to_integer(sample_angle) = 0
            report "FAIL T9: sample_angle should be 0 after wraparound"
            severity failure;
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for CLK_PERIOD;
        report "========================================";
        report "All sample_trigger tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;