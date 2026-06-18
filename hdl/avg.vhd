library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- avg.vhd
--
-- Theta-P averaging accumulator.
-- Consumes the raw AXI-Stream from pack.vhd and produces a second AXI-Stream
-- of averaged frames for the display DMA path.
--
-- Input stream (from pack.vhd, 2 words per sample):
--   Word 0: [31:0]  tdc_deg  (0-7199, used directly as bin address)
--   Word 1: [31:24] DI[7:0] | [23:16] 0x00 | [15:4] pressure | [3:0] 0x0
--   tlast asserted on Word 1 of the last sample in each engine cycle
--
-- Output stream (to avg DMA, 2 words per bin, matching pack.vhd format):
--   Word 0: [31:0]  tdc_deg = bin index (0-7199)
--   Word 1: [31:24] DI snapshot | [23:16] 0x00 | [15:4] pressure_avg | [3:0] 0x0
--   tlast asserted on Word 1 of bin 7199
--   Frame = 14400 words = 57600 bytes (identical layout to raw 1-rev frame)
--
-- Averaging:
--   N = 0: bypass mode. Raw stream passes directly to output.
--   N > 0: accumulate 2^N engine cycles, output averaged frame.
--          pressure_avg = sum >> N (right shift, exact for power-of-2 counts)
--          DI: snapshot from most recent accumulated frame (not averaged)
--
-- Double buffering:
--   Pressure: two 7200x32-bit BRAMs (ping-pong banks)
--   DI snapshot: single 7200x8-bit BRAM (no double buffer needed -- single
--                cycle snapshot, torn reads acceptable for display)
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

        -- Status
        frame_count     : out unsigned(31 downto 0);

        -- Diagnostic counters (avg<->DMA1 handshake visibility)
        in_beat_count   : out unsigned(31 downto 0);  -- s_axis beats accepted
        out_beat_count  : out unsigned(31 downto 0);  -- m_axis beats accepted (tvalid & tready)
        out_tlast_count : out unsigned(31 downto 0);  -- m_axis tlast beats accepted
        out_stall_count : out unsigned(31 downto 0);  -- cycles tvalid=1, tready=0
        bad_tlast_count : out unsigned(31 downto 0);  -- tlast asserted on word 0 (framing bug)

        -- Output FSM state, for ILA correlation against stall/tlast counters
        -- 0=IDLE 1=RDREQ 2=RDWAIT 3=RDWAIT2 4=STREAM 5=CLR
        out_state_dbg   : out std_logic_vector(2 downto 0)
    );
end entity avg;

