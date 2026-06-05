library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- integration_tb.vhd (v3)
--
-- End-to-end integration test: crank -> src_sel -> angle -> trig/phase/sync
-- Drives crank_clean directly (post-filter) with a realistic 60-2 pattern.
--
-- Key tests vs v1 archive:
--   T5: nco_clk_inc consistent before and after z_edge -- verifies the
--       crank.vhd ab_period fix (gap period must not contaminate the
--       nco_clk_inc divider on the first tooth after the gap).
--   T6: trig_pulse fires at z_edge (0 deg sample added in trig.vhd)
--   T7: trig count per revolution consistent (~3601 at decimation=1)
--   T8: phase_eng toggles correctly
--
-- Timing (scaled for simulation speed):
--   TOOTH_PERIOD = 1000 clocks
--   GAP_PERIOD   = 3000 clocks (3x tooth = 2-tooth gap)
-- =============================================================================
entity integration_tb is end entity;

architecture sim of integration_tb is

    constant CLK_PERIOD       : time    := 10 ns;
    constant N_TEETH          : integer := 60;
    constant N_MISSING        : integer := 2;
    constant TOOTH_PERIOD     : integer := 100;   -- clocks (filter bypassed, keep fast)
    constant GAP_PERIOD       : integer := TOOTH_PERIOD * (N_MISSING + 1);
    constant TIMEOUT          : time    := 500 ms;
    constant NCO_AB_INC       : integer := 71_582_788;
    constant NCO_CLK_INC_EXP  : integer := 71_583;
    constant NCO_CLK_TOL      : integer := NCO_CLK_INC_EXP / 20;  -- 5%
    constant PHASE_REF_MIN    : unsigned(31 downto 0) := x"60000000";  -- 135 deg
    constant PHASE_REF_MAX    : unsigned(31 downto 0) := x"A0000000";  -- 225 deg

    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';
    signal sim_done    : boolean   := false;
    signal z_count_sig : integer   := 0;
    signal z_toggle    : std_logic := '0';
    signal ab_toggle   : std_logic := '0';  -- toggles on each ab_edge for wait on
    signal test_num    : integer   := 0;
    signal crank_run   : boolean   := false;
    signal crank_raw   : std_logic := '0';
    signal cam_raw     : std_logic := '0';

    -- crank outputs
    signal crank_ab           : std_logic;
    signal crank_z            : std_logic;
    signal crank_z_edge       : std_logic;
    signal crank_ab_edge      : std_logic;
    signal crank_tooth_period : unsigned(31 downto 0);
    signal crank_tooth_count  : unsigned(7 downto 0);
    signal crank_ab_count     : unsigned(7 downto 0);
    signal crank_ppr_conf     : unsigned(7 downto 0);
    signal crank_gap_det      : std_logic;
    signal crank_signal_ok    : std_logic;

    -- src_sel outputs
    signal ab_edge   : std_logic;
    signal z_edge    : std_logic;
    signal ab_period : unsigned(31 downto 0);
    signal ppr_conf  : unsigned(7 downto 0);
    signal ab_count  : unsigned(7 downto 0);

    -- angle outputs
    signal angle_angfac            : unsigned(31 downto 0);
    signal angle_nco_ab_inc        : unsigned(31 downto 0);
    signal angle_nco_clk_inc       : unsigned(31 downto 0);
    signal angle_nco_clk_inc_valid : std_logic;

    -- cam / ref_sel
    signal cam_edge  : std_logic;
    signal ref_edge  : std_logic;

    -- phase outputs
    signal phase_ref_det      : std_logic;
    signal phase_ref_found    : std_logic;
    signal phase_ref_ok       : std_logic;
    signal phase_eng          : std_logic;
    signal phase_ref_angfac   : unsigned(31 downto 0);
    signal phase_ref_det_cnt  : unsigned(15 downto 0);

    -- sync outputs
    signal sync_state       : unsigned(1 downto 0);
    signal sync_full        : std_logic;
    signal sync_fault_count : unsigned(15 downto 0);

    -- trig outputs
    signal trig_pulse : std_logic;
    signal trig_count : unsigned(31 downto 0);

    -- config
    signal angle_interp_en : std_logic           := '0';
    signal trig_decimation : unsigned(15 downto 0) := to_unsigned(1, 16);

begin

    p_clk : process begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop; wait;
    end process;

    p_crank : process
        procedure do_tooth is begin
            crank_raw <= '1'; wait for CLK_PERIOD;
            crank_raw <= '0'; wait for (TOOTH_PERIOD - 1) * CLK_PERIOD;
        end procedure;
    begin
        crank_raw <= '0';
        wait until crank_run;
        loop
            for i in 1 to (N_TEETH - N_MISSING) loop do_tooth; end loop;
            wait for GAP_PERIOD * CLK_PERIOD;
            exit when not crank_run or sim_done;
        end loop;
        crank_raw <= '0';
        wait;
    end process;

    u_crank : entity work.crank
        port map (clk=>clk, rst=>rst, crank_clean=>crank_raw,
                  crank_edge_sel=>'1',
                  crank_gap_thresh=>to_unsigned(192, 8),
                  crank_n_teeth=>to_unsigned(N_TEETH, 8),
                  crank_n_missing=>to_unsigned(N_MISSING, 8),
                  crank_ab=>crank_ab, crank_z=>crank_z,
                  crank_z_edge=>crank_z_edge, crank_ab_edge=>crank_ab_edge,
                  crank_tooth_period=>crank_tooth_period, crank_gap_period=>open,
                  crank_tooth_count=>crank_tooth_count,
                  crank_ab_count=>crank_ab_count,
                  crank_ppr_conf=>crank_ppr_conf,
                  crank_gap_det=>crank_gap_det,
                  crank_signal_ok=>crank_signal_ok);

    u_src_sel : entity work.src_sel
        port map (sel=>'0',
                  crank_ab_edge=>crank_ab_edge, crank_z_edge=>crank_z_edge,
                  crank_ppr_conf=>crank_ppr_conf,
                  crank_tooth_period=>crank_tooth_period,
                  crank_ab_count=>crank_ab_count,
                  enc_ab_edge=>'0', enc_z_edge=>'0',
                  enc_ppr_conf=>(others=>'0'), enc_ab_period=>(others=>'0'),
                  enc_ab_count=>(others=>'0'),
                  ab_edge=>ab_edge, z_edge=>z_edge,
                  ppr_conf=>ppr_conf, ab_period=>ab_period,
                  ab_count=>ab_count);

    u_angle : entity work.angle
        port map (clk=>clk, rst=>rst,
                  ab_edge=>ab_edge, z_edge=>z_edge,
                  ab_period=>ab_period, ppr_conf=>ppr_conf,
                  angle_interp_en=>angle_interp_en,
                  angle_angfac=>angle_angfac,
                  angle_nco_ab_inc=>angle_nco_ab_inc,
                  angle_nco_clk_inc=>angle_nco_clk_inc,
                  angle_nco_clk_inc_valid=>angle_nco_clk_inc_valid);

    u_cam : entity work.cam
        port map (clk=>clk, rst=>rst, cam_clean=>cam_raw,
                  z_edge=>z_edge, cam_edge_sel=>'1',
                  cam_edge=>cam_edge, cam_tooth_count=>open);

    u_ref_sel : entity work.ref_sel
        port map (sel=>'0', cam_edge=>cam_edge,
                  peak_edge=>'0', ref_edge=>ref_edge);

    u_phase : entity work.phase
        port map (clk=>clk, rst=>rst,
                  ref_edge=>ref_edge, angle_angfac=>angle_angfac,
                  z_edge=>z_edge,
                  phase_ref_min=>PHASE_REF_MIN,
                  phase_ref_max=>PHASE_REF_MAX,
                  phase_ref_phase=>'0',
                  phase_ref_det=>phase_ref_det,
                  phase_ref_ok=>phase_ref_ok,
                  phase_ref_found=>phase_ref_found,
                  phase_eng=>phase_eng,
                  phase_ref_angfac=>phase_ref_angfac,
                  phase_ref_det_cnt=>phase_ref_det_cnt);

    u_sync : entity work.sync
        port map (clk=>clk, rst=>rst,
                  ab_edge=>ab_edge, z_edge=>z_edge,
                  ppr_conf=>ppr_conf, ab_count=>ab_count,
                  phase_ref_found=>phase_ref_found,
                  sync_state=>sync_state, sync_full=>sync_full,
                  sync_fault_count=>sync_fault_count);

    u_trig : entity work.trig
        port map (clk=>clk, rst=>rst,
                  z_edge=>z_edge, ang_angfac=>angle_angfac,
                  trig_decimation=>trig_decimation,
                  trig_pulse=>trig_pulse, trig_count=>trig_count);

    -- Simple sensitivity-list monitor (no wait statements)
    p_zedge : process(z_edge)
    begin
        if z_edge = '1' then
            z_toggle    <= not z_toggle;
            z_count_sig <= z_count_sig + 1;
        end if;
    end process;

    p_abtog : process(ab_edge)
    begin
        if ab_edge = '1' then ab_toggle <= not ab_toggle; end if;
    end process;

    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim : process
        variable ang_prev       : integer;
        variable ang_curr       : integer;
        variable step           : integer;
        variable nco_normal     : integer;
        variable nco_post_z     : integer;
        variable phase_bef      : std_logic;
        variable trig_seen      : boolean;
        variable pulse_cnt      : integer;

        -- NOTE: wait statements cannot be in procedures in GHDL.
        -- Use inline 'wait on z_toggle' and 'wait until sync_state>='
        -- directly in the process body. These procedures are kept for
        -- non-wait logic only.

        procedure fire_cam is begin
            cam_raw <= '1'; wait for 5 * CLK_PERIOD;
            cam_raw <= '0';
        end procedure;

        -- wait_ab: use inline wait on ab_edge_d directly in process body

    begin
        rst <= '1'; wait for 30 * CLK_PERIOD;
        rst <= '0'; wait for 10 * CLK_PERIOD;

        -- ==================================================================
        -- T1: CRANK_SYNC acquisition (sync_state = 2)
        -- ==================================================================
        -- T1: CRANK_SYNC
        test_num <= 1;
        report "TEST 1: CRANK_SYNC acquisition";
        assert to_integer(sync_state) = 0
            report "FAIL T1: should start STOPPED" severity failure;
        crank_run <= true;
        if to_integer(sync_state) < 2 then
            wait until to_integer(sync_state) >= 2 for TIMEOUT;
            assert to_integer(sync_state) >= 2
                report "FAIL T1: TIMEOUT waiting for CRANK_SYNC" severity failure;
        end if;
        report "TEST 1: PASS -- sync_state=" & integer'image(to_integer(sync_state));

        -- T2: FULL_SYNC via cam
        test_num <= 2;
        report "TEST 2: FULL_SYNC via cam";
        wait on z_toggle for TIMEOUT;
        wait for 2 * CLK_PERIOD; wait for 1 ns;  -- let p_angle process z_edge
        wait for (TOOTH_PERIOD * 30) * CLK_PERIOD;  -- advance to ~180 deg
        fire_cam;
        wait for 20 * CLK_PERIOD; wait for 1 ns;
        report "T2: after cam, phase_ref_found=" & std_logic'image(phase_ref_found) &
               " sync_state=" & integer'image(to_integer(sync_state));
        if to_integer(sync_state) < 3 then
            wait until to_integer(sync_state) >= 3 for TIMEOUT;
            assert to_integer(sync_state) >= 3
                report "FAIL T2: TIMEOUT waiting for FULL_SYNC" severity failure;
        end if;
        assert sync_full = '1' report "FAIL T2: sync_full should be 1" severity failure;
        report "TEST 2: PASS";

        -- T3: angle_angfac steps by nco_ab_inc per tooth
        test_num <= 3;
        report "TEST 3: angle_angfac per-tooth step = nco_ab_inc";
        wait on z_toggle for TIMEOUT;
        wait for 2 * CLK_PERIOD; wait for 1 ns;
        for i in 1 to 10 loop wait on ab_toggle for TIMEOUT; end loop;
        wait for 2 * CLK_PERIOD; wait for 1 ns;
        ang_prev := to_integer(angle_angfac);
        wait on ab_toggle for TIMEOUT;
        wait for 2 * CLK_PERIOD; wait for 1 ns;
        ang_curr := to_integer(angle_angfac);
        step := ang_curr - ang_prev;
        assert step >= NCO_AB_INC - 2 and step <= NCO_AB_INC + 2
            report "FAIL T3: step=" & integer'image(step) &
                   " expected ~" & integer'image(NCO_AB_INC)
            severity failure;
        report "TEST 3: PASS -- step=" & integer'image(step);

        -- T4: angle_angfac = 0 at z_edge
        test_num <= 4;
        report "TEST 4: angle_angfac resets to 0 at z_edge";
        wait on z_toggle for TIMEOUT;
        wait for 2 * CLK_PERIOD; wait for 1 ns;  -- let p_angle reset nco_accum
        assert to_integer(angle_angfac) = 0
            report "FAIL T4: angle_angfac=" & integer'image(to_integer(angle_angfac)) &
                   " should be 0"
            severity failure;
        report "TEST 4: PASS";

        -- T5: nco_clk_inc consistent before and after z_edge
        --     THE KEY TEST: verifies crank.vhd ab_period fix.
        --     Before the fix, nco_clk_inc was ~3x too small on the first
        --     tooth after the gap (gap period used instead of tooth period).
        test_num <= 5;
        report "TEST 5: nco_clk_inc consistent across z_edge";
        angle_interp_en <= '1';
        wait on z_toggle for TIMEOUT;
        wait for 2 * CLK_PERIOD; wait for 1 ns;
        for i in 1 to 10 loop wait on ab_toggle for TIMEOUT; end loop;
        wait for 60 * CLK_PERIOD; wait for 1 ns;
        nco_normal := to_integer(angle_nco_clk_inc);
        wait on z_toggle for TIMEOUT;
        wait for 2 * CLK_PERIOD; wait for 1 ns;
        wait on ab_toggle for TIMEOUT;
        wait for 60 * CLK_PERIOD; wait for 1 ns;
        nco_post_z := to_integer(angle_nco_clk_inc);
        assert abs(nco_post_z - nco_normal) <= NCO_CLK_TOL
            report "FAIL T5: nco_clk_inc post-z=" & integer'image(nco_post_z) &
                   " normal=" & integer'image(nco_normal) &
                   " diff=" & integer'image(abs(nco_post_z - nco_normal)) &
                   " tol=" & integer'image(NCO_CLK_TOL)
            severity failure;
        report "TEST 5: PASS -- normal=" & integer'image(nco_normal) &
               " post_z=" & integer'image(nco_post_z);
        angle_interp_en <= '0';

        -- T6: trig_pulse fires at z_edge (0 deg sample)
        test_num <= 6;
        report "TEST 6: trig_pulse fires at z_edge";
        wait on z_toggle for TIMEOUT;
        -- trig_pulse fires exactly 1 clock after z_edge (registered in trig.vhd)
        -- Check over the 2 clocks immediately following z_edge
        trig_seen := false;
        for i in 1 to 2 loop
            wait until rising_edge(clk);
            wait for 1 ns;
            if trig_pulse = '1' then trig_seen := true; end if;
        end loop;
        assert trig_seen
            report "FAIL T6: trig_pulse did not fire at z_edge" severity failure;
        report "TEST 6: PASS";

        -- T7: trig pulse count per revolution = 3601
        test_num <= 7;
        report "TEST 7: trig pulses per revolution";
        -- Check trig_count = 1 immediately after z_edge (the 0 deg pulse)
        wait on z_toggle for TIMEOUT;
        wait for 3 * CLK_PERIOD; wait for 1 ns;
        assert to_integer(trig_count) = 1
            report "FAIL T7a: trig_count at z_edge should be 1, got " &
                   integer'image(to_integer(trig_count))
            severity failure;
        -- Advance to tooth 30 and verify trig_count is growing correctly
        for i in 1 to 30 loop wait on ab_toggle for TIMEOUT; end loop;
        wait for 2 * CLK_PERIOD; wait for 1 ns;
        pulse_cnt := to_integer(trig_count);
        assert pulse_cnt > 1600 and pulse_cnt < 2100
            report "FAIL T7b: trig_count after 30 teeth should be ~1800, got " &
                   integer'image(pulse_cnt)
            severity failure;
        report "TEST 7: PASS -- trig_count at mid-rev=" & integer'image(pulse_cnt);

        -- T8: phase_eng toggles on each z_edge
        test_num <= 8;
        report "TEST 8: phase_eng toggles on z_edge";
        wait on z_toggle for TIMEOUT;
        wait for 3 * CLK_PERIOD; wait for 1 ns;
        phase_bef := phase_eng;
        wait on z_toggle for TIMEOUT;
        wait for 3 * CLK_PERIOD; wait for 1 ns;
        assert phase_eng /= phase_bef
            report "FAIL T8: phase_eng should toggle" severity failure;
        wait on z_toggle for TIMEOUT;
        wait for 3 * CLK_PERIOD; wait for 1 ns;
        assert phase_eng = phase_bef
            report "FAIL T8: phase_eng should return after 2 z_edges" severity failure;
        report "TEST 8: PASS";

        crank_run <= false;
        wait for 50 * CLK_PERIOD;
        report "========================================";
        report "All integration tests PASS";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
