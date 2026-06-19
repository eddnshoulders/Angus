-- Fast simulation variant: short INPUT frames (16 bins) instead of 7200.
-- avg.vhd's BINS is a fixed constant (7200), not a generic, and the
-- output FSM always streams out_bin 0..BINS-1 regardless of how many
-- input bins were sent or when input tlast arrived -- there is no way
-- to shorten the OUTPUT side without modifying avg.vhd itself. So this
-- testbench speeds up only the input/accumulation phase (16 words vs
-- 7200 per frame); draining a full output frame still walks all 7200
-- output bins, same as avg_tb.vhd. Useful for quickly exercising
-- accumulation-side behaviour (bypass, N changes, accumulator timing)
-- without the full 7200-word input cost; output-side drain time is
-- unchanged from the full testbench.
--
-- Packet format matches avg.vhd's current 2-word-per-bin layout:
--   Word 0: tdc_deg = bin index
--   Word 1: DI[31:24] | 0x00 | pressure_avg[15:4] | 0x0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.env.all;

entity avg_tb_fast is
end entity avg_tb_fast;

architecture sim of avg_tb_fast is

    constant CLK_PERIOD     : time    := 10 ns;
    constant BINS           : integer := 16;  -- short INPUT frame only, see header note
    constant WORDS_PER_BIN  : integer := 2;

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

    -- Diagnostic counters under test (avg<->DMA1 handshake visibility)
    signal in_beat_count   : unsigned(31 downto 0);
    signal out_beat_count  : unsigned(31 downto 0);
    signal out_tlast_count : unsigned(31 downto 0);
    signal out_stall_count : unsigned(31 downto 0);
    signal bad_tlast_count : unsigned(31 downto 0);
    signal out_state_dbg   : std_logic_vector(2 downto 0);

    -- Send one short frame: BINS samples, 2 words each (tdc_deg, DI|pressure)
    procedure send_frame (
        constant pressure   : in integer;
        constant di         : in integer;
        signal   tdata      : out std_logic_vector(31 downto 0);
        signal   tvalid     : out std_logic;
        signal   tlast      : out std_logic;
        signal   tready     : in  std_logic;
        signal   clk_p      : in  std_logic
    ) is
    begin
        tvalid <= '1';
        for bin in 0 to BINS - 1 loop
            tlast <= '0';
            -- Word 0: tdc_deg = bin index
            tdata <= std_logic_vector(to_unsigned(bin, 32));
            loop
                wait until rising_edge(clk_p); wait for 1 ns;
                exit when tready = '1';
            end loop;
            -- Word 1: DI | pressure
            tdata <= std_logic_vector(to_unsigned(di, 8)) &
                     x"00" &
                     std_logic_vector(to_unsigned(pressure * 16, 16));
            if bin = BINS - 1 then tlast <= '1'; end if;
            loop
                wait until rising_edge(clk_p); wait for 1 ns;
                exit when tready = '1';
            end loop;
        end loop;
        tvalid <= '0';
        tlast  <= '0';
        wait until rising_edge(clk_p);
    end procedure send_frame;

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
            frame_count     => frame_count,
            in_beat_count   => in_beat_count,
            out_beat_count  => out_beat_count,
            out_tlast_count => out_tlast_count,
            out_stall_count => out_stall_count,
            bad_tlast_count => bad_tlast_count,
            out_state_dbg   => out_state_dbg
        );

    p_stim : process
        variable data_v       : std_logic_vector(31 downto 0);
        variable fc_before    : unsigned(31 downto 0);
        variable stall_before : unsigned(31 downto 0);
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
        report "TEST 2: Bypass (N=0)";
        test_num <= 2;
        avg_n <= to_unsigned(0, 4);
        m_axis_tready <= '1';
        s_axis_tdata  <= x"00000064";
        s_axis_tvalid <= '1';
        s_axis_tlast  <= '0';
        wait until rising_edge(clk) and s_axis_tready = '1'; wait for 1 ns;
        assert m_axis_tvalid = '1'
            report "FAIL T2: tvalid in bypass" severity failure;
        assert m_axis_tdata = x"00000064"
            report "FAIL T2: word 0 mismatch in bypass" severity failure;
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

        -- T3: N=1, 2 short frames, pressure=100, DI=0xAB
        report "TEST 3: N=1 -- 2 short frames, pressure=100, DI=0xAB";
        test_num <= 3;
        avg_n <= to_unsigned(1, 4);
        m_axis_tready <= '1';
        fc_before := frame_count;

        send_frame(100, 16#AB#, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(100, 16#AB#, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        wait until m_axis_tvalid = '1'; wait for 1 ns;

        -- Bin 0, word 0: tdc_deg = 0
        assert to_integer(unsigned(m_axis_tdata)) = 0
            report "FAIL T3: bin 0 word 0 (tdc_deg) wrong, expected 0, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata)))
            severity failure;

        -- Bin 0, word 1: DI=0xAB, pressure=100
        wait until rising_edge(clk); wait for 1 ns;
        assert m_axis_tdata(31 downto 24) = x"AB"
            report "FAIL T3: bin 0 DI wrong, expected 0xAB" severity failure;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 100
            report "FAIL T3: bin 0 pressure wrong, expected 100, got " &
                   integer'image(to_integer(unsigned(m_axis_tdata(15 downto 4))))
            severity failure;
        report "TEST 3: bin 0 = 100 PASS";

        -- Drain remaining bins by waiting for tlast rather than a
        -- derived beat count. NOTE: avg.vhd's output FSM always walks
        -- the full 7200-bin frame regardless of how few input bins
        -- were sent (out_bin is checked against the fixed BINS=7200
        -- constant, not against where input tlast arrived) -- so this
        -- wait still takes the full output-frame duration even though
        -- only 16 input bins were driven. Bins beyond what we sent
        -- (16..7199) were never written this accumulation cycle, so
        -- they read back whatever OUT_CLR last zeroed them to: 0.
        -- Wait for bin 7199 (real BINS-1) word 0 -- tdc_deg = 7199 --
        -- then advance one more edge to reach word 1 where tlast is
        -- registered and stable. Matches avg_tb.vhd's proven sequencing
        -- rather than a single compound wait (which can land one delta
        -- cycle late and miss the pulse).
        m_axis_tready <= '1';
        loop
            wait until rising_edge(clk); wait for 1 ns;
            exit when m_axis_tvalid = '1'
                  and m_axis_tdata = std_logic_vector(to_unsigned(7199, 32));
        end loop;

        -- Bin 7199, word 1: tlast asserted here.
        -- We never sent data for this bin, so expect a cleared/zero
        -- pressure value, not the 100 we drove into bins 0..15.
        wait until rising_edge(clk); wait for 1 ns;
        assert m_axis_tlast = '1'
            report "FAIL T3: tlast not asserted on final word" severity failure;
        assert to_integer(unsigned(m_axis_tdata(15 downto 4))) = 0
            report "FAIL T3: bin 7199 pressure should be 0 (never written), got " &
                   integer'image(to_integer(unsigned(m_axis_tdata(15 downto 4))))
            severity failure;

        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert frame_count = fc_before + 1
            report "FAIL T3: frame_count did not increment" severity failure;

        -- Diagnostic counter checks: clean run, no backpressure.
        -- Output frame is always the full 7200 bins x 2 words,
        -- regardless of the short 16-bin input frame above.
        assert to_integer(out_beat_count) = 7200 * 2
            report "FAIL T3: out_beat_count expected " &
                   integer'image(7200 * 2) & ", got " &
                   integer'image(to_integer(out_beat_count))
            severity failure;
        assert to_integer(out_tlast_count) = 1
            report "FAIL T3: out_tlast_count expected 1, got " &
                   integer'image(to_integer(out_tlast_count))
            severity failure;
        assert to_integer(out_stall_count) = 0
            report "FAIL T3: out_stall_count expected 0, got " &
                   integer'image(to_integer(out_stall_count))
            severity failure;
        assert to_integer(bad_tlast_count) = 0
            report "FAIL T3: bad_tlast_count expected 0, got " &
                   integer'image(to_integer(bad_tlast_count))
            severity failure;
        report "TEST 3: PASS";
        wait for 10 * CLK_PERIOD;

        -- T4: Back-pressure mid-frame
        report "TEST 4: Back-pressure mid-frame";
        test_num <= 4;
        avg_n <= to_unsigned(1, 4);

        send_frame(50, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);
        send_frame(50, 0, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                   s_axis_tready, clk);

        m_axis_tready <= '1';
        wait until m_axis_tvalid = '1'; wait for 1 ns;
        data_v := m_axis_tdata;
        m_axis_tready <= '0';
        stall_before := out_stall_count;
        wait for 10 * CLK_PERIOD;

        assert m_axis_tvalid = '1'
            report "FAIL T4: tvalid dropped under back-pressure" severity failure;
        assert m_axis_tdata = data_v
            report "FAIL T4: data changed under back-pressure" severity failure;
        assert to_integer(out_stall_count) = to_integer(stall_before) + 10
            report "FAIL T4: out_stall_count expected +10, got +" &
                   integer'image(to_integer(out_stall_count) - to_integer(stall_before))
            severity failure;
        assert out_state_dbg = "100"  -- OUT_STREAM
            report "FAIL T4: expected out_state_dbg=OUT_STREAM during stall, got " &
                   to_hstring(out_state_dbg)
            severity failure;

        m_axis_tready <= '1';
        loop
            wait until rising_edge(clk); wait for 1 ns;
            exit when m_axis_tvalid = '1' and m_axis_tlast = '1';
        end loop;
        wait for 5 * CLK_PERIOD;
        report "TEST 4: PASS";

        -- Done
        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All avg fast tests PASS";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;
    end process p_stim;

end architecture sim;
