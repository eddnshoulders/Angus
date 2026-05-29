library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity peak_detector_tb is end entity;
architecture sim of peak_detector_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal done      : boolean := false;
    signal rst       : std_logic := '1';
    signal adc_data  : unsigned(11 downto 0) := (others => '0');
    signal adc_valid : std_logic := '0';
    signal peak_edge : std_logic;

    procedure send_sample(val : integer; signal d : out unsigned(11 downto 0);
                          signal v : out std_logic; signal c : in std_logic) is
    begin
        d <= to_unsigned(val, 12);
        v <= '1'; wait until rising_edge(c); v <= '0'; wait until rising_edge(c);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.peak_detector port map(clk=>clk, rst=>rst, adc_data=>adc_data,
        adc_valid=>adc_valid, peak_edge=>peak_edge);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: rising samples, no peak
        send_sample(100, adc_data, adc_valid, clk);
        send_sample(200, adc_data, adc_valid, clk);
        send_sample(300, adc_data, adc_valid, clk);
        wait for 1 ns;
        assert peak_edge = '0' report "FAIL T1: spurious peak on rising" severity failure;
        report "T1: PASS";

        -- T2: peak at transition from rising to falling
        -- Drive sample manually to check peak_edge at the right clock cycle
        adc_data <= to_unsigned(200, 12);
        adc_valid <= '1'; wait until rising_edge(clk); wait for 1 ns;
        assert peak_edge = '1' report "FAIL T2: peak not detected" severity failure;
        adc_valid <= '0'; wait until rising_edge(clk);
        report "T2: PASS";

        -- T3: falling samples, no further peak
        send_sample(100, adc_data, adc_valid, clk);
        wait for 1 ns;
        assert peak_edge = '0' report "FAIL T3: spurious peak on falling" severity failure;
        report "T3: PASS";

        -- T4: second peak
        send_sample(400, adc_data, adc_valid, clk);
        send_sample(500, adc_data, adc_valid, clk);
        adc_data <= to_unsigned(400, 12);
        adc_valid <= '1'; wait until rising_edge(clk); wait for 1 ns;
        assert peak_edge = '1' report "FAIL T4: second peak not detected" severity failure;
        adc_valid <= '0'; wait until rising_edge(clk);
        report "T4: PASS";

        report "All peak_detector tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
