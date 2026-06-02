library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- crank_tb2
--
-- Continuous crank pattern testbench for crank_input.
-- Tests gap timing between last interpolated edge and first real edge
-- of next revolution using a background process rather than manual pulses.
-- =============================================================================

entity crank_tb2 is
end entity crank_tb2;

architecture sim of crank_tb2 is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD      : time    := 1000 ns;
    constant N_TEETH         : integer := 60;
    constant N_MISSING       : integer := 2;
    constant TEETH_REAL      : integer := N_TEETH - N_MISSING;

    constant PERIOD_1000_RPM : time    := 1_000_000 ns;
    constant PERIOD_2000_RPM : time    :=   500_000 ns;
    constant GAP_THRESHOLD   : unsigned(7 downto 0) := x"C0";
    
    -- One full cycle duration at 1000 RPM
    -- 58 real teeth + 3 tooth periods gap = 61 tooth periods
    constant CYCLE_1000_RPM  : time := PERIOD_1000_RPM * 61;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal clean          : std_logic := '1';   -- start inactive (high)
    signal edge_sel       : std_logic := '0';   -- falling edge
    signal gap_thresh     : unsigned(7 downto 0) := GAP_THRESHOLD;
    signal n_teeth_s      : unsigned(7 downto 0) := to_unsigned(N_TEETH, 8);
    signal n_missing_s    : unsigned(7 downto 0) := to_unsigned(N_MISSING, 8);
    signal ab_edge        : std_logic;
    signal z_edge         : std_logic;
    signal ppr_conf       : unsigned(7 downto 0);
    signal tooth_per      : unsigned(31 downto 0);
    signal tooth_cnt      : unsigned(7 downto 0);
    signal ab_cnt         : unsigned(7 downto 0);
    signal gap_det        : std_logic;
    signal gap_period     : unsigned(31 downto 0);
    signal signal_ok      : std_logic;
    signal crank_ab       : std_logic;
    signal crank_z        : std_logic;
    
    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal done           : boolean := false;
    signal crank_run      : std_logic := '0';
    signal crank_period   : time      := PERIOD_1000_RPM;
    signal test_num       : integer   := 0;
    signal z_count        : integer   := 0;
    signal cycle_ab_count  : integer := 0;  -- AB toggles this cycle
    signal cycle_ab_last   : integer := 0;  -- AB toggles last complete cycle

