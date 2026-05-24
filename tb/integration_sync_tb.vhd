library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- integration_sync_tb
--
-- Integration testbench for the signal conditioning and sync acquisition chain:
--   crank_raw → signal_conditioner → crank_input → angle_engine → sync
--   cam_raw   → signal_conditioner → phase_detector
--
-- Drives realistic raw crank and cam signals and verifies:
--   - Sync acquisition (UNSYNC → FIRST_GAP → SYNC_CRANK → SYNC_FULL)
--   - Angle tracking in SYNC_CRANK and SYNC_FULL
--   - Phase detection in both bands
--   - Glitch rejection
--   - Sync loss and reacquisition
-- =============================================================================

entity integration_sync_tb is
end entity integration_sync_tb;

architecture sim of integration_sync_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD      : time    := 1000 ns;   -- 1MHz sim clock
    constant N_TEETH         : integer := 60;
    constant N_MISSING       : integer := 2;
    constant TEETH_REAL      : integer := N_TEETH - N_MISSING;
    constant DEBOUNCE_CYCLES : integer := 5;

    -- At 1MHz, 1000 RPM:
    -- Tooth period = 1ms = 1000 cycles
    constant TOOTH_1000_RPM  : time    := 1_000_000 ns;
    constant TOOTH_2000_RPM  : time    :=   500_000 ns;

    -- One complete engine cycle at 1000 RPM
    -- N_TEETH tooth periods (no gap since crank_input interpolates)
    constant CYCLE_1000      : time    := TOOTH_1000_RPM * N_TEETH;

    -- Sync state encoding
    constant ST_UNSYNC       : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP    : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRANK   : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL    : std_logic_vector(2 downto 0) := "011";

    -- Expected phase angle for cam: 90.0 degrees = 900 in 0.1 deg units
    constant EXP_PHASE_ANGLE : integer := 900;
    constant PHASE_TOLERANCE : integer := 300;  -- 30.0 degrees

    -- -------------------------------------------------------------------------
    -- Raw input signals (driven by testbench)
    -- -------------------------------------------------------------------------
    signal clk               : std_logic := '0';
    signal rst               : std_logic := '1';
    signal crank_raw         : std_logic := '1';   -- inactive high (open drain)
    signal cam_raw           : std_logic := '1';   -- inactive high

    -- -------------------------------------------------------------------------
    -- Internal chain signals (for observation in GTKWave)
    -- -------------------------------------------------------------------------
    -- signal_conditioner outputs
    signal crank_clean       : std_logic;
    signal crank_stable      : std_logic;
    signal cam_clean         : std_logic;
    signal cam_stable        : std_logic;

    -- crank_input outputs
    signal ab                : std_logic;
    signal z                 : std_logic;
    signal tooth_period      : unsigned(31 downto 0);
    signal tooth_count       : unsigned(7 downto 0);
    signal gap_detected      : std_logic;
    signal signal_present    : std_logic;

    -- angle_engine output
    signal raw_angle         : unsigned(15 downto 0);

    -- sync outputs
    signal sync_state        : std_logic_vector(2 downto 0);
    signal sync_loss_count   : unsigned(15 downto 0);
    signal phase_fault       : std_logic;
    signal phase_fault_count : unsigned(15 downto 0);

    -- phase_detector outputs
    signal ref_detected      : std_logic;
    signal sync_offset       : std_logic;

    -- -------------------------------------------------------------------------
    -- Configuration signals (driven directly, normally from axi_lite_regs)
    -- -------------------------------------------------------------------------
    signal edge_select           : std_logic          := '0';   -- falling edge
    signal gap_threshold         : unsigned(7 downto 0)  := x"C0";
    signal kp                    : unsigned(15 downto 0) := x"0100";
    signal ki                    : unsigned(15 downto 0) := x"0010";
    signal max_correction        : unsigned(15 downto 0) := x"0400";
    signal expected_phase_angle  : unsigned(15 downto 0) :=
                                   to_unsigned(EXP_PHASE_ANGLE, 16);
    signal phase_tolerance_sig   : unsigned(15 downto 0) :=
                                   to_unsigned(PHASE_TOLERANCE, 16);
    signal fault_clear           : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done          : boolean   := false;
    signal test_num          : integer   := 0;
    signal test_step         : integer   := 0;
    signal crank_run         : std_logic := '0';
    signal crank_period      : time      := TOOTH_1000_RPM;
    signal cam_run           : std_logic := '0';
    -- Cam fires at this tooth position after Z (in tooth periods)
    signal cam_tooth_offset  : integer   := 5;  -- 5 teeth = 30 deg into cycle
    signal glitch_request    : std_logic := '0';

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
    -- Crank signal generator
    -- Generates falling-edge 60-2 pattern on crank_raw
    -- Runs continuously when crank_run = '1'
    -- Inactive state is high (open drain)
    -- glitch_request injects a short pulse shorter than debounce window
    -- -------------------------------------------------------------------------
    p_crank : process
        variable t_half : time;
    begin
        loop
            if crank_run = '0' then
                crank_raw <= '1';
                wait until crank_run = '1';
            end if;

            t_half := crank_period / 2;

            -- Generate TEETH_REAL falling-edge teeth
            for i in 1 to TEETH_REAL loop
                if crank_run = '0' then
                    crank_raw <= '1';
                    exit;
                end if;

                -- Check for glitch injection between teeth
                if glitch_request = '1' then
                    crank_raw <= '0'; wait for 3 * CLK_PERIOD;
                    crank_raw <= '1'; wait for 2 * CLK_PERIOD;
                end if;

                crank_raw <= '1'; wait for t_half;
                crank_raw <= '0'; wait for t_half;
            end loop;

            -- Gap: hold inactive for N_MISSING + 1 tooth periods
            if crank_run = '1' then
                crank_raw <= '1';
                wait for crank_period * (N_MISSING + 1);
            end if;
        end loop;
    end process p_crank;

    -- -------------------------------------------------------------------------
    -- Cam signal generator
    -- Fires one pulse per engine cycle at cam_tooth_offset teeth after Z
    -- Z fires at start of each crank_input cycle
    -- -------------------------------------------------------------------------
    p_cam : process
        variable t_half    : time;
        variable cam_delay : time;
    begin
        loop
            if cam_run = '0' then
                cam_raw <= '1';
                wait until cam_run = '1';
            end if;

            t_half    := crank_period / 2;
            -- Wait until Z fires (start of cycle) then offset by cam_tooth_offset teeth
            -- Z fires at start of crank_input cycle (after gap)
            -- We sync to Z rising edge then wait cam_tooth_offset tooth periods
            wait until z = '1';
            cam_delay := crank_period * cam_tooth_offset;
            wait for cam_delay;

            -- Fire cam pulse (one tooth period wide)
            if cam_run = '1' then
                cam_raw <= '0'; wait for crank_period;
                cam_raw <= '1';
            end if;
        end loop;
    end process p_cam;

    -- =========================================================================
    -- DUT chain instantiation
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- signal_conditioner: crank
    -- -------------------------------------------------------------------------
    u_sig_cond_crank : entity work.signal_conditioner
        generic map (
            DEBOUNCE_CYCLES => DEBOUNCE_CYCLES
        )
        port map (
            clk            => clk,
            rst            => rst,
            raw_signal     => crank_raw,
            clean_signal   => crank_clean,
            signal_stable  => crank_stable
        );

    -- -------------------------------------------------------------------------
    -- signal_conditioner: cam
    -- -------------------------------------------------------------------------
    u_sig_cond_cam : entity work.signal_conditioner
        generic map (
            DEBOUNCE_CYCLES => DEBOUNCE_CYCLES
        )
        port map (
            clk            => clk,
            rst            => rst,
            raw_signal     => cam_raw,
            clean_signal   => cam_clean,
            signal_stable  => cam_stable
        );

    -- -------------------------------------------------------------------------
    -- crank_input
    -- -------------------------------------------------------------------------
    u_crank_input : entity work.crank_input
        generic map (
            CLK_FREQ_HZ => 1_000_000,
            N_TEETH     => N_TEETH,
            N_MISSING   => N_MISSING
        )
        port map (
            clk            => clk,
            rst            => rst,
            clean_signal   => crank_clean,
            signal_stable  => crank_stable,
            edge_select    => edge_select,
            gap_threshold  => gap_threshold,
            ab             => ab,
            z              => z,
            tooth_period   => tooth_period,
            tooth_count    => tooth_count,
            gap_detected   => gap_detected,
            signal_present => signal_present
        );

    -- -------------------------------------------------------------------------
    -- angle_engine
    -- -------------------------------------------------------------------------
    u_angle_engine : entity work.angle_engine
        generic map (
            CLK_FREQ_HZ => 1_000_000,
            N_TEETH     => N_TEETH
        )
        port map (
            clk            => clk,
            rst            => rst,
            ab             => ab,
            z              => z,
            tooth_period   => tooth_period,
            sync_state     => sync_state,
            kp             => kp,
            ki             => ki,
            max_correction => max_correction,
            raw_angle      => raw_angle
        );

    -- -------------------------------------------------------------------------
    -- sync
    -- -------------------------------------------------------------------------
    u_sync : entity work.sync
        generic map (
            CLK_FREQ_HZ => 1_000_000,
            N_TEETH     => N_TEETH
        )
        port map (
            clk               => clk,
            rst               => rst,
            ab                => ab,
            z                 => z,
            signal_present    => signal_present,
            ref_detected      => ref_detected,
            sync_offset       => sync_offset,
            fault_clear       => fault_clear,
            sync_state        => sync_state,
            sync_loss_count   => sync_loss_count,
            phase_fault_count => phase_fault_count,
            phase_fault       => phase_fault
        );

    -- -------------------------------------------------------------------------
    -- phase_detector
    -- -------------------------------------------------------------------------
    u_phase_detector : entity work.phase_detector
        port map (
            clk                  => clk,
            rst                  => rst,
            raw_angle            => raw_angle,
            phase_ref            => cam_clean,
            expected_phase_angle => expected_phase_angle,
            phase_tolerance      => phase_tolerance_sig,
            ref_detected         => ref_detected,
            sync_offset          => sync_offset
        );

    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim : process
        variable loss_start : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset - all outputs in known state
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst       <= '1';
        crank_run <= '0';
        cam_run   <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert sync_state = ST_UNSYNC
            report "FAIL T1: sync_state should be UNSYNC after reset"
            severity failure;
        assert signal_present = '0'
            report "FAIL T1: signal_present should be low after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: signal_present goes high when crank signal arrives
        -- --------------------------------------------------------------------
        report "TEST 2: signal_present on crank signal";
        test_num  <= 2;
        test_step <= 1;

        crank_run <= '1';
        -- Wait for at least 2 edges to establish period
        wait for TOOTH_1000_RPM * 5;

        test_step <= 2;

        assert signal_present = '1'
            report "FAIL T2: signal_present should be high with crank signal"
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Sync acquisition UNSYNC → FIRST_GAP → SYNC_CRANK
        -- Allow enough cycles for full acquisition
        -- --------------------------------------------------------------------
        report "TEST 3: Sync acquisition to SYNC_CRANK";
        test_num <= 3;
        test_step <= 1;

        -- Allow 3 full cycles for acquisition
        wait for CYCLE_1000 * 3;

        test_step <= 2;

        assert sync_state = ST_SYNC_CRANK
            report "FAIL T3: should be in SYNC_CRANK after 3 cycles, got " &
                   integer'image(to_integer(unsigned(sync_state)))
            severity failure;
        report "TEST 3: PASS - sync_state = SYNC_CRANK";

        -- --------------------------------------------------------------------
        -- TEST 4: raw_angle increments correctly in SYNC_CRANK
        -- Wait for Z then verify angle advances monotonically
        -- --------------------------------------------------------------------
        report "TEST 4: raw_angle increments in SYNC_CRANK";
        test_num <= 4;

        wait until z = '1';
        wait for 3 * CLK_PERIOD;

        -- Verify angle is near 0 after Z
        assert to_integer(raw_angle) < 200
            report "FAIL T4: raw_angle should be near 0 after Z, got " &
                   integer'image(to_integer(raw_angle))
            severity failure;

        -- Wait one tooth period and verify angle has advanced
        wait for TOOTH_1000_RPM;
        assert to_integer(raw_angle) > 0
            report "FAIL T4: raw_angle should advance after Z"
            severity failure;

        report "TEST 4: PASS - raw_angle advancing correctly";

        -- --------------------------------------------------------------------
        -- TEST 5: Cam pulse triggers SYNC_CRANK → SYNC_FULL
        -- cam_tooth_offset = 5, so cam fires at tooth 5 = 60 deg
        -- expected_phase_angle = 900 (90.0 deg)
        -- 60 deg = 600 in 0.1 deg units
        -- Within tolerance of 300 (30.0 deg): 900 - 600 = 300 = edge of band
        -- Use offset 7 teeth = 84 deg = 840 units, within tolerance of 900
        -- --------------------------------------------------------------------
        report "TEST 5: Cam pulse triggers SYNC_FULL";
        test_num        <= 5;

        -- Set cam to fire at tooth 7 = 84 deg = 840 units
        -- expected = 900, tolerance = 300: |840 - 900| = 60 < 300 ✓
        cam_tooth_offset <= 7;
        cam_run          <= '1';

        -- Wait for SYNC_FULL (allow several cycles for cam to fire)
        wait for CYCLE_1000 * 5;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T5: should be in SYNC_FULL after cam pulse, got " &
                   integer'image(to_integer(unsigned(sync_state)))
            severity failure;
        report "TEST 5: PASS - sync_state = SYNC_FULL";

        -- --------------------------------------------------------------------
        -- TEST 6: sync_offset = 0 when cam in Band A
        -- cam at tooth 7 = 84 deg ≈ 900 units, near expected 900 → Band A
        -- --------------------------------------------------------------------
        report "TEST 6: sync_offset = 0 for Band A cam";
        test_num <= 6;

        assert sync_offset = '0'
            report "FAIL T6: sync_offset should be 0 for Band A cam"
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: sync_offset = 1 when cam in Band B
        -- Band B centre = (900 + 3600) mod 7200 = 4500 (450.0 deg)
        -- 450 deg / 12 deg per tooth = 37.5 teeth into cycle
        -- Set cam_tooth_offset = 38 teeth
        -- --------------------------------------------------------------------
        report "TEST 7: sync_offset = 1 for Band B cam";
        test_num <= 7;

        -- Reset to get clean state
        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        cam_run <= '0';
        wait for 5 * CLK_PERIOD;

        -- Reacquire SYNC_CRANK
        wait for CYCLE_1000 * 3;

        assert sync_state = ST_SYNC_CRANK
            report "FAIL T7 setup: should be in SYNC_CRANK"
            severity failure;

        -- Fire cam at Band B position
        cam_tooth_offset <= 38;
        cam_run          <= '1';

        wait for CYCLE_1000 * 5;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T7: should reach SYNC_FULL with Band B cam"
            severity failure;
        assert sync_offset = '1'
            report "FAIL T7: sync_offset should be 1 for Band B cam"
            severity failure;
        report "TEST 7: PASS - sync_offset = 1 for Band B";

        -- --------------------------------------------------------------------
        -- TEST 8: Glitch on crank doesn't disrupt sync
        -- --------------------------------------------------------------------
        report "TEST 8: Glitch rejection in sync";
        test_num <= 8;

        -- Already in SYNC_FULL, inject a short glitch on crank_raw
        -- Glitch shorter than DEBOUNCE_CYCLES (5 cycles = 5us at 1MHz)
        glitch_request <= '1';
        wait for 5 * CLK_PERIOD; 
        glitch_request <= '0';

        -- Sync should still be SYNC_FULL
        assert sync_state = ST_SYNC_FULL
            report "FAIL T8: glitch should not disrupt SYNC_FULL"
            severity failure;
        report "TEST 8: PASS - glitch rejected, still SYNC_FULL";

        -- --------------------------------------------------------------------
        -- TEST 9: Sync loss on signal removal
        -- --------------------------------------------------------------------
        report "TEST 9: Sync loss on signal removal";
        test_num <= 9;

        crank_run <= '0';
        cam_run   <= '0';

        -- Wait for signal_present timeout
        -- Timeout = N_MISSING + 2 tooth periods = 4ms at 1000 RPM
        wait for TOOTH_1000_RPM * 10;

        assert sync_state = ST_UNSYNC
            report "FAIL T9: should be UNSYNC after signal loss"
            severity failure;
        assert signal_present = '0'
            report "FAIL T9: signal_present should be low after timeout"
            severity failure;
        report "TEST 9: PASS - sync loss detected correctly";

        -- --------------------------------------------------------------------
        -- TEST 10: Reacquisition after sync loss
        -- --------------------------------------------------------------------
        report "TEST 10: Reacquisition after sync loss";
        test_num <= 10;

        loss_start := to_integer(sync_loss_count);

        -- Restart crank and cam
        cam_tooth_offset <= 7;
        crank_run        <= '1';

        -- Wait for SYNC_CRANK
        wait for CYCLE_1000 * 4;

        assert sync_state = ST_SYNC_CRANK
            report "FAIL T10: should reach SYNC_CRANK after reacquisition"
            severity failure;

        -- Start cam for SYNC_FULL
        cam_run <= '1';
        wait for CYCLE_1000 * 5;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T10: should reach SYNC_FULL after reacquisition"
            severity failure;

        report "TEST 10: PASS - full reacquisition successful";
        report "  sync_loss_count = " &
               integer'image(to_integer(sync_loss_count));

        -- --------------------------------------------------------------------
        -- TEST 11: RPM change doesn't break sync
        -- --------------------------------------------------------------------
        report "TEST 11: RPM change 1000 to 2000 RPM";
        test_num <= 11;

        crank_period <= TOOTH_2000_RPM;

        -- Allow PLL to relock
        wait for CYCLE_1000 * 3;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T11: should stay in SYNC_FULL through RPM change"
            severity failure;

        report "TEST 11: PASS - sync maintained through RPM change";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        crank_run <= '0';
        cam_run   <= '0';
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "All integration_tb1 tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;