library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity peak_detector_tb is
end entity peak_detector_tb;

architecture sim of peak_detector_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- HYST_VAL:     hysteresis count.  Peak fires when adc_val < max - HYST_VAL
    -- PULSE_CYCLES: how many clocks peak_edge stays high after detection
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 10 ns;
    constant HYST_VAL     : integer := 100;
    constant PULSE_CYCLES : integer := 5;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal adc_val   : unsigned(11 downto 0) := (others => '0');
    signal z_edge    : std_logic := '0';
    signal peak_hyst : unsigned(15 downto 0) := to_unsigned(HYST_VAL, 16);
    signal pulse_cyc : unsigned(15 downto 0) := to_unsigned(PULSE_CYCLES, 16);
    signal peak_edge : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Set ADC value and wait for one clock
    -- -------------------------------------------------------------------------
    procedure set_adc(
        constant val : in  integer;
        signal   sig : out unsigned(11 downto 0);
        signal   c   : in  std_logic
    ) is
    begin
        sig <= to_unsigned(val, 12);
        wait until rising_edge(c);
        wait for 1 ns;
    end procedure set_adc;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock z_edge strobe
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   z   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
        wait for 1 ns;
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
    dut : entity work.peak_detector
        port map (
            clk              => clk,
            rst              => rst,
            adc_val          => adc_val,
            z_edge           => z_edge,
            peak_hyst        => peak_hyst,
            peak_pulse_cycles => pulse_cyc,
            peak_edge        => peak_edge
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour -- no peak on startup
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert peak_edge = '0'
            report "FAIL T1: peak_edge should be low after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Rising signal arms detector -- no peak while signal is rising
        -- --------------------------------------------------------------------
        report "TEST 2: Rising signal arms detector, no peak while rising";
        test_num <= 2;

        set_adc(100, adc_val, clk);
        assert peak_edge = '0'
            report "FAIL T2: peak on first sample" severity failure;

        set_adc(300, adc_val, clk);
        assert peak_edge = '0'
            report "FAIL T2: peak while rising" severity failure;

        set_adc(500, adc_val, clk);
        assert peak_edge = '0'
            report "FAIL T2: peak at new maximum" severity failure;

        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Peak fires when signal drops below max - hysteresis
        -- With max=500 and HYST_VAL=100: threshold = 400
        -- 450 > 400 so no peak; 399 < 400 so peak fires
        -- --------------------------------------------------------------------
        report "TEST 3: Peak fires at max - hysteresis threshold";
        test_num <= 3;

        set_adc(450, adc_val, clk);
        assert peak_edge = '0'
            report "FAIL T3: peak fired above threshold (450 > 400)"
            severity failure;

        set_adc(399, adc_val, clk);
        assert peak_edge = '1'
            report "FAIL T3: peak not fired below threshold (399 < 400)"
            severity failure;

        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: Peak pulse lasts exactly PULSE_CYCLES clocks
        -- --------------------------------------------------------------------
        report "TEST 4: Peak pulse width = PULSE_CYCLES clocks";
        test_num <= 4;

        -- peak_edge is already high from T3; check it stays high for PULSE_CYCLES
        wait for (PULSE_CYCLES - 2) * CLK_PERIOD;
        wait for 1 ns;
        assert peak_edge = '1'
            report "FAIL T4: pulse ended early (before PULSE_CYCLES)"
            severity failure;

        wait for 2 * CLK_PERIOD;
        wait for 1 ns;
        assert peak_edge = '0'
            report "FAIL T4: pulse did not end after PULSE_CYCLES clocks"
            severity failure;

        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: Detector re-arms after peak and fires a second peak
        -- After T4: adc=399, max=399, armed=1 (re-armed during T4 wait), threshold=299
        -- Raise to new max (600), verify no peak at 501, peak at 499
        -- --------------------------------------------------------------------
        report "TEST 5: Detector re-arms and fires a second peak";
        test_num <= 5;

        set_adc(600, adc_val, clk);  -- 600>399=max: max=600, armed=1, threshold=500
        set_adc(501, adc_val, clk);  -- 501 >= 500: no peak
        wait for 1 ns;
        assert peak_edge = '0'
            report "FAIL T5: peak fired above threshold (501 >= 500)"
            severity failure;

        set_adc(499, adc_val, clk);  -- 499 < 500: peak fires
        wait for 1 ns;
        assert peak_edge = '1'
            report "FAIL T5: second peak not detected (499 < 500)"
            severity failure;

        wait for (PULSE_CYCLES + 1) * CLK_PERIOD;
        -- After pulse: max=0 (reset by peak), then re-armed to 499 (adc stays at 499)
        -- After wait: adc=499, max=499, armed=1, threshold=399

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: z_edge resets detector
        -- State: adc=499, max=499, armed=1, threshold=399
        -- Fire z_edge while adc=499 > threshold (399) so no peak fires on OLD state
        -- Drop adc=0 simultaneously when z_edge goes low -- OLD_armed=0 at that clock
        -- --------------------------------------------------------------------
        report "TEST 6: z_edge resets detector";
        test_num <= 6;

        -- z_edge='1' with adc=499 (above threshold 399): reset fires, no peak
        z_edge <= '1';
        wait until rising_edge(clk);
        -- Clock: z_edge=1, adc=499, OLD_armed=1. 499<399? NO. Reset: max<=0,armed<=0.

        -- Drop adc to 0 at the SAME clock as z_edge='0'
        -- OLD_max=0, OLD_armed=0 at this clock so no peak and no re-arm
        z_edge <= '0';
        adc_val <= to_unsigned(0, 12);
        wait until rising_edge(clk);
        -- Clock: z_edge=0, adc=0, OLD_max=0, OLD_armed=0. 0>0? No. No re-arm.
        wait for 1 ns;

        assert peak_edge = '0'
            report "FAIL T6: peak fired after z_edge reset"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: peak_hyst=0 fires on any drop below maximum
        -- --------------------------------------------------------------------
        report "TEST 7: peak_hyst=0 fires on any drop below maximum";
        test_num <= 7;

        peak_hyst <= to_unsigned(0, 16);
        set_adc(0,   adc_val, clk);   -- reset max
        wait for 3 * CLK_PERIOD;

        set_adc(200, adc_val, clk);   -- arms at 200
        set_adc(199, adc_val, clk);   -- 199 < 200 - 0 = 200, fires

        assert peak_edge = '1'
            report "FAIL T7: peak not fired with hyst=0"
            severity failure;

        peak_hyst <= to_unsigned(HYST_VAL, 16);   -- restore
        wait for (PULSE_CYCLES + 1) * CLK_PERIOD;
        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All peak_detector tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(peak_edge)
    begin
        if peak_edge = '1' then
            report "PEAK_EDGE fired  adc=" &
                   integer'image(to_integer(adc_val)) &
                   "  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
