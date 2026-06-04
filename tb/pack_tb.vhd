library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- pack_tb.vhd  (v3)
--
-- Unit testbench for pack.vhd.
-- 6-word packet format:
--   W0: speed_rpm_slow | speed_rpm_fast
--   W1: 0x0000         | tdc_deg
--   W2: DI[7:0]        | 0x0 | adc_ch1[11:0]
--   W3: 0x0|adc_ch2    | 0x0|adc_ch3
--   W4: 0x0|adc_ch4    | 0x0|adc_ch5
--   W5: 0x0|adc_ch6    | 0x0000 (reserved)
-- =============================================================================

entity pack_tb is
end entity pack_tb;

architecture sim of pack_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant N_WORDS    : integer := 6;

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal trig_pulse : std_logic := '0';
    signal tdc_deg_s  : unsigned(15 downto 0) := to_unsigned(1234, 16);
    signal rpm_slow   : unsigned(15 downto 0) := to_unsigned(3000, 16);
    signal rpm_fast   : unsigned(15 downto 0) := to_unsigned(3100, 16);
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

    signal sim_done   : boolean := false;
    signal test_num   : integer := 0;

    -- Captured packet words
    type packet_t is array (0 to N_WORDS - 1) of std_logic_vector(31 downto 0);
    signal rx_words   : packet_t := (others => (others => '0'));
    signal rx_idx     : integer := 0;
    signal rx_done    : std_logic := '0';
    signal rx_tlast   : std_logic := '0';

    procedure fire_trig(signal t : out std_logic; signal c : in std_logic) is
    begin
        t <= '1'; wait until rising_edge(c);
        t <= '0';
    end procedure fire_trig;

    procedure fire_z(signal z : out std_logic; signal c : in std_logic) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
    end procedure fire_z;

    procedure wait_packet(constant clks : in integer) is
    begin
        wait for clks * CLK_PERIOD;
    end procedure wait_packet;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.pack
        port map (
            clk             => clk,
            rst             => rst,
            trig_pulse      => trig_pulse,
            tdc_deg         => tdc_deg_s,
            speed_rpm_slow  => rpm_slow,
            speed_rpm_fast  => rpm_fast,
            di_ch           => di_ch,
            adc_ch1         => adc1,
            adc_ch2         => adc2,
            adc_ch3         => adc3,
            adc_ch4         => adc4,
            adc_ch5         => adc5,
            adc_ch6         => adc6,
            z_edge          => z_edge,
            dma_buffer_size => buf_size,
            m_axis_tdata    => tdata,
            m_axis_tvalid   => tvalid,
            m_axis_tready   => tready,
            m_axis_tlast    => tlast,
            pkt_count       => pkt_cnt,
            ovf_count       => ovf_cnt
        );

    -- AXI stream receiver
    p_rx : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_idx  <= 0;
                rx_done <= '0';
                rx_tlast <= '0';
            else
                rx_done <= '0';
                if tvalid = '1' and tready = '1' then
                    rx_words(rx_idx) <= tdata;
                    if tlast = '1' then
                        rx_done  <= '1';
                        rx_tlast <= '1';
                        rx_idx   <= 0;
                    elsif rx_idx < N_WORDS - 1 then
                        rx_idx <= rx_idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_rx;

    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset -- tvalid low, counters zero
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 10 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD; wait for 1 ns;

        assert tvalid = '0'
            report "FAIL T1: tvalid should be low after reset"
            severity failure;
        assert to_integer(pkt_cnt) = 0
            report "FAIL T1: pkt_count should be 0"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Word 0 content -- speed_rpm_slow | speed_rpm_fast
        -- --------------------------------------------------------------------
        report "TEST 2: Word 0 content (speed_rpm_slow | speed_rpm_fast)";
        test_num <= 2;

        tready <= '1';
        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;

        assert tdata(31 downto 16) = std_logic_vector(to_unsigned(3000, 16))
            report "FAIL T2: Word 0 [31:16] should be rpm_slow (3000), got " &
                   integer'image(to_integer(unsigned(tdata(31 downto 16))))
            severity failure;
        assert tdata(15 downto 0) = std_logic_vector(to_unsigned(3100, 16))
            report "FAIL T2: Word 0 [15:0] should be rpm_fast (3100), got " &
                   integer'image(to_integer(unsigned(tdata(15 downto 0))))
            severity failure;
        report "TEST 2: PASS";

        -- Drain rest of packet (5 more words at 1 clock/word with tready=1)
        wait_packet(8);

        -- --------------------------------------------------------------------
        -- TEST 3: Word 1 content -- tdc_deg
        -- --------------------------------------------------------------------
        report "TEST 3: Word 1 content (tdc_deg = 1234)";
        test_num <= 3;

        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;  -- Word 0

        wait until rising_edge(clk); wait for 1 ns;  -- Word 1
        assert tdata(15 downto 0) = std_logic_vector(to_unsigned(1234, 16))
            report "FAIL T3: Word 1 [15:0] should be tdc_deg (1234), got " &
                   integer'image(to_integer(unsigned(tdata(15 downto 0))))
            severity failure;
        report "TEST 3: PASS";
        wait_packet(8);

        -- --------------------------------------------------------------------
        -- TEST 4: pkt_count increments after each complete packet
        -- --------------------------------------------------------------------
        report "TEST 4: pkt_count increments";
        test_num <= 4;

        wait for 1 ns;
        assert to_integer(pkt_cnt) = 2
            report "FAIL T4: pkt_count should be 2 after 2 packets, got " &
                   integer'image(to_integer(pkt_cnt))
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: Back-pressure -- tvalid held high while tready=0
        -- --------------------------------------------------------------------
        report "TEST 5: Back-pressure -- tvalid held while tready=0";
        test_num <= 5;

        tready <= '0';
        fire_trig(trig_pulse, clk);
        wait for 5 * CLK_PERIOD; wait for 1 ns;

        assert tvalid = '1'
            report "FAIL T5: tvalid should remain high during back-pressure"
            severity failure;

        tready <= '1';
        wait_packet(10);
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: Overflow when trig fires during packet transmission
        -- --------------------------------------------------------------------
        report "TEST 6: Overflow counter increments on busy trig";
        test_num <= 6;

        tready <= '0';
        fire_trig(trig_pulse, clk);   -- start packet (stalled)
        wait for 3 * CLK_PERIOD;
        fire_trig(trig_pulse, clk);   -- overflow
        wait for 3 * CLK_PERIOD; wait for 1 ns;

        assert to_integer(ovf_cnt) = 1
            report "FAIL T6: ovf_count should be 1, got " &
                   integer'image(to_integer(ovf_cnt))
            severity failure;
        tready <= '1';
        wait_packet(10);
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: tlast fires after dma_buffer_size z_edges (= 2)
        -- --------------------------------------------------------------------
        report "TEST 7: tlast asserts at dma_buffer_size z_edge boundary";
        test_num <= 7;

        fire_z(z_edge, clk);
        fire_z(z_edge, clk);   -- 2nd z_edge: next_is_last set
        wait for 2 * CLK_PERIOD;
        fire_trig(trig_pulse, clk);
        wait_packet(10);
        wait for 1 ns;

        assert rx_tlast = '1'
            report "FAIL T7: tlast should have been asserted at buffer boundary"
            severity failure;
        report "TEST 7: PASS";

        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All pack tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