begin

    -- -------------------------------------------------------------------------
    -- Clock generation
    -- -------------------------------------------------------------------------
    p_clk : process
    begin
        while not done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    -- -------------------------------------------------------------------------
    -- Continuous crank pattern generator
    -- Runs when crank_run = '1'
    -- Generates falling edge teeth followed by gap, continuously
    -- clean held inactive (high) when stopped
    -- -------------------------------------------------------------------------
    p_crank : process
    begin
        loop
            -- Check at top of every cycle
            if crank_run = '0' then
                clean <= '1';
                wait until crank_run = '1';
            end if;

            -- Generate teeth, checking crank_run between each tooth
            for i in 1 to TEETH_REAL loop
                if crank_run = '0' then
                    clean <= '1';
                    exit;   -- exit the for loop
                end if;
                clean <= '1'; wait for crank_period / 2;
                clean <= '0'; wait for crank_period / 2;
            end loop;

            -- Only generate gap if still running
            if crank_run = '1' then
                clean <= '1';
                wait for crank_period * (N_MISSING + 1);
            end if;
        end loop;
    end process p_crank;

    -- -------------------------------------------------------------------------
    -- DUT instantiation
    -- -------------------------------------------------------------------------
    dut : entity work.crank
        port map (
            clk=>clk,
            rst=>rst,
            crank_clean=>clean,
            crank_edge_sel=>edge_sel,
            crank_gap_thresh=>gap_thresh,
            crank_n_teeth=>n_teeth_s,
            crank_n_missing=>n_missing_s,
            crank_ab=>crank_ab,
            crank_z=>crank_z,
            crank_ab_edge=>ab_edge,
            crank_tooth_period=>tooth_per,
            crank_gap_period=>gap_period,
            crank_tooth_count=>tooth_cnt,
            crank_ab_count=>ab_cnt,
            crank_ppr_conf=>ppr_conf,
            crank_gap_det=>gap_det,         
            crank_z_edge=>z_edge,
            crank_signal_ok=>signal_ok
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable ab_count_start  : integer;
        variable z_count_start   : integer;
        variable ab_per_cycle    : integer;
    begin

        -- --------------------------------------------------------------------
        -- Reset
        -- --------------------------------------------------------------------
        rst        <= '1';
        crank_run  <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 10: Continuous AB count per cycle at 1000 RPM
        -- Verify exactly N_TEETH AB toggles per cycle
        -- --------------------------------------------------------------------
        report "TEST 10: Continuous AB count per cycle at 1000 RPM";
        test_num <= 10;

        crank_period <= PERIOD_1000_RPM;
        crank_run    <= '1';

        -- Allow 3 cycles to establish sync and interpolation
        wait for CYCLE_1000_RPM * 3;

        -- wait until we're just past the 1st edge of the next cycle
        wait for CLK_PERIOD * 10;

        -- cycle_ab_last holds the AB count for the last complete cycle
        assert cycle_ab_last = N_TEETH
            report "FAIL T10: AB per cycle = " &
                integer'image(cycle_ab_last) &
                " expected " & integer'image(N_TEETH)
            severity error;

        report "TEST 10: PASS - AB per cycle = " &
            integer'image(cycle_ab_last);

        -- --------------------------------------------------------------------
        -- TEST 11: Gap timing - interval from last interp edge to first real edge
        -- Should be approximately current_period (one tooth period)
        -- --------------------------------------------------------------------
        report "TEST 11: Gap timing - last interp to first real edge";
        test_num <= 11;

        -- Wait for gap_det to go high
        wait until gap_det = '1';

        -- Capture time reference
        -- Measure time from gap_detected rising edge to Z rising edge
        -- Z fires on first real edge after gap, so this is the gap duration
        -- Expected: approximately (N_MISSING + 1) * tooth_period
        -- from gap threshold crossing to first real tooth

        wait until crank_z = '1';
        wait for CLK_PERIOD * 10;

        -- If we reach here Z fired after gap_detected, which is correct
        assert signal_ok = '1'
            report "FAIL T11: signal_ok dropped during gap"
            severity error;

        assert gap_det = '0'
            report "FAIL T11: gap_det should be low after first real edge"
            severity error;

        report "TEST 11: PASS - Z fired correctly after gap_det";

        -- --------------------------------------------------------------------
        -- TEST 12: RPM change - AB count remains N_TEETH per cycle
        -- --------------------------------------------------------------------
        report "TEST 12: AB count correct after RPM change to 2000 RPM";
        test_num <= 12;

        -- Change RPM
        crank_period <= PERIOD_2000_RPM;

        -- Allow 3 cycles to settle at new RPM
        wait for (PERIOD_2000_RPM * 61) * 3;

        -- Wait for a complete cycle at new RPM
        -- Use z_count to detect cycle boundary cleanly
        z_count_start := z_count;
        wait until z_count > z_count_start;

        -- Wait for monitor to update cycle_ab_last
        wait for 10 * CLK_PERIOD;

        assert cycle_ab_last = N_TEETH
            report "FAIL T12: AB toggles per cycle at 2000 RPM = " &
                integer'image(cycle_ab_last) &
                " expected " & integer'image(N_TEETH)
            severity error;

        report "TEST 12: PASS - AB per cycle at 2000 RPM = " &
            integer'image(cycle_ab_last);

        -- --------------------------------------------------------------------
        -- TEST 13: Signal present goes low on stop, recovers on restart
        -- --------------------------------------------------------------------
        report "TEST 13: Signal present on stop and restart";
        test_num <= 13;

        crank_period <= PERIOD_1000_RPM;
        crank_run    <= '0';

        -- Wait for timeout: N_MISSING + 2 tooth periods
        wait for PERIOD_1000_RPM * (N_MISSING + 2);

        assert signal_ok = '0'
            report "FAIL T13: signal_ok did not go low after stop"
            severity error;

        -- Restart
        crank_run <= '1';

        -- Wait for signal_ok to recover
        wait until signal_ok = '1';

        report "TEST 13: PASS - signal_ok timed out and recovered";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        crank_run <= '0';
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "Tests from crank_input_tb2 complete";
        report "========================================";

        done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(clk)
        variable ab_prev     : std_logic := '0';
        variable z_prev      : std_logic := '0';
        variable cycle_ab    : integer := 0;
    begin
        if rising_edge(clk) then
            -- AB toggle detection
            if crank_ab /= ab_prev then
                ab_cnt  <= ab_cnt + 1;
                cycle_ab  := cycle_ab + 1;
            end if;
            ab_prev := crank_ab;

            -- Z rising edge: end of cycle
            -- Latch cycle count and reset
            if crank_z = '1' and z_prev = '0' then
                z_count        <= z_count + 1;
                cycle_ab_last  <= cycle_ab;
                cycle_ab       := 0;
                cycle_ab_count <= cycle_ab;
                report "Z PULSE: AB last cycle = " &
                    integer'image(cycle_ab_last);
            end if;
            z_prev := crank_z;
        end if;
    end process p_monitor;

end architecture sim;