library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- avg.vhd
--
-- Theta-P averaging accumulator.
-- Consumes the raw AXI-Stream from pack.vhd and produces a second AXI-Stream
-- of averaged pressure vs crank-angle frames for the display DMA path.
--
-- Input stream (from pack.vhd):
--   Word 0: [31:0]  tdc_deg  (0-7199, used directly as bin address)
--   Word 1: [31:0]  DI + pressure  (pressure in [15:4])
--   tlast asserted on Word 1 of the last sample in each engine cycle
--
-- Output stream (to avg DMA):
--   Word 0:          rpm        (captured at frame boundary)
--   Word 1:          N          (averaging depth, 0 = bypass)
--   Words 2..7201:   averaged pressure bins (bin 0..7199, angle implicit)
--   tlast asserted on Word 7201
--
-- Averaging:
--   N = 0: bypass mode. Raw stream passes directly to output.
--   N > 0: accumulate 2^N engine cycles, output averaged frame.
--          Average = sum >> N (right shift, exact for power-of-2 counts).
--
-- Double buffering:
--   Bank A (addresses 0..7199) and Bank B (addresses 7200..14399).
--   Implemented as two independent single-port BRAMs to avoid VHDL-2008
--   protected-type requirement for shared variables.
-- =============================================================================

entity avg is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- Raw input stream (from pack.vhd)
        s_axis_tdata    : in  std_logic_vector(31 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;
        s_axis_tlast    : in  std_logic;

        -- Averaged output stream (to avg DMA)
        m_axis_tdata    : out std_logic_vector(31 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;

        -- Control inputs
        avg_n           : in  unsigned(3 downto 0);
        rpm             : in  unsigned(15 downto 0);

        -- Status
        frame_count     : out unsigned(31 downto 0)
    );
end entity avg;

architecture rtl of avg is

    -- =========================================================================
    -- BRAM: two independent 7200 x 32-bit single-port RAMs (ping-pong banks)
    -- Port A used by accumulator FSM (read-modify-write)
    -- Port B used by output generator FSM (read + clear)
    -- acc_bank selects which physical RAM the accumulator uses.
    -- =========================================================================
    constant BINS       : integer := 7200;

    type t_bram is array (0 to BINS - 1) of unsigned(31 downto 0);

    -- Bank 0
    signal ram0         : t_bram := (others => (others => '0'));
    signal r0_addr      : unsigned(12 downto 0) := (others => '0');
    signal r0_wdata     : unsigned(31 downto 0) := (others => '0');
    signal r0_rdata     : unsigned(31 downto 0);
    signal r0_we        : std_logic := '0';

    -- Bank 1
    signal ram1         : t_bram := (others => (others => '0'));
    signal r1_addr      : unsigned(12 downto 0) := (others => '0');
    signal r1_wdata     : unsigned(31 downto 0) := (others => '0');
    signal r1_rdata     : unsigned(31 downto 0);
    signal r1_we        : std_logic := '0';

    -- =========================================================================
    -- Bank routing: accumulator and output use opposite banks
    -- =========================================================================
    signal acc_bank     : std_logic := '0';  -- 0=acc uses ram0, 1=acc uses ram1

    -- Muxed read data back to accumulator FSM
    signal acc_rdata    : unsigned(31 downto 0);
    -- Muxed read data back to output FSM
    signal out_rdata    : unsigned(31 downto 0);

    -- Accumulator BRAM port signals
    signal acc_addr     : unsigned(12 downto 0) := (others => '0');
    signal acc_wdata    : unsigned(31 downto 0) := (others => '0');
    signal acc_we       : std_logic := '0';

    -- Output BRAM port signals
    signal out_addr     : unsigned(12 downto 0) := (others => '0');
    signal out_wdata    : unsigned(31 downto 0) := (others => '0');
    signal out_we       : std_logic := '0';

    -- =========================================================================
    -- Accumulator FSM
    -- =========================================================================
    type t_acc_state is (ACC_IDLE, ACC_READ, ACC_WRITE, ACC_WAIT_SWAP);
    signal acc_state    : t_acc_state := ACC_IDLE;

    signal word_cnt     : std_logic := '0';
    signal s_tdc        : unsigned(12 downto 0) := (others => '0');
    signal s_pressure   : unsigned(11 downto 0) := (others => '0');
    signal frame_cnt    : unsigned(14 downto 0) := (others => '0');
    signal frame_target : unsigned(14 downto 0);
    signal bank_full    : std_logic := '0';
    signal swap_ack     : std_logic := '0';

    -- =========================================================================
    -- Output generator FSM
    -- =========================================================================
    type t_out_state is (OUT_IDLE, OUT_HDR0, OUT_HDR1, OUT_RDREQ,
                         OUT_RDWAIT, OUT_STREAM, OUT_CLR);
    signal out_state    : t_out_state := OUT_IDLE;

    signal out_bin      : unsigned(12 downto 0) := (others => '0');
    signal out_data     : unsigned(31 downto 0) := (others => '0');
    signal out_valid    : std_logic := '0';
    signal tlast_int    : std_logic := '0';
    signal clr_bin      : unsigned(12 downto 0) := (others => '0');

    signal lat_n        : unsigned(3 downto 0)  := (others => '0');
    signal lat_rpm      : unsigned(15 downto 0) := (others => '0');
    signal out_bank     : std_logic := '1';

    signal frame_out_cnt : unsigned(31 downto 0) := (others => '0');

    -- =========================================================================
    -- Bypass
    -- =========================================================================
    signal bypass_active : std_logic;

begin

    -- =========================================================================
    -- BRAM processes (single-port, synchronous read)
    -- =========================================================================
    p_ram0 : process(clk)
    begin
        if rising_edge(clk) then
            if r0_we = '1' then
                ram0(to_integer(r0_addr)) <= r0_wdata;
            end if;
            r0_rdata <= ram0(to_integer(r0_addr));
        end if;
    end process p_ram0;

    p_ram1 : process(clk)
    begin
        if rising_edge(clk) then
            if r1_we = '1' then
                ram1(to_integer(r1_addr)) <= r1_wdata;
            end if;
            r1_rdata <= ram1(to_integer(r1_addr));
        end if;
    end process p_ram1;

    -- =========================================================================
    -- Bank routing muxes
    -- Accumulator uses acc_bank, output uses the opposite bank.
    -- =========================================================================
    out_bank <= not acc_bank;

    -- Accumulator drives whichever bank it owns
    r0_addr  <= acc_addr  when acc_bank = '0' else out_addr;
    r0_wdata <= acc_wdata when acc_bank = '0' else out_wdata;
    r0_we    <= acc_we    when acc_bank = '0' else out_we;

    r1_addr  <= acc_addr  when acc_bank = '1' else out_addr;
    r1_wdata <= acc_wdata when acc_bank = '1' else out_wdata;
    r1_we    <= acc_we    when acc_bank = '1' else out_we;

    -- Read data back to each FSM
    acc_rdata <= r0_rdata when acc_bank = '0' else r1_rdata;
    out_rdata <= r0_rdata when out_bank = '0' else r1_rdata;

    -- Frame target = 2^N
    frame_target <= shift_left(to_unsigned(1, 15), to_integer(avg_n));

    bypass_active <= '1' when avg_n = 0 else '0';

    -- =========================================================================
    -- Accumulator FSM
    -- Consumes raw stream words, performs read-modify-write into BRAM.
    -- Counts engine cycles (z_edges via tlast on word 1).
    -- Signals bank_full after 2^N cycles, waits for swap_ack before flipping.
    -- =========================================================================
    p_acc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                acc_state   <= ACC_IDLE;
                word_cnt    <= '0';
                frame_cnt   <= (others => '0');
                bank_full   <= '0';
                acc_we      <= '0';
                acc_bank    <= '0';
            else
                acc_we   <= '0';

                case acc_state is

                    when ACC_IDLE =>
                        if s_axis_tvalid = '1' and bypass_active = '0' then
                            if word_cnt = '0' then
                                -- Word 0: latch bin address
                                s_tdc    <= unsigned(s_axis_tdata(12 downto 0));
                                word_cnt <= '1';
                            else
                                -- Word 1: latch pressure [15:4]
                                s_pressure <= unsigned(s_axis_tdata(15 downto 4));
                                word_cnt   <= '0';
                                -- Issue BRAM read
                                acc_addr   <= s_tdc;
                                acc_state  <= ACC_READ;
                                -- Count complete cycles on tlast
                                if s_axis_tlast = '1' then
                                    if frame_cnt + 1 >= frame_target then
                                        frame_cnt <= (others => '0');
                                        bank_full <= '1';
                                        -- Stay in ACC_WAIT_SWAP after write
                                    else
                                        frame_cnt <= frame_cnt + 1;
                                    end if;
                                end if;
                            end if;
                        end if;

                    when ACC_READ =>
                        -- 1-cycle BRAM read latency
                        acc_state <= ACC_WRITE;

                    when ACC_WRITE =>
                        acc_wdata <= acc_rdata + resize(s_pressure, 32);
                        acc_we    <= '1';
                        acc_addr  <= s_tdc;
                        if bank_full = '1' then
                            acc_state <= ACC_WAIT_SWAP;
                        else
                            acc_state <= ACC_IDLE;
                        end if;

                    when ACC_WAIT_SWAP =>
                        acc_we <= '0';
                        if swap_ack = '1' then
                            bank_full <= '0';
                            acc_bank  <= not acc_bank;
                            acc_state <= ACC_IDLE;
                        end if;

                    when others =>
                        acc_state <= ACC_IDLE;

                end case;
            end if;
        end if;
    end process p_acc;

    -- =========================================================================
    -- Output generator FSM
    -- Waits for bank_full, swaps banks, streams header + 7200 bins,
    -- then clears the drained bank ready for next accumulation.
    -- =========================================================================
    p_out : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_state     <= OUT_IDLE;
                out_valid     <= '0';
                tlast_int     <= '0';
                out_bin       <= (others => '0');
                clr_bin       <= (others => '0');
                out_we        <= '0';
                swap_ack      <= '0';
                frame_out_cnt <= (others => '0');
            else
                out_we   <= '0';
                swap_ack <= '0';  -- default low, pulsed for one cycle only

                case out_state is

                    when OUT_IDLE =>
                        out_valid <= '0';
                        tlast_int <= '0';
                        if bank_full = '1' then
                            swap_ack  <= '1';
                            lat_n     <= avg_n;
                            lat_rpm   <= rpm;
                            out_bin   <= (others => '0');
                            -- Pre-load out_data with rpm so it is stable
                            -- for the full HDR0 cycle when out_valid goes high
                            out_data  <= resize(rpm, 32);
                            out_state <= OUT_HDR0;
                        end if;

                    when OUT_HDR0 =>
                        out_valid <= '1';
                        tlast_int <= '0';
                        out_data  <= resize(lat_rpm, 32);
                        report "HDR0: lat_rpm=" & integer'image(to_integer(lat_rpm)) &
                               " out_data(prev)=" & integer'image(to_integer(out_data)) &
                               " tready=" & std_logic'image(m_axis_tready);
                        if m_axis_tready = '1' then
                            out_state <= OUT_HDR1;
                        end if;

                    when OUT_HDR1 =>
                        out_data  <= resize(lat_n, 32);
                        report "HDR1: lat_n=" & integer'image(to_integer(lat_n)) &
                               " out_data(prev)=" & integer'image(to_integer(out_data)) &
                               " tready=" & std_logic'image(m_axis_tready);
                        if m_axis_tready = '1' then
                            out_addr  <= (others => '0');
                            out_state <= OUT_RDREQ;
                        end if;

                    when OUT_RDREQ =>
                        out_valid <= '0';
                        out_addr  <= out_bin;
                        out_state <= OUT_RDWAIT;

                    when OUT_RDWAIT =>
                        out_state <= OUT_STREAM;

                    when OUT_STREAM =>
                        out_valid <= '1';
                        out_data  <= shift_right(out_rdata, to_integer(lat_n));
                        if out_bin = BINS - 2 then
                            tlast_int <= '1';
                        end if;
                        if m_axis_tready = '1' then
                            if out_bin = BINS - 1 then
                                out_valid     <= '0';
                                tlast_int     <= '0';
                                frame_out_cnt <= frame_out_cnt + 1;
                                clr_bin       <= (others => '0');
                                out_state     <= OUT_CLR;
                            else
                                out_bin   <= out_bin + 1;
                                out_state <= OUT_RDREQ;
                            end if;
                        end if;

                    when OUT_CLR =>
                        out_addr  <= clr_bin;
                        out_wdata <= (others => '0');
                        out_we    <= '1';
                        if clr_bin = BINS - 1 then
                            out_we    <= '0';
                            out_state <= OUT_IDLE;
                        else
                            clr_bin <= clr_bin + 1;
                        end if;

                    when others =>
                        out_state <= OUT_IDLE;

                end case;
            end if;
        end if;
    end process p_out;

    -- =========================================================================
    -- Bypass mux and output assignments
    -- out_data is pre-loaded one state early throughout the FSM so it is
    -- always stable for the full cycle when out_valid is high.
    -- =========================================================================
    m_axis_tdata  <= s_axis_tdata              when bypass_active = '1'
                     else std_logic_vector(out_data);
    m_axis_tvalid <= s_axis_tvalid             when bypass_active = '1'
                     else out_valid;
    m_axis_tlast  <= s_axis_tlast              when bypass_active = '1'
                     else tlast_int;
    s_axis_tready <= m_axis_tready             when bypass_active = '1'
                     else '1' when acc_state = ACC_IDLE else '0';
    m_axis_tvalid <= s_axis_tvalid             when bypass_active = '1'
                     else out_valid;
    m_axis_tlast  <= s_axis_tlast              when bypass_active = '1'
                     else tlast_int;
    s_axis_tready <= m_axis_tready             when bypass_active = '1'
                     else '1' when acc_state = ACC_IDLE else '0';

    frame_count   <= frame_out_cnt;

end architecture rtl;
