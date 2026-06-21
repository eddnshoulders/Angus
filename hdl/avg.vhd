library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- avg_direct.vhd
--
-- Direct-sample crank-angle profile averaging block.
--
-- Intended use:
--   tdc/adc/di sample bus
--      |-- pack.vhd          -> raw DMA / saved data
--      `-- avg_direct.vhd    -> realtime averaged profile DMA
--
-- Input samples are written using tdc_deg as the accumulation address. An
-- internal expected-bin counter is used only for validation and resync. A missed
-- sample therefore creates a local under-sampled bin; it never shifts all later
-- samples.
--
-- Averaging window:
--   avg_n = 0..3 means 2^avg_n complete 720-degree frames per output frame.
--   avg_n is latched only when a new accumulation bank is claimed.
--   output average is sum >> latched_avg_n.
--
-- Output stream is pack-compatible, two 32-bit words per bin:
--   word0 = bin/tdc_deg as 32-bit unsigned
--   word1 = DI[31:24] | 0x00[23:16] | adc_avg[15:4] | 0x0[3:0]
--   tlast on word1 of the final bin.
--
-- The block is deliberately simple rather than one-sample-per-clock optimised.
-- At 20,000 rpm and 0.1 degree sampling the input rate is 2.4 MS/s, which gives
-- ~41 clocks/sample at 100 MHz.
-- =============================================================================

entity avg is
    generic (
        BINS   : positive := 7200;
        ADDR_W : positive := 13
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        sample_valid : in  std_logic;
        sample_ready : out std_logic;
        tdc_deg      : in  unsigned(ADDR_W - 1 downto 0);
        adc_ch0      : in  unsigned(11 downto 0);
        di_in        : in  std_logic_vector(7 downto 0);

        avg_n        : in  unsigned(1 downto 0); -- 0..3 only

        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic;

        -- Status/counters for AXI-lite exposure upstream
        frames_in_count     : out unsigned(31 downto 0);
        frames_out_count    : out unsigned(31 downto 0);
        samples_in_count    : out unsigned(31 downto 0);
        missed_sample_count : out unsigned(31 downto 0);
        out_of_order_count  : out unsigned(31 downto 0);
        bank_overrun_count  : out unsigned(31 downto 0);
        dropped_sample_count: out unsigned(31 downto 0);
        out_stall_count     : out unsigned(31 downto 0);
        state_dbg           : out std_logic_vector(7 downto 0)
    );
end entity avg;

architecture rtl of avg is
    subtype addr_t is unsigned(ADDR_W - 1 downto 0);

    type sum_ram_t is array (0 to BINS - 1) of unsigned(31 downto 0);
    type di_ram_t  is array (0 to BINS - 1) of std_logic_vector(7 downto 0);

    signal sum0 : sum_ram_t := (others => (others => '0'));
    signal sum1 : sum_ram_t := (others => (others => '0'));
    signal di0  : di_ram_t  := (others => (others => '0'));
    signal di1  : di_ram_t  := (others => (others => '0'));

    type bank_state_t is (BANK_EMPTY, BANK_ACCUM, BANK_FULL, BANK_STREAM, BANK_CLEAR);
    signal bank0_state : bank_state_t := BANK_ACCUM;
    signal bank1_state : bank_state_t := BANK_EMPTY;
    signal acc_bank    : std_logic := '0';
    signal out_bank    : std_logic := '0';
    signal bank0_shift : unsigned(1 downto 0) := (others => '0');
    signal bank1_shift : unsigned(1 downto 0) := (others => '0');
    signal acc_shift   : unsigned(1 downto 0) := (others => '0');
    signal out_shift   : unsigned(1 downto 0) := (others => '0');

    type acc_state_t is (ACC_IDLE, ACC_READ, ACC_ADD, ACC_WRITE);
    signal acc_state : acc_state_t := ACC_IDLE;
    signal lat_addr  : addr_t := (others => '0');
    signal lat_adc   : unsigned(11 downto 0) := (others => '0');
    signal lat_di    : std_logic_vector(7 downto 0) := (others => '0');
    signal lat_bank  : std_logic := '0';
    signal rd_sum    : unsigned(31 downto 0) := (others => '0');
    signal new_sum   : unsigned(31 downto 0) := (others => '0');

    signal prev_tdc      : addr_t := (others => '0');
    signal expected_bin  : addr_t := (others => '0');
    signal have_prev     : std_logic := '0';
    signal frames_window : unsigned(3 downto 0) := (others => '0'); -- max 8

    type out_state_t is (OUT_IDLE, OUT_READ, OUT_SEND0, OUT_SEND1, OUT_CLEAR, OUT_DONE);
    signal out_state : out_state_t := OUT_IDLE;
    signal out_bin   : addr_t := (others => '0');
    signal out_sum   : unsigned(31 downto 0) := (others => '0');
    signal out_di    : std_logic_vector(7 downto 0) := (others => '0');
    signal out_word0 : std_logic_vector(31 downto 0) := (others => '0');
    signal out_word1 : std_logic_vector(31 downto 0) := (others => '0');
    signal clr_bin   : addr_t := (others => '0');

    signal m_data  : std_logic_vector(31 downto 0) := (others => '0');
    signal m_valid : std_logic := '0';
    signal m_last  : std_logic := '0';

    -- Internal copy of sample_ready: needed because the entity's
    -- sample_ready is an 'out' port and cannot be read directly (this
    -- compiles under GHDL but Vivado's synthesizer enforces the
    -- restriction strictly -- Synth 8-10557).
    signal sample_ready_i : std_logic;

    signal c_frames_in      : unsigned(31 downto 0) := (others => '0');
    signal c_frames_out     : unsigned(31 downto 0) := (others => '0');
    signal c_samples_in     : unsigned(31 downto 0) := (others => '0');
    signal c_missed         : unsigned(31 downto 0) := (others => '0');
    signal c_ooo            : unsigned(31 downto 0) := (others => '0');
    signal c_overrun        : unsigned(31 downto 0) := (others => '0');
    signal c_dropped        : unsigned(31 downto 0) := (others => '0');
    signal c_out_stall      : unsigned(31 downto 0) := (others => '0');

    function target_frames(n : unsigned(1 downto 0)) return unsigned is
        variable r : unsigned(3 downto 0) := (others => '0');
    begin
        case to_integer(n) is
            when 0 => r := to_unsigned(1, 4);
            when 1 => r := to_unsigned(2, 4);
            when 2 => r := to_unsigned(4, 4);
            when others => r := to_unsigned(8, 4);
        end case;
        return r;
    end function;

    function at_last_bin(a : addr_t) return boolean is
    begin
        return to_integer(a) = BINS - 1;
    end function;

    function inc_bin(a : addr_t) return addr_t is
    begin
        if to_integer(a) = BINS - 1 then
            return (others => '0');
        else
            return a + 1;
        end if;
    end function;

    function make_word1(d : std_logic_vector(7 downto 0); p : unsigned(11 downto 0)) return std_logic_vector is
        variable w : std_logic_vector(31 downto 0) := (others => '0');
    begin
        w(31 downto 24) := d;
        w(23 downto 16) := x"00";
        w(15 downto 4)  := std_logic_vector(p);
        w(3 downto 0)   := "0000";
        return w;
    end function;

begin
    sample_ready_i <= '1' when acc_state = ACC_IDLE and
                             ((acc_bank = '0' and bank0_state = BANK_ACCUM) or
                              (acc_bank = '1' and bank1_state = BANK_ACCUM)) else '0';
    sample_ready <= sample_ready_i;

    m_axis_tdata  <= m_data;
    m_axis_tvalid <= m_valid;
    m_axis_tlast  <= m_last;

    frames_in_count      <= c_frames_in;
    frames_out_count     <= c_frames_out;
    samples_in_count     <= c_samples_in;
    missed_sample_count  <= c_missed;
    out_of_order_count   <= c_ooo;
    bank_overrun_count   <= c_overrun;
    dropped_sample_count <= c_dropped;
    out_stall_count      <= c_out_stall;

    state_dbg(1 downto 0) <= std_logic_vector(to_unsigned(acc_state_t'pos(acc_state), 2));
    state_dbg(4 downto 2) <= std_logic_vector(to_unsigned(out_state_t'pos(out_state), 3));
    state_dbg(5) <= acc_bank;
    state_dbg(6) <= out_bank;
    state_dbg(7) <= '0';

    p_main : process(clk)
        variable boundary       : boolean;
        variable target_reached : boolean;
        variable use_bank       : std_logic;
        variable next_frames    : unsigned(3 downto 0);
        variable diff           : integer;
        variable avg_p          : unsigned(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bank0_state <= BANK_ACCUM;
                bank1_state <= BANK_EMPTY;
                acc_bank    <= '0';
                out_bank    <= '0';
                bank0_shift <= avg_n;
                bank1_shift <= (others => '0');
                acc_shift   <= avg_n;
                out_shift   <= (others => '0');

                acc_state <= ACC_IDLE;
                out_state <= OUT_IDLE;
                frames_window <= (others => '0');
                expected_bin <= (others => '0');
                prev_tdc <= (others => '0');
                have_prev <= '0';
                out_bin <= (others => '0');
                clr_bin <= (others => '0');
                m_valid <= '0';
                m_last <= '0';
                m_data <= (others => '0');

                c_frames_in <= (others => '0');
                c_frames_out <= (others => '0');
                c_samples_in <= (others => '0');
                c_missed <= (others => '0');
                c_ooo <= (others => '0');
                c_overrun <= (others => '0');
                c_dropped <= (others => '0');
                c_out_stall <= (others => '0');
            else
                -- Count input attempts that arrive while the deliberately slow
                -- accumulator is not ready. With the real 2.4 MS/s maximum this
                -- should remain zero if upstream obeys sample_ready or samples
                -- are naturally spaced by many PL clocks.
                if sample_valid = '1' and sample_ready_i = '0' then
                    c_dropped <= c_dropped + 1;
                end if;

                -- Accumulator: simple multi-cycle read-modify-write.
                case acc_state is
                    when ACC_IDLE =>
                        if sample_valid = '1' and sample_ready_i = '1' then
                            boundary := false;
                            target_reached := false;
                            use_bank := acc_bank;

                            -- A tdc_deg decrease, normally 7199 -> 0, marks a
                            -- new input frame. The new sample belongs to the new
                            -- frame, so bank switching is handled before latching
                            -- this sample for accumulation.
                            if have_prev = '1' and tdc_deg < prev_tdc then
                                boundary := true;
                            end if;

                            if boundary then
                                c_frames_in <= c_frames_in + 1;
                                next_frames := frames_window + 1;
                                if next_frames >= target_frames(acc_shift) then
                                    target_reached := true;
                                end if;

                                if target_reached then
                                    if acc_bank = '0' then
                                        bank0_state <= BANK_FULL;
                                        bank0_shift <= acc_shift;
                                        if bank1_state = BANK_EMPTY then
                                            bank1_state <= BANK_ACCUM;
                                            acc_bank <= '1';
                                            use_bank := '1';
                                            acc_shift <= avg_n; -- latch setting for new binning cycle
                                            bank1_shift <= avg_n;
                                            frames_window <= (others => '0');
                                        else
                                            c_overrun <= c_overrun + 1;
                                            frames_window <= (others => '0');
                                        end if;
                                    else
                                        bank1_state <= BANK_FULL;
                                        bank1_shift <= acc_shift;
                                        if bank0_state = BANK_EMPTY then
                                            bank0_state <= BANK_ACCUM;
                                            acc_bank <= '0';
                                            use_bank := '0';
                                            acc_shift <= avg_n; -- latch setting for new binning cycle
                                            bank0_shift <= avg_n;
                                            frames_window <= (others => '0');
                                        else
                                            c_overrun <= c_overrun + 1;
                                            frames_window <= (others => '0');
                                        end if;
                                    end if;
                                else
                                    frames_window <= next_frames;
                                end if;
                            end if;

                            -- Sequence validation. tdc_deg is authoritative for
                            -- the write address; expected_bin only flags/resyncs.
                            if have_prev = '1' then
                                if tdc_deg = expected_bin then
                                    null;
                                elsif tdc_deg > expected_bin then
                                    diff := to_integer(tdc_deg) - to_integer(expected_bin);
                                    c_missed <= c_missed + to_unsigned(diff, 32);
                                else
                                    if tdc_deg /= 0 then
                                        c_ooo <= c_ooo + 1;
                                    end if;
                                end if;
                            end if;

                            lat_addr <= tdc_deg;
                            lat_adc  <= adc_ch0;
                            lat_di   <= di_in;
                            lat_bank <= use_bank;
                            prev_tdc <= tdc_deg;
                            expected_bin <= inc_bin(tdc_deg);
                            have_prev <= '1';
                            c_samples_in <= c_samples_in + 1;
                            acc_state <= ACC_READ;
                        end if;

                    when ACC_READ =>
                        if lat_bank = '0' then
                            rd_sum <= sum0(to_integer(lat_addr));
                        else
                            rd_sum <= sum1(to_integer(lat_addr));
                        end if;
                        acc_state <= ACC_ADD;

                    when ACC_ADD =>
                        new_sum <= rd_sum + resize(lat_adc, 32);
                        acc_state <= ACC_WRITE;

                    when ACC_WRITE =>
                        if lat_bank = '0' then
                            sum0(to_integer(lat_addr)) <= new_sum;
                            di0(to_integer(lat_addr))  <= lat_di;
                        else
                            sum1(to_integer(lat_addr)) <= new_sum;
                            di1(to_integer(lat_addr))  <= lat_di;
                        end if;
                        acc_state <= ACC_IDLE;
                end case;

                -- Output streamer and clearer. It only ever claims FULL banks.
                -- Deterministic priority: bank0 before bank1 if both are full.
                if m_valid = '1' and m_axis_tready = '0' then
                    c_out_stall <= c_out_stall + 1;
                end if;

                case out_state is
                    when OUT_IDLE =>
                        m_valid <= '0';
                        m_last <= '0';
                        if bank0_state = BANK_FULL then
                            bank0_state <= BANK_STREAM;
                            out_bank <= '0';
                            out_shift <= bank0_shift;
                            out_bin <= (others => '0');
                            out_state <= OUT_READ;
                        elsif bank1_state = BANK_FULL then
                            bank1_state <= BANK_STREAM;
                            out_bank <= '1';
                            out_shift <= bank1_shift;
                            out_bin <= (others => '0');
                            out_state <= OUT_READ;
                        end if;

                    when OUT_READ =>
                        -- Deassert TVALID while preparing the next bin. Without
                        -- this, the previous data beat can be accepted again
                        -- during the BRAM/read preparation cycle when TREADY is
                        -- held high by the downstream DMA/testbench.
                        m_valid <= '0';
                        m_last  <= '0';
                        if out_bank = '0' then
                            out_sum <= sum0(to_integer(out_bin));
                            out_di  <= di0(to_integer(out_bin));
                        else
                            out_sum <= sum1(to_integer(out_bin));
                            out_di  <= di1(to_integer(out_bin));
                        end if;
                        out_state <= OUT_SEND0;

                    when OUT_SEND0 =>
                        if m_valid = '0' or m_axis_tready = '1' then
                            m_data  <= std_logic_vector(resize(out_bin, 32));
                            m_valid <= '1';
                            m_last  <= '0';
                            out_state <= OUT_SEND1;
                        end if;

                    when OUT_SEND1 =>
                        if m_valid = '0' or m_axis_tready = '1' then
                            avg_p := shift_right(out_sum, to_integer(out_shift));
                            m_data  <= make_word1(out_di, avg_p(11 downto 0));
                            m_valid <= '1';
                            if at_last_bin(out_bin) then
                                m_last <= '1';
                                clr_bin <= (others => '0');
                                out_state <= OUT_CLEAR;
                                c_frames_out <= c_frames_out + 1;
                            else
                                m_last <= '0';
                                out_bin <= out_bin + 1;
                                out_state <= OUT_READ;
                            end if;
                        end if;

                    when OUT_CLEAR =>
                        -- Clear one bin per clock. This runs only on the bank
                        -- just streamed, so it cannot collide with accumulation.
                        m_valid <= '0';
                        m_last <= '0';
                        if out_bank = '0' then
                            sum0(to_integer(clr_bin)) <= (others => '0');
                            di0(to_integer(clr_bin))  <= (others => '0');
                        else
                            sum1(to_integer(clr_bin)) <= (others => '0');
                            di1(to_integer(clr_bin))  <= (others => '0');
                        end if;

                        if at_last_bin(clr_bin) then
                            out_state <= OUT_DONE;
                        else
                            clr_bin <= clr_bin + 1;
                        end if;

                    when OUT_DONE =>
                        if out_bank = '0' then
                            bank0_state <= BANK_EMPTY;
                        else
                            bank1_state <= BANK_EMPTY;
                        end if;
                        out_state <= OUT_IDLE;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
