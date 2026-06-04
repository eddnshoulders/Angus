library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- phase_tb.vhd  (v3)
--
-- Unit testbench for phase.vhd.
-- Detection window: WIN_MIN to WIN_MAX (in angfac units).
-- phase_ref_phase = '0' means the ref edge is expected on phase 0.
--
-- Expected cam fire position: WIN_CENTRE = (WIN_MIN + WIN_MAX) / 2
-- =============================================================================

entity phase_tb is
end entity phase_tb;

architecture sim of phase_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD  : time     := 10 ns;
    constant WIN_MIN_C   : unsigned(31 downto 0) := x"10000000";
    constant WIN_MAX_C   : unsigned(31 downto 0) := x"20000000";
    constant WIN_CENTRE_C: unsigned(31 downto 0) := x"18000000";
    constant OUTSIDE_C   : unsigned(31 downto 0) := x"30000000";

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal ref_edge     : std_logic := '0';
    signal angle_angfac : unsigned(31 downto 0) := (others => '0');
    signal z_edge       : std_logic := '0';
    signal ref_min      : unsigned(31 downto 0) := WIN_MIN_C;
    signal ref_max      : unsigned(31 downto 0) := WIN_MAX_C;
    signal ref_phase    : std_logic := '0';
    signal ph_ref_det   : std_logic;
    signal ph_ref_ok    : std_logic;
    signal ph_ref_found : std_logic;
    signal ph_eng       : std_logic;
    signal ph_angfac    : unsigned(31 downto 0);
    signal ph_det_cnt   : unsigned(15 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock ref_edge at the given angle_angfac value
    -- -------------------------------------------------------------------------
    procedure fire_ref(
        signal   ang  : out unsigned(31 downto 0);
        signal   ref  : out std_logic;
        signal   c    : in  std_logic;
        constant val  : in  unsigned(31 downto 0)
    ) is
    begin
        ang <= val;
        wait until rising_edge(c); wait for 1 ns;
        ref <= '1';
        wait until rising_edge(c); wait for 1 ns;
        ref <= '0';
        wait until rising_edge(c); wait for 1 ns;
    end procedure fire_ref;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock z_edge strobe
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   z : out std_logic;
        signal   c : in  std_logic
    ) is
    begin
        z <= '1'; wait until rising_edge(c); wait for 1 ns;
        z <= '0'; wait until rising_edge(c); wait for 1 ns;
    end procedure fire_z;

