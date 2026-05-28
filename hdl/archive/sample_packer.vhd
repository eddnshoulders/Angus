library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sample_packer
--
-- Assembles sample packets from angle, ADC and digital input data and streams
-- them to DMA via AXI Stream interface.
--
-- Packet structure (4 x 32-bit words):
--   Word 0: timestamp[15:0]    & sample_angle[15:0]
--   Word 1: adc_ch[1][15:0]   & adc_ch[0][15:0]
--   Word 2: adc_ch[3][15:0]   & adc_ch[2][15:0]
--   Word 3: digital_in[7:0]   & adc_ch[4][15:0]    (upper 8 bits = digital)
--
-- For Phase 1 (xADC, single channel), adc_ch[1..4] = 0.
--
-- AXI Stream handshake:
--   tvalid asserted for each word
--   tlast asserted on final word (word 3)
--   Waits for tready before advancing to next word
--   New packet only accepted when previous is fully sent
-- =============================================================================

entity sample_packer is
    generic (
        ADC_CHANNELS : integer := 8
    );
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- From sample_trigger
        sample_pulse   : in  std_logic;
        sample_angle   : in  unsigned(15 downto 0);

        -- ADC data (latched on sample_pulse, 16 bits per channel)
        adc_data       : in  std_logic_vector(ADC_CHANNELS * 16 - 1 downto 0);

        -- Digital inputs (spark flags etc, latched on sample_pulse)
        digital_inputs : in  std_logic_vector(7 downto 0);

        -- AXI Stream output to DMA
        m_axis_tdata   : out std_logic_vector(31 downto 0);
        m_axis_tvalid  : out std_logic;
        m_axis_tready  : in  std_logic;
        m_axis_tlast   : out std_logic;

        -- Status
        packet_count   : out unsigned(31 downto 0);  -- total packets sent
        overflow_count : out unsigned(15 downto 0)   -- packets dropped (DMA not ready)
    );
end entity sample_packer;

architecture rtl of sample_packer is

    -- Packet words
    type packet_t is array (0 to 3) of std_logic_vector(31 downto 0);
    signal packet      : packet_t := (others => (others => '0'));

    -- State machine
    type state_t is (IDLE, SENDING);
    signal state       : state_t := IDLE;

    -- Word counter
    signal word_idx    : integer range 0 to 3 := 0;

    -- Free-running timestamp counter
    signal timestamp   : unsigned(15 downto 0) := (others => '0');

    -- Status counters
    signal pkt_count   : unsigned(31 downto 0) := (others => '0');
    signal ovf_count   : unsigned(15 downto 0) := (others => '0');

    -- Internal output signals
    signal tvalid_int  : std_logic := '0';
    signal tlast_int   : std_logic := '0';

    -- Helper: extract 16-bit ADC channel from flat vector
    function adc_ch(
        data : std_logic_vector;
        ch   : integer
    ) return std_logic_vector is
    begin
        return data((ch + 1) * 16 - 1 downto ch * 16);
    end function;

begin

    -- -------------------------------------------------------------------------
    -- Free-running timestamp
    -- -------------------------------------------------------------------------
    p_timestamp : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                timestamp <= (others => '0');
            else
                timestamp <= timestamp + 1;
            end if;
        end if;
    end process p_timestamp;

    -- -------------------------------------------------------------------------
    -- Packet assembly and AXI Stream output
    -- -------------------------------------------------------------------------
    p_pack : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= IDLE;
                word_idx   <= 0;
                tvalid_int <= '0';
                tlast_int  <= '0';
                pkt_count  <= (others => '0');
                ovf_count  <= (others => '0');
                packet     <= (others => (others => '0'));
            else
                case state is

                    when IDLE =>
                        tvalid_int <= '0';
                        tlast_int  <= '0';

                        if sample_pulse = '1' then
                            -- Assemble packet words
                            packet(0) <= std_logic_vector(timestamp) &
                                         std_logic_vector(sample_angle);

                            packet(1) <= adc_ch(adc_data, 1) &
                                         adc_ch(adc_data, 0);

                            packet(2) <= adc_ch(adc_data, 3) &
                                         adc_ch(adc_data, 2);

                            packet(3) <= digital_inputs &
                                         "00000000" &
                                         adc_ch(adc_data, 4);

                            -- Start sending
                            word_idx   <= 0;
                            tvalid_int <= '1';
                            tlast_int  <= '0';
                            state      <= SENDING;
                        end if;

                    when SENDING =>
                        -- Detect overflow: sample_pulse arrived while still sending
                        if sample_pulse = '1' then
                            if ovf_count /= (ovf_count'range => '1') then
                                ovf_count <= ovf_count + 1;
                            end if;
                        end if;

                        if m_axis_tready = '1' then
                            if word_idx = 3 then
                                tvalid_int <= '0';
                                tlast_int  <= '0';
                                pkt_count  <= pkt_count + 1;
                                state      <= IDLE;
                            else
                                word_idx  <= word_idx + 1;
                                tlast_int <= '1' when word_idx = 2 else '0';
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process p_pack;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    m_axis_tdata  <= packet(word_idx);
    m_axis_tvalid <= tvalid_int;
    m_axis_tlast  <= tlast_int;
    packet_count  <= pkt_count;
    overflow_count <= ovf_count;

end architecture rtl;