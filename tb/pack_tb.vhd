library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity pack_tb is end entity;
architecture sim of pack_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal trig_pulse : std_logic := '0';
    signal ang_deg    : unsigned(15 downto 0) := to_unsigned(1234, 16);
    signal speed      : unsigned(15 downto 0) := to_unsigned(3000, 16);
    signal di_ch      : std_logic_vector(7 downto 0) := x"A5";
    signal adc1       : unsigned(11 downto 0) := to_unsigned(100, 12);
    signal adc2       : unsigned(11 downto 0) := to_unsigned(200, 12);
    signal adc3       : unsigned(11 downto 0) := to_unsigned(300, 12);
    signal adc4       : unsigned(11 downto 0) := to_unsigned(400, 12);
    signal adc5       : unsigned(11 downto 0) := to_unsigned(500, 12);
    signal adc6       : unsigned(11 downto 0) := to_unsigned(600, 12);
    signal z_edge     : std_logic := '0';
    signal buf_size   : unsigned(3 downto 0) := to_unsigned(2, 4);
    signal tdata      : std_logic_vector(31 downto 0);
    signal tvalid     : std_logic;
    signal tready     : std_logic := '1';
    signal tlast      : std_logic;
    signal pkt_cnt    : unsigned(31 downto 0);
    signal ovf_cnt    : unsigned(15 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.pack port map(clk=>clk, rst=>rst, trig_pulse=>trig_pulse,
        ang_deg=>ang_deg, speed_rpm_fast=>speed, di_ch=>di_ch,
        adc_ch1=>adc1, adc_ch2=>adc2, adc_ch3=>adc3, adc_ch4=>adc4,
        adc_ch5=>adc5, adc_ch6=>adc6, z_edge=>z_edge,
        dma_buffer_size=>buf_size, m_axis_tdata=>tdata, m_axis_tvalid=>tvalid,
        m_axis_tready=>tready, m_axis_tlast=>tlast, pkt_count=>pkt_cnt,
        ovf_count=>ovf_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: trig_pulse starts a 5-word AXI stream packet
        trig_pulse <= '1'; wait for CLK_PERIOD; trig_pulse <= '0';
        -- Wait for WORD0 to appear
        wait until tvalid = '1';
        wait for 1 ns;
        -- Word0: ang_deg | speed
        assert tdata = std_logic_vector(to_unsigned(1234, 16)) & std_logic_vector(to_unsigned(3000, 16))
            report "FAIL T1: word0 wrong" severity failure;
        assert tlast = '0' report "FAIL T1: tlast set too early" severity failure;
        -- Clock through remaining words
        wait until rising_edge(clk); wait for 1 ns;  -- Word1
        assert tdata(31 downto 24) = x"A5" report "FAIL T1: DI wrong in word1" severity failure;
        wait until rising_edge(clk); wait for 1 ns;  -- Word2
        wait until rising_edge(clk); wait for 1 ns;  -- Word3
        wait until rising_edge(clk); wait for 1 ns;  -- Word4
        assert tdata(31 downto 16) = x"01F4" report "FAIL T1: adc5 wrong" severity failure;  -- 500=0x1F4
        report "T1: PASS";

        -- T2: packet count increments after 5 words
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(pkt_cnt) = 1 report "FAIL T2: pkt_cnt wrong" severity failure;
        report "T2: PASS";

        -- T3: overflow when pack is busy (mid-packet, new trig arrives)
        tready <= '0';
        trig_pulse <= '1'; wait for CLK_PERIOD; trig_pulse <= '0'; wait for CLK_PERIOD;
        -- Pack is now in WORD0 state (tready='0' so it's waiting)
        -- Fire another trig while busy - should overflow
        trig_pulse <= '1'; wait for CLK_PERIOD; trig_pulse <= '0';
        wait for 2 * CLK_PERIOD;
        assert to_integer(ovf_cnt) = 1 report "FAIL T3: ovf_cnt wrong" severity failure;
        tready <= '1';
        wait for 10 * CLK_PERIOD;  -- drain
        report "T3: PASS";

        -- T4: tlast on last word of dma_buffer_size (2) z_edge cycles
        tready <= '1';
        -- Wait for any in-flight packet from T3 to drain
        wait for 20 * CLK_PERIOD;  -- enough time to drain 5-word packet
        -- Fire 2 z_edges to count up to dma_buffer_size=2, next_is_last goes high
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        -- Fire trig -- last_sample should be latched from next_is_last
        trig_pulse <= '1'; wait for CLK_PERIOD; trig_pulse <= '0';
        -- Wait for tlast to appear (will be on word 4 of the packet)
        wait until tlast = '1';
        wait for 1 ns;
        assert tlast = '1' report "FAIL T4: tlast not set on buffer boundary" severity failure;
        -- Verify it clears after word4 accepted
        wait until rising_edge(clk); wait for 1 ns;
        assert tlast = '0' report "FAIL T4: tlast did not clear after word4" severity failure;
        report "T4: PASS";

        report "All pack tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
