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
        -- Software-controlled active-low reset. Assert (drive low) to
        -- hold avg in reset while arming DMA1; release (drive high) once
        -- DMA1 is ready to accept data. Combines with rst internally.
        -- On release, accumulation waits for the first clean frame
        -- boundary before writing any data, so the output always starts
        -- at bin 0 of a complete engine cycle.
        avg_resetn : in std_logic;

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
        state_dbg           : out std_logic_vector(7 downto 0);
        -- Additional ILA debug ports
        bank0_state_dbg     : out std_logic_vector(2 downto 0);
        bank1_state_dbg     : out std_logic_vector(2 downto 0);
        out_bin_dbg         : out std_logic_vector(ADDR_W - 1 downto 0)
    );
end entity avg;

architecture rtl of avg is
    subtype addr_t is unsigned(ADDR_W - 1 downto 0);

    type sum_ram_t is array (0 to BINS - 1) of unsigned(31 downto 0);
    type di_ram_t  is array (0 to BINS - 1) of std_logic_vector(7 downto 0);

    -- sum0/sum1/di0/di1 are each accessed from two logically distinct
    -- roles: the accumulator (read-modify-write during ACC_READ/
    -- ACC_WRITE) and the output streamer/clearer (read during OUT_READ,
    -- write during OUT_CLEAR). Bank ownership (acc_bank/out_bank) always
    -- keeps these two roles pointed at *different* physical banks, so
    -- each individual array only ever needs one read/write port active
    -- at a time -- but the original code accessed each array from four
    -- separate if/elsif branches spread across the process, which Vivado
    -- could not map onto an inferable BRAM template (Synth 8-3391:
    -- "memory pattern used is not supported"). Restructured below into
    -- the standard single-port-RAM inference template (one address/
    -- data/we per array, address/data/we muxed by whichever role
    -- currently owns that bank) so each array has exactly one syntactic
    -- access point.
    signal sum0 : sum_ram_t := (others => (others => '0'));
    signal sum1 : sum_ram_t := (others => (others => '0'));
    signal di0  : di_ram_t  := (others => (others => '0'));
    signal di1  : di_ram_t  := (others => (others => '0'));

    -- Bank 0 port: address/write-data/write-enable muxed between
    -- accumulator and output roles; rdata is the registered BRAM output.
    signal bank0_addr  : addr_t := (others => '0');
    signal bank0_wdata : unsigned(31 downto 0) := (others => '0');
    signal bank0_we    : std_logic := '0';
    signal bank0_di_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal bank0_rdata : unsigned(31 downto 0);
    signal bank0_di_rdata : std_logic_vector(7 downto 0);

    -- Bank 1 port: same shape as bank 0.
    signal bank1_addr  : addr_t := (others => '0');
    signal bank1_wdata : unsigned(31 downto 0) := (others => '0');
    signal bank1_we    : std_logic := '0';
    signal bank1_di_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal bank1_rdata : unsigned(31 downto 0);
    signal bank1_di_rdata : std_logic_vector(7 downto 0);

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
    signal new_sum   : unsigned(31 downto 0) := (others => '0');

    signal prev_tdc      : addr_t := (others => '0');
    signal expected_bin  : addr_t := (others => '0');
    signal have_prev     : std_logic := '0';
    signal frames_window : unsigned(3 downto 0) := (others => '0'); -- max 8

    type out_state_t is (OUT_IDLE, OUT_READ, OUT_READ2, OUT_SEND0, OUT_SEND1, OUT_CLEAR, OUT_DONE);
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

    -- bank_state_t: EMPTY=0 ACCUM=1 FULL=2 STREAM=3 CLEAR=4 DONE=5
    bank0_state_dbg <= std_logic_vector(to_unsigned(bank_state_t'pos(bank0_state), 3));
    bank1_state_dbg <= std_logic_vector(to_unsigned(bank_state_t'pos(bank1_state), 3));
    out_bin_dbg     <= std_logic_vector(out_bin);

    -- =========================================================================
    -- BRAM port muxing: each bank's single read+write port is driven by
    -- whichever role (accumulator or output) currently owns that bank.
    -- The accumulator side is gated on lat_bank (the bank latched for the
    -- in-flight sample at ACC_IDLE), not acc_bank directly -- matching
    -- the original code's addressing exactly, and correct even in the
    -- edge case where acc_bank changes (a fresh bank claim) on the same
    -- cycle a sample is latched, since lat_bank is updated from the same
    -- post-claim value in that case (see ACC_IDLE). acc_bank and out_bank
    -- are never equal (ping-pong banking always keeps the accumulator
    -- and the output streamer/clearer pointed at different physical
    -- banks), so this mux is unambiguous -- exactly one role drives each
    -- bank's port at any given time.
    -- =========================================================================
    bank0_addr     <= lat_addr  when lat_bank = '0' and (acc_state = ACC_READ or acc_state = ACC_ADD or acc_state = ACC_WRITE)
                      else out_bin when out_bank = '0' and (out_state = OUT_READ or out_state = OUT_READ2)
                      else clr_bin;
    bank0_wdata    <= new_sum   when lat_bank = '0' else (others => '0');
    bank0_di_wdata <= lat_di    when lat_bank = '0' else (others => '0');
    bank0_we       <= '1' when (lat_bank = '0' and acc_state = ACC_WRITE)
                          or  (out_bank = '0' and out_state = OUT_CLEAR)
                     else '0';

    bank1_addr     <= lat_addr  when lat_bank = '1' and (acc_state = ACC_READ or acc_state = ACC_ADD or acc_state = ACC_WRITE)
                      else out_bin when out_bank = '1' and (out_state = OUT_READ or out_state = OUT_READ2)
                      else clr_bin;
    bank1_wdata    <= new_sum   when lat_bank = '1' else (others => '0');
    bank1_di_wdata <= lat_di    when lat_bank = '1' else (others => '0');
    bank1_we       <= '1' when (lat_bank = '1' and acc_state = ACC_WRITE)
                          or  (out_bank = '1' and out_state = OUT_CLEAR)
                     else '0';

    -- =========================================================================
    -- Bank 0 / Bank 1 BRAMs: single registered read+write port each, one
    -- standard inferable template per array (Synth 8-3391 fix -- see
    -- signal declaration comment above).
    -- =========================================================================
    p_bank0_sum : process(clk)
    begin
        if rising_edge(clk) then
            if bank0_we = '1' then
                sum0(to_integer(bank0_addr)) <= bank0_wdata;
            end if;
            bank0_rdata <= sum0(to_integer(bank0_addr));
        end if;
    end process p_bank0_sum;

    p_bank0_di : process(clk)
    begin
        if rising_edge(clk) then
            if bank0_we = '1' then
                di0(to_integer(bank0_addr)) <= bank0_di_wdata;
            end if;
            bank0_di_rdata <= di0(to_integer(bank0_addr));
        end if;
    end process p_bank0_di;

    p_bank1_sum : process(clk)
    begin
        if rising_edge(clk) then
            if bank1_we = '1' then
                sum1(to_integer(bank1_addr)) <= bank1_wdata;
            end if;
            bank1_rdata <= sum1(to_integer(bank1_addr));
        end if;
    end process p_bank1_sum;

    p_bank1_di : process(clk)
    begin
        if rising_edge(clk) then
            if bank1_we = '1' then
                di1(to_integer(bank1_addr)) <= bank1_di_wdata;
            end if;
            bank1_di_rdata <= di1(to_integer(bank1_addr));
        end if;
    end process p_bank1_di;

    p_main : process(clk)
        variable boundary       : boolean;
        variable target_reached : boolean;
        variable use_bank       : std_logic;
        variable next_frames    : unsigned(3 downto 0);
        variable diff           : integer;
        variable avg_p          : unsigned(31 downto 0);
        -- wait_frame as a variable so clearing it on the boundary
        -- detection cycle is immediately visible to the BRAM-write
        -- gate check later in the same process cycle. A signal would
        -- only update next clock, causing bin 0 of the first real
        -- frame to be incorrectly discarded.
        variable wait_frame     : std_logic := '1';
    begin
        if rising_edge(clk) then
            if rst = '1' or avg_resetn = '0' then
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
                wait_frame := '1';
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

                            -- If we're still waiting for the first clean
                            -- frame start after reset, clear the flag on
                            -- the first boundary but don't process it as
                            -- an accumulation event -- just let the sample
                            -- proceed as a normal first-bin write below.
                            if boundary and wait_frame = '1' then
                                wait_frame := '0';
                                boundary := false;
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
                            -- Only proceed to BRAM read-modify-write once
                            -- we have seen a clean frame boundary after
                            -- reset (wait_frame cleared above). Before
                            -- that, just track sequence without writing.
                            if wait_frame = '0' then
                                acc_state <= ACC_READ;
                            end if;
                        end if;

                    when ACC_READ =>
                        -- bank0_addr/bank1_addr already present lat_addr
                        -- this cycle (see mux above, gated on
                        -- acc_state=ACC_READ/ACC_ADD/ACC_WRITE). The
                        -- BRAM's registered read output is not valid
                        -- until the next cycle -- captured in ACC_ADD
                        -- below, not here, to match the one-cycle
                        -- latency (mirrors OUT_READ/OUT_READ2 on the
                        -- output side).
                        acc_state <= ACC_ADD;

                    when ACC_ADD =>
                        if lat_bank = '0' then
                            new_sum <= bank0_rdata + resize(lat_adc, 32);
                        else
                            new_sum <= bank1_rdata + resize(lat_adc, 32);
                        end if;
                        acc_state <= ACC_WRITE;

                    when ACC_WRITE =>
                        -- The actual write to sum0/sum1/di0/di1 happens
                        -- in p_bank0_sum/p_bank0_di/p_bank1_sum/p_bank1_di
                        -- via the bank0_we/bank1_we mux above (gated on
                        -- lat_bank and acc_state=ACC_WRITE), not here.
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
                        -- bank0_addr/bank1_addr already present out_bin this
                        -- cycle (see mux above); the BRAM's registered read
                        -- output is not valid until the next cycle, captured
                        -- in OUT_READ2.
                        m_valid <= '0';
                        m_last  <= '0';
                        out_state <= OUT_READ2;

                    when OUT_READ2 =>
                        if out_bank = '0' then
                            out_sum <= bank0_rdata;
                            out_di  <= bank0_di_rdata;
                        else
                            out_sum <= bank1_rdata;
                            out_di  <= bank1_di_rdata;
                        end if;
                        out_state <= OUT_SEND0;

                    when OUT_SEND0 =>
                        if m_valid = '0' or m_axis_tready = '1' then
                            m_data  <= std_logic_vector(resize(out_bin, 32));
                            m_valid <= '1';
                            -- Assert m_last here (word 0 of this bin) so
                            -- it is registered and stable when the DMA
                            -- accepts word 1 (the true last beat). If we
                            -- wait until OUT_SEND1 to set m_last, it only
                            -- takes effect the cycle *after* OUT_SEND1's
                            -- condition fires, producing a spurious extra
                            -- beat that triggers dma_internal_error.
                            m_last  <= '0';
                            if at_last_bin(out_bin) then
                                m_last <= '1';
                            end if;
                            out_state <= OUT_SEND1;
                        end if;

                    when OUT_SEND1 =>
                        if m_valid = '0' or m_axis_tready = '1' then
                            avg_p := shift_right(out_sum, to_integer(out_shift));
                            m_data  <= make_word1(out_di, avg_p(11 downto 0));
                            m_valid <= '1';
                            if at_last_bin(out_bin) then
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
                        -- The actual zeroing write happens in
                        -- p_bank0_sum/p_bank0_di/p_bank1_sum/p_bank1_di via
                        -- the bank0_we/bank1_we mux above (gated on out_bank
                        -- and out_state=OUT_CLEAR; bank*_wdata/bank*_di_wdata
                        -- default to all-zero whenever lat_bank doesn't
                        -- match, which is always true here since the
                        -- accumulator is on the other bank).
                        m_valid <= '0';
                        m_last <= '0';

                        if at_last_bin(clr_bin) then
                            out_state <= OUT_DONE;
                        else
                            clr_bin <= clr_bin + 1;
                        end if;

                    when OUT_DONE =>
                        -- Normal path: free the bank that just finished
                        -- streaming and clearing.
                        -- Recovery path: if the accumulator is stranded
                        -- (acc_bank points at a BANK_FULL bank because
                        -- the other bank was not EMPTY when the last
                        -- window completed), claim the newly-freed bank
                        -- for accumulation immediately rather than
                        -- leaving it EMPTY and waiting for the next
                        -- boundary event to find it -- which may never
                        -- happen while the output side is still catching
                        -- up from a DMA stall.
                        if out_bank = '0' then
                            if acc_bank = '0' and bank0_state = BANK_FULL then
                                -- Recovery: redirect stranded accumulator
                                -- to this bank instead of leaving EMPTY.
                                bank0_state   <= BANK_ACCUM;
                                acc_bank      <= '0';
                                acc_shift     <= avg_n;
                                bank0_shift   <= avg_n;
                                frames_window <= (others => '0');
                            else
                                bank0_state <= BANK_EMPTY;
                            end if;
                        else
                            if acc_bank = '1' and bank1_state = BANK_FULL then
                                bank1_state   <= BANK_ACCUM;
                                acc_bank      <= '1';
                                acc_shift     <= avg_n;
                                bank1_shift   <= avg_n;
                                frames_window <= (others => '0');
                            else
                                bank1_state <= BANK_EMPTY;
                            end if;
                        end if;
                        out_state <= OUT_IDLE;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
