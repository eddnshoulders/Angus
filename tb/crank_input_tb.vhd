library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity crank_input_tb is
end entity crank_input_tb;

architecture sim of crank_input_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 1000 ns;   -- 1MHz sim clock
    constant N_TEETH      : integer := 60;
    constant N_MISSING    : integer := 2;
    constant TEETH_REAL   : integer := N_TEETH - N_MISSING;  -- 58

    -- Tooth period at 1000 RPM with 1MHz clock
    -- 1000 RPM, 60 teeth: period = 60s / (1000 * 60) = 1ms = 1000 cycles at 1MHz
    constant PERIOD_1000_RPM : time    := 1_000_000 ns;
    constant PERIOD_2000_RPM : time    :=   500_000 ns;
    constant EXP_PERIOD_1000 : integer := 1_000;
    constant EXP_PERIOD_2000 : integer :=   500;
    constant PERIOD_TOL      : integer := 5;

    -- Gap threshold: 0xC0 = 192 = 1.5 in 1.7 fixed point
    --constant GAP_THRESH   : ufixed(1 downto -7) := 1.5;
    constant GAP_THRESH      : unsigned(7 downto 0) := x"C0";

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal clean_signal   : std_logic := '0';
    signal signal_stable  : std_logic := '1';
    signal edge_select    : std_logic := '0';   -- falling edge default
    signal gap_threshold         : unsigned(7 downto 0) := GAP_THRESH;
    --gap_threshold         : ufixed(1 downto -7) := GAP_THRESH;
    signal ab             : std_logic;
    signal z              : std_logic;
    signal tooth_period   : unsigned(31 downto 0);
    signal tooth_count    : unsigned(7 downto 0);
    signal signal_present : std_logic;
    signal gap_detected   : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done       : boolean := false;
    signal test_num       : integer := 0;
    signal ab_count       : integer := 0;
    signal z_count        : integer := 0;
    signal crank_period   : time := PERIOD_1000_RPM;
    signal crank_run      : std_logic := '0'; 

    -- -------------------------------------------------------------------------
    -- Generate one complete n-m crank cycle on clean_signal
    -- Uses falling edges (open drain default)
    -- t_period: time between falling edges
    -- -------------------------------------------------------------------------
    procedure gen_crank_cycle(
        signal   sig      : out std_logic;
        constant t_period : in  time;
        constant fall     : in  boolean    -- true = falling edge teeth
    ) is
        constant t_pulse : time := t_period / 2;
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

        -- Gap: hold inactive for (N_MISSING + 1) tooth periods
        if fall then
            sig <= '1'; wait for t_period * (N_MISSING);
        else
            sig <= '0'; wait for t_period * (N_MISSING);
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
    dut : entity work.crank_input
        generic map (
            CLK_FREQ_HZ => 1_000_000,
            N_TEETH     => N_TEETH,
            N_MISSING   => N_MISSING
        )
        port map (
            clk            => clk,
            rst            => rst,
            clean_signal   => clean_signal,
            signal_stable  => signal_stable,
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
        test_num     <= 1;
        report "TEST 1: Reset behaviour";
        rst          <= '1';
        clean_signal <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert ab = '0'
            report "FAIL T1: ab should be low after reset"
            severity error;
        assert z = '0'
            report "FAIL T1: z should be low after reset"
            severity error;
        assert signal_present = '0'
            report "FAIL T1: signal_present should be low after reset"
            severity error;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Period measurement - falling edge at 1000 RPM
        -- --------------------------------------------------------------------
        report "TEST 2: Period measurement at 1000 RPM (falling edge)";
        test_num <= 2;

        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        -- falling edge
        edge_select <= '0';   

        -- Start high (inactive for open drain)
        clean_signal <= '1';
        wait for PERIOD_1000_RPM;

        -- First falling edge
        clean_signal <= '0'; wait for PERIOD_1000_RPM / 2;
        clean_signal <= '1'; wait for PERIOD_1000_RPM / 2;

        -- Second falling edge
        clean_signal <= '0'; wait for PERIOD_1000_RPM / 2;
        clean_signal <= '1';

        -- Wait for period to be measured
        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_period) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T2: period error = " & integer'image(period_error) &
                   " cycles, got " & integer'image(to_integer(tooth_period)) &
                   " expected " & integer'image(EXP_PERIOD_1000)
            severity error;

        assert signal_present = '1'
            report "FAIL T2: signal_present should be high"
            severity error;

        report "TEST 2: PASS - period = " &
               integer'image(to_integer(tooth_period)) & " cycles";

        -- --------------------------------------------------------------------
        -- TEST 3: Period measurement - rising edge at 1000 RPM
        -- --------------------------------------------------------------------
        report "TEST 3: Period measurement at 1000 RPM (rising edge)";
        test_num <= 3;

        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        -- Reset and switch to rising edge
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        edge_select  <= '1';   -- rising edge
        clean_signal <= '0';
        wait for PERIOD_1000_RPM;

        -- First rising edge
        clean_signal <= '1'; wait for PERIOD_1000_RPM / 2;
        clean_signal <= '0'; wait for PERIOD_1000_RPM / 2;

        -- Second rising edge
        clean_signal <= '1'; wait for PERIOD_1000_RPM / 2;
        clean_signal <= '0';

        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_period) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T3: period error = " & integer'image(period_error) &
                   " cycles, got " & integer'image(to_integer(tooth_period)) &
                   " expected " & integer'image(EXP_PERIOD_1000)
            severity error;

        report "TEST 3: PASS - period = " &
               integer'image(to_integer(tooth_period)) & " cycles";

        -- Reset back to falling edge for remaining tests
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        edge_select <= '0';
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Gap detection
        -- Send normal teeth then a gap
        -- Verify tooth_count resets and z fires
        -- --------------------------------------------------------------------
        report "TEST 4: Gap detection and Z pulse";
        test_num <= 4;

        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        -- Establish signal with one full cycle
        clean_signal <= '1';
        wait for PERIOD_1000_RPM * 3;
        z_count_start := z_count;
        gen_crank_cycle(clean_signal, PERIOD_1000_RPM, true);

        -- send 1st edge after gap and check at middle of tooth for for z being high
        clean_signal <= '0';
        wait for PERIOD_1000_RPM / 4;
        assert z = '1'
            report "FAIL T4: Z pulse in correct position"
            severity error;

        -- continue to the 2nd tooth and check z has cleared
        wait for PERIOD_1000_RPM / 4;
        clean_signal <= '1';
        wait for PERIOD_1000_RPM / 2;
        clean_signal <= '0';
        wait for PERIOD_1000_RPM / 4;
        assert z = '0'
            report "FAIL T4: Z pulse not cleared at correct position"
            severity error;

        assert z_count > z_count_start
            report "FAIL T4: z_count not incremented"
            severity error;

        assert to_integer(tooth_count) < N_TEETH
            report "FAIL T4: tooth_count exceeded N_TEETH"
            severity error;

        report "TEST 4: PASS - Z pulse detected, z_count = " &
               integer'image(z_count);

        -- --------------------------------------------------------------------
        -- TEST 5: AB toggles on each tooth including interpolated
        -- Over one full cycle should see N_TEETH toggles
        -- --------------------------------------------------------------------
        report "TEST 5: AB toggle count over one cycle";
        test_num <= 5;
         
        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        
        count_start := ab_count;
        
        -- generate 1 crank revolution
        gen_crank_cycle(clean_signal, PERIOD_1000_RPM, true);

        -- Wait for interpolation to complete
        wait for PERIOD_1000_RPM * (N_MISSING + 1);

        -- Should have seen N_TEETH toggles (58 real + 2 interpolated)
        assert (ab_count - count_start) = N_TEETH
            report "FAIL T5: AB toggle count = " &
                   integer'image(ab_count - count_start) &
                   " expected " & integer'image(N_TEETH)
            severity error;

        report "TEST 5: PASS - AB toggles = " &
               integer'image(ab_count - count_start);

        -- --------------------------------------------------------------------
        -- TEST 6: RPM change - period updates correctly
        -- --------------------------------------------------------------------
        report "TEST 6: RPM change 1000 to 2000 RPM";
        test_num <= 6;

        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        -- generate 2 crank revolutions
        gen_crank_cycle(clean_signal, PERIOD_1000_RPM, true);
        gen_crank_cycle(clean_signal, PERIOD_2000_RPM, true);

        -- Wait for period to settle at new RPM
        wait for 10 * CLK_PERIOD;

        period_error := abs(to_integer(tooth_period) - EXP_PERIOD_2000);
        assert period_error <= PERIOD_TOL
            report "FAIL T6: period error after RPM change = " &
                   integer'image(period_error) & " cycles, got " &
                   integer'image(to_integer(tooth_period))
            severity error;

        report "TEST 6: PASS - period at 2000 RPM = " &
               integer'image(to_integer(tooth_period)) & " cycles";

        -- --------------------------------------------------------------------
        -- TEST 7: Signal present goes low on timeout
        -- --------------------------------------------------------------------
        report "TEST 7: Signal present timeout";
        test_num <= 7;

        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        -- generate 1 crank revolution
        gen_crank_cycle(clean_signal, PERIOD_1000_RPM, true);

        assert signal_present = '1'
            report "FAIL T7 setup: signal_present not high before timeout test"
            severity error;

        -- Stop signal
        clean_signal <= '1';   -- inactive state for falling edge mode

        -- Wait for timeout
        wait for (N_MISSING + 3) * to_integer(tooth_period) * 1000 ns;

        assert signal_present = '0'
            report "FAIL T7: signal_present did not go low after timeout"
            severity error;

        report "TEST 7: PASS - signal_present timed out correctly";

        -- --------------------------------------------------------------------
        -- TEST 8: Signal present recovers after timeout
        -- --------------------------------------------------------------------
        report "TEST 8: Signal present recovery";
        test_num <= 8;
        
        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        gen_crank_cycle(clean_signal, PERIOD_1000_RPM, true);

        assert signal_present = '1'
            report "FAIL T8: signal_present did not recover"
            severity error;

        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- TEST 9: Z pulse fires once per cycle only
        -- Run 3 cycles and verify exactly 3 Z pulses
        -- --------------------------------------------------------------------
        report "TEST 9: Z pulse fires once per cycle";
        test_num <= 9;

        -- Reset crank_input module
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';

        z_count_start := z_count;

        for i in 1 to 3 loop
            gen_crank_cycle(clean_signal, PERIOD_1000_RPM, true);
        end loop;

        wait for PERIOD_1000_RPM;

        -- since Z won't occur on the 1st cycle, we should have 2 pulses
        assert (z_count - z_count_start) = 2
            report "FAIL T9: Z pulse count = " &
                   integer'image(z_count - z_count_start) &
                   " expected 2"
            severity error;

        report "TEST 9: PASS - Z fired " &
               integer'image(z_count - z_count_start) & " times in 3 cycles";

        
        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "Tests from crank_input_tb complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor: count AB toggles and Z pulses
    -- Uses registered previous values for edge detection inside clocked process
    -- -------------------------------------------------------------------------
    p_monitor : process(clk)
        variable ab_prev : std_logic := '0';
        variable z_prev  : std_logic := '0';
    begin
        if rising_edge(clk) then
            -- AB toggle detection
            if ab /= ab_prev then
                ab_count <= ab_count + 1;
            end if;
            ab_prev := ab;

            -- Z rising edge detection
            if z = '1' and z_prev = '0' then
                z_count <= z_count + 1;
                report "Z PULSE: tooth_count = " &
                       integer'image(to_integer(tooth_count));
            end if;
            z_prev := z;
        end if;
    end process p_monitor;

end architecture sim;