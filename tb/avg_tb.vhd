library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- avg_tb.vhd
--
-- Unit testbench for avg.vhd.
--
-- Test plan:
--   T1: Reset -- outputs inactive, no valid on output stream
--   T2: Bypass (N=0) -- raw stream passes through unchanged, word-for-word
--   T3: N=1 (2 frames) -- two engine cycles accumulated, output averaged frame
--       correct bin values, header words (rpm, N), tlast on final bin
--   T4: N=2 (4 frames) -- four cycles, verify right-shift by 2
--   T5: Bank swap / double buffer -- accumulator fills next bank while output
--       drains previous bank; no stall, no data corruption
--   T6: N change mid-run -- changing N between frames takes effect cleanly
--   T7: Back-pressure on output -- m_axis_tready deasserted mid-frame,
--       output holds valid/data until ready
--   T8: Pressure accumulation correctness -- known pressure values per bin,
--       verify averaged output matches expected
-- =============================================================================

entity avg_tb is
end entity avg_tb;

architecture sim of avg_tb is

    constant CLK_PERIOD : time    := 10 ns;  -- 100 MHz
    constant BINS       : integer := 7200;

    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';

    -- Input stream (from pack.vhd)
    signal s_axis_tdata    : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axis_tvalid   : std_logic := '0';
    signal s_axis_tready   : std_logic;
    signal s_axis_tlast    : std_logic := '0';

    -- Output stream (to avg DMA)
    signal m_axis_tdata    : std_logic_vector(31 downto 0);
    signal m_axis_tvalid   : std_logic;
    signal m_axis_tready   : std_logic := '1';
    signal m_axis_tlast    : std_logic;

    -- Control
    signal avg_n           : unsigned(3 downto 0) := (others => '0');
    signal rpm             : unsigned(15 downto 0) := to_unsigned(3000, 16);
    signal frame_count     : unsigned(31 downto 0);

    signal sim_done        : boolean := false;
    signal test_num        : integer := 0;

    -- =========================================================================
    -- Helper: send one raw pack.vhd frame (BINS samples, one engine cycle)
    -- pressure_val applied to all bins uniformly for simplicity.
    -- tlast asserted on final word 1.
    -- =========================================================================
    procedure send_frame (
        constant pressure   : in integer;
        constant di         : in integer;
        signal   tdata      : out std_logic_vector(31 downto 0);
        signal   tvalid     : out std_logic;
        signal   tlast      : out std_logic;
        signal   tready     : in  std_logic;
        signal   clk        : in  std_logic
    ) is
    begin
        for bin in 0 to BINS - 1 loop
            -- Word 0: tdc_deg = bin index
            tdata  <= std_logic_vector(to_unsigned(bin, 32));
            tvalid <= '1';
            tlast  <= '0';
            wait until rising_edge(clk) and tready = '1';

            -- Word 1: pressure in [15:4], DI in [31:24]
            tdata  <= std_logic_vector(
                        to_unsigned(di, 8) &        -- [31:24] DI
                        x"00" &                     -- [23:16] 0x00
                        to_unsigned(pressure * 16, 16)); -- [15:4] pressure, [3:0]=0
            if bin = BINS - 1 then
                tlast <= '1';
            end if;
            wait until rising_edge(clk) and tready = '1';
        end loop;
        tvalid <= '0';
        tlast  <= '0';
        wait until rising_edge(clk);
    end procedure send_frame;

    -- =========================================================================
    -- Helper: receive one output word, return data
    -- =========================================================================
    procedure recv_word (
        signal   tdata      : in  std_logic_vector(31 downto 0);
        signal   tvalid     : in  std_logic;
        signal   tlast      : in  std_logic;
        signal   tready     : out std_logic;
        signal   clk        : in  std_logic;
        variable data_out   : out std_logic_vector(31 downto 0);
        variable last_out   : out std_logic
    ) is
    begin
        tready <= '1';
        wait until rising_edge(clk) and tvalid = '1';
        data_out := tdata;
        last_out := tlast;
        wait for 1 ns;
    end procedure recv_word;

    -- =========================================================================
    -- Helper: receive and discard N output words
    -- =========================================================================
    procedure drain_words (
        constant n_words    : in  integer;
        signal   tvalid     : in  std_logic;
        signal   tready     : out std_logic;
        signal   clk        : in  std_logic
    ) is
    begin
        tready <= '1';
        for i in 0 to n_words - 1 loop
            wait until rising_edge(clk) and tvalid = '1';
        end loop;
        wait for 1 ns;
    end procedure drain_words;

