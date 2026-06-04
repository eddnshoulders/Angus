library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- pack.vhd  (v3)
--
-- AXI-Stream DMA sample packer.
-- On each trig_pulse, packs one 6-word sample into the AXI stream:
--
--   Word 0: [31:16] speed_rpm_slow    [15:0]  speed_rpm_fast
--   Word 1: [31:16] reserved(0)       [15:0]  tdc_deg[15:0]
--   Word 2: [31:24] DI[7:0]           [23:16] reserved(0)   [15:4] reserved(0) [3:0] adc_ch1[11:8]
--          (more precisely: x"00" & di_ch & x"0" & adc_ch1)
--   Word 3: [31:20] adc_ch2[11:0]     [19:16] 0   [15:4] adc_ch3[11:0]  [3:0] 0
--          (more precisely: x"0" & adc_ch2 & x"0" & adc_ch3)
--   Word 4: [31:16] (x"0"&adc_ch4)   [15:0]  (x"0"&adc_ch5)
--   Word 5: [31:16] (x"0"&adc_ch6)   [15:0]  reserved(0)
--
-- tlast is asserted on Word 5 of every dma_buffer_size engine cycles (z_edges).
-- z_edge resets the DMA cycle counter.
-- ovf_count increments when trig_pulse arrives while a packet is in progress.
-- =============================================================================

entity pack is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        -- Trigger
        trig_pulse      : in  std_logic;
        -- Sample data
        tdc_deg         : in  unsigned(15 downto 0);   -- TDC-referenced angle, 0-7199
        speed_rpm_slow  : in  unsigned(15 downto 0);
        speed_rpm_fast  : in  unsigned(15 downto 0);
        di_ch           : in  std_logic_vector(7 downto 0);
        adc_ch1         : in  unsigned(11 downto 0);
        adc_ch2         : in  unsigned(11 downto 0);
        adc_ch3         : in  unsigned(11 downto 0);
        adc_ch4         : in  unsigned(11 downto 0);
        adc_ch5         : in  unsigned(11 downto 0);
        adc_ch6         : in  unsigned(11 downto 0);
        -- DMA control
        z_edge          : in  std_logic;
        dma_buffer_size : in  unsigned(3 downto 0);   -- engine cycles per DMA buffer
        -- AXI-Stream master
        m_axis_tdata    : out std_logic_vector(31 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;
        -- Status
        pkt_count       : out unsigned(31 downto 0);
        ovf_count       : out unsigned(15 downto 0)
    );
end entity pack;

architecture rtl of pack is

    type t_state is (IDLE, WORD0, WORD1, WORD2, WORD3, WORD4, WORD5);
    signal state        : t_state := IDLE;
    signal pkt_cnt      : unsigned(31 downto 0) := (others => '0');
    signal ovf_cnt      : unsigned(15 downto 0) := (others => '0');
    signal tvalid_int   : std_logic := '0';
    signal tlast_int    : std_logic := '0';
    signal tdata_int    : std_logic_vector(31 downto 0) := (others => '0');

    -- Latched sample data (captured at trig_pulse)
    signal s_tdc        : unsigned(15 downto 0) := (others => '0');
    signal s_rpm_slow   : unsigned(15 downto 0) := (others => '0');
    signal s_rpm_fast   : unsigned(15 downto 0) := (others => '0');
    signal s_di         : std_logic_vector(7 downto 0) := (others => '0');
    signal s_adc1       : unsigned(11 downto 0) := (others => '0');
    signal s_adc2       : unsigned(11 downto 0) := (others => '0');
    signal s_adc3       : unsigned(11 downto 0) := (others => '0');
    signal s_adc4       : unsigned(11 downto 0) := (others => '0');
    signal s_adc5       : unsigned(11 downto 0) := (others => '0');
    signal s_adc6       : unsigned(11 downto 0) := (others => '0');

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
                last_sample <= '0';
            else
                case state is

                    when IDLE =>
                        tvalid_int <= '0';
                        tlast_int  <= '0';
                        if trig_pulse = '1' then
                            -- Latch sample data and buffer boundary flag
                            last_sample <= next_is_last;
                            s_tdc       <= tdc_deg;
                            s_rpm_slow  <= speed_rpm_slow;
                            s_rpm_fast  <= speed_rpm_fast;
                            s_di        <= di_ch;
                            s_adc1      <= adc_ch1;
                            s_adc2      <= adc_ch2;
                            s_adc3      <= adc_ch3;
                            s_adc4      <= adc_ch4;
                            s_adc5      <= adc_ch5;
                            s_adc6      <= adc_ch6;
                            state       <= WORD0;
                        end if;

                    when WORD0 =>
                        tvalid_int <= '1';
                        tlast_int  <= '0';
                        tdata_int  <= std_logic_vector(s_rpm_slow) &
                                      std_logic_vector(s_rpm_fast);
                        if m_axis_tready = '1' then state <= WORD1; end if;

                    when WORD1 =>
                        tdata_int <= x"0000" & std_logic_vector(s_tdc);
                        if m_axis_tready = '1' then state <= WORD2; end if;

                    when WORD2 =>
                        tdata_int <= x"00" & s_di & x"0" & std_logic_vector(s_adc1);
                        if m_axis_tready = '1' then state <= WORD3; end if;

                    when WORD3 =>
                        tdata_int <= x"0" & std_logic_vector(s_adc2) &
                                     x"0" & std_logic_vector(s_adc3);
                        if m_axis_tready = '1' then state <= WORD4; end if;

                    when WORD4 =>
                        tdata_int <= x"0" & std_logic_vector(s_adc4) &
                                     x"0" & std_logic_vector(s_adc5);
                        if m_axis_tready = '1' then state <= WORD5; end if;

                    when WORD5 =>
                        tdata_int <= x"0" & std_logic_vector(s_adc6) & x"0000";
                        tlast_int <= last_sample;
                        if m_axis_tready = '1' then
                            pkt_cnt <= pkt_cnt + 1;
                            state   <= IDLE;
                        end if;

                    when others =>
                        state <= IDLE;

                end case;

                -- Overflow: trig_pulse arrived while packet in progress
                if trig_pulse = '1' and state /= IDLE then
                    if ovf_cnt /= (ovf_cnt'range => '1') then
                        ovf_cnt <= ovf_cnt + 1;
                    end if;
                end if;

            end if;
        end if;
    end process p_pack;

    -- =========================================================================
    -- DMA cycle counter: flags the last sample of each DMA buffer
    -- Counts z_edges (engine cycles); next_is_last set when count expires.
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
                -- Clear flag after tlast is transmitted
                if state = WORD5 and m_axis_tready = '1' and last_sample = '1' then
                    next_is_last <= '0';
                end if;
            end if;
        end if;
    end process p_cycle;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    m_axis_tdata  <= tdata_int;
    m_axis_tvalid <= tvalid_int;
    m_axis_tlast  <= tlast_int;
    pkt_count     <= pkt_cnt;
    ovf_count     <= ovf_cnt;

end architecture rtl;
