library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- pack_tb.vhd  (v3)
--
-- Unit testbench for pack.vhd.
-- 3-word packet format:
--   W0: speed_rpm_slow[15:0] | speed_rpm_fast[15:0]
--   W1: 0x0000               | tdc_deg[15:0]
--   W2: DI[7:0]              | adc_ch0[11:0] | 0x000
-- =============================================================================

entity pack_tb is
end entity pack_tb;

architecture sim of pack_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant N_WORDS    : integer := 3;

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal trig_pulse : std_logic := '0';
    signal tdc_deg_s  : unsigned(15 downto 0) := to_unsigned(1234, 16);
    signal rpm_slow   : unsigned(15 downto 0) := to_unsigned(3000, 16);
    signal rpm_fast   : unsigned(15 downto 0) := to_unsigned(3100, 16);
    signal di_ch      : std_logic_vector(7 downto 0) := x"A5";
    signal adc0       : unsigned(11 downto 0) := to_unsigned(512, 12);
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
            adc_ch0         => adc0,
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
                if tvalid = '1' and tready = '1' then
                    rx_words(rx_idx) <= tdata;
                    rx_tlast         <= tlast;
                    if tlast = '1' then
                        rx_done <= '1';
                        rx_idx  <= 0;
                    elsif rx_idx < N_WORDS - 1 then
                        rx_idx <= rx_idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_rx;

    p_stim : process
    begin

        -- ----------------------------------------------------------------
        -- T1: Reset -- tvalid low, counters zero
        -- ----------------------------------------------------------------
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

        -- ----------------------------------------------------------------
        -- T2: Word 0 content -- speed_rpm_slow | speed_rpm_fast
        -- ----------------------------------------------------------------
        report "TEST 2: Word 0 content (rpm_slow=3000 | rpm_fast=3100)";
        test_num <= 2;

        tready <= '1';
        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;

        assert tdata(31 downto 16) = std_logic_vector(to_unsigned(3000, 16))
            report "FAIL T2: W0[31:16] rpm_slow expected 3000 got " &
                   integer'image(to_integer(unsigned(tdata(31 downto 16))))
            severity failure;
        assert tdata(15 downto 0) = std_logic_vector(to_unsigned(3100, 16))
            report "FAIL T2: W0[15:0] rpm_fast expected 3100 got " &
                   integer'image(to_integer(unsigned(tdata(15 downto 0))))
            severity failure;
        report "TEST 2: PASS";
        wait_packet(5);

        -- ----------------------------------------------------------------
        -- T3: Word 1 content -- tdc_deg
        -- ----------------------------------------------------------------
        report "TEST 3: Word 1 content (tdc_deg=1234)";
        test_num <= 3;

        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;    -- Word 0
        wait until rising_edge(clk); wait for 1 ns; -- Word 1

        assert tdata = std_logic_vector(to_unsigned(1234, 32))
            report "FAIL T3: W1 tdc_deg expected 1234 got " &
                   integer'image(to_integer(unsigned(tdata)))
            severity failure;
        report "TEST 3: PASS";
        wait_packet(5);

        -- ----------------------------------------------------------------
        -- T4: Word 2 content -- DI + adc_ch0
        -- ----------------------------------------------------------------
        report "TEST 4: Word 2 content (DI=0xA5 | adc_ch0=512)";
        test_num <= 4;

        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;    -- Word 0
        wait until rising_edge(clk); wait for 1 ns; -- Word 1
        wait until rising_edge(clk); wait for 1 ns; -- Word 2

        assert tdata(31 downto 24) = x"A5"
            report "FAIL T4: W2[31:24] DI expected 0xA5 got " &
                   integer'image(to_integer(unsigned(tdata(31 downto 24))))
            severity failure;
        assert tdata(23 downto 16) = x"00"
            report "FAIL T4: W2[23:16] should be 0x00"
            severity failure;
        assert to_integer(unsigned(tdata(15 downto 4))) = 512
            report "FAIL T4: W2[15:4] adc_ch0 expected 512 got " &
                   integer'image(to_integer(unsigned(tdata(15 downto 4))))
            severity failure;
        assert tdata(3 downto 0) = x"0"
            report "FAIL T4: W2[3:0] should be 0x0"
            severity failure;
        report "TEST 4: PASS";
        wait_packet(5);

        -- ----------------------------------------------------------------
        -- T5: pkt_count increments after each complete packet
        -- ----------------------------------------------------------------
        report "TEST 5: pkt_count increments";
        test_num <= 5;

        wait for 1 ns;
        assert to_integer(pkt_cnt) = 3
            report "FAIL T5: pkt_count should be 3 after 3 packets, got " &
                   integer'image(to_integer(pkt_cnt))
            severity failure;
        report "TEST 5: PASS";

        -- ----------------------------------------------------------------
        -- T6: Back-pressure -- tvalid held while tready=0
        -- ----------------------------------------------------------------
        report "TEST 6: Back-pressure";
        test_num <= 6;

        tready <= '0';
        fire_trig(trig_pulse, clk);
        wait for 5 * CLK_PERIOD; wait for 1 ns;

        assert tvalid = '1'
            report "FAIL T6: tvalid should remain high during back-pressure"
            severity failure;
        tready <= '1';
        wait_packet(8);
        report "TEST 6: PASS";

        -- ----------------------------------------------------------------
        -- T7: Overflow counter increments on busy trig
        -- ----------------------------------------------------------------
        report "TEST 7: Overflow counter";
        test_num <= 7;

        tready <= '0';
        fire_trig(trig_pulse, clk);
        wait for 3 * CLK_PERIOD;
        fire_trig(trig_pulse, clk);
        wait for 3 * CLK_PERIOD; wait for 1 ns;

        assert to_integer(ovf_cnt) = 1
            report "FAIL T7: ovf_count expected 1 got " &
                   integer'image(to_integer(ovf_cnt))
            severity failure;
        tready <= '1';
        wait_packet(8);
        report "TEST 7: PASS";

        -- ----------------------------------------------------------------
        -- T8: tlast fires after dma_buffer_size z_edges
        -- ----------------------------------------------------------------
        report "TEST 8: tlast at dma_buffer_size boundary";
        test_num <= 8;

        fire_z(z_edge, clk);
        fire_z(z_edge, clk);   -- 2nd z_edge: next_is_last set
        wait for 2 * CLK_PERIOD;
        fire_trig(trig_pulse, clk);
        wait_packet(8);
        wait for 1 ns;

        assert rx_tlast = '1'
            report "FAIL T8: tlast should be asserted at buffer boundary"
            severity failure;
        report "TEST 8: PASS";

        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All pack tests PASS";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
