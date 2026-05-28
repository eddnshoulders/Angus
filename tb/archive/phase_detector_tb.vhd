library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity phase_detector_tb is
end entity phase_detector_tb;

architecture sim of phase_detector_tb is

    constant CLK_PERIOD : time := 10 ns;

    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';
    signal sim_done         : boolean   := false;
    signal test_num         : integer   := 0;

    signal angle_raw        : unsigned(15 downto 0) := (others => '0');
    signal phase            : std_logic := '0';
    signal ref_pulse        : std_logic := '0';
    signal expected_cam_ang : unsigned(15 downto 0) := to_unsigned(900, 16);
    signal window_tolerance : unsigned(15 downto 0) := to_unsigned(300, 16);
    signal tdc_offset       : unsigned(15 downto 0) := (others => '0');

    signal ref_detected     : std_logic;
    signal phase_offset     : std_logic;
    signal angle_corr       : unsigned(15 downto 0);
    signal ref_edge_pulse   : std_logic;
    signal ref_angle        : unsigned(15 downto 0);

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.phase_detector
        port map (
            clk              => clk,
            rst              => rst,
            angle_raw        => angle_raw,
            phase            => phase,
            ref_pulse        => ref_pulse,
            expected_cam_ang => expected_cam_ang,
            window_tolerance => window_tolerance,
            tdc_offset       => tdc_offset,
            ref_detected     => ref_detected,
            phase_offset     => phase_offset,
            angle_corr       => angle_corr,
            ref_edge_pulse   => ref_edge_pulse,
            ref_angle        => ref_angle
        );

    p_stim : process

        -- Fire ref_pulse and wait for ref_detected or ref_edge_pulse to pulse
        -- Returns true if ref_detected pulsed, false if only ref_edge_pulse
        procedure fire_ref(angle : integer; expect_detect : boolean) is
        begin
            angle_raw <= to_unsigned(angle, 16);
            wait for 3 * CLK_PERIOD;  -- input pipeline settle
            ref_pulse <= '1';
            -- Wait for ref_edge_pulse (fires the cycle after ref_pulse rises)
            wait until rising_edge(clk) and ref_edge_pulse = '1';
            -- ref_detected pulses on same clock edge as ref_edge_pulse
            if expect_detect then
                assert ref_detected = '1'
                    report "fire_ref(" & integer'image(angle) &
                           "): ref_detected should be 1"
                    severity failure;
            else
                assert ref_detected = '0'
                    report "fire_ref(" & integer'image(angle) &
                           "): ref_detected should be 0"
                    severity failure;
            end if;
            wait for CLK_PERIOD;
            ref_pulse <= '0';
            wait for 3 * CLK_PERIOD;
        end procedure;

    begin

        -- T1: Reset
        test_num <= 1;
        report "TEST 1: Reset behaviour";
        rst <= '1'; wait for 20 * CLK_PERIOD; rst <= '0';
        wait for 10 * CLK_PERIOD;
        assert ref_detected = '0' report "FAIL T1: ref_detected" severity failure;
        assert phase_offset = '0'  report "FAIL T1: phase_offset" severity failure;
        report "TEST 1: PASS";

        -- T2: Band A centre
        test_num <= 2;
        report "TEST 2: Band A detection at centre (900)";
        fire_ref(900, true);
        assert phase_offset = '0'
            report "FAIL T2: phase_offset should be 0 (Band A)" severity failure;
        assert to_integer(ref_angle) = 900
            report "FAIL T2: ref_angle should be 900, got " &
                   integer'image(to_integer(ref_angle)) severity failure;
        report "TEST 2: PASS";

        -- T3: Band A tolerance edge
        test_num <= 3;
        report "TEST 3: Band A at tolerance boundary (+300)";
        fire_ref(900 + 300, true);
        assert phase_offset = '0' report "FAIL T3: phase_offset" severity failure;
        report "TEST 3: PASS";

        -- T4: Just outside tolerance
        test_num <= 4;
        report "TEST 4: Outside both bands (900+301)";
        fire_ref(900 + 301, false);
        report "TEST 4: PASS";

        -- T5: Band B detection
        test_num <= 5;
        report "TEST 5: Band B detection (4500)";
        fire_ref(4500, true);
        assert phase_offset = '1'
            report "FAIL T5: phase_offset should be 1 (Band B)" severity failure;
        report "TEST 5: PASS";

        -- T6: angle_corr phase_offset=0, tdc=0
        test_num <= 6;
        report "TEST 6: angle_corr phase_offset=0 tdc=0";
        tdc_offset <= to_unsigned(0, 16);
        fire_ref(900, true);  -- sets phase_offset=0
        angle_raw <= to_unsigned(1200, 16);
        wait for 3 * CLK_PERIOD;
        assert to_integer(angle_corr) = 1200
            report "FAIL T6: angle_corr should be 1200, got " &
                   integer'image(to_integer(angle_corr)) severity failure;
        report "TEST 6: PASS";

        -- T7: angle_corr with tdc_offset
        test_num <= 7;
        report "TEST 7: angle_corr with tdc_offset=600";
        tdc_offset <= to_unsigned(600, 16);
        wait for 3 * CLK_PERIOD;
        angle_raw <= to_unsigned(1000, 16);
        wait for 3 * CLK_PERIOD;
        assert to_integer(angle_corr) = 1600
            report "FAIL T7: angle_corr should be 1600, got " &
                   integer'image(to_integer(angle_corr)) severity failure;
        report "TEST 7: PASS";

        -- T8: angle_corr phase_offset=1
        test_num <= 8;
        report "TEST 8: angle_corr phase_offset=1";
        tdc_offset <= to_unsigned(0, 16);
        fire_ref(4500, true);
        angle_raw <= to_unsigned(1000, 16);
        wait for 3 * CLK_PERIOD;
        assert to_integer(angle_corr) = 4600
            report "FAIL T8: angle_corr should be 4600, got " &
                   integer'image(to_integer(angle_corr)) severity failure;
        report "TEST 8: PASS";

        -- T9: angle_corr wraparound mod 7200
        test_num <= 9;
        report "TEST 9: angle_corr wraparound";
        fire_ref(4500, true);
        angle_raw <= to_unsigned(5000, 16);
        wait for 3 * CLK_PERIOD;
        assert to_integer(angle_corr) = 1400
            report "FAIL T9: angle_corr should be 1400, got " &
                   integer'image(to_integer(angle_corr)) severity failure;
        report "TEST 9: PASS";

        -- T10: Band A wraparound near 0 deg
        test_num <= 10;
        report "TEST 10: Band A wraparound near 0 deg";
        expected_cam_ang <= to_unsigned(100, 16);
        window_tolerance <= to_unsigned(200, 16);
        wait for 5 * CLK_PERIOD;
        fire_ref(7150, true);  -- dist = 150 < 200
        assert phase_offset = '0' report "FAIL T10: phase_offset" severity failure;
        report "TEST 10: PASS";

        -- T11: Band B wraparound
        test_num <= 11;
        report "TEST 11: Band B detection (100+3600=3700)";
        fire_ref(3700, true);
        assert phase_offset = '1' report "FAIL T11: phase_offset should be 1" severity failure;
        report "TEST 11: PASS";

        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All phase_detector tests complete";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
