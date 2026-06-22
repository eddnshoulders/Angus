library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- pack.vhd  (v3)
--
-- AXI-Stream DMA sample packer.
-- On each trig_pulse, packs one 2-word sample into the AXI stream:
--
--   Word 0: [31:0]  tdc_deg (0-7199 = 0.0-719.9 deg, 0.1 deg/LSB)
--   Word 1: [31:24] DI[7:0]  [23:16] 0x00  [15:4] pressure[11:0]  [3:0] 0x0
--
-- RPM is available via AXI-Lite registers (SPEED_RPM_SLOW / SPEED_RPM_FAST)
-- and does not need to be streamed at 0.1 deg sample intervals.
--
-- Python unpacking:
--   tdc_deg  = buf[0] * 0.1          # degrees (0.0-719.9)
--   di       = (buf[1] >> 24) & 0xFF
--   pressure = (buf[1] >>  4) & 0xFFF
--
-- tlast is asserted on Word 1 every dma_buffer_size engine cycles (z_edges).
--
-- FIFO protection: if raw_fifo_almost_full is asserted when a new packet
-- would start (IDLE->WORD0 transition), the entire packet is dropped and
-- dropped_pkt_count increments. Partial-packet corruption is avoided by
-- only making the drop decision at packet boundaries, never mid-packet.
-- =============================================================================

entity pack is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        -- Trigger
        trig_pulse      : in  std_logic;
        -- Sample data
        tdc_deg         : in  unsigned(15 downto 0);
        di_ch           : in  std_logic_vector(7 downto 0);
        adc_ch0         : in  unsigned(11 downto 0);
        -- DMA control
        z_edge          : in  std_logic;
        dma_buffer_size : in  unsigned(3 downto 0);
        -- FIFO protection: asserted by the downstream AXI Stream FIFO
        -- when it is nearly full. Pack will drop the next packet rather
        -- than risk the FIFO overflowing mid-packet.
        raw_fifo_almost_full : in std_logic;
        -- AXI-Stream master
        m_axis_tdata    : out std_logic_vector(31 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;
        -- Status
        pkt_count           : out unsigned(31 downto 0);
        ovf_count           : out unsigned(15 downto 0);
        dropped_pkt_count   : out unsigned(31 downto 0)
    );
end entity pack;

architecture rtl of pack is

    -- DROP state: packet is being silently discarded because the FIFO
    -- was almost full at the moment it would have started. We wait for
    -- tlast (last_sample) to ensure we discard a whole packet boundary-
    -- aligned unit, then return to IDLE.
    type t_state is (IDLE, WORD0, WORD1, DROP);
    signal state        : t_state := IDLE;
    signal pkt_cnt      : unsigned(31 downto 0) := (others => '0');
    signal ovf_cnt      : unsigned(15 downto 0) := (others => '0');
    signal drop_cnt     : unsigned(31 downto 0) := (others => '0');
    signal tvalid_int   : std_logic := '0';
    signal tlast_int    : std_logic := '0';
    signal tdata_int    : std_logic_vector(31 downto 0) := (others => '0');

    -- Latched sample data (captured at trig_pulse)
    signal s_tdc        : unsigned(15 downto 0) := (others => '0');
    signal s_di         : std_logic_vector(7 downto 0) := (others => '0');
    signal s_adc0       : unsigned(11 downto 0) := (others => '0');

    -- DMA buffer boundary tracking
    signal last_sample  : std_logic := '0';
    signal cycle_cnt    : unsigned(3 downto 0) := (others => '0');
    signal next_is_last : std_logic := '0';

begin

    -- =========================================================================
    -- Packet state machine
    -- =========================================================================
    p_pack : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state       <= IDLE;
                tvalid_int  <= '0';
                tlast_int   <= '0';
                pkt_cnt     <= (others => '0');
                ovf_cnt     <= (others => '0');
                drop_cnt    <= (others => '0');
                last_sample <= '0';
            else
                case state is

                    when IDLE =>
                        tvalid_int <= '0';
                        tlast_int  <= '0';
                        if trig_pulse = '1' then
                            last_sample <= next_is_last;
                            s_tdc       <= tdc_deg;
                            s_di        <= di_ch;
                            s_adc0      <= adc_ch0;
                            if raw_fifo_almost_full = '1' then
                                -- FIFO is nearly full: drop this packet to
                                -- avoid a partial-write overflow. Count the
                                -- drop and wait for the packet boundary.
                                drop_cnt <= drop_cnt + 1;
                                state    <= DROP;
                            else
                                state <= WORD0;
                            end if;
                        end if;

                    when WORD0 =>
                        tvalid_int <= '1';
                        tlast_int  <= '0';
                        tdata_int  <= std_logic_vector(resize(s_tdc, 32));
                        if m_axis_tready = '1' then state <= WORD1; end if;

                    when WORD1 =>
                        tdata_int <= s_di &
                                     x"00" &
                                     std_logic_vector(s_adc0) &
                                     x"0";
                        tlast_int <= last_sample;
                        if m_axis_tready = '1' then
                            pkt_cnt <= pkt_cnt + 1;
                            state   <= IDLE;
                        end if;

                    when DROP =>
                        -- Silently discard samples until the packet
                        -- boundary (last_sample), consuming trig_pulses
                        -- without driving the AXI-Stream bus.
                        tvalid_int <= '0';
                        tlast_int  <= '0';
                        if trig_pulse = '1' then
                            if last_sample = '1' then
                                -- Boundary: resume normal operation on
                                -- the next packet.
                                state <= IDLE;
                            else
                                last_sample <= next_is_last;
                                s_tdc       <= tdc_deg;
                                s_di        <= di_ch;
                                s_adc0      <= adc_ch0;
                            end if;
                        end if;

                    when others =>
                        state <= IDLE;

                end case;

                -- Overflow: trig_pulse arrived while a packet is actively
                -- being streamed (WORD0/WORD1). Does not fire during DROP
                -- since dropping is intentional, not an overflow.
                if trig_pulse = '1' and (state = WORD0 or state = WORD1) then
                    if ovf_cnt /= (ovf_cnt'range => '1') then
                        ovf_cnt <= ovf_cnt + 1;
                    end if;
                end if;

            end if;
        end if;
    end process p_pack;

    -- =========================================================================
    -- DMA cycle counter: flags the last sample of each DMA buffer
    -- =========================================================================
    p_cycle : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cycle_cnt    <= (others => '0');
                next_is_last <= '0';
            else
                if z_edge = '1' then
                    if cycle_cnt + 1 >= dma_buffer_size then
                        next_is_last <= '1';
                        cycle_cnt    <= (others => '0');
                    else
                        cycle_cnt    <= cycle_cnt + 1;
                        next_is_last <= '0';
                    end if;
                end if;
                if state = WORD1 and m_axis_tready = '1' and last_sample = '1' then
                    next_is_last <= '0';
                end if;
            end if;
        end if;
    end process p_cycle;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    m_axis_tdata      <= tdata_int;
    m_axis_tvalid     <= tvalid_int;
    m_axis_tlast      <= tlast_int;
    pkt_count         <= pkt_cnt;
    ovf_count         <= ovf_cnt;
    dropped_pkt_count <= drop_cnt;

end architecture rtl;