begin

    -- =========================================================================
    -- Clock
    -- =========================================================================
    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    -- =========================================================================
    -- DUT
    -- =========================================================================
    dut : entity work.avg
        port map (
            clk             => clk,
            rst             => rst,
            s_axis_tdata    => s_axis_tdata,
            s_axis_tvalid   => s_axis_tvalid,
            s_axis_tready   => s_axis_tready,
            s_axis_tlast    => s_axis_tlast,
            m_axis_tdata    => m_axis_tdata,
            m_axis_tvalid   => m_axis_tvalid,
            m_axis_tready   => m_axis_tready,
            m_axis_tlast    => m_axis_tlast,
            avg_n           => avg_n,
            rpm             => rpm,
            frame_count     => frame_count
        );

    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim : process
        variable data_v     : std_logic_vector(31 downto 0);
        variable last_v     : std_logic;
        variable fc_before  : unsigned(31 downto 0);
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset
        -- --------------------------------------------------------------------
        report "TEST 1: Reset -- output inactive";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert m_axis_tvalid = '0'
            report "FAIL T1: m_axis_tvalid should be low after reset"
            severity failure;
        assert to_integer(frame_count) = 0
            report "FAIL T1: frame_count should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Bypass (N=0) -- raw stream passes through
        -- Send 10 word pairs, verify they appear unchanged on output
        -- --------------------------------------------------------------------
        report "TEST 2: Bypass (N=0) -- raw passthrough";
        test_num <= 2;

        avg_n <= to_unsigned(0, 4);
        m_axis_tready <= '1';

        -- Send word 0
        s_axis_tdata  <= x"00000064";  -- tdc_deg = 100
        s_axis_tvalid <= '1';
        s_axis_tlast  <= '0';
        wait until rising_edge(clk) and s_axis_tready = '1';
        wait for 1 ns;

        assert m_axis_tvalid = '1'
            report "FAIL T2: m_axis_tvalid should follow s_axis_tvalid in bypass"
            severity failure;
        assert m_axis_tdata = x"00000064"
            report "FAIL T2: word 0 data mismatch in bypass"
            severity failure;

        -- Send word 1 with tlast
        s_axis_tdata  <= x"12003456";
        s_axis_tlast  <= '1';
        wait until rising_edge(clk) and s_axis_tready = '1';
        wait for 1 ns;

        assert m_axis_tdata = x"12003456"
            report "FAIL T2: word 1 data mismatch in bypass"
            severity failure;
        assert m_axis_tlast = '1'
            report "FAIL T2: tlast should pass through in bypass"
            severity failure;

        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';
        wait for 5 * CLK_PERIOD;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: N=1 (2 frames averaged)
        -- Send 2 engine cycles, each bin gets pressure = 100
        -- Expected averaged output per bin = (100 + 100) >> 1 = 100
        -- Verify header (rpm=3000, N=1) and spot-check bin 0 and bin 7199
        -- --------------------------------------------------------------------
        report "TEST 3: N=1 averaging -- 2 frames, uniform pressure=100";
        test_num <= 3;

        avg_n <= to_unsigned(1, 4);
        rpm   <= to_unsigned(3000, 16);
        m_axis_tready <= '1';
        fc_before := frame_count;

        -- Send 2 engine cycles
        send_frame(100, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(100, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        -- Wait for output frame to start
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        wait for 1 ns;

        -- Header word 0: rpm
        assert unsigned(m_axis_tdata) = 3000
            report "FAIL T3: header rpm mismatch, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;
        wait until rising_edge(clk) and m_axis_tvalid = '1';

        -- Header word 1: N
        assert unsigned(m_axis_tdata) = 1
            report "FAIL T3: header N mismatch, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        -- Bin 0: expect 100
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 100
            report "FAIL T3: bin 0 averaged value wrong, expected 100, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        -- Drain remaining bins
        drain_words(BINS - 2, m_axis_tvalid, m_axis_tready, clk);

        -- Last bin (7199): expect 100, tlast asserted
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 100
            report "FAIL T3: bin 7199 averaged value wrong, expected 100, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;
        assert m_axis_tlast = '1'
            report "FAIL T3: tlast not asserted on final bin"
            severity failure;

        -- frame_count should have incremented
        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert frame_count = fc_before + 1
            report "FAIL T3: frame_count did not increment"
            severity failure;

        report "TEST 3: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: N=2 (4 frames averaged)
        -- pressure = 200 each frame, expected = (200*4) >> 2 = 200
        -- --------------------------------------------------------------------
        report "TEST 4: N=2 averaging -- 4 frames, pressure=200";
        test_num <= 4;

        avg_n <= to_unsigned(2, 4);
        rpm   <= to_unsigned(6000, 16);
        fc_before := frame_count;

        for f in 0 to 3 loop
            send_frame(200, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                       s_axis_tready, clk);
        end loop;

        -- Wait for output, check header rpm=6000, N=2
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert unsigned(m_axis_tdata) = 6000
            report "FAIL T4: header rpm mismatch"
            severity failure;
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert unsigned(m_axis_tdata) = 2
            report "FAIL T4: header N mismatch"
            severity failure;

        -- Bin 0: expect 200
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 200
            report "FAIL T4: bin 0 wrong, expected 200, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        drain_words(BINS - 1, m_axis_tvalid, m_axis_tready, clk);

        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert frame_count = fc_before + 1
            report "FAIL T4: frame_count did not increment"
            severity failure;
        report "TEST 4: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Back-pressure on output (m_axis_tready deasserted)
        -- Send 2 frames (N=1), deassert tready mid-output, verify no data lost
        -- --------------------------------------------------------------------
        report "TEST 5: Back-pressure -- tready deasserted mid-frame";
        test_num <= 5;

        avg_n <= to_unsigned(1, 4);
        rpm   <= to_unsigned(3000, 16);

        send_frame(50, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(50, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        -- Wait for output to start, receive header
        m_axis_tready <= '1';
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- rpm header
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- N header

        -- Receive bin 0 then deassert tready for 10 cycles
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        data_v := m_axis_tdata;
        m_axis_tready <= '0';
        wait for 10 * CLK_PERIOD;

        -- tvalid should still be held
        assert m_axis_tvalid = '1'
            report "FAIL T5: tvalid dropped during back-pressure"
            severity failure;
        -- data should be stable
        assert m_axis_tdata = data_v
            report "FAIL T5: data changed during back-pressure"
            severity failure;

        -- Resume and drain remaining
        m_axis_tready <= '1';
        drain_words(BINS - 1, m_axis_tvalid, m_axis_tready, clk);

        report "TEST 5: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: Double buffer -- accumulator fills next bank while output
        -- is still draining. Send 4 frames (N=1 x2), assert output frame 1
        -- completes correctly and frame 2 starts without corruption.
        -- --------------------------------------------------------------------
        report "TEST 6: Double buffer -- concurrent accumulate and output";
        test_num <= 6;

        avg_n <= to_unsigned(1, 4);
        rpm   <= to_unsigned(3000, 16);
        fc_before := frame_count;

        -- Send first 2 frames (fills bank and triggers output)
        send_frame(10, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(10, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        -- Start sending next 2 frames immediately (should go to other bank)
        -- while first output frame is draining
        m_axis_tready <= '1';
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- frame 1 starts

        -- Concurrently send frames 3 and 4
        send_frame(20, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(20, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        -- Drain frame 1 (header + 7200 bins)
        drain_words(BINS + 1, m_axis_tvalid, m_axis_tready, clk);

        -- Wait for frame 2 output
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- rpm
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- N

        -- Bin 0 of frame 2 should be 20 (not contaminated by frame 1's 10)
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 20
            report "FAIL T6: frame 2 bin 0 corrupted, expected 20, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        drain_words(BINS - 1, m_axis_tvalid, m_axis_tready, clk);

        assert frame_count = fc_before + 2
            report "FAIL T6: expected 2 output frames"
            severity failure;
        report "TEST 6: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: N change between frames
        -- Send 2 frames at N=1, then change to N=2 and send 4 frames.
        -- Verify second output uses N=2 averaging correctly.
        -- --------------------------------------------------------------------
        report "TEST 7: N change between frames";
        test_num <= 7;

        avg_n <= to_unsigned(1, 4);
        rpm   <= to_unsigned(3000, 16);

        send_frame(40, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(40, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        -- Drain N=1 output frame
        drain_words(BINS + 2, m_axis_tvalid, m_axis_tready, clk);

        -- Change to N=2 and send 4 frames
        avg_n <= to_unsigned(2, 4);
        for f in 0 to 3 loop
            send_frame(80, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                       s_axis_tready, clk);
        end loop;

        -- Check N=2 output: header N should be 2, bin 0 should be 80
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- rpm
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- N
        assert unsigned(m_axis_tdata) = 2
            report "FAIL T7: N header should be 2 after N change"
            severity failure;

        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 80
            report "FAIL T7: bin 0 wrong after N change, expected 80, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        drain_words(BINS - 1, m_axis_tvalid, m_axis_tready, clk);
        report "TEST 7: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 8: Pressure accumulation correctness
        -- Bin 0 gets pressure=100, all other bins get pressure=0.
        -- After N=1 (2 frames): bin 0 = (100+100)>>1 = 100, others = 0.
        -- --------------------------------------------------------------------
        report "TEST 8: Sparse pressure -- bin 0 only";
        test_num <= 8;

        avg_n <= to_unsigned(1, 4);
        rpm   <= to_unsigned(3000, 16);

        -- Send 2 frames: bin 0 gets pressure=100, rest get 0
        for f in 0 to 1 loop
            for bin in 0 to BINS - 1 loop
                -- Word 0: tdc_deg
                s_axis_tdata  <= std_logic_vector(to_unsigned(bin, 32));
                s_axis_tvalid <= '1';
                s_axis_tlast  <= '0';
                wait until rising_edge(clk) and s_axis_tready = '1';

                -- Word 1: pressure only for bin 0
                if bin = 0 then
                    s_axis_tdata <= x"00000640";  -- pressure=100 in [15:4]
                else
                    s_axis_tdata <= x"00000000";
                end if;
                if bin = BINS - 1 then s_axis_tlast <= '1'; end if;
                wait until rising_edge(clk) and s_axis_tready = '1';
            end loop;
        end loop;
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';

        -- Drain header
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- rpm
        wait until rising_edge(clk) and m_axis_tvalid = '1';  -- N

        -- Bin 0: expect 100
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 100
            report "FAIL T8: bin 0 expected 100, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        -- Bin 1: expect 0
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        assert to_integer(unsigned(m_axis_tdata)) = 0
            report "FAIL T8: bin 1 expected 0, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        drain_words(BINS - 2, m_axis_tvalid, m_axis_tready, clk);
        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All avg tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
