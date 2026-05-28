library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity signal_conditioner_tb is
end entity signal_conditioner_tb;

architecture sim of signal_conditioner_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD      : time    := 1000 ns;   -- 1MHz sim clock
    constant DEBOUNCE_CYCLES : integer := 5;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal raw_signal     : std_logic := '0';
    signal clean_signal   : std_logic;
    signal signal_stable  : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done       : boolean   := false;
    signal test_num       : integer   := 0;

    -- -------------------------------------------------------------------------
    -- Generate a clean pulse of given width and polarity
    -- -------------------------------------------------------------------------
    procedure gen_pulse(
        signal   sig       : out std_logic;
        constant width     : in  time;
        constant pol       : in  std_logic   -- '1' = high pulse, '0' = low pulse
    ) is
    begin
        sig <= pol;
        wait for width;
        sig <= not pol;
    end procedure gen_pulse;

    -- -------------------------------------------------------------------------
    -- Generate a glitch shorter than debounce window
    -- -------------------------------------------------------------------------
    procedure gen_glitch(
        signal   sig       : out std_logic;
        constant pol       : in  std_logic
    ) is
    begin
        sig <= pol;
        wait for (DEBOUNCE_CYCLES - 2) * CLK_PERIOD;
        sig <= not pol;
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
    dut : entity work.signal_conditioner
        generic map (
            DEBOUNCE_CYCLES => DEBOUNCE_CYCLES
        )
        port map (
            clk            => clk,
            rst            => rst,
            raw_signal     => raw_signal,
            clean_signal   => clean_signal,
            signal_stable  => signal_stable
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num   <= 1;

        rst        <= '1';
        raw_signal <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert clean_signal = '0'
            report "FAIL T1: clean_signal should be low after reset"
            severity failure;
        assert signal_stable = '1'
            report "FAIL T1: signal_stable should be high after reset"
            severity failure;
        report "TEST 1: PASS";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: Rising edge passes through cleanly
        -- --------------------------------------------------------------------
        report "TEST 2: Rising edge passes through";
        test_num <= 2;

        raw_signal <= '1';
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        assert clean_signal = '1'
            report "FAIL T2: clean_signal should be high after rising edge"
            severity failure;
        report "TEST 2: PASS";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: Falling edge passes through cleanly
        -- --------------------------------------------------------------------
        report "TEST 3: Falling edge passes through";
        test_num <= 3;

        raw_signal <= '0';
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        assert clean_signal = '0'
            report "FAIL T3: clean_signal should be low after falling edge"
            severity failure;
        report "TEST 3: PASS";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Glitch rejection on rising edge
        -- --------------------------------------------------------------------
        report "TEST 4: Glitch rejection on rising edge";
        test_num <= 4;

        gen_glitch(raw_signal, '1');
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        assert clean_signal = '0'
            report "FAIL T4: rising glitch passed debounce filter"
            severity failure;
        report "TEST 4: PASS";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Glitch rejection on falling edge
        -- --------------------------------------------------------------------
        report "TEST 5: Glitch rejection on falling edge";
        test_num <= 5;

        -- First get signal high cleanly
        raw_signal <= '1';
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        -- Now glitch low
        gen_glitch(raw_signal, '0');
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        assert clean_signal = '1'
            report "FAIL T5: falling glitch passed debounce filter"
            severity failure;
        report "TEST 5: PASS";

        -- Return to low for next test
        raw_signal <= '0';
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: signal_stable goes low during debounce window
        -- --------------------------------------------------------------------
        report "TEST 6: signal_stable low during debounce window";
        test_num <= 6;

        -- Start a transition
        raw_signal <= '1';

        -- Check signal_stable goes low immediately
        wait for 4 * CLK_PERIOD;
        assert signal_stable = '0'
            report "FAIL T6: signal_stable should be low during debounce"
            severity failure;

        -- Wait for debounce to complete
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;
        assert signal_stable = '1'
            report "FAIL T6: signal_stable should be high after debounce"
            severity failure;

        report "TEST 6: PASS";

        -- Return to low
        raw_signal <= '0';
        wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: Multiple transitions, signal follows cleanly
        -- --------------------------------------------------------------------
        report "TEST 7: Multiple transitions follow cleanly";
        test_num <= 7;

        for i in 1 to 5 loop
            raw_signal <= '1';
            wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;
            assert clean_signal = '1'
                report "FAIL T7: clean_signal should be high, iteration " &
                       integer'image(i)
                severity failure;

            raw_signal <= '0';
            wait for (DEBOUNCE_CYCLES + 5) * CLK_PERIOD;
            assert clean_signal = '0'
                report "FAIL T7: clean_signal should be low, iteration " &
                       integer'image(i)
                severity failure;
        end loop;

        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "All signal_conditioner tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process
    begin
        wait until rising_edge(clk);
        if clean_signal'event then
            report "EDGE: clean_signal = " & std_logic'image(clean_signal) &
                   "  signal_stable = " & std_logic'image(signal_stable);
        end if;
    end process p_monitor;

end architecture sim;