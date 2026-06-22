library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity avg_tb is
end entity;

architecture tb of avg_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant BINS_C     : positive := 16;
    constant ADDR_W_C   : positive := 4;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';

    signal sample_valid : std_logic := '0';
    signal sample_ready : std_logic;
    signal tdc_deg      : unsigned(ADDR_W_C - 1 downto 0) := (others => '0');
    signal adc_ch0      : unsigned(11 downto 0) := (others => '0');
    signal di_in        : std_logic_vector(7 downto 0) := (others => '0');
    signal avg_n        : unsigned(1 downto 0) := (others => '0');

    signal m_axis_tdata  : std_logic_vector(31 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '0';
    signal m_axis_tlast  : std_logic;

    signal frames_in_count      : unsigned(31 downto 0);
    signal frames_out_count     : unsigned(31 downto 0);
    signal samples_in_count     : unsigned(31 downto 0);
    signal missed_sample_count  : unsigned(31 downto 0);
    signal out_of_order_count   : unsigned(31 downto 0);
    signal bank_overrun_count   : unsigned(31 downto 0);
    signal dropped_sample_count : unsigned(31 downto 0);
    signal out_stall_count      : unsigned(31 downto 0);
    signal state_dbg            : std_logic_vector(7 downto 0);

    procedure wait_clk(signal clk_s : in std_logic; n : natural := 1) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk_s);
        end loop;
    end procedure;

    procedure send_sample(
        signal clk_s   : in std_logic;
        signal valid_s : out std_logic;
        signal ready_s : in std_logic;
        signal deg_s   : out unsigned(ADDR_W_C - 1 downto 0);
        signal adc_s   : out unsigned(11 downto 0);
        signal di_s    : out std_logic_vector(7 downto 0);
        constant deg_v  : natural;
        constant adc_v  : natural;
        constant di_v   : natural
    ) is
    begin
        deg_s   <= to_unsigned(deg_v, ADDR_W_C);
        adc_s   <= to_unsigned(adc_v, 12);
        di_s    <= std_logic_vector(to_unsigned(di_v, 8));
        valid_s <= '1';
        loop
            wait until rising_edge(clk_s);
            wait for 1 ns;
            exit when ready_s = '1';
        end loop;
        valid_s <= '0';
        wait until rising_edge(clk_s);
    end procedure;

    procedure send_frame(
        signal clk_s   : in std_logic;
        signal valid_s : out std_logic;
        signal ready_s : in std_logic;
        signal deg_s   : out unsigned(ADDR_W_C - 1 downto 0);
        signal adc_s   : out unsigned(11 downto 0);
        signal di_s    : out std_logic_vector(7 downto 0);
        constant base_adc : natural;
        constant di_v     : natural
    ) is
    begin
        for b in 0 to BINS_C - 1 loop
            send_sample(clk_s, valid_s, ready_s, deg_s, adc_s, di_s, b, base_adc + b, di_v);
        end loop;
    end procedure;

    procedure get_beat(
        signal clk_s   : in std_logic;
        signal valid_s : in std_logic;
        signal ready_s : in std_logic;
        signal data_s  : in std_logic_vector(31 downto 0);
        signal last_s  : in std_logic;
        variable data_v : out std_logic_vector(31 downto 0);
        variable last_v : out std_logic
    ) is
    begin
        -- Capture data while it is stable before the clock edge that accepts
        -- the AXI beat. Sampling after the rising edge can accidentally read
        -- the next beat from a registered master.
        loop
            wait until falling_edge(clk_s);
            if valid_s = '1' and ready_s = '1' then
                data_v := data_s;
                last_v := last_s;
                wait until rising_edge(clk_s);
                exit;
            end if;
        end loop;
    end procedure;

    procedure expect_frame(
        signal clk_s   : in std_logic;
        signal valid_s : in std_logic;
        signal ready_s : inout std_logic;
        signal data_s  : in std_logic_vector(31 downto 0);
        signal last_s  : in std_logic;
        constant base_adc : natural;
        constant di_v     : natural
    ) is
        variable d : std_logic_vector(31 downto 0);
        variable l : std_logic;
        variable expected_word1 : std_logic_vector(31 downto 0);
    begin
        -- Hold the output stream stalled until the checker is ready. This makes
        -- bin 0 word 0 the first accepted beat rather than allowing the DUT to
        -- stream part of a frame before expect_frame starts listening.
        -- Assert ready, then let get_beat capture the already-present
        -- first beat before the next rising edge accepts it. Do not wait for a
        -- rising edge here, because that would accept and discard bin 0 word 0
        -- before the checker starts reading.
        ready_s <= '1';
        wait for 1 ns;

        for b in 0 to BINS_C - 1 loop
            get_beat(clk_s, valid_s, ready_s, data_s, last_s, d, l);
            assert d = std_logic_vector(to_unsigned(b, 32))
                report "bin word mismatch. got 0x" & to_hstring(d) & " expected bin " & integer'image(b)
                severity failure;
            -- tlast is pre-asserted on word 0 of the last bin (lookahead,
            -- so it is registered and stable when word 1 is accepted).
            if b < BINS_C - 1 then
                assert l = '0'
                    report "tlast asserted on bin word (not last bin)"
                    severity failure;
            end if;

            get_beat(clk_s, valid_s, ready_s, data_s, last_s, d, l);
            expected_word1 := std_logic_vector(to_unsigned(di_v, 8)) & x"00" &
                              std_logic_vector(to_unsigned(base_adc + b, 12)) & "0000";
            assert d = expected_word1
                report "data word mismatch at bin " & integer'image(b) &
                       ". got 0x" & to_hstring(d) & " expected 0x" & to_hstring(expected_word1)
                severity failure;
            if b = BINS_C - 1 then
                assert l = '1' report "missing tlast on final data word" severity failure;
            else
                assert l = '0' report "early tlast" severity failure;
            end if;
        end loop;

        ready_s <= '0';
        wait until rising_edge(clk_s);
    end procedure;

begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.avg
        generic map (
            BINS => BINS_C,
            ADDR_W => ADDR_W_C
        )
        port map (
            clk => clk,
            rst => rst,
            avg_resetn => '1',  -- always released in testbench
            sample_valid => sample_valid,
            sample_ready => sample_ready,
            tdc_deg => tdc_deg,
            adc_ch0 => adc_ch0,
            di_in => di_in,
            avg_n => avg_n,
            m_axis_tdata => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready,
            m_axis_tlast => m_axis_tlast,
            frames_in_count => frames_in_count,
            frames_out_count => frames_out_count,
            samples_in_count => samples_in_count,
            missed_sample_count => missed_sample_count,
            out_of_order_count => out_of_order_count,
            bank_overrun_count => bank_overrun_count,
            dropped_sample_count => dropped_sample_count,
            out_stall_count => out_stall_count,
            state_dbg => state_dbg
        );

    stim : process
        variable d_tmp : std_logic_vector(31 downto 0);
        variable l_tmp : std_logic;
    begin
        report "TEST 0: reset";
        rst <= '1';
        wait_clk(clk, 5);
        rst <= '0';
        wait_clk(clk, 5);

        -- After reset, avg discards samples until the first frame boundary
        -- (tdc_deg decrease) so that accumulation always starts at bin 0
        -- of a complete engine cycle. Send one dummy frame here to trigger
        -- that boundary; its data is not accumulated (wait_frame='1' until
        -- the wrap to bin 0 that starts the next frame).
        send_frame(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, 0, 16#00#);

        report "TEST 1: avg_n=0 uses binning path, one frame in gives one frame out";
        avg_n <= to_unsigned(0, 2);
        send_frame(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, 100, 16#A5#);

        -- Set avg_n before the wrap sample that starts the next accumulation
        -- bank. Per the design rule, avg_n is latched only when a new
        -- binning cycle/bank is claimed. Changing it after this sample would
        -- be too late for the 200/300 two-frame window.
        avg_n <= to_unsigned(1, 2);

        -- Send first sample of next frame to create the 15->0 wrap boundary.
        -- This sample belongs to the new avg_n=1 accumulation window.
        send_sample(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, 0, 200, 16#5A#);
        expect_frame(clk, m_axis_tvalid, m_axis_tready, m_axis_tdata, m_axis_tlast, 100, 16#A5#);

        report "TEST 2: avg_n change latches at new accumulation cycle";
        -- The first sample of this frame was already sent above with adc=200.
        for b in 1 to BINS_C - 1 loop
            send_sample(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, b, 200 + b, 16#5A#);
        end loop;
        send_frame(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, 300, 16#5A#);
        -- Boundary to close the second frame of the avg_n=1 window and start
        -- a new avg_n=1 window with bin 0 = 400.
        send_sample(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, 0, 400, 16#11#);
        -- Average of 200+b and 300+b is 250+b.
        expect_frame(clk, m_axis_tvalid, m_axis_tready, m_axis_tdata, m_axis_tlast, 250, 16#5A#);

        report "TEST 3: missed sample is counted and does not shift following bins";
        avg_n <= to_unsigned(0, 2);
        -- Complete the frame that started with bin 0 = 400, but skip bin 5.
        for b in 1 to BINS_C - 1 loop
            if b /= 5 then
                send_sample(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, b, 400 + b, 16#11#);
            end if;
        end loop;
        send_sample(clk, sample_valid, sample_ready, tdc_deg, adc_ch0, di_in, 0, 500, 16#22#);
        -- The realtime output should still be angularly aligned. We only assert
        -- the counter here; a full missing-bin data check can be added once the
        -- desired display policy for under-sampled bins is finalised.
        assert missed_sample_count > 0
            report "missed sample counter did not increment"
            severity failure;

        report "PASS: all avg_direct tests completed";
        std.env.stop;
		
    end process;
end architecture;
