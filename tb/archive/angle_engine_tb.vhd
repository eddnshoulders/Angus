library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- angle_engine_tb
-- Key priming rule: tooth 0 = 2nd ab_edge after priming starts.
-- This ensures ab_period = AB_PERIOD (not 1) when the divider fires.
-- =============================================================================

entity angle_engine_tb is
end entity angle_engine_tb;

architecture sim of angle_engine_tb is

    constant CLK_PERIOD   : time    := 10 ns;
    constant N_TEETH      : integer := 60;
    constant AB_PERIOD    : integer := 1000;

    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal sim_done       : boolean   := false;
    signal test_num       : integer   := 0;

    signal ab             : std_logic := '0';
    signal z              : std_logic := '0';
    signal synced         : std_logic := '0';
    signal phase_engine   : std_logic := '0';
    signal n_teeth_s      : unsigned(7 downto 0) := to_unsigned(N_TEETH, 8);
    signal config_apply   : std_logic := '0';
    signal kp             : unsigned(15 downto 0) := (others => '0');
    signal ki             : unsigned(15 downto 0) := (others => '0');
    signal max_correction : unsigned(15 downto 0) := to_unsigned(65535, 16);
    signal correction_dir : std_logic := '0';

    signal angle_hires    : unsigned(15 downto 0);
    signal div_valid_out  : std_logic;
    signal nco_inc_out    : unsigned(31 downto 0);
    signal nco_accum_out  : unsigned(31 downto 0);
    signal phase_error_out: signed(31 downto 0);
    signal correction_out : signed(31 downto 0);

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.angle_engine
        port map (
            clk             => clk,
            rst             => rst,
            ab              => ab,
            z               => z,
            synced          => synced,
            phase_engine    => phase_engine,
            n_teeth         => n_teeth_s,
            config_apply    => config_apply,
            kp              => kp,
            ki              => ki,
            max_correction  => max_correction,
            correction_dir  => correction_dir,
            angle_hires     => angle_hires,
            div_valid_out   => div_valid_out,
            nco_inc_out     => nco_inc_out,
            nco_accum_out   => nco_accum_out,
            phase_error_out => phase_error_out,
            correction_out  => correction_out
        );

    p_stim : process

        -- Full isolation reset
        procedure do_reset is
        begin
            synced <= '0';
            wait for 3 * CLK_PERIOD;
            rst <= '1'; wait for 10 * CLK_PERIOD; rst <= '0';
            wait for 5 * CLK_PERIOD;
        end procedure;

        -- Apply config for n teeth
        procedure do_config(n : integer) is
        begin
            n_teeth_s    <= to_unsigned(n, 8);
            config_apply <= '1'; wait for CLK_PERIOD;
            config_apply <= '0';
            wait for 80 * CLK_PERIOD;
        end procedure;

        -- Standard tooth sequence:
        -- 1. Fire prime edge (ab toggle) with synced=0
        -- 2. Wait AB_PERIOD
        -- 3. Enable synced and fire tooth 0 (ab_period = AB_PERIOD)
        -- 4. Wait for divider (80 cycles)
        -- 5. Wait remaining tooth period
        -- 6. Fire tooth 1
        -- 7. Wait a few cycles then read angle_hires
        procedure do_two_teeth(period : integer; n : integer) is
        begin
            synced <= '0';
            ab <= not ab;              -- prime edge: starts ab_timer
            wait for period * CLK_PERIOD;
            synced <= '1';
            phase_engine <= '0';
            ab <= not ab;              -- tooth 0: ab_period = period, divider fires
            wait for 80 * CLK_PERIOD; -- divider latency
            wait for (period - 80) * CLK_PERIOD;
            ab <= not ab;              -- tooth 1
            wait for 3 * CLK_PERIOD;
        end procedure;

        variable angle_curr : integer;
        variable angle_prev : integer;

    begin

        -- T1: Reset
        test_num <= 1;
        report "TEST 1: Reset behaviour";
        do_reset;
        assert to_integer(angle_hires) = 0
            report "FAIL T1: angle_hires should be 0" severity failure;
        report "TEST 1: PASS";

        -- T2: config_apply completes
        test_num <= 2;
        report "TEST 2: config_apply";
        do_config(60);
        report "TEST 2: PASS";

        -- T3: monotonically increasing angle
        test_num <= 3;
        report "TEST 3: angle_hires monotonically increasing";
        do_reset;
        do_config(60);
        -- Prime and start NCO
        synced <= '0';
        ab <= not ab;
        wait for AB_PERIOD * CLK_PERIOD;
        synced <= '1'; phase_engine <= '0';
        ab <= not ab;  -- tooth 0
        wait for 80 * CLK_PERIOD;

        angle_prev := 0;
        for i in 1 to 200 loop
            wait for CLK_PERIOD;
            angle_curr := to_integer(angle_hires);
            if angle_curr < angle_prev then
                assert angle_prev >= 3590
                    report "FAIL T3: angle decreased from " &
                           integer'image(angle_prev) & " to " &
                           integer'image(angle_curr)
                    severity failure;
            end if;
            angle_prev := angle_curr;
        end loop;
        report "TEST 3: PASS";

        -- T4: 60-tooth wheel, angle per tooth ~60
        test_num <= 4;
        report "TEST 4: 60-tooth, ~60 steps/tooth";
        do_reset;
        do_config(60);
        do_two_teeth(AB_PERIOD, N_TEETH);
        angle_curr := to_integer(angle_hires);
        report "DEBUG T4: angle=" & integer'image(angle_curr) &
               " nco_inc=" & integer'image(to_integer(nco_inc_out));
        assert angle_curr >= 50 and angle_curr <= 70
            report "FAIL T4: expected ~60, got " & integer'image(angle_curr)
            severity failure;
        report "TEST 4: PASS - angle/tooth = " & integer'image(angle_curr);

        -- T5: phase_engine=1 adds 3600
        test_num <= 5;
        report "TEST 5: phase_engine offset";
        do_reset;
        do_config(60);
        do_two_teeth(AB_PERIOD, N_TEETH);
        angle_curr := to_integer(angle_hires);
        assert angle_curr < 3600
            report "FAIL T5: phase_engine=0 should give < 3600, got " &
                   integer'image(angle_curr)
            severity failure;
        phase_engine <= '1';
        wait for 3 * CLK_PERIOD;
        angle_curr := to_integer(angle_hires);
        assert angle_curr >= 3600
            report "FAIL T5: phase_engine=1 should give >= 3600, got " &
                   integer'image(angle_curr)
            severity failure;
        report "TEST 5: PASS";

        -- T6: synced=0 resets PI
        test_num <= 6;
        report "TEST 6: synced=0 resets PI";
        synced <= '0';
        wait for 5 * CLK_PERIOD;
        assert to_integer(correction_out) = 0
            report "FAIL T6: correction should be 0" severity failure;
        report "TEST 6: PASS";

        -- T7: nco_inc ~71582 for AB_PERIOD=1000
        test_num <= 7;
        report "TEST 7: nco_inc from ab_period=1000";
        do_reset;
        do_config(60);
        synced <= '0';
        ab <= not ab;
        wait for AB_PERIOD * CLK_PERIOD;
        synced <= '1';
        ab <= not ab;   -- tooth 0
        wait for 80 * CLK_PERIOD;
        assert to_integer(nco_inc_out) >= 71000 and
               to_integer(nco_inc_out) <= 72000
            report "FAIL T7: nco_inc should be ~71582, got " &
                   integer'image(to_integer(nco_inc_out))
            severity failure;
        report "TEST 7: PASS - nco_inc = " & integer'image(to_integer(nco_inc_out));

        -- T8: 36-tooth wheel, ~100 steps/tooth
        test_num <= 8;
        report "TEST 8: 36-tooth, ~100 steps/tooth";
        do_reset;
        do_config(36);
        do_two_teeth(AB_PERIOD, 36);
        angle_curr := to_integer(angle_hires);
        assert angle_curr >= 90 and angle_curr <= 110
            report "FAIL T8: expected ~100, got " & integer'image(angle_curr)
            severity failure;
        report "TEST 8: PASS - angle/tooth = " & integer'image(angle_curr);

        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All angle_engine tests complete";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
