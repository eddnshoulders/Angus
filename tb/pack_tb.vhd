library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- pack_tb.vhd  (v3)
--
-- Unit testbench for pack.vhd -- 2-word packet format:
--   W0: tdc_deg[31:0]
--   W1: DI[7:0] | 0x00 | pressure[11:0] | 0x0
-- =============================================================================

entity pack_tb is end entity;

architecture sim of pack_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant N_WORDS    : integer := 2;

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal trig_pulse : std_logic := '0';
    signal tdc_deg_s  : unsigned(15 downto 0) := to_unsigned(1234, 16);
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
    signal rx_tlast   : std_logic := '0';

    procedure fire_trig(signal t : out std_logic; signal c : in std_logic) is
    begin
        t <= '1'; wait until rising_edge(c); t <= '0';
    end procedure;

    procedure fire_z(signal z : out std_logic; signal c : in std_logic) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
    end procedure;

begin

    p_clk : process begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop; wait;
    end process;

    dut : entity work.pack
        port map (
            clk             => clk,
            rst             => rst,
            trig_pulse      => trig_pulse,
            tdc_deg         => tdc_deg_s,
            di_ch           => di_ch,
            adc_ch0         => adc0,
            z_edge          => z_edge,
            dma_buffer_size => buf_size,
            raw_fifo_almost_full => '0',  -- not full: normal operation
            m_axis_tdata    => tdata,
            m_axis_tvalid   => tvalid,
            m_axis_tready   => tready,
            m_axis_tlast    => tlast,
            pkt_count       => pkt_cnt,
            ovf_count       => ovf_cnt,
            dropped_pkt_count => open);

    -- AXI stream receiver
    p_rx : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_idx <= 0; rx_tlast <= '0';
            else
                if tvalid = '1' and tready = '1' then
                    rx_words(rx_idx) <= tdata;
                    rx_tlast         <= tlast;
                    if tlast = '1' or rx_idx = N_WORDS - 1 then
                        rx_idx <= 0;
                    else
                        rx_idx <= rx_idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    p_stim : process

        procedure wclk(n : integer) is begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
            wait for 1 ns;
        end procedure;

    begin
        -- ----------------------------------------------------------------
        -- T1: Reset
        -- ----------------------------------------------------------------
        test_num <= 1; report "TEST 1: Reset";
        rst <= '1'; wait for 10 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD; wait for 1 ns;

        assert tvalid = '0'
            report "FAIL T1: tvalid should be low" severity failure;
        assert to_integer(pkt_cnt) = 0
            report "FAIL T1: pkt_count should be 0" severity failure;
        report "TEST 1: PASS";

        -- ----------------------------------------------------------------
        -- T2: Word 0 -- tdc_deg full 32 bits
        -- ----------------------------------------------------------------
        test_num <= 2; report "TEST 2: Word 0 = tdc_deg";
        tready <= '1';
        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;

        assert tdata = std_logic_vector(to_unsigned(1234, 32))
            report "FAIL T2: W0 tdc_deg expected 1234 got " &
                   integer'image(to_integer(unsigned(tdata))) severity failure;
        report "TEST 2: PASS";
        wclk(5);

        -- ----------------------------------------------------------------
        -- T3: Word 1 -- DI + pressure
        -- ----------------------------------------------------------------
        test_num <= 3; report "TEST 3: Word 1 = DI | pressure";
        fire_trig(trig_pulse, clk);
        wait until tvalid = '1'; wait for 1 ns;     -- W0
        wait until rising_edge(clk); wait for 1 ns; -- W1

        assert tdata(31 downto 24) = x"A5"
            report "FAIL T3: W1[31:24] DI expected 0xA5" severity failure;
        assert tdata(23 downto 16) = x"00"
            report "FAIL T3: W1[23:16] should be 0x00" severity failure;
        assert to_integer(unsigned(tdata(15 downto 4))) = 512
            report "FAIL T3: W1[15:4] pressure expected 512 got " &
                   integer'image(to_integer(unsigned(tdata(15 downto 4)))) severity failure;
        assert tdata(3 downto 0) = x"0"
            report "FAIL T3: W1[3:0] should be 0x0" severity failure;
        report "TEST 3: PASS";
        wclk(5);

        -- ----------------------------------------------------------------
        -- T4: pkt_count increments
        -- ----------------------------------------------------------------
        test_num <= 4; report "TEST 4: pkt_count";
        wait for 1 ns;
        assert to_integer(pkt_cnt) = 2
            report "FAIL T4: pkt_count expected 2 got " &
                   integer'image(to_integer(pkt_cnt)) severity failure;
        report "TEST 4: PASS";

        -- ----------------------------------------------------------------
        -- T5: Back-pressure
        -- ----------------------------------------------------------------
        test_num <= 5; report "TEST 5: Back-pressure";
        tready <= '0';
        fire_trig(trig_pulse, clk);
        wclk(5);
        assert tvalid = '1'
            report "FAIL T5: tvalid should remain high" severity failure;
        tready <= '1'; wclk(5);
        report "TEST 5: PASS";

        -- ----------------------------------------------------------------
        -- T6: Overflow counter
        -- ----------------------------------------------------------------
        test_num <= 6; report "TEST 6: Overflow counter";
        tready <= '0';
        fire_trig(trig_pulse, clk);
        wclk(3);
        fire_trig(trig_pulse, clk);
        wclk(3); wait for 1 ns;
        assert to_integer(ovf_cnt) = 1
            report "FAIL T6: ovf_count expected 1 got " &
                   integer'image(to_integer(ovf_cnt)) severity failure;
        tready <= '1'; wclk(5);
        report "TEST 6: PASS";

        -- ----------------------------------------------------------------
        -- T7: tlast fires at dma_buffer_size boundary
        -- ----------------------------------------------------------------
        test_num <= 7; report "TEST 7: tlast at buffer boundary";
        fire_z(z_edge, clk);
        fire_z(z_edge, clk);
        wclk(2);
        fire_trig(trig_pulse, clk);
        wclk(8); wait for 1 ns;
        assert rx_tlast = '1'
            report "FAIL T7: tlast should be asserted at boundary" severity failure;
        report "TEST 7: PASS";

        wclk(5);
        report "========================================";
        report "All pack tests PASS";
        report "========================================";
        sim_done <= true; std.env.stop; wait;
    end process;

end architecture sim;
