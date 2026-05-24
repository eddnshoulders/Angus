library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity tooth_detector_tb is
end entity tooth_detector_tb;

architecture sim of tooth_detector_tb is

    -- -------------------------------------------------------------------------
    -- Simulation clock is 1MHz (1000ns period) instead of 100MHz
    -- Keeps simulation time reasonable while testing the same logic
    -- All cycle counts scale proportionally
    -- -------------------------------------------------------------------------
    constant CLK_FREQ_HZ     : integer := 1_000_000;
    constant CLK_PERIOD      : time    := 1000 ns;
    constant DEBOUNCE_CYCLES : integer := 5;
    constant TIMEOUT_CYCLES  : integer := 10_000;   -- 10ms at 1MHz

    constant TEETH_REAL      : integer := 58;

    -- Tooth periods as time values, avoids integer overflow
    -- 1000 RPM: 60s / (1000 * 60 teeth) = 1ms per tooth
    -- 2000 RPM: 60s / (2000 * 60 teeth) = 500us per tooth
    constant PERIOD_1000_RPM : time := 1_000_000 ns;
    constant PERIOD_2000_RPM : time :=   500_000 ns;

    -- Expected tooth periods in clock cycles at 1MHz
    -- 1000 RPM: 1ms / 1000ns = 1000 cycles
    -- 2000 RPM: 500us / 1000ns = 500 cycles
    constant EXP_PERIOD_1000 : integer := 1_000;
    constant EXP_PERIOD_2000 : integer :=   500;

    -- Tolerance in clock cycles
    constant PERIOD_TOL      : integer := 5;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal crank_in       : std_logic := '0';
    signal edge_rising    : std_logic := '1';
    signal tooth_detected : std_logic;
    signal tooth_period   : unsigned(31 downto 0);
    signal signal_present : std_logic := '0';
    
    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done    : boolean := false;
    signal tooth_count : integer := 0;
    signal test_num    : integer := 0;

    -- -------------------------------------------------------------------------
    -- Generate one complete 60-2 crank cycle
    -- t_period: wall-clock time between tooth edges
    -- rising_ed: true = rising edge teeth, false = falling edge teeth
    -- -------------------------------------------------------------------------
    procedure gen_crank_cycle(
        signal   crank     : out std_logic;
        constant t_period  : in  time;
        constant rising_ed : in  boolean
    ) is
        constant t_pulse : time := t_period / 2;
    begin
        for i in 1 to TEETH_REAL loop
            if rising_ed then
                crank <= '1'; wait for t_pulse;
                crank <= '0'; wait for t_pulse;
            else
                crank <= '0'; wait for t_pulse;
                crank <= '1'; wait for t_pulse;
            end if;
        end loop;

        -- Missing tooth gap: hold inactive for 3 tooth periods
        if rising_ed then
            crank <= '0'; wait for t_period * 3;
        else
            crank <= '1'; wait for t_period * 3;
        end if;
    end procedure gen_crank_cycle;

    -- -------------------------------------------------------------------------
    -- Generate a glitch shorter than debounce window
    -- -------------------------------------------------------------------------
    procedure gen_glitch(
        signal   crank     : out std_logic;
        constant rising_ed : in  boolean
    ) is
    begin
        if rising_ed then
            crank <= '1'; wait for 3 * CLK_PERIOD;
            crank <= '0';
        else
            crank <= '0'; wait for 3 * CLK_PERIOD;
            crank <= '1';
        end if;
    end procedure gen_glitch;

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
    dut : entity work.tooth_detector
        generic map (
            CLK_FREQ_HZ     => CLK_FREQ_HZ,
            DEBOUNCE_CYCLES => DEBOUNCE_CYCLES,
            TIMEOUT_CYCLES  => TIMEOUT_CYCLES
        )
        port map (
            clk            => clk,
            rst            => rst,
            crank_in       => crank_in,
            edge_rising    => edge_rising,
            tooth_detected => tooth_detected,
            tooth_period   => tooth_period,
            signal_present => signal_present
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable period_error : integer;
        variable count_start  : integer := 0;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;
        rst      <= '1';
        crank_in <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert tooth_detected = '0'
            report "FAIL T1: tooth_detected should be low after reset"
            severity error;
        assert signal_present = '0'
            report "FAIL T1: signal_present should be low after reset"
            severity error;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Period measurement at 1000 RPM
        -- Send two teeth, sample period on the clock edge when tooth_detected
        -- is high to guarantee we capture the latched value
        -- --------------------------------------------------------------------
        report "TEST 2: Period measurement at 1000 RPM";
        test_num <= 2; 

        -- get the current tooth_count 
        count_start := tooth_count;

        -- First tooth: starts the period counter
        crank_in <= '1'; wait for PERIOD_1000_RPM / 2;
        crank_in <= '0'; wait for PERIOD_1000_RPM / 2;

        -- Second tooth: period is latched on this edge
        crank_in <= '1'; wait for PERIOD_1000_RPM / 2;
        crank_in <= '0';

        -- check number of teeth detected is correct
        wait for 10 * CLK_PERIOD;
        assert (tooth_count - count_start) = 2
            report "FAIL T2: Didn't detect 2 teeth. Detected " & integer'image(tooth_count - count_start)
            severity error;

        period_error := abs(to_integer(tooth_period) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T2: period error = " & integer'image(period_error) &
                   " cycles, got " & integer'image(to_integer(tooth_period)) &
                   " expected ~" & integer'image(EXP_PERIOD_1000)
            severity error;

        assert signal_present = '1'
            report "FAIL T2: signal_present should be high"
            severity error;

        report "TEST 2: PASS - period = " &
               integer'image(to_integer(tooth_period)) &
               " cycles (expected " & integer'image(EXP_PERIOD_1000) & ")";

        wait for PERIOD_1000_RPM;

        -- --------------------------------------------------------------------
        -- TEST 3: Glitch rejection
        -- --------------------------------------------------------------------
        report "TEST 3: Glitch rejection";
        test_num <= 3;

        gen_glitch(crank_in, true);
        wait for 10 * CLK_PERIOD;

        assert tooth_detected = '0'
            report "FAIL T3: glitch passed debounce filter"
            severity error;

        report "TEST 3: PASS";

        wait for PERIOD_1000_RPM;

        -- --------------------------------------------------------------------
        -- TEST 4: Full 60-2 cycle at 1000 RPM
        -- signal_present should remain high throughout
        -- --------------------------------------------------------------------
        report "TEST 4: Full 60-2 cycle at 1000 RPM";
        test_num <= 4;

        gen_crank_cycle(crank_in, PERIOD_1000_RPM, true);

        assert signal_present = '1'
            report "FAIL T4: signal_present dropped during crank signal"
            severity error;

        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: RPM change 1000 to 2000 RPM
        -- --------------------------------------------------------------------
        report "TEST 5: RPM change 1000 to 2000 RPM";
        test_num <= 5;

        -- get the current tooth count
        count_start := tooth_count;

        gen_crank_cycle(crank_in, PERIOD_1000_RPM, true);
        gen_crank_cycle(crank_in, PERIOD_2000_RPM, true);

        -- check number of teeth detected is correct
        wait for 10 * CLK_PERIOD;
        assert (tooth_count - count_start) = 116
            report "FAIL T5: Didn't detect 116 teeth. Detected " & integer'image(tooth_count - count_start)
            severity error;

        period_error := abs(to_integer(tooth_period) - EXP_PERIOD_2000);
        assert period_error <= PERIOD_TOL
            report "FAIL T5: period error after RPM change = " &
                   integer'image(period_error) & " cycles, got " &
                   integer'image(to_integer(tooth_period)) &
                   " expected ~" & integer'image(EXP_PERIOD_2000)
            severity error;

        report "TEST 5: PASS - period at 2000 RPM = " &
               integer'image(to_integer(tooth_period)) &
               " cycles (expected " & integer'image(EXP_PERIOD_2000) & ")";

        -- Finish the current cycle
        --gen_crank_cycle(crank_in, PERIOD_2000_RPM, true);

        -- --------------------------------------------------------------------
        -- TEST 6: Timeout - signal_present goes low
        -- --------------------------------------------------------------------
        report "TEST 6: Timeout - signal_present goes low";
        test_num <= 6;

        gen_crank_cycle(crank_in, PERIOD_1000_RPM, true);

        assert signal_present = '1'
            report "FAIL T6 setup: signal_present not high before timeout test"
            severity error;

        -- Stop crank signal and wait for timeout plus margin
        crank_in <= '0';
        wait for (TIMEOUT_CYCLES + 100) * CLK_PERIOD;

        assert signal_present = '0'
            report "FAIL T6: signal_present did not go low after timeout"
            severity error;

        report "TEST 6: PASS - signal_present went low after timeout";

        -- --------------------------------------------------------------------
        -- TEST 7: Recovery after timeout
        -- --------------------------------------------------------------------
        report "TEST 7: Signal recovery after timeout";
        test_num <= 7;

        gen_crank_cycle(crank_in, PERIOD_1000_RPM, true);

        assert signal_present = '1'
            report "FAIL T7: signal_present did not recover"
            severity error;

        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- TEST 8: Falling edge polarity
        -- Switch edge_rising to '0', verify teeth still detected
        -- --------------------------------------------------------------------
        report "TEST 8: Falling edge polarity";
        test_num <= 8;

        -- get the current tooth_count 
        count_start := tooth_count;
        
        -- set high gap state, then change edge detection polarity and run cycle
        crank_in <= '1';
        edge_rising <= '0';
        wait for 2_000 * CLK_PERIOD;
        gen_crank_cycle(crank_in, PERIOD_1000_RPM, false);

        -- check number of teeth detected is correct
        wait for 10 * CLK_PERIOD;
        assert (tooth_count - count_start) = 58
            report "FAIL T8: Didn't detect 58 teeth. Detected " & integer'image(tooth_count - count_start)
            severity error;

        period_error := abs(to_integer(tooth_period) - EXP_PERIOD_1000);
        assert period_error <= PERIOD_TOL
            report "FAIL T8: period error with falling edge = " &
                   integer'image(period_error) & " cycles"
            severity error;

        report "TEST 8: PASS - falling edge polarity works correctly";

        -- Restore rising edge for waveform check
        edge_rising <= '1';
        wait for CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 9: Missing tooth gap visible in waveform
        -- --------------------------------------------------------------------
        report "TEST 9: Missing tooth gap - check waveform";
        test_num <= 9;
        report "  Normal period = " & integer'image(EXP_PERIOD_1000) & " cycles";
        report "  Gap period    = " & integer'image(EXP_PERIOD_1000 * 3) &
               " cycles approx";

        gen_crank_cycle(crank_in, PERIOD_1000_RPM, true);

        report "TEST 9: Check waveform for tooth_period spike at missing tooth gap";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "All tooth_detector tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor: log every tooth detection to transcript
    -- -------------------------------------------------------------------------
    p_monitor : process
    begin
        wait until rising_edge(clk);
        if tooth_detected = '1' then
            tooth_count <= tooth_count + 1;
            --report "TOOTH: period = " &
            --       integer'image(to_integer(tooth_period)) &
            --       " cycles  signal_present = " &
            --       std_logic'image(signal_present);
        end if;
    end process p_monitor;

end architecture sim;