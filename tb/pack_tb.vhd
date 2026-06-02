library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity pack_tb is
end entity pack_tb;

architecture sim of pack_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- Pack produces 5-word AXI stream packets. Words are:
    --   W0: ang_deg[15:0] | speed_rpm[15:0]
    --   W1: di_ch[7:0] | adc_ch1[11:0] | adc_ch2[11:0]   (padded to 32b)
    --   W2: adc_ch3[11:0] | adc_ch4[11:0]
    --   W3: adc_ch5[11:0] | adc_ch6[11:0]
    --   W4: (status/spare)
    -- tlast asserts on the last word of a DMA buffer (dma_buffer_size z_edge cycles)
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time    := 10 ns;
    constant N_WORDS    : integer := 5;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk        : std_logic := '0';
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

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- Received packet capture (5 words)
    type packet_words_t is array (0 to N_WORDS - 1) of std_logic_vector(31 downto 0);
    signal rx_words      : packet_words_t := (others => (others => '0'));
    signal rx_word_idx   : integer := 0;
    signal rx_done       : std_logic := '0';
    signal rx_tlast_seen : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Fire one trigger pulse and wait for full packet to be received
    -- -------------------------------------------------------------------------
    procedure fire_trig(
        signal   trig : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        trig <= '1';
        wait until rising_edge(c);
        trig <= '0';
    end procedure fire_trig;

    -- -------------------------------------------------------------------------
    -- Fire one z_edge strobe
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   z   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
    end procedure fire_z;

    -- -------------------------------------------------------------------------
    -- Wait for one complete packet to arrive in rx_words
    -- -------------------------------------------------------------------------
    procedure wait_packet(
        signal   done : in  std_logic;
        constant clk_p: in  time;
        constant timeout_cyc : in integer
    ) is
        variable n : integer := 0;
    begin
        while done = '0' and n < timeout_cyc loop
            wait for clk_p;
            n := n + 1;
        end loop;
        assert done = '1' report "FAIL: packet timeout" severity failure;
    end procedure wait_packet;

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
    dut : entity work.pack
        port map (
            clk             => clk,
            rst             => rst,
            trig_pulse      => trig_pulse,
            ang_deg         => ang_deg,
            speed_rpm_fast  => speed,
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

    -- -------------------------------------------------------------------------
    -- AXI stream packet receiver
    -- Captures each word into rx_words, asserts rx_done when tlast seen
    -- -------------------------------------------------------------------------
    p_receiver : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_word_idx   <= 0;
                rx_done       <= '0';
                rx_tlast_seen <= '0';
            else
                rx_done <= '0';
                if tvalid = '1' and tready = '1' then
                    rx_words(rx_word_idx) <= tdata;
                    if tlast = '1' then
                        rx_done       <= '1';
                        rx_tlast_seen <= '1';
                        rx_word_idx   <= 0;
                    else
                        if rx_word_idx < N_WORDS - 1 then
                            rx_word_idx <= rx_word_idx + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_receiver;

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- tvalid low and counters zero after reset
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 10 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD;
        wait for 1 ns;

        assert tvalid = '0'
            report "FAIL T1: tvalid should be low after reset"
            severity failure;
        assert to_integer(pkt_cnt) = 0
            report "FAIL T1: pkt_count should be 0 after reset"
            severity failure;
        assert to_integer(ovf_cnt) = 0
            report "FAIL T1: ovf_count should be 0 after reset"
            severity failure;

        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: Single packet -- verify word 0 content (ang_deg | speed)
        -- tlast should NOT be set on word 0 (dma_buffer_size not reached yet)
        -- --------------------------------------------------------------------
        report "TEST 2: Single packet content and word 0 format";
        test_num <= 2;

        tready <= '1';
        ang_deg <= to_unsigned(1234, 16);
        speed   <= to_unsigned(3000, 16);
        fire_trig(trig_pulse, clk);

        wait until tvalid = '1';
        wait for 1 ns;

        assert tdata(31 downto 16) = std_logic_vector(to_unsigned(1234, 16))
            report "FAIL T2: word0 ang_deg wrong: " &
                   integer'image(to_integer(unsigned(tdata(31 downto 16)))) &
                   " expected 1234"
            severity failure;
        assert tdata(15 downto 0) = std_logic_vector(to_unsigned(3000, 16))
            report "FAIL T2: word0 speed wrong: " &
                   integer'image(to_integer(unsigned(tdata(15 downto 0)))) &
                   " expected 3000"
            severity failure;
        assert tlast = '0'
            report "FAIL T2: tlast should not be set on word 0"
            severity failure;

        report "TEST 2: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: pkt_count increments after each complete packet
        -- --------------------------------------------------------------------
        report "TEST 3: pkt_count increments";
        test_num <= 3;

        -- T2 packet finishes in 5 clocks; wait 10*CLK_PERIOD already elapsed
        -- pkt_cnt should be 1
        wait for 1 ns;
        assert to_integer(pkt_cnt) = 1
            report "FAIL T3: pkt_count should be 1 after T2 packet, got " &
                   integer'image(to_integer(pkt_cnt))
            severity failure;
        -- Fire 2 more packets and allow each to drain (5 words * CLK_PERIOD)
        fire_trig(trig_pulse, clk);
        wait for 8 * CLK_PERIOD;
        fire_trig(trig_pulse, clk);
        wait for 8 * CLK_PERIOD;

        assert to_integer(pkt_cnt) = 3
            report "FAIL T3: pkt_count wrong: " &
                   integer'image(to_integer(pkt_cnt)) & " expected 3"
            severity failure;

        report "TEST 3: PASS - pkt_count = " &
               integer'image(to_integer(pkt_cnt));
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Overflow when trigger fires during packet transmission
        -- With tready='0' the packer is stalled; a second trig = overflow
        -- --------------------------------------------------------------------
        report "TEST 4: Overflow on trigger while busy";
        test_num <= 4;

        tready <= '0';
        fire_trig(trig_pulse, clk);   -- starts a packet (stalled in tvalid)
        wait for 3 * CLK_PERIOD;
        fire_trig(trig_pulse, clk);   -- second trig while stalled = overflow
        wait for 3 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(ovf_cnt) = 1
            report "FAIL T4: ovf_count wrong: " &
                   integer'image(to_integer(ovf_cnt)) & " expected 1"
            severity failure;

        tready <= '1';
        wait for 8 * CLK_PERIOD;   -- drain 5-word packet

        report "TEST 4: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Back-pressure -- tvalid held high while tready='0'
        -- --------------------------------------------------------------------
        report "TEST 5: Back-pressure -- tvalid held high when tready=0";
        test_num <= 5;

        tready <= '0';
        fire_trig(trig_pulse, clk);
        wait for 5 * CLK_PERIOD;
        wait for 1 ns;

        assert tvalid = '1'
            report "FAIL T5: tvalid dropped during back-pressure"
            severity failure;

        tready <= '1';
        wait for 8 * CLK_PERIOD;   -- drain after back-pressure

        report "TEST 5: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: tlast fires on last word of dma_buffer_size (=2) z_edge cycles
        -- dma_buffer_size=2: every 2nd z_edge causes the next trig to assert tlast
        -- --------------------------------------------------------------------
        report "TEST 6: tlast asserts at dma_buffer_size z_edge boundary";
        test_num <= 6;

        -- Ensure rx_tlast_seen is clear from previous packets
        -- (previous packets had buf_size=2 but no z_edges yet)
        -- Fire 2 z_edges to reach the buffer boundary
        fire_z(z_edge, clk);
        fire_z(z_edge, clk);
        wait for 2 * CLK_PERIOD;

        fire_trig(trig_pulse, clk);
        wait for 8 * CLK_PERIOD;   -- drain final packet
        wait for 1 ns;

        assert rx_tlast_seen = '1'
            report "FAIL T6: tlast never asserted at buffer boundary"
            severity failure;

        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All pack tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(clk)
    begin
        if rising_edge(clk) then
            if tvalid = '1' and tready = '1' then
                report "AXI word " & integer'image(rx_word_idx) &
                       " tlast=" & std_logic'image(tlast) &
                       " test=" & integer'image(test_num);
            end if;
        end if;
    end process p_monitor;

end architecture sim;
