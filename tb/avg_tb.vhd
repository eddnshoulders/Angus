library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.env.all;

-- =============================================================================
-- avg_tb.vhd
--
-- Testbench for avg.vhd with 2-word output format.
-- Output frame: 14400 words (7200 bins × 2 words each)
--   Word 0: tdc_deg = bin index (0-7199)
--   Word 1: DI[31:24] | 0x00 | pressure_avg[15:4] | 0x0
--
-- Tests:
--   T1: Reset
--   T2: Bypass (N=0) -- raw passthrough
--   T3: N=1 (2 frames) -- verify bin 0 pressure and tdc_deg word
--   T4: N=2 (4 frames)
--   T5: Back-pressure
--   T6: Double buffer
--   T7: N change
--   T8: Sparse pressure + DI value
-- =============================================================================

entity avg_tb is
end entity avg_tb;

architecture sim of avg_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant BINS       : integer := 7200;
    constant WORDS_PER_BIN : integer := 2;
    constant FRAME_WORDS   : integer := BINS * WORDS_PER_BIN; -- 14400

    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal s_axis_tdata    : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axis_tvalid   : std_logic := '0';
    signal s_axis_tready   : std_logic;
    signal s_axis_tlast    : std_logic := '0';
    signal m_axis_tdata    : std_logic_vector(31 downto 0);
    signal m_axis_tvalid   : std_logic;
    signal m_axis_tready   : std_logic := '1';
    signal m_axis_tlast    : std_logic;
    signal avg_n           : unsigned(3 downto 0) := (others => '0');
    signal frame_count     : unsigned(31 downto 0);
    signal sim_done        : boolean := false;
    signal test_num        : integer := 0;

    -- Send one full engine cycle (BINS samples, 2 words each)
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
        tvalid <= '1';
        for bin in 0 to BINS - 1 loop
            tlast <= '0';
            -- Word 0: set tdc_deg, wait until acc samples it (tready='1' post-delta)
            tdata <= std_logic_vector(to_unsigned(bin, 32));
            loop
                wait until rising_edge(clk); wait for 1 ns;
                exit when tready = '1';
            end loop;
            -- Word 1: set pressure/DI, wait until acc samples it
            tdata <= std_logic_vector(to_unsigned(di, 8)) &
                     x"00" &
                     std_logic_vector(to_unsigned(pressure * 16, 16));
            if bin = BINS - 1 then tlast <= '1'; end if;
            loop
                wait until rising_edge(clk); wait for 1 ns;
                exit when tready = '1';
            end loop;
        end loop;
        tvalid <= '0';
        tlast  <= '0';
        wait until rising_edge(clk);
    end procedure send_frame;

    -- Drain n_words output words (tvalid continuously high during averaging)
    procedure drain_words (
        constant n_words    : in  integer;
        signal   tvalid     : in  std_logic;
        signal   tready     : out std_logic;
        signal   clk        : in  std_logic
    ) is
    begin
        tready <= '1';
        for i in 0 to n_words - 1 loop
            wait until rising_edge(clk);
        end loop;
    end procedure drain_words;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process p_clk;

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
            frame_count     => frame_count
        );

    p_stim : process
        variable data_v     : std_logic_vector(31 downto 0);
        variable fc_before  : unsigned(31 downto 0);
    begin

        -- T1: Reset
        report "TEST 1: Reset";
        test_num <= 1;
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD; wait for 1 ns;
        assert m_axis_tvalid = '0'
            report "FAIL T1: tvalid should be low" severity failure;
        assert to_integer(frame_count) = 0
            report "FAIL T1: frame_count should be 0" severity failure;
        report "TEST 1: PASS";

        -- T2: Bypass (N=0)
        report "TEST 2: Bypass (N=0) -- raw passthrough";
        test_num <= 2;
        avg_n <= to_unsigned(0, 4);
        m_axis_tready <= '1';
        -- Send word 0
        s_axis_tdata  <= x"00000064";
        s_axis_tvalid <= '1';
        s_axis_tlast  <= '0';
        wait until rising_edge(clk) and s_axis_tready = '1'; wait for 1 ns;
        assert m_axis_tvalid = '1'
            report "FAIL T2: tvalid in bypass" severity failure;
        assert m_axis_tdata = x"00000064"
            report "FAIL T2: word 0 mismatch in bypass" severity failure;
        -- Send word 1 with tlast
        s_axis_tdata  <= x"AABBCCDD";
        s_axis_tlast  <= '1';
        wait until rising_edge(clk) and s_axis_tready = '1'; wait for 1 ns;
        assert m_axis_tdata = x"AABBCCDD"
            report "FAIL T2: word 1 mismatch in bypass" severity failure;
        assert m_axis_tlast = '1'
            report "FAIL T2: tlast in bypass" severity failure;
        s_axis_tvalid <= '0'; s_axis_tlast <= '0';
        wait for 5 * CLK_PERIOD;
        report "TEST 2: PASS";

        -- T3: N=1, 2 frames, pressure=100, DI=0xAB
        -- Expected: bin 0 word0=0, word1=0xAB_00_640_0 (pressure=100>>1*16=800? no)
        -- pressure sum = 100+100=200, avg = 200>>1 = 100
        -- word1 = 0xAB | 0x00 | (100 << 4) | 0x0 = 0xAB001640 -- wait
        -- pressure field [15:4] = 100 = 0x064, so [15:0] = 0x0640
        -- word1 = 0xAB_00_0640
        report "TEST 3: N=1 -- 2 frames, pressure=100, DI=0xAB";
        test_num <= 3;
        avg_n <= to_unsigned(1, 4);
        m_axis_tready <= '1';
        fc_before := frame_count;

        send_frame(100, 16#AB#, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(100, 16#AB#, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        -- Wait for output frame
        wait until m_axis_tvalid = '1'; wait for 1 ns;

        -- Bin 0, word 0: tdc_deg should be 0
        assert to_integer(unsigned(m_axis_tdata)) = 0
            report "FAIL T3: bin 0 word 0 (tdc_deg) wrong, expected 0, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        -- Bin 0, word 1: DI=0xAB, pressure=100
        wait until rising_edge(clk); wait for 1 ns;
        assert m_axis_tdata(31 downto 24) = x"AB"
            report "FAIL T3: bin 0 DI wrong, expected 0xAB"
            severity failure;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 100
            report "FAIL T3: bin 0 pressure wrong, expected 100, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata(15 downto 4))))
            severity failure;

        -- Drain remaining bins (bins 1..7198 = 7198 bins = 14396 words)
        -- then check last bin
        drain_words(FRAME_WORDS - 4, m_axis_tvalid, m_axis_tready, clk);

        -- Bin 7199, word 0: tdc_deg = 7199
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(unsigned(m_axis_tdata)) = 7199
            report "FAIL T3: bin 7199 word 0 wrong, expected 7199, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        -- Bin 7199, word 1: tlast asserted
        wait until rising_edge(clk); wait for 1 ns;
        assert m_axis_tlast = '1'
            report "FAIL T3: tlast not asserted on final word"
            severity failure;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 100
            report "FAIL T3: bin 7199 pressure wrong"
            severity failure;

        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert frame_count = fc_before + 1
            report "FAIL T3: frame_count did not increment"
            severity failure;
        report "TEST 3: PASS";
        wait for 10 * CLK_PERIOD;

        -- T4: N=2, 4 frames, pressure=200
        report "TEST 4: N=2 -- 4 frames, pressure=200";
        test_num <= 4;
        avg_n <= to_unsigned(2, 4);
        fc_before := frame_count;

        for f in 0 to 3 loop
            send_frame(200, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                       s_axis_tready, clk);
        end loop;

        wait until m_axis_tvalid = '1'; wait for 1 ns;
        -- Bin 0 word 0: tdc_deg=0
        assert to_integer(unsigned(m_axis_tdata)) = 0
            report "FAIL T4: bin 0 tdc_deg wrong" severity failure;
        wait until rising_edge(clk); wait for 1 ns;
        -- Bin 0 word 1: pressure=200
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 200
            report "FAIL T4: bin 0 pressure wrong, expected 200, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata(15 downto 4))))
            severity failure;

        drain_words(FRAME_WORDS - 2, m_axis_tvalid, m_axis_tready, clk);

        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert frame_count = fc_before + 1
            report "FAIL T4: frame_count did not increment"
            severity failure;
        report "TEST 4: PASS";
        wait for 10 * CLK_PERIOD;

        -- T5: Back-pressure
        report "TEST 5: Back-pressure -- tready deasserted mid-frame";
        test_num <= 5;
        avg_n <= to_unsigned(1, 4);

        send_frame(50, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(50, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        m_axis_tready <= '1';
        wait until m_axis_tvalid = '1'; wait for 1 ns;
        data_v := m_axis_tdata;
        m_axis_tready <= '0';
        wait for 10 * CLK_PERIOD;

        assert m_axis_tvalid = '1'
            report "FAIL T5: tvalid dropped under back-pressure"
            severity failure;
        assert m_axis_tdata = data_v
            report "FAIL T5: data changed under back-pressure"
            severity failure;

        m_axis_tready <= '1';
        drain_words(FRAME_WORDS - 1, m_axis_tvalid, m_axis_tready, clk);
        report "TEST 5: PASS";
        wait for 10 * CLK_PERIOD;

        -- T6: Double buffer
        report "TEST 6: Double buffer -- 4 frames, 2 output frames";
        test_num <= 6;
        avg_n <= to_unsigned(1, 4);
        fc_before := frame_count;

        send_frame(10, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(10, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(20, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(20, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        m_axis_tready <= '1';
        drain_words(2 * FRAME_WORDS, m_axis_tvalid, m_axis_tready, clk);

        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert frame_count = fc_before + 2
            report "FAIL T6: expected 2 output frames"
            severity failure;
        report "TEST 6: PASS";
        wait for 10 * CLK_PERIOD;

        -- T7: N change
        report "TEST 7: N change between frames";
        test_num <= 7;
        avg_n <= to_unsigned(1, 4);

        send_frame(40, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(40, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        wait until m_axis_tvalid = '1';
        drain_words(FRAME_WORDS - 1, m_axis_tvalid, m_axis_tready, clk);

        avg_n <= to_unsigned(2, 4);
        for f in 0 to 3 loop
            send_frame(80, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                       s_axis_tready, clk);
        end loop;

        wait until m_axis_tvalid = '1'; wait for 1 ns;
        -- Skip tdc_deg word
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 80
            report "FAIL T7: bin 0 pressure wrong after N change, expected 80, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata(15 downto 4))))
            severity failure;
        drain_words(FRAME_WORDS - 2, m_axis_tvalid, m_axis_tready, clk);
        report "TEST 7: PASS";
        wait for 10 * CLK_PERIOD;

        -- T8: Sparse pressure + DI verification
        report "TEST 8: Sparse pressure + DI snapshot";
        test_num <= 8;
        avg_n <= to_unsigned(1, 4);

        -- Frame 1: bin 0 pressure=100 DI=0xCD, others pressure=0 DI=0
        -- Frame 2: same
        for f in 0 to 1 loop
            s_axis_tvalid <= '1';
            for bin in 0 to BINS - 1 loop
                s_axis_tlast  <= '0';
                s_axis_tdata  <= std_logic_vector(to_unsigned(bin, 32));
                loop
                    wait until rising_edge(clk); wait for 1 ns;
                    exit when s_axis_tready = '1';
                end loop;
                if bin = 0 then
                    s_axis_tdata <= x"CD" & x"00" & x"0640";
                else
                    s_axis_tdata <= x"00000000";
                end if;
                if bin = BINS - 1 then s_axis_tlast <= '1'; end if;
                loop
                    wait until rising_edge(clk); wait for 1 ns;
                    exit when s_axis_tready = '1';
                end loop;
            end loop;
        end loop;
        s_axis_tvalid <= '0'; s_axis_tlast <= '0';

        wait until m_axis_tvalid = '1'; wait for 1 ns;

        -- Bin 0 word 0: tdc_deg=0
        assert to_integer(unsigned(m_axis_tdata)) = 0
            report "FAIL T8: bin 0 tdc_deg wrong" severity failure;

        -- Bin 0 word 1: DI=0xCD, pressure=100
        wait until rising_edge(clk); wait for 1 ns;
        assert m_axis_tdata(31 downto 24) = x"CD"
            report "FAIL T8: bin 0 DI wrong, expected 0xCD, got " &
                   to_hstring(m_axis_tdata(31 downto 24))
            severity failure;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 100
            report "FAIL T8: bin 0 pressure wrong, expected 100, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata(15 downto 4))))
            severity failure;

        -- Bin 1 word 0: tdc_deg=1
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(unsigned(m_axis_tdata)) = 1
            report "FAIL T8: bin 1 tdc_deg wrong" severity failure;

        -- Bin 1 word 1: DI=0x00, pressure=0
        wait until rising_edge(clk); wait for 1 ns;
        assert m_axis_tdata(31 downto 24) = x"00"
            report "FAIL T8: bin 1 DI should be 0" severity failure;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 0
            report "FAIL T8: bin 1 pressure should be 0" severity failure;

        drain_words(FRAME_WORDS - 4, m_axis_tvalid, m_axis_tready, clk);
        report "TEST 8: PASS";

        -- Done
        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All avg tests complete";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
