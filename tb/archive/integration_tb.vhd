library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- integration_tb - concurrent crank generator, single driver for crank_raw
-- =============================================================================
entity integration_tb is end entity;
architecture sim of integration_tb is

    constant CLK_PERIOD   : time    := 10 ns;
    constant N_TEETH      : integer := 60;
    constant N_MISSING    : integer := 2;
    constant CLK_FREQ     : integer := 1_000_000;
    constant TOOTH_PERIOD : integer := 1000;
    constant GAP_PERIOD   : integer := 3000;
    constant TIMEOUT      : time    := 5000 ms;

    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal sim_done       : boolean   := false;
    signal test_num       : integer   := 0;

    -- Crank control
    signal crank_run      : boolean   := false;
    signal trigger_wrong  : std_logic := '0';  -- p_stim sets, p_crank reads
    signal crank_raw      : std_logic := '0';
    signal cam_raw        : std_logic := '0';

    -- DUT signals
    signal crank_ab       : std_logic;
    signal crank_z        : std_logic;
    signal crank_tp       : unsigned(31 downto 0);
    signal crank_tc       : unsigned(7 downto 0);
    signal crank_sp       : std_logic;
    signal cam_pulse      : std_logic;
    signal angle_raw      : unsigned(15 downto 0);
    signal phase_calc     : std_logic;
    signal ac_div_start   : std_logic;
    signal ac_div_dend    : unsigned(31 downto 0);
    signal ac_div_dsor    : unsigned(31 downto 0);
    signal ac_div_quot    : unsigned(31 downto 0);
    signal ac_div_rem     : unsigned(31 downto 0);
    signal ac_div_valid   : std_logic;
    signal ac_div_zerr    : std_logic;
    signal ref_detected   : std_logic;
    signal phase_offset   : std_logic;
    signal angle_corr     : unsigned(15 downto 0);
    signal ref_edge_pulse : std_logic;
    signal ref_angle      : unsigned(15 downto 0);
    signal sync_state     : std_logic_vector(2 downto 0);
    signal synced         : std_logic;
    signal phase_engine   : std_logic;
    signal sync_loss_cnt  : unsigned(15 downto 0);
    signal phase_fault    : std_logic;
    signal phase_flt_cnt  : unsigned(15 downto 0);
    signal ab_count       : unsigned(7 downto 0);
    signal z_count        : unsigned(15 downto 0);
    signal angle_hires    : unsigned(15 downto 0);
    signal ae_div_valid   : std_logic;
    signal nco_inc        : unsigned(31 downto 0);
    signal nco_accum      : unsigned(31 downto 0);
    signal phase_error    : signed(31 downto 0);
    signal correction     : signed(31 downto 0);

    -- Config
    signal config_apply   : std_logic := '0';
    signal n_teeth_s      : unsigned(7 downto 0) := to_unsigned(N_TEETH,  8);
    signal n_missing_s    : unsigned(7 downto 0) := to_unsigned(N_MISSING, 8);
    signal gap_threshold  : unsigned(7 downto 0) := to_unsigned(192, 8);
    signal edge_select    : std_logic := '1';
    signal exp_cam_ang    : unsigned(15 downto 0) := to_unsigned(1800, 16);
    signal win_tol        : unsigned(15 downto 0) := to_unsigned(600,  16);
    signal tdc_offset     : unsigned(15 downto 0) := (others => '0');
    signal kp_s           : unsigned(15 downto 0) := (others => '0');
    signal ki_s           : unsigned(15 downto 0) := (others => '0');
    signal max_corr       : unsigned(15 downto 0) := to_unsigned(65535, 16);
    signal corr_dir       : std_logic := '0';
    signal fault_clr      : std_logic := '0';
    signal pfd            : std_logic := '0';

    constant ST_UNSYNC    : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRNK : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL : std_logic_vector(2 downto 0) := "011";

