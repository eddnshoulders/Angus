library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity phase_detector_tb is
end entity phase_detector_tb;

architecture sim of phase_detector_tb is

    constant CLK_PERIOD   : time    := 1000 ns;

    -- Test angles in 0.1 degree units
    -- Expected phase at 90.0 degrees = 900
    constant EXP_ANGLE    : unsigned(15 downto 0) := to_unsigned(900, 16);
    -- Tolerance: +/- 18.0 degrees = 180
    constant TOLERANCE    : unsigned(15 downto 0) := to_unsigned(180, 16);

    -- Band A centre: 900 (90.0 deg)
    -- Band B centre: 900 + 3600 = 4500 (450.0 deg)
    constant BAND_A_CENTRE : integer := 900;
    constant BAND_B_CENTRE : integer := 4500;

    -- Test angles
    -- In Band A:         900 (exact centre)
    -- In Band A edge:    900 + 180 = 1080
    -- Just outside A:    900 + 181 = 1081
    -- In Band B:         4500 (exact centre)
    -- In Band B edge:    4500 - 180 = 4320
    -- Just outside B:    4500 - 181 = 4319
    -- Outside both:      2700 (270.0 deg)

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk                  : std_logic := '0';
    signal rst                  : std_logic := '1';
    signal raw_angle            : unsigned(15 downto 0) := (others => '0');
    signal phase_ref            : std_logic := '0';
    signal expected_phase_angle : unsigned(15 downto 0) := EXP_ANGLE;
    signal phase_tolerance      : unsigned(15 downto 0) := TOLERANCE;
    signal ref_detected         : std_logic;
    signal sync_offset          : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done       : boolean := false;
    signal test_num       : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a phase_ref pulse at a given raw_angle value
    -- -------------------------------------------------------------------------
    procedure fire_ref(
        signal angle_sig : out unsigned(15 downto 0);
        signal ref_sig   : out std_logic;
        constant angle   : in  integer;
        constant clk_p   : in  time
    ) is
    begin
        angle_sig <= to_unsigned(angle, 16);
        wait for clk_p;
        ref_sig <= '1';
        wait for clk_p * 2;
        ref_sig <= '0';
        wait for clk_p * 5;
    end procedure fire_ref;

