library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity crank_tb is
end entity crank_tb;

architecture sim of crank_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- 1MHz sim clock gives convenient tooth periods at engine-like RPM values.
    -- At 1000 RPM, 60 teeth: tooth period = 60s/(1000*60) = 1ms = 1000 cycles.
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD      : time    := 1000 ns;   -- 1 MHz
    constant N_TEETH         : integer := 60;
    constant N_MISSING       : integer := 2;
    constant TEETH_REAL      : integer := N_TEETH - N_MISSING;  -- 58

    constant PERIOD_1000_RPM : time    := 1_000_000 ns;
    constant PERIOD_2000_RPM : time    :=   500_000 ns;
    constant EXP_PERIOD_1000 : integer := 1_000;
    constant EXP_PERIOD_2000 : integer :=   500;
    constant PERIOD_TOL      : integer := 5;

    constant GAP_THRESH_C    : unsigned(7 downto 0) := x"C0";

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal clean        : std_logic := '0';
    signal edge_sel     : std_logic := '0';   -- falling edge (open drain default)
    signal gap_thresh   : unsigned(7 downto 0) := GAP_THRESH_C;
    signal n_teeth_s    : unsigned(7 downto 0) := to_unsigned(N_TEETH, 8);
    signal n_missing_s  : unsigned(7 downto 0) := to_unsigned(N_MISSING, 8);
    signal ab_edge      : std_logic;
    signal z_edge       : std_logic;
    signal ppr_conf     : unsigned(7 downto 0);
    signal tooth_per    : unsigned(31 downto 0);
    signal tooth_cnt    : unsigned(7 downto 0);
    signal ab_cnt       : unsigned(7 downto 0);
    signal gap_det      : std_logic;
    signal gap_period   : unsigned(31 downto 0);
    signal signal_ok    : std_logic;
    signal crank_ab     : std_logic;
    signal crank_z      : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done     : boolean := false;
    signal test_num     : integer := 0;
    signal ab_count     : integer := 0;   -- cumulative AB toggle count
    signal z_count      : integer := 0;   -- cumulative Z rising-edge count

    -- -------------------------------------------------------------------------
    -- Generate one complete TEETH_REAL teeth + gap on clean
    -- fall=true: falling edges are teeth (open drain / inverted signal)
    -- -------------------------------------------------------------------------
    procedure gen_crank_cycle(
        signal   sig    : out std_logic;
        constant t_per  : in  time;
        constant fall   : in  boolean
    ) is
        constant t_pulse : time := t_per / 2;
    begin
        for i in 1 to TEETH_REAL loop
            if fall then
                sig <= '1'; wait for t_pulse;
                sig <= '0'; wait for t_pulse;
            else
                sig <= '0'; wait for t_pulse;
                sig <= '1'; wait for t_pulse;
            end if;
        end loop;
        -- Gap: hold inactive for N_MISSING tooth periods
        if fall then
            sig <= '1'; wait for t_per * N_MISSING;
        else
            sig <= '0'; wait for t_per * N_MISSING;
        end if;
    end procedure gen_crank_cycle;

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
    dut : entity work.crank
        port map (
            clk              => clk,
            rst              => rst,
            crank_clean      => clean,
            crank_edge_sel   => edge_sel,
            crank_gap_thresh => gap_thresh,
            crank_n_teeth    => n_teeth_s,
            crank_n_missing  => n_missing_s,
            crank_ab_edge    => ab_edge,
            crank_z_edge     => z_edge,
            crank_ppr_conf   => ppr_conf,
            crank_tooth_period => tooth_per,
            crank_tooth_count  => tooth_cnt,
            crank_ab_count     => ab_cnt,
            crank_gap_det      => gap_det,
            crank_gap_period   => gap_period,
            crank_signal_ok    => signal_ok,
            crank_ab           => crank_ab,
            crank_z            => crank_z
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable period_error  : integer;
        variable count_start   : integer;
        variable z_count_start : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst   <= '1';
        clean <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert signal_ok = '0'
            report "FAIL T1: signal_ok should be low after reset"
            severity failure;
        assert crank_z = '0'
            report "FAIL T1: z should be low after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: ppr_conf is a pass-through of n_teeth
        -- --------------------------------------------------------------------
        report "TEST 2: ppr_conf passthrough";
        test_num <= 2;

        assert ppr_conf = to_unsigned(N_TEETH, 8)
            report "FAIL T2: ppr_conf wrong: " &
                   integer'image(to_integer(ppr_conf)) &
                   " expected " & integer'image(N_TEETH)
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Period measurement at 1000 RPM (falling edge)
        -- Two consecutive falling edges should give tooth_period within
        -- PERIOD_TOL clocks of EXP_PERIOD_1000
        -- --------------------------------------------------------------------
        report "TEST 3: Period measurement at 1000 RPM (falling edge)";
        test_num <= 3;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        edge_sel <= '0';    -- falling edge
        clean <= '1';
        wait for PERIOD_1000_RPM;

        -- First falling edge
        clean <= '0'; wait for PERIOD_1000_RPM / 2;
        clean <= '1'; wait for PERIOD_1000_RPM / 2;

        -- Second falling edge
        clean <= '0'; wait for PERIOD_1000_RPM / 2;
        clean <= '1';
        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T3: period = " &
                   integer'image(to_integer(tooth_per)) &
                   " expected " & integer'image(EXP_PERIOD_1000) &
                   " tol " & integer'image(PERIOD_TOL)
            severity failure;
        assert signal_ok = '1'
            report "FAIL T3: signal_ok should be high after edges"
            severity failure;
        report "TEST 3: PASS - period = " & integer'image(to_integer(tooth_per));

        -- --------------------------------------------------------------------
        -- TEST 4: Period measurement at 1000 RPM (rising edge)
        -- --------------------------------------------------------------------
        report "TEST 4: Period measurement at 1000 RPM (rising edge)";
        test_num <= 4;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        edge_sel <= '1';    -- rising edge
        clean <= '0';
        wait for PERIOD_1000_RPM;

        clean <= '1'; wait for PERIOD_1000_RPM / 2;
        clean <= '0'; wait for PERIOD_1000_RPM / 2;
        clean <= '1'; wait for PERIOD_1000_RPM / 2;
        clean <= '0';
        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T4: period = " &
                   integer'image(to_integer(tooth_per)) &
                   " expected " & integer'image(EXP_PERIOD_1000)
            severity failure;
        report "TEST 4: PASS";

        -- Reset back to falling for remaining tests
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        edge_sel <= '0';
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Gap detection and Z pulse
        -- Run one full cycle; verify gap_det fires and Z fires once
        -- --------------------------------------------------------------------
        report "TEST 5: Gap detection and Z pulse";
        test_num <= 5;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        -- Prime with one full cycle for period_valid and last_period
        clean <= '1'; wait for PERIOD_1000_RPM * 3;
        z_count_start := z_count;
        gen_crank_cycle(clean, PERIOD_1000_RPM, true);

        -- First tooth after gap
        clean <= '0'; wait for PERIOD_1000_RPM / 4;
        assert crank_z = '1'
            report "FAIL T5: Z not high during first post-gap tooth"
            severity failure;

        wait for PERIOD_1000_RPM / 4;
        clean <= '1'; wait for PERIOD_1000_RPM / 2;
        clean <= '0'; wait for PERIOD_1000_RPM / 4;
        assert crank_z = '0'
            report "FAIL T5: Z not cleared by second tooth"
            severity failure;

        assert z_count > z_count_start
            report "FAIL T5: Z pulse not counted"
            severity failure;
        report "TEST 5: PASS - Z fired at tooth_count=" &
               integer'image(to_integer(tooth_cnt));

        -- --------------------------------------------------------------------
        -- TEST 6: AB toggle count per cycle = N_TEETH
        -- (real teeth + interpolated missing teeth)
        -- --------------------------------------------------------------------
        report "TEST 6: AB toggle count per cycle = " & integer'image(N_TEETH);
        test_num <= 6;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        count_start := ab_count;

        gen_crank_cycle(clean, PERIOD_1000_RPM, true);
        -- Wait for interpolation to complete
        wait for PERIOD_1000_RPM * (N_MISSING + 1);

        assert (ab_count - count_start) = N_TEETH
            report "FAIL T6: AB toggles = " &
                   integer'image(ab_count - count_start) &
                   " expected " & integer'image(N_TEETH)
            severity failure;
        report "TEST 6: PASS - AB toggles = " &
               integer'image(ab_count - count_start);

        -- --------------------------------------------------------------------
        -- TEST 7: RPM change - period updates correctly
        -- Run at 1000 RPM then switch to 2000 RPM; verify period halves
        -- --------------------------------------------------------------------
        report "TEST 7: RPM change 1000 -> 2000 RPM";
        test_num <= 7;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        gen_crank_cycle(clean, PERIOD_1000_RPM, true);
        gen_crank_cycle(clean, PERIOD_2000_RPM, true);
        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_2000);
        assert period_error <= PERIOD_TOL
            report "FAIL T7: period after RPM change = " &
                   integer'image(to_integer(tooth_per)) &
                   " expected " & integer'image(EXP_PERIOD_2000)
            severity failure;
        report "TEST 7: PASS - period at 2000 RPM = " &
               integer'image(to_integer(tooth_per));

        -- --------------------------------------------------------------------
        -- TEST 8: signal_ok times out after signal stops
        -- --------------------------------------------------------------------
        report "TEST 8: signal_ok times out on signal stop";
        test_num <= 8;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        gen_crank_cycle(clean, PERIOD_1000_RPM, true);
        assert signal_ok = '1'
            report "FAIL T8 setup: signal_ok not high after cycle"
            severity failure;

        -- Stop signal (hold inactive high for falling-edge mode)
        clean <= '1';
        wait for (N_MISSING + 3) * EXP_PERIOD_1000 * 1000 ns;

        assert signal_ok = '0'
            report "FAIL T8: signal_ok did not time out"
            severity failure;
        report "TEST 8: PASS - signal_ok timed out";

        -- --------------------------------------------------------------------
        -- TEST 9: Z fires exactly once per cycle over 3 cycles
        -- (First cycle after reset only primes the period; Z fires from 2nd)
        -- --------------------------------------------------------------------
        report "TEST 9: Z fires once per cycle over 3 cycles";
        test_num <= 9;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        z_count_start := z_count;

        for i in 1 to 3 loop
            gen_crank_cycle(clean, PERIOD_1000_RPM, true);
        end loop;
        wait for PERIOD_1000_RPM;

        -- First cycle primes period, no Z. Next 2 cycles each fire 1 Z.
        assert (z_count - z_count_start) = 2
            report "FAIL T9: Z count = " &
                   integer'image(z_count - z_count_start) &
                   " expected 2 for 3 cycles"
            severity failure;
        report "TEST 9: PASS - Z fired " &
               integer'image(z_count - z_count_start) & " times in 3 cycles";

        -- --------------------------------------------------------------------
        -- TEST 10: ab_period_filt frozen correctly across gap boundary
        --
        -- crank_tooth_period (= ab_period_filt) must hold the pre-gap tooth
        -- period across the whole gap crossing, not the gap period itself.
        -- Three sub-checks:
        --   T10a: frozen during gap (no edge_pulse fires, so always true)
        --   T10b: tooth 0 (z_armed tooth) -- must NOT update to gap period
        --   T10c: tooth 1 (first post-gap tooth) -- must resume at tooth period
        --         (NOT the gap period, which was current_period at tooth 0)
        --
        -- T10b catches: ab_period_filt NOT gated at z_armed tooth
        -- T10c catches: one-tooth lag where gap period propagates to tooth 1
        --               via current_period (the original fix bug)
        -- --------------------------------------------------------------------
        report "TEST 10: tooth_period frozen across gap (ab_period_filt fix)";
        test_num <= 10;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        edge_sel <= '0';    -- falling edge mode

        -- Prime with 2 complete revolutions for stable period measurement
        gen_crank_cycle(clean, PERIOD_1000_RPM, true);
        gen_crank_cycle(clean, PERIOD_1000_RPM, true);
        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T10 setup: tooth_per not stable, got " &
                   integer'image(to_integer(tooth_per))
            severity failure;

        -- Cycle 3: generate all 58 real teeth manually (same timing as gen_crank_cycle)
        for i in 1 to TEETH_REAL loop
            clean <= '1'; wait for PERIOD_1000_RPM / 2;
            clean <= '0'; wait for PERIOD_1000_RPM / 2;
        end loop;

        -- Gap: hold inactive (high in fall mode) for N_MISSING tooth periods
        -- gap_det fires at ~1.5x tooth period into the gap
        clean <= '1';
        wait for PERIOD_1000_RPM;    -- 1 tooth period into gap

        -- T10a: tooth_per frozen during gap (no edge_pulse fires)
        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T10a: tooth_per mid-gap = " &
                   integer'image(to_integer(tooth_per)) &
                   " expected frozen at " & integer'image(EXP_PERIOD_1000)
            severity failure;

        wait for PERIOD_1000_RPM;    -- complete N_MISSING tooth periods of gap

        -- Tooth 0: z_armed tooth (first tooth after gap)
        -- period_cnt at this point = gap period (~3x EXP_PERIOD_1000)
        -- ab_period_filt must NOT update here
        clean <= '1'; wait for PERIOD_1000_RPM / 2;
        clean <= '0'; wait for 5 * CLK_PERIOD;   -- falling edge fires

        -- T10b: tooth_per must still hold pre-gap period, not gap period
        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T10b: tooth_per at z_armed tooth = " &
                   integer'image(to_integer(tooth_per)) &
                   " expected " & integer'image(EXP_PERIOD_1000) &
                   " (gap period ~3000 means z_armed gate missing)"
            severity failure;

        -- Tooth 1: first normal tooth after gap
        -- current_period is still gap period at this point if not fixed
        -- ab_period_filt must use period_cnt (tooth 1's own period), not current_period
        wait for PERIOD_1000_RPM / 2 - 5 * CLK_PERIOD;
        clean <= '1'; wait for PERIOD_1000_RPM / 2;
        clean <= '0'; wait for 5 * CLK_PERIOD;

        -- T10c: tooth_per must resume at EXP_PERIOD_1000, not gap period
        period_error := abs(to_integer(tooth_per) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T10c: tooth_per at tooth 1 (post-gap) = " &
                   integer'image(to_integer(tooth_per)) &
                   " expected " & integer'image(EXP_PERIOD_1000) &
                   " (gap period ~3000 means one-tooth lag in ab_period_filt)"
            severity failure;

        report "TEST 10: PASS - tooth_per frozen at gap: " &
               integer'image(to_integer(tooth_per));

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All crank tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor: counts AB toggles and Z rising edges
    -- -------------------------------------------------------------------------
    p_monitor : process(clk)
        variable ab_prev : std_logic := '0';
        variable z_prev  : std_logic := '0';
    begin
        if rising_edge(clk) then
            if crank_ab /= ab_prev then
                ab_count <= ab_count + 1;
            end if;
            ab_prev := crank_ab;

            if crank_z = '1' and z_prev = '0' then
                z_count <= z_count + 1;
                report "Z PULSE: tooth_count=" &
                       integer'image(to_integer(tooth_cnt)) &
                       " ab_count=" & integer'image(to_integer(ab_cnt));
            end if;
            z_prev := crank_z;
        end if;
    end process p_monitor;

end architecture sim;