architecture rtl of avg is

    -- =========================================================================
    -- Pressure BRAM: two independent 7200x32-bit ping-pong banks
    -- =========================================================================
    constant BINS       : integer := 7200;

    type t_bram32 is array (0 to BINS - 1) of unsigned(31 downto 0);
    type t_bram8  is array (0 to BINS - 1) of std_logic_vector(7 downto 0);

    -- Pressure bank 0
    signal ram0         : t_bram32 := (others => (others => '0'));
    signal r0_addr      : unsigned(12 downto 0) := (others => '0');
    signal r0_wdata     : unsigned(31 downto 0) := (others => '0');
    signal r0_rdata     : unsigned(31 downto 0);
    signal r0_we        : std_logic := '0';

    -- Pressure bank 1
    signal ram1         : t_bram32 := (others => (others => '0'));
    signal r1_addr      : unsigned(12 downto 0) := (others => '0');
    signal r1_wdata     : unsigned(31 downto 0) := (others => '0');
    signal r1_rdata     : unsigned(31 downto 0);
    signal r1_we        : std_logic := '0';

    -- DI snapshot BRAM (single port, accumulator writes, output reads)
    signal di_snap      : t_bram8  := (others => (others => '0'));
    signal di_wr_addr   : unsigned(12 downto 0) := (others => '0');
    signal di_wr_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal di_we        : std_logic := '0';
    signal di_rd_addr   : unsigned(12 downto 0) := (others => '0');
    signal di_rdata     : std_logic_vector(7 downto 0);

    -- =========================================================================
    -- Bank routing
    -- =========================================================================
    signal acc_bank     : std_logic := '0';
    signal out_bank     : std_logic;

    signal acc_rdata    : unsigned(31 downto 0);
    signal out_rdata    : unsigned(31 downto 0);

    signal acc_addr     : unsigned(12 downto 0) := (others => '0');
    signal acc_wdata    : unsigned(31 downto 0) := (others => '0');
    signal acc_we       : std_logic := '0';

    signal out_addr     : unsigned(12 downto 0) := (others => '0');
    signal out_wdata    : unsigned(31 downto 0) := (others => '0');
    signal out_we       : std_logic := '0';

    -- =========================================================================
    -- Accumulator FSM
    -- =========================================================================
    type t_acc_state is (ACC_IDLE, ACC_READ, ACC_WRITE, ACC_COOLDOWN, ACC_WAIT_SWAP);
    signal acc_state    : t_acc_state := ACC_IDLE;

    signal word_cnt     : std_logic := '0';
    signal s_tdc        : unsigned(12 downto 0) := (others => '0');
    signal s_pressure   : unsigned(11 downto 0) := (others => '0');
    signal s_di         : std_logic_vector(7 downto 0) := (others => '0');
    signal frame_cnt    : unsigned(14 downto 0) := (others => '0');
    signal frame_target : unsigned(14 downto 0);
    -- Latched avg_n: captured at frame boundary so changes only take
    -- effect at the start of the next accumulation, not mid-frame
    signal lat_avg_n    : unsigned(3 downto 0) := (others => '0');
    signal bank_full    : std_logic := '0';
    signal swap_ack     : std_logic := '0';

    -- =========================================================================
    -- Output generator FSM
    -- =========================================================================
    type t_out_state is (OUT_IDLE, OUT_RDREQ, OUT_RDWAIT, OUT_RDWAIT2, OUT_STREAM, OUT_CLR);
    signal out_state    : t_out_state := OUT_IDLE;

    signal out_bin      : unsigned(12 downto 0) := (others => '0');
    signal out_pres     : unsigned(31 downto 0) := (others => '0');
    signal out_di       : std_logic_vector(7 downto 0) := (others => '0');
    signal out_word     : std_logic := '0';  -- 0=tdc_deg word, 1=pressure/DI word
    signal out_valid    : std_logic := '0';
    signal tlast_int    : std_logic := '0';
    signal clr_bin      : unsigned(12 downto 0) := (others => '0');

    signal frame_out_cnt : unsigned(31 downto 0) := (others => '0');

    -- =========================================================================
    -- Diagnostic counters
    -- =========================================================================
    signal in_beat_cnt   : unsigned(31 downto 0) := (others => '0');
    signal out_beat_cnt  : unsigned(31 downto 0) := (others => '0');
    signal out_tlast_cnt : unsigned(31 downto 0) := (others => '0');
    signal out_stall_cnt : unsigned(31 downto 0) := (others => '0');
    signal bad_tlast_cnt : unsigned(31 downto 0) := (others => '0');

    -- Internal copy of s_axis_tready: needed because the entity's
    -- s_axis_tready is an 'out' port and cannot be read directly
    -- (VHDL restriction -- same pattern as avg_tdata_i/tvalid_i/tlast_i).
    signal s_axis_tready_i : std_logic;

    -- Combinatorial output data mux
    signal out_data_i   : std_logic_vector(31 downto 0);

    -- =========================================================================
    -- Bypass
    -- =========================================================================
    signal bypass_active : std_logic;