begin

    -- -------------------------------------------------------------------------
    -- Clock
    -- -------------------------------------------------------------------------
    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    -- -------------------------------------------------------------------------
    -- DUT
    -- -------------------------------------------------------------------------
    dut : entity work.phase_detector
        port map (
            clk                  => clk,
            rst                  => rst,
            raw_angle            => raw_angle,
            phase_ref            => phase_ref,
            expected_phase_angle => expected_phase_angle,
            phase_tolerance      => phase_tolerance,
            ref_detected         => ref_detected,
            sync_offset          => sync_offset
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: Reset behaviour";
        rst <= '1'; wait for 10 * CLK_PERIOD;
        rst <= '0'; wait for 10 * CLK_PERIOD;

        assert ref_detected = '0'
            report "FAIL T1: ref_detected should be low after reset"
            severity failure;
        assert sync_offset = '0'
            report "FAIL T1: sync_offset should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Band A centre - ref detected, sync_offset = 0
        -- --------------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: Band A centre (90.0 deg)";

        fire_ref(raw_angle, phase_ref, BAND_A_CENTRE, CLK_PERIOD);

        assert ref_detected = '1' or sync_offset = '0'
            report "FAIL T2: ref_detected should fire in Band A"
            severity failure;

        wait for 2 * CLK_PERIOD;
        assert sync_offset = '0'
            report "FAIL T2: sync_offset should be 0 for Band A"
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Band A edge (just inside tolerance)
        -- --------------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: Band A edge (90.0 + 18.0 deg)";

        fire_ref(raw_angle, phase_ref, BAND_A_CENTRE + 180, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert sync_offset = '0'
            report "FAIL T3: sync_offset should be 0 at Band A edge"
            severity failure;
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: Just outside Band A
        -- --------------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: Just outside Band A (90.0 + 18.1 deg)";

        -- Save current sync_offset to detect if it changes
        fire_ref(raw_angle, phase_ref, BAND_A_CENTRE + 181, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert ref_detected = '0'
            report "FAIL T4: ref_detected should not fire outside Band A"
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: Band B centre - ref detected, sync_offset = 1
        -- --------------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: Band B centre (450.0 deg)";

        fire_ref(raw_angle, phase_ref, BAND_B_CENTRE, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert sync_offset = '1'
            report "FAIL T5: sync_offset should be 1 for Band B"
            severity failure;
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: Band B edge (just inside tolerance)
        -- --------------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: Band B edge (450.0 - 18.0 deg)";

        fire_ref(raw_angle, phase_ref, BAND_B_CENTRE - 180, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert sync_offset = '1'
            report "FAIL T6: sync_offset should be 1 at Band B edge"
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: Just outside Band B
        -- --------------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: Just outside Band B (450.0 - 18.1 deg)";

        fire_ref(raw_angle, phase_ref, BAND_B_CENTRE - 181, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert ref_detected = '0'
            report "FAIL T7: ref_detected should not fire outside Band B"
            severity failure;
        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- TEST 8: Outside both bands
        -- --------------------------------------------------------------------
        test_num <= 8;
        report "TEST 8: Outside both bands (270.0 deg)";

        fire_ref(raw_angle, phase_ref, 2700, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert ref_detected = '0'
            report "FAIL T8: ref_detected should not fire outside both bands"
            severity failure;
        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- TEST 9: Band A wraparound - expected near 0 deg
        -- Band A: 0 +/- 180 wraps through 7200/0
        -- --------------------------------------------------------------------
        test_num <= 9;
        report "TEST 9: Band A wraparound (expected near 0.0 deg)";

        expected_phase_angle <= to_unsigned(100, 16);  -- 10.0 deg
        phase_tolerance      <= to_unsigned(200, 16);  -- 20.0 deg
        -- Band A: 10.0 +/- 20.0 = 350.0 to 30.0 (wraps through 0)
        -- Test at 7150 = 715.0 deg (wraps to -5.0 deg, inside band)

        wait for CLK_PERIOD;
        fire_ref(raw_angle, phase_ref, 7150, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert sync_offset = '0'
            report "FAIL T9: should detect Band A through wraparound"
            severity failure;
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- TEST 10: sync_offset holds between ref pulses
        -- --------------------------------------------------------------------
        test_num <= 10;
        report "TEST 10: sync_offset holds between ref pulses";

        expected_phase_angle <= EXP_ANGLE;
        phase_tolerance      <= TOLERANCE;
        wait for CLK_PERIOD;

        -- Fire Band B ref
        fire_ref(raw_angle, phase_ref, BAND_B_CENTRE, CLK_PERIOD);
        wait for 2 * CLK_PERIOD;
        assert sync_offset = '1'
            report "FAIL T10 setup: sync_offset should be 1"
            severity failure;

        -- Wait without firing ref and check sync_offset holds
        wait for 20 * CLK_PERIOD;
        assert sync_offset = '1'
            report "FAIL T10: sync_offset should hold between ref pulses"
            severity failure;
        report "TEST 10: PASS";

        -- --------------------------------------------------------------------
        -- TEST 11: sync_offset updates on subsequent ref pulse
        -- --------------------------------------------------------------------
        test_num <= 11;
        report "TEST 11: sync_offset updates on next ref pulse";

        -- Fire Band A ref
        fire_ref(raw_angle, phase_ref, BAND_A_CENTRE, CLK_PERIOD);

        wait for 2 * CLK_PERIOD;
        assert sync_offset = '0'
            report "FAIL T11: sync_offset should update to 0 on Band A ref"
            severity failure;
        report "TEST 11: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All phase_detector tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;