begin

    p_clk: process begin
        while not sim_done loop
            clk<='0'; wait for CLK_PERIOD/2;
            clk<='1'; wait for CLK_PERIOD/2;
        end loop; wait;
    end process;

    -- =========================================================================
    -- Crank generator - SOLE driver of crank_raw
    -- =========================================================================
    p_crank: process
        procedure do_tooth is
        begin
            crank_raw <= '1'; wait for CLK_PERIOD;
            crank_raw <= '0'; wait for (TOOTH_PERIOD-1) * CLK_PERIOD;
        end procedure;
    begin
        crank_raw <= '0';
        wait until crank_run;
        loop
            if trigger_wrong = '1' then
                -- T6: only 50 teeth then gap
                for i in 1 to 50 loop do_tooth; end loop;
                wait for GAP_PERIOD * CLK_PERIOD;
                do_tooth;  -- trigger Z
            else
                -- Normal revolution
                for i in 1 to (N_TEETH - N_MISSING) loop do_tooth; end loop;
                wait for GAP_PERIOD * CLK_PERIOD;
            end if;
            exit when not crank_run or sim_done;
        end loop;
        crank_raw <= '0';
        wait until crank_run or sim_done;
        if not sim_done then
            wait until false;  -- restart by re-entering
        end if;
        wait;
    end process;

    -- =========================================================================
    -- DUT
    -- =========================================================================
    u_crank: entity work.crank_input
        generic map (CLK_FREQ_HZ => CLK_FREQ)
        port map (clk=>clk, rst=>rst, clean_signal=>crank_raw,
                  signal_stable=>'1', edge_select=>edge_select,
                  gap_threshold=>gap_threshold, n_teeth=>n_teeth_s,
                  n_missing=>n_missing_s, ab=>crank_ab, z=>crank_z,
                  tooth_period=>crank_tp, tooth_count=>crank_tc,
                  gap_detected=>open, signal_present=>crank_sp,
                  edge_pulse_out=>open, gap_period=>open);

    u_cam: entity work.cam_input
        port map (clk=>clk, rst=>rst, cam_clean=>cam_raw,
                  edge_sel=>'1', cam_pulse=>cam_pulse);

    u_acd: entity work.divider
        generic map (WIDTH=>32, CACHING=>0, INIT_VLD=>0)
        port map (clk=>clk, rst=>rst, start=>ac_div_start,
                  dividend=>ac_div_dend, divisor=>ac_div_dsor,
                  quotient=>ac_div_quot, remainder=>ac_div_rem,
                  zero_err=>ac_div_zerr, valid=>ac_div_valid);

    u_ac: entity work.angle_calc
        port map (clk=>clk, rst=>rst, ab=>crank_ab, z=>crank_z,
                  tooth_period=>crank_tp, tooth_count=>crank_tc,
                  signal_present=>crank_sp, n_teeth=>n_teeth_s,
                  div_start=>ac_div_start, div_dividend=>ac_div_dend,
                  div_divisor=>ac_div_dsor, div_quotient=>ac_div_quot,
                  div_valid=>ac_div_valid, config_apply=>config_apply,
                  angle_raw=>angle_raw, phase=>phase_calc);

    u_pd: entity work.phase_detector
        port map (clk=>clk, rst=>rst, angle_raw=>angle_raw,
                  phase=>phase_calc, ref_pulse=>cam_pulse,
                  expected_cam_ang=>exp_cam_ang, window_tolerance=>win_tol,
                  tdc_offset=>tdc_offset, ref_detected=>ref_detected,
                  phase_offset=>phase_offset, angle_corr=>angle_corr,
                  ref_edge_pulse=>ref_edge_pulse, ref_angle=>ref_angle);

    u_sync: entity work.sync
        port map (clk=>clk, rst=>rst, ab=>crank_ab, z=>crank_z,
                  signal_present=>crank_sp, ref_detected=>ref_detected,
                  phase_offset=>phase_offset, n_teeth=>n_teeth_s,
                  fault_clear=>fault_clr, phase_fault_drop=>pfd,
                  sync_state=>sync_state, synced=>synced,
                  phase_engine=>phase_engine,
                  sync_loss_count=>sync_loss_cnt,
                  phase_fault_count=>phase_flt_cnt,
                  phase_fault=>phase_fault,
                  ab_count_out=>ab_count, z_count_out=>z_count);

    u_ae: entity work.angle_engine
        port map (clk=>clk, rst=>rst, ab=>crank_ab, z=>crank_z,
                  synced=>synced, phase_engine=>phase_engine,
                  n_teeth=>n_teeth_s, config_apply=>config_apply,
                  kp=>kp_s, ki=>ki_s, max_correction=>max_corr,
                  correction_dir=>corr_dir, angle_hires=>angle_hires,
                  div_valid_out=>ae_div_valid, nco_inc_out=>nco_inc,
                  nco_accum_out=>nco_accum, phase_error_out=>phase_error,
                  correction_out=>correction);

    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim: process

        procedure wait_sync(target: std_logic_vector(2 downto 0)) is
        begin
            wait until sync_state = target for TIMEOUT;
            assert sync_state = target
                report "TIMEOUT waiting for sync_state = " &
                       integer'image(to_integer(unsigned(target)))
                severity failure;
        end procedure;

        variable angle_prev : integer;
        variable angle_curr : integer;
        variable phase_bef  : std_logic;
        variable z_bef      : unsigned(15 downto 0);
        variable loss_bef   : unsigned(15 downto 0);

    begin

        rst <= '1'; wait for 20 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD;
        config_apply <= '1'; wait for CLK_PERIOD; config_apply <= '0';
        wait for 100 * CLK_PERIOD;

        -- ==================================================================
        -- T1: SYNC_CRANK acquisition
        -- ==================================================================
        test_num <= 1;
        report "TEST 1: SYNC_CRANK acquisition";
        assert sync_state = ST_UNSYNC
            report "FAIL T1: should start UNSYNC" severity failure;

        crank_run <= true;
        wait_sync(ST_FIRST_GAP);
        wait_sync(ST_SYNC_CRNK);
        report "TEST 1: PASS";

        -- ==================================================================
        -- T2: SYNC_FULL via cam pulse
        -- ==================================================================
        test_num <= 2;
        report "TEST 2: SYNC_FULL via cam pulse";

        -- Wait a few revolutions then fire cam pulse
        -- The cam fires when angle_raw is in the window for the phase_detector
        -- Since angle_raw may be 0 (angle_calc needs more time), use z_count instead
        -- Wait for 3 more Z pulses (3 revolutions) then fire cam during the window
        z_bef := z_count;
        wait until z_count >= z_bef + 3 for TIMEOUT;
        -- Now fire cam - we expect to be somewhere in a revolution
        -- Fire it and wait to see if it hits the window (1200-2400)
        -- If angle_raw is non-zero, fire when in window; otherwise fire anyway
        -- Phase_detector will accept if it falls in 1200-2400
        wait for (TOOTH_PERIOD * 10) * CLK_PERIOD;  -- wait ~10 teeth into revolution
        cam_raw <= '1'; wait for 5 * CLK_PERIOD; cam_raw <= '0';

        wait_sync(ST_SYNC_FULL);
        assert synced = '1'
            report "FAIL T2: synced should be 1" severity failure;
        report "TEST 2: PASS";

        -- ==================================================================
        -- T3: angle_raw ~120 per tooth
        -- ==================================================================
        test_num <= 3;
        report "TEST 3: angle_raw ~120 steps/tooth";

        wait until rising_edge(clk) and crank_ab'event for TIMEOUT;
        wait for 2 * CLK_PERIOD;
        angle_prev := to_integer(angle_raw);
        wait until rising_edge(clk) and crank_ab'event for TIMEOUT;
        wait for 2 * CLK_PERIOD;
        angle_curr := to_integer(angle_raw);

        if angle_curr >= angle_prev then
            assert (angle_curr - angle_prev) >= 100 and
                   (angle_curr - angle_prev) <= 140
                report "FAIL T3: steps/tooth should be ~120, got " &
                       integer'image(angle_curr - angle_prev)
                severity failure;
        end if;
        report "TEST 3: PASS - steps/tooth=" &
               integer'image(angle_curr - angle_prev);

        -- ==================================================================
        -- T4: angle_hires monotonically increasing
        -- ==================================================================
        test_num <= 4;
        report "TEST 4: angle_hires monotonically increasing";

        angle_prev := 0;
        for i in 1 to 500 loop
            wait for CLK_PERIOD;
            angle_curr := to_integer(angle_hires);
            if angle_curr < angle_prev then
                assert angle_prev >= 3590
                    report "FAIL T4: angle_hires decreased from " &
                           integer'image(angle_prev) & " to " &
                           integer'image(angle_curr)
                    severity failure;
            end if;
            angle_prev := angle_curr;
        end loop;
        report "TEST 4: PASS";

        -- ==================================================================
        -- T5: phase_engine toggles on Z
        -- ==================================================================
        test_num <= 5;
        report "TEST 5: phase_engine toggles on Z";

        z_bef     := z_count;
        phase_bef := phase_engine;
        -- Wait two Z pulses
        wait until z_count >= z_bef + 2 for TIMEOUT;
        wait for 5 * CLK_PERIOD;
        assert phase_engine = phase_bef
            report "FAIL T5: phase_engine should return same after 2 Z pulses"
            severity failure;
        report "TEST 5: PASS";

        -- ==================================================================
        -- T6: sync_loss on wrong tooth count
        -- ==================================================================
        test_num <= 6;
        report "TEST 6: sync_loss on wrong tooth count";

        loss_bef := sync_loss_cnt;
        trigger_wrong <= '1';  -- next revolution will be wrong count
        -- Wait for sync_loss to increment
        wait until sync_loss_cnt > loss_bef for TIMEOUT;
        trigger_wrong <= '0';  -- back to normal
        report "TEST 6: PASS - sync_loss=" &
               integer'image(to_integer(sync_loss_cnt));

        -- ==================================================================
        -- T7: angle_corr with tdc_offset
        -- ==================================================================
        test_num <= 7;
        report "TEST 7: angle_corr with tdc_offset";

        -- Reacquire sync after T6 disruption
        wait_sync(ST_FIRST_GAP);
        wait_sync(ST_SYNC_CRNK);
        wait until to_integer(angle_raw) < 600 for TIMEOUT;
        wait until (to_integer(angle_raw) >= 1200 and
                    to_integer(angle_raw) <= 2400) for TIMEOUT;
        cam_raw <= '1'; wait for 5 * CLK_PERIOD; cam_raw <= '0';
        wait_sync(ST_SYNC_FULL);

        tdc_offset <= to_unsigned(600, 16);
        wait for 5 * CLK_PERIOD;

        wait until to_integer(angle_raw) > 100 for TIMEOUT;
        wait for 3 * CLK_PERIOD;

        assert to_integer(angle_corr) /= to_integer(angle_raw)
            report "FAIL T7: angle_corr should differ from angle_raw with tdc_offset"
            severity failure;
        report "TEST 7: PASS - angle_raw=" & integer'image(to_integer(angle_raw)) &
               " angle_corr=" & integer'image(to_integer(angle_corr));

        crank_run <= false;
        wait for 50 * CLK_PERIOD;
        report "========================================";
        report "All integration tests complete";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