begin

    -- -------------------------------------------------------------------------
    -- Clock generation
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
    -- DUT instantiation
    -- -------------------------------------------------------------------------
    dut : entity work.phase
        port map (
            clk              => clk,
            rst              => rst,
            ref_edge         => ref_edge,
            angle_angfac     => angle_angfac,
            z_edge           => z_edge,
            phase_ref_min    => ref_min,
            phase_ref_max    => ref_max,
            phase_ref_phase  => ref_phase,
            phase_ref_det    => ph_ref_det,
            phase_ref_ok     => ph_ref_ok,
            phase_ref_found  => ph_ref_found,
            phase_eng        => ph_eng,
            phase_ref_angfac => ph_angfac,
            phase_ref_det_cnt => ph_det_cnt
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour -- all outputs zero
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert ph_ref_found = '0'
            report "FAIL T1: phase_ref_found should be 0 after reset"
            severity failure;
        assert ph_ref_ok = '0'
            report "FAIL T1: phase_ref_ok should be 0 after reset"
            severity failure;
        assert ph_eng = '0'
            report "FAIL T1: phase_eng should be 0 after reset"
            severity failure;
        assert ph_ref_det = '0'
            report "FAIL T1: phase_ref_det should be 0 after reset"
            severity failure;

        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: First ref_edge in window latches phase_ref_found
        --         and sets phase_eng to phase_ref_phase
        -- --------------------------------------------------------------------
        report "TEST 2: First detection in window latches phase_ref_found";
        test_num <= 2;

        -- Check phase_ref_det while ref_edge is still asserted --
        -- it is a 1-clock strobe cleared on the following clock.
        ref_phase <= '0';
        angle_angfac <= WIN_CENTRE_C;
        wait until rising_edge(clk); wait for 1 ns;
        ref_edge <= '1';
        wait until rising_edge(clk); wait for 1 ns;  -- detection fires this clock

        assert ph_ref_det = '1'
            report "FAIL T2: phase_ref_det not set on detection"
            severity failure;
        assert ph_ref_found = '1'
            report "FAIL T2: phase_ref_found not latched"
            severity failure;
        assert ph_eng = '0'
            report "FAIL T2: phase_eng should match phase_ref_phase (0)"
            severity failure;
        assert ph_ref_ok = '1'
            report "FAIL T2: phase_ref_ok should be 1 after detection"
            severity failure;

        -- Clear ref_edge; phase_ref_det should go low on next clock
        ref_edge <= '0';
        wait until rising_edge(clk); wait for 1 ns;
        assert ph_ref_det = '0'
            report "FAIL T2: phase_ref_det should be a 1-clock strobe"
            severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: z_edge toggles phase_eng each crank revolution
        --         (once phase_ref_found = 1)
        -- --------------------------------------------------------------------
        report "TEST 3: z_edge toggles phase_eng each revolution";
        test_num <= 3;

        assert ph_eng = '0' report "FAIL T3 setup: phase_eng should be 0" severity failure;

        fire_z(z_edge, clk);
        assert ph_eng = '1'
            report "FAIL T3: phase_eng should toggle to 1 on first z_edge"
            severity failure;

        fire_z(z_edge, clk);
        assert ph_eng = '0'
            report "FAIL T3: phase_eng should toggle to 0 on second z_edge"
            severity failure;

        fire_z(z_edge, clk);
        assert ph_eng = '1'
            report "FAIL T3: phase_eng should toggle to 1 on third z_edge"
            severity failure;

        -- Return to phase 0 for subsequent tests
        fire_z(z_edge, clk);
        assert ph_eng = '0' report "FAIL T3: restore" severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: ref_edge outside window -- no detection
        -- --------------------------------------------------------------------
        report "TEST 4: ref_edge outside window causes no detection";
        test_num <= 4;

        fire_ref(angle_angfac, ref_edge, clk, OUTSIDE_C);

        assert ph_ref_det = '0'
            report "FAIL T4: phase_ref_det should not fire outside window"
            severity failure;

        -- phase_ref_found stays latched from T2
        assert ph_ref_found = '1'
            report "FAIL T4: phase_ref_found should remain latched"
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: phase_ref_phase = '1' -- first detection sets phase_eng = 1
        -- Reset to get clean state for this test.
        -- --------------------------------------------------------------------
        report "TEST 5: phase_ref_phase = 1 sets phase_eng = 1 on first detection";
        test_num <= 5;

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        wait for 3 * CLK_PERIOD;

        ref_phase <= '1';
        fire_ref(angle_angfac, ref_edge, clk, WIN_CENTRE_C);

        assert ph_ref_found = '1'
            report "FAIL T5: phase_ref_found not set" severity failure;
        assert ph_eng = '1'
            report "FAIL T5: phase_eng should be 1 when phase_ref_phase=1"
            severity failure;

        -- z_edge should toggle to 0
        fire_z(z_edge, clk);
        assert ph_eng = '0'
            report "FAIL T5: phase_eng should toggle to 0 after z_edge"
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: phase_ref_angfac latches angle_angfac at each detection
        -- --------------------------------------------------------------------
        report "TEST 6: phase_ref_angfac latches angle_angfac at detection";
        test_num <= 6;

        -- Already have phase_ref_found=1 from T5 (phase_eng=0 now)
        -- Fire in window at a specific angle
        fire_ref(angle_angfac, ref_edge, clk, WIN_MIN_C + 1);

        assert ph_angfac = WIN_MIN_C + 1
            report "FAIL T6: phase_ref_angfac wrong after detection at WIN_MIN+1: " &
                   integer'image(to_integer(ph_angfac))
            severity failure;

        -- Fire again at a different angle -- latch should update
        fire_ref(angle_angfac, ref_edge, clk, WIN_MAX_C - 1);
        assert ph_angfac = WIN_MAX_C - 1
            report "FAIL T6: phase_ref_angfac should update on each detection"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: phase_ref_ok clears after 3 consecutive z_edges
        --         without a detection incrementing det_cnt
        --         (simulates lost cam signal)
        -- --------------------------------------------------------------------
        report "TEST 7: phase_ref_ok clears after 3 missed z_edges";
        test_num <= 7;

        assert ph_ref_ok = '1'
            report "FAIL T7 setup: phase_ref_ok should be 1"
            severity failure;

        -- Fire one sync z_edge first to align det_cnt_prev with det_cnt_int
        -- (det_cnt may have advanced during T6 detections without an intervening
        -- z_edge, so the first z_edge here will sync rather than count as a miss).
        fire_z(z_edge, clk);
        assert ph_ref_ok = '1'
            report "FAIL T7 setup: phase_ref_ok should still be 1 after sync z_edge"
            severity failure;

        -- Now fire 3 z_edges without any detection: each is a miss.
        -- 3rd miss clears phase_ref_ok.
        fire_z(z_edge, clk);
        assert ph_ref_ok = '1'
            report "FAIL T7: phase_ref_ok should still be 1 after 1 miss"
            severity failure;

        fire_z(z_edge, clk);
        assert ph_ref_ok = '1'
            report "FAIL T7: phase_ref_ok should still be 1 after 2 misses"
            severity failure;

        fire_z(z_edge, clk);
        assert ph_ref_ok = '0'
            report "FAIL T7: phase_ref_ok should clear after 3 consecutive misses"
            severity failure;

        report "TEST 7: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 8: phase_ref_ok recovers on next detection
        -- --------------------------------------------------------------------
        report "TEST 8: phase_ref_ok recovers on detection after miss";
        test_num <= 8;

        assert ph_ref_ok = '0'
            report "FAIL T8 setup: phase_ref_ok should be 0 from T7"
            severity failure;

        fire_ref(angle_angfac, ref_edge, clk, WIN_CENTRE_C);

        assert ph_ref_ok = '1'
            report "FAIL T8: phase_ref_ok should recover on detection"
            severity failure;

        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All phase tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(ph_ref_det, ph_ref_found, ph_eng)
    begin
        if ph_ref_det = '1' then
            report "REF_DET: angfac=" & integer'image(to_integer(angle_angfac)) &
                   " found=" & std_logic'image(ph_ref_found) &
                   " eng=" & std_logic'image(ph_eng) &
                   " ok=" & std_logic'image(ph_ref_ok) &
                   " cnt=" & integer'image(to_integer(ph_det_cnt)) &
                   " test=" & integer'image(test_num);
        end if;
        if ph_eng'event then
            report "PHASE_ENG -> " & std_logic'image(ph_eng) &
                   "  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