begin

    -- =========================================================================
    -- BRAM processes
    -- =========================================================================
    p_ram0 : process(clk)
    begin
        if rising_edge(clk) then
            if r0_we = '1' and to_integer(r0_addr) = 0 then
            end if;
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

    -- DI snapshot: write port driven by accumulator, read port by output FSM
    -- Address clamped to BINS-1 to prevent out-of-bounds during pipeline startup
    p_di_snap : process(clk)
        variable safe_rd_addr : integer range 0 to BINS-1;
        variable safe_wr_addr : integer range 0 to BINS-1;
    begin
        if rising_edge(clk) then
            -- Clamp addresses to valid range
            if to_integer(di_rd_addr) < BINS then
                safe_rd_addr := to_integer(di_rd_addr);
            else
                safe_rd_addr := BINS - 1;
            end if;
            if to_integer(di_wr_addr) < BINS then
                safe_wr_addr := to_integer(di_wr_addr);
            else
                safe_wr_addr := BINS - 1;
            end if;
            if di_we = '1' then
                di_snap(safe_wr_addr) <= di_wr_data;
            end if;
            di_rdata <= di_snap(safe_rd_addr);
        end if;
    end process p_di_snap;

    -- =========================================================================
    -- Bank routing muxes
    -- =========================================================================
    out_bank <= not acc_bank;

    r0_addr  <= acc_addr  when acc_bank = '0' else out_addr;
    r0_wdata <= acc_wdata when acc_bank = '0' else out_wdata;
    r0_we    <= acc_we    when acc_bank = '0' else out_we;

    r1_addr  <= acc_addr  when acc_bank = '1' else out_addr;
    r1_wdata <= acc_wdata when acc_bank = '1' else out_wdata;
    r1_we    <= acc_we    when acc_bank = '1' else out_we;

    acc_rdata <= r0_rdata when acc_bank = '0' else r1_rdata;
    out_rdata <= r0_rdata when out_bank = '0' else r1_rdata;

    frame_target  <= shift_left(to_unsigned(1, 15), to_integer(lat_avg_n));
    bypass_active <= '1' when avg_n = 0 else '0';

    -- =========================================================================
    -- Accumulator FSM
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
                di_we       <= '0';
                acc_bank    <= '0';
                lat_avg_n   <= (others => '0');
            else
                acc_we <= '0';
                di_we  <= '0';

                case acc_state is

                    when ACC_IDLE =>
                        if s_axis_tvalid = '1' and bypass_active = '0' then
                            if word_cnt = '0' then
                                -- Word 0: latch bin address (tdc_deg)
                                -- Also latch avg_n at very first sample of frame
                                -- (for power-on case before first WAIT_SWAP)
                                if frame_cnt = 0 then
                                    lat_avg_n <= avg_n;
                                end if;
                                s_tdc    <= unsigned(s_axis_tdata(12 downto 0));
                                word_cnt <= '1';
                            else
                                -- Word 1: latch pressure [15:4] and DI [31:24]
                                s_pressure   <= unsigned(s_axis_tdata(15 downto 4));
                                s_di         <= s_axis_tdata(31 downto 24);
                                word_cnt     <= '0';
                                -- Write DI snapshot immediately (no averaging)
                                di_wr_addr   <= s_tdc;
                                di_wr_data   <= s_axis_tdata(31 downto 24);
                                di_we        <= '1';
                                -- Issue pressure BRAM read for RMW
                                acc_addr     <= s_tdc;
                                acc_state    <= ACC_READ;
                                -- Count complete cycles on tlast
                                if s_axis_tlast = '1' then
                                    if frame_cnt + 1 >= frame_target then
                                        frame_cnt <= (others => '0');
                                        bank_full <= '1';
                                    else
                                        frame_cnt <= frame_cnt + 1;
                                    end if;
                                end if;
                            end if;
                        end if;

                    when ACC_READ =>
                        acc_state <= ACC_WRITE;

                    when ACC_WRITE =>
                        acc_wdata <= acc_rdata + resize(s_pressure, 32);
                        acc_we    <= '1';
                        acc_addr  <= s_tdc;
                        if bank_full = '1' then
                            acc_state <= ACC_WAIT_SWAP;
                        else
                            acc_state <= ACC_COOLDOWN;
                        end if;

                    when ACC_COOLDOWN =>
                        -- One dead cycle: tready='0', gives master time to
                        -- update tdata before acc re-enters IDLE and samples
                        acc_we    <= '0';
                        acc_state <= ACC_IDLE;

                    when ACC_WAIT_SWAP =>
                        acc_we <= '0';
                        if swap_ack = '1' then
                            bank_full <= '0';
                            acc_bank  <= not acc_bank;
                            lat_avg_n <= avg_n;  -- latch new avg_n for next frame
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
    -- Streams 2 words per bin: word0=tdc_deg, word1=DI|pressure_avg
    -- tlast on word 1 of bin 7199 (last word of frame)
    -- =========================================================================
    p_out : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_state     <= OUT_IDLE;
                out_valid     <= '0';
                tlast_int     <= '0';
                out_bin       <= (others => '0');
                out_word      <= '0';
                clr_bin       <= (others => '0');
                out_we        <= '0';
                frame_out_cnt <= (others => '0');
                swap_ack      <= '0';
            else
                out_we <= '0';

                -- swap_ack: set when OUT_IDLE sees bank_full, hold until
                -- bank_full clears (gives acc FSM time to reach WAIT_SWAP)
                if bank_full = '0' then
                    swap_ack <= '0';
                elsif out_state = OUT_IDLE then
                    swap_ack <= '1';
                end if;

                case out_state is

                    when OUT_IDLE =>
                        out_valid <= '0';
                        tlast_int <= '0';
                        out_word  <= '0';
                        if bank_full = '1' then
                            out_bin   <= (others => '0');
                            out_state <= OUT_RDREQ;
                        end if;

                    when OUT_RDREQ =>
                        -- Wait for bank swap to complete (bank_full clears
                        -- when acc_bank has flipped and out_bank is stable)
                        if bank_full = '0' then
                            out_addr    <= (others => '0');
                            di_rd_addr  <= (others => '0');
                            out_state   <= OUT_RDWAIT;
                        end if;

                    when OUT_RDWAIT =>
                        -- bin 0 address was issued in RDREQ (cycle N).
                        -- BRAM is registering the read this cycle (addr now stable).
                        -- Issue lookahead read for bin 1.
                        out_addr    <= to_unsigned(1, 13);
                        di_rd_addr  <= to_unsigned(1, 13);
                        out_state   <= OUT_RDWAIT2;

                    when OUT_RDWAIT2 =>
                        -- out_rdata now holds bin 0 data (registered from RDWAIT read).
                        -- Capture into stable output registers.
                        out_pres  <= shift_right(out_rdata, to_integer(lat_avg_n));
                        out_di    <= di_rdata;
                        -- Assert valid so word 0 is stable for a full cycle
                        -- before STREAM's first tready check
                        out_valid <= '1';
                        out_state <= OUT_STREAM;

                    when OUT_STREAM =>
                        out_valid <= '1';

                        if m_axis_tready = '1' then
                            if out_word = '0' then
                                -- Just presented word 0 (tdc_deg), move to word 1
                                out_word <= '1';
                            else
                                -- Just presented word 1 (DI|pressure)
                                out_word <= '0';
                                if out_bin = BINS - 1 then
                                    -- Last bin word 1 -- frame complete
                                    out_valid     <= '0';
                                    tlast_int     <= '0';
                                    frame_out_cnt <= frame_out_cnt + 1;
                                    clr_bin       <= (others => '0');
                                    out_state     <= OUT_CLR;
                                else
                                    -- Advance to next bin
                                    -- Capture lookahead data
                                    out_pres <= shift_right(out_rdata,
                                                            to_integer(lat_avg_n));
                                    out_di   <= di_rdata;
                                    out_bin  <= out_bin + 1;
                                    -- Issue lookahead read for bin+2
                                    if to_integer(out_bin) + 2 < BINS then
                                        out_addr   <= out_bin + 2;
                                        di_rd_addr <= out_bin + 2;
                                    else
                                        out_addr   <= to_unsigned(BINS-1, 13);
                                        di_rd_addr <= to_unsigned(BINS-1, 13);
                                    end if;
                                end if;
                            end if;

                            -- Assert tlast on word 1 of second-to-last bin
                            -- so it is registered and stable for last bin word 1
                            if out_bin = BINS - 1 and out_word = '0' then
                                tlast_int <= '1';
                            end if;
                        end if;

                    when OUT_CLR =>
                        if clr_bin = 0 then report "CLR: out_bank=" & std_logic'image(out_bank) & " acc_bank=" & std_logic'image(acc_bank) & " clr_bin=" & integer'image(to_integer(clr_bin)) & " out_addr=" & integer'image(to_integer(out_addr)) & " out_we=" & std_logic'image(out_we); end if;
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
    -- Diagnostic counters
    -- Free-running, do not affect any datapath or control logic.
    -- Read out via axi_lite_regs for avg<->DMA1 handshake visibility.
    -- =========================================================================
    p_diag : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                in_beat_cnt   <= (others => '0');
                out_beat_cnt  <= (others => '0');
                out_tlast_cnt <= (others => '0');
                out_stall_cnt <= (others => '0');
                bad_tlast_cnt <= (others => '0');
            else
                -- Input beat: any accepted s_axis transfer (bypass or accumulate)
                if s_axis_tvalid = '1' and s_axis_tready_i = '1' then
                    in_beat_cnt <= in_beat_cnt + 1;
                end if;

                -- Output beat / tlast / stall: only meaningful in accumulate
                -- mode, since bypass mode's m_axis is just s_axis passed
                -- through and is already covered by in_beat_cnt above.
                if bypass_active = '0' then
                    if out_valid = '1' and m_axis_tready = '1' then
                        out_beat_cnt <= out_beat_cnt + 1;
                        if tlast_int = '1' then
                            out_tlast_cnt <= out_tlast_cnt + 1;
                        end if;
                    elsif out_valid = '1' and m_axis_tready = '0' then
                        out_stall_cnt <= out_stall_cnt + 1;
                    end if;

                    -- Framing sanity check: tlast must only ever appear on
                    -- word 1 (the DI|pressure word), never word 0 (tdc_deg)
                    if tlast_int = '1' and out_word = '0' then
                        bad_tlast_cnt <= bad_tlast_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_diag;

    -- =========================================================================
    -- Output data mux
    -- word 0: tdc_deg = bin index
    -- word 1: DI[31:24] | 0x00 | pressure_avg[15:4] | 0x0
    -- =========================================================================
    process(out_word, out_bin, out_pres, out_di)
        variable w1 : std_logic_vector(31 downto 0);
    begin
        if out_word = '0' then
            out_data_i <= std_logic_vector(resize(out_bin, 32));
        else
            w1(31 downto 24) := out_di;
            w1(23 downto 16) := x"00";
            w1(15 downto 4)  := std_logic_vector(out_pres(11 downto 0));
            w1(3 downto 0)   := "0000";
            out_data_i <= w1;
        end if;
    end process;

    -- =========================================================================
    -- Bypass mux and output assignments
    -- =========================================================================
    m_axis_tdata  <= s_axis_tdata when bypass_active = '1' else out_data_i;
    m_axis_tvalid <= s_axis_tvalid when bypass_active = '1' else out_valid;
    m_axis_tlast  <= s_axis_tlast  when bypass_active = '1' else tlast_int;
    s_axis_tready_i <= m_axis_tready when bypass_active = '1'
                       else '1' when acc_state = ACC_IDLE else '0';
    s_axis_tready   <= s_axis_tready_i;

    frame_count   <= frame_out_cnt;

    in_beat_count   <= in_beat_cnt;
    out_beat_count  <= out_beat_cnt;
    out_tlast_count <= out_tlast_cnt;
    out_stall_count <= out_stall_cnt;
    bad_tlast_count <= bad_tlast_cnt;

    -- Output FSM state encoding for ILA
    with out_state select out_state_dbg <=
        "000" when OUT_IDLE,
        "001" when OUT_RDREQ,
        "010" when OUT_RDWAIT,
        "011" when OUT_RDWAIT2,
        "100" when OUT_STREAM,
        "101" when OUT_CLR,
        "111" when others;

end architecture rtl;
