library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- peak_detector_tb
-- T1: rising signal arms detector, no peak fires while rising
-- T2: peak fires when signal drops below max - hyst
-- T3: peak_edge pulse lasts peak_pulse_cycles clocks
-- T4: after peak, detector re-arms on next rise
-- T5: z_edge resets detector, suppresses peak in same cycle
-- =============================================================================
entity peak_detector_tb is end entity;
architecture sim of peak_detector_tb is
    constant CLK_PERIOD    : time    := 10 ns;
    constant HYST_VAL      : integer := 100;
    constant PULSE_CYCLES  : integer := 5;

    signal clk        : std_logic := '0';
    signal done       : boolean   := false;
    signal rst        : std_logic := '1';
    signal adc_val    : unsigned(11 downto 0) := (others => '0');
    signal z_edge     : std_logic := '0';
    signal peak_hyst  : unsigned(15 downto 0) := to_unsigned(HYST_VAL, 16);
    signal pulse_cyc  : unsigned(15 downto 0) := to_unsigned(PULSE_CYCLES, 16);
    signal peak_edge  : std_logic;

    procedure set_adc(val : integer; signal s : out unsigned(11 downto 0);
                      signal c : in std_logic) is
    begin
        s <= to_unsigned(val, 12);
        wait until rising_edge(c);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';

    dut : entity work.peak_detector
        port map (clk=>clk, rst=>rst, adc_val=>adc_val, z_edge=>z_edge,
                  peak_hyst=>peak_hyst, peak_pulse_cycles=>pulse_cyc,
                  peak_edge=>peak_edge);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: rising signal arms detector, no peak while rising
        set_adc(100, adc_val, clk); wait for 1 ns;
        assert peak_edge = '0' report "FAIL T1: peak on first sample" severity failure;
        set_adc(200, adc_val, clk); wait for 1 ns;
        assert peak_edge = '0' report "FAIL T1: peak while rising" severity failure;
        set_adc(500, adc_val, clk); wait for 1 ns;
        assert peak_edge = '0' report "FAIL T1: peak at max" severity failure;
        report "T1: PASS";

        -- T2: peak fires when signal drops below max(500) - hyst(100) = 400
        set_adc(450, adc_val, clk); wait for 1 ns;
        assert peak_edge = '0' report "FAIL T2: peak fired above threshold (450>400)" severity failure;
        set_adc(399, adc_val, clk); wait for 1 ns;
        assert peak_edge = '1' report "FAIL T2: peak not fired below threshold (399<400)" severity failure;
        report "T2: PASS";

        -- T3: pulse lasts PULSE_CYCLES clocks
        wait for (PULSE_CYCLES - 1) * CLK_PERIOD;
        wait for 1 ns;
        assert peak_edge = '1' report "FAIL T3: pulse ended early" severity failure;
        wait for CLK_PERIOD;
        wait for 1 ns;
        assert peak_edge = '0' report "FAIL T3: pulse did not end after PULSE_CYCLES" severity failure;
        report "T3: PASS";

        -- T4: detector re-arms after reset, fires again on next peak
        set_adc(0,   adc_val, clk);  -- stay low
        set_adc(300, adc_val, clk);  -- rise again
        set_adc(600, adc_val, clk);  -- new max
        set_adc(499, adc_val, clk); wait for 1 ns;  -- 499 < 600-100=500, fires
        assert peak_edge = '1' report "FAIL T4: second peak not detected" severity failure;
        wait for (PULSE_CYCLES + 1) * CLK_PERIOD;
        report "T4: PASS";

        -- T5: z_edge resets detector
        -- First let adc settle to 0 to avoid re-arming during T4 pulse drain
        set_adc(0, adc_val, clk);
        wait for 3 * CLK_PERIOD;  -- let any residual state clear
        -- Now arm with a high value
        set_adc(800, adc_val, clk);  -- max_val becomes 800, armed=1
        -- Fire z_edge to reset
        z_edge <= '1'; wait until rising_edge(clk); z_edge <= '0';
        -- Immediately set low value -- should NOT fire (max was reset by z_edge)
        set_adc(0, adc_val, clk);  -- adc=0, max=0 (from z_edge), armed=0
        wait for CLK_PERIOD;
        wait for 1 ns;
        assert peak_edge = '0' report "FAIL T5: peak fired after z_edge reset" severity failure;
        report "T5: PASS";

        report "All peak_detector tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
