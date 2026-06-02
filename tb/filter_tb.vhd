library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity filter_tb is
end entity filter_tb;

architecture sim of filter_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- clk_period chosen so debounce timing is easy to reason about.
    -- DEBOUNCE is the runtime-configurable debounce count.
    -- Total settling time from raw change to clean change:
    --   2 cycles (2-FF synchroniser) + DEBOUNCE cycles = SETTLE cycles.
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time    := 10 ns;   -- 100 MHz
    constant DEBOUNCE   : integer := 4;
    constant SETTLE     : integer := 2 + DEBOUNCE;   -- 6 cycles

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal raw             : std_logic := '0';
    signal debounce_cycles : unsigned(15 downto 0) := to_unsigned(DEBOUNCE, 16);
    signal clean           : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Apply a clean stable pulse of given polarity and duration
    -- -------------------------------------------------------------------------
    procedure gen_pulse(
        signal   sig   : out std_logic;
        constant pol   : in  std_logic;
        constant width : in  integer      -- width in clock cycles
    ) is
    begin
        sig <= pol;
        wait for width * CLK_PERIOD;
        sig <= not pol;
    end procedure gen_pulse;

    -- -------------------------------------------------------------------------
    -- Apply a glitch shorter than the debounce window (DEBOUNCE - 2 cycles)
    -- -------------------------------------------------------------------------
    procedure gen_glitch(
        signal   sig : out std_logic;
        constant pol : in  std_logic
    ) is
    begin
        sig <= pol;
        wait for (DEBOUNCE - 2) * CLK_PERIOD;
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
    dut : entity work.filter
        port map (
            clk             => clk,
            rst             => rst,
            raw             => raw,
            debounce_cycles => debounce_cycles,
            clean           => clean
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- clean should remain low after reset regardless of raw input
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1';
        raw <= '1';   -- raw driven high during reset
        wait for 10 * CLK_PERIOD;

        assert clean = '0'
            report "FAIL T1: clean should be low while in reset"
            severity failure;

        rst <= '0';
        raw <= '0';
        wait for 5 * CLK_PERIOD;

        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Rising edge passes through after debounce settling time
        -- raw goes high; clean must not change before SETTLE cycles,
        -- and must be high after SETTLE + margin cycles.
        -- --------------------------------------------------------------------
        report "TEST 2: Rising edge passes through after debounce";
        test_num <= 2;

        raw <= '1';
        wait for (SETTLE - 2) * CLK_PERIOD;

        assert clean = '0'
            report "FAIL T2: clean went high before debounce settled"
            severity failure;

        wait for 4 * CLK_PERIOD;   -- now well past SETTLE

        assert clean = '1'
            report "FAIL T2: clean did not go high after debounce"
            severity failure;

        report "TEST 2: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: Falling edge passes through after debounce settling time
        -- --------------------------------------------------------------------
        report "TEST 3: Falling edge passes through after debounce";
        test_num <= 3;

        raw <= '0';
        wait for (SETTLE - 2) * CLK_PERIOD;

        assert clean = '1'
            report "FAIL T3: clean went low before debounce settled"
            severity failure;

        wait for 4 * CLK_PERIOD;

        assert clean = '0'
            report "FAIL T3: clean did not go low after debounce"
            severity failure;

        report "TEST 3: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Rising glitch shorter than debounce window is rejected
        -- raw is currently low; apply a short high glitch
        -- --------------------------------------------------------------------
        report "TEST 4: Rising glitch rejected";
        test_num <= 4;

        gen_glitch(raw, '1');
        wait for (SETTLE + 5) * CLK_PERIOD;

        assert clean = '0'
            report "FAIL T4: rising glitch passed debounce filter"
            severity failure;

        report "TEST 4: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Falling glitch shorter than debounce window is rejected
        -- first get raw cleanly high, then apply a short low glitch
        -- --------------------------------------------------------------------
        report "TEST 5: Falling glitch rejected";
        test_num <= 5;

        raw <= '1';
        wait for (SETTLE + 5) * CLK_PERIOD;   -- clean now high

        gen_glitch(raw, '0');
        wait for (SETTLE + 5) * CLK_PERIOD;

        assert clean = '1'
            report "FAIL T5: falling glitch passed debounce filter"
            severity failure;

        raw <= '0';
        wait for (SETTLE + 5) * CLK_PERIOD;   -- clean back low

        report "TEST 5: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: Multiple clean transitions follow correctly
        -- --------------------------------------------------------------------
        report "TEST 6: Multiple clean transitions";
        test_num <= 6;

        for i in 1 to 4 loop
            raw <= '1';
            wait for (SETTLE + 5) * CLK_PERIOD;
            assert clean = '1'
                report "FAIL T6: clean should be high, iteration " &
                       integer'image(i)
                severity failure;

            raw <= '0';
            wait for (SETTLE + 5) * CLK_PERIOD;
            assert clean = '0'
                report "FAIL T6: clean should be low, iteration " &
                       integer'image(i)
                severity failure;
        end loop;

        report "TEST 6: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: Runtime debounce_cycles change takes effect
        -- increase debounce from 4 to 12; verify that a pulse that would
        -- have passed with debounce=4 is now rejected with debounce=12
        -- --------------------------------------------------------------------
        report "TEST 7: Runtime debounce_cycles change";
        test_num <= 7;

        debounce_cycles <= to_unsigned(12, 16);
        wait for 2 * CLK_PERIOD;   -- let new value register

        -- pulse of SETTLE (=6) cycles used to pass with debounce=4
        -- but with debounce=12 settle time is 2+12=14 cycles so it must not pass
        raw <= '1';
        wait for SETTLE * CLK_PERIOD;

        assert clean = '0'
            report "FAIL T7: pulse passed with increased debounce=12 (settle not reached)"
            severity failure;

        -- wait the additional time to reach new settle (14 cycles total)
        wait for 10 * CLK_PERIOD;

        assert clean = '1'
            report "FAIL T7: clean did not go high after new debounce settled"
            severity failure;

        raw <= '0';
        wait for 20 * CLK_PERIOD;
        debounce_cycles <= to_unsigned(DEBOUNCE, 16);   -- restore

        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "All filter tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor -- reports every time clean changes
    -- -------------------------------------------------------------------------
    p_monitor : process(clean)
    begin
        if clean'event then
            report "EDGE: clean = " & std_logic'image(clean) &
                   "  test = " & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
