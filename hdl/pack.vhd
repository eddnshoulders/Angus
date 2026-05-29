library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- pack.vhd
-- AXI-Stream DMA sample packer.
-- On each trig_pulse, packs one sample into the AXI stream:
--   Word 0: [31:16] ang_deg     [15:0] speed_rpm_fast
--   Word 1: [31:24] DI[7:0]    [23:0] padding
--   Word 2: [31:16] ADC_ch1    [15:0] ADC_ch2
--   Word 3: [31:16] ADC_ch3    [15:0] ADC_ch4
--   Word 4: [31:16] ADC_ch5    [15:0] ADC_ch6
-- tlast asserted on Word 4 of every (dma_buffer_size * 720)th sample
-- (i.e., on last word of 2nd 720-sample cycle by default)
-- z_edge resets cycle counter
-- ovf_count increments on trig_pulse when tready='0'
-- =============================================================================
entity pack is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        -- Sample inputs
        trig_pulse       : in  std_logic;
        ang_deg          : in  unsigned(15 downto 0);
        speed_rpm_fast   : in  unsigned(15 downto 0);
        di_ch            : in  std_logic_vector(7 downto 0);
        adc_ch1          : in  unsigned(11 downto 0);
        adc_ch2          : in  unsigned(11 downto 0);
        adc_ch3          : in  unsigned(11 downto 0);
        adc_ch4          : in  unsigned(11 downto 0);
        adc_ch5          : in  unsigned(11 downto 0);
        adc_ch6          : in  unsigned(11 downto 0);
        z_edge           : in  std_logic;
        dma_buffer_size  : in  unsigned(3 downto 0);
        -- AXI-Stream master
        m_axis_tdata     : out std_logic_vector(31 downto 0);
        m_axis_tvalid    : out std_logic;
        m_axis_tready    : in  std_logic;
        m_axis_tlast     : out std_logic;
        -- Status
        pkt_count        : out unsigned(31 downto 0);
        ovf_count        : out unsigned(15 downto 0)
    );
end entity pack;

architecture rtl of pack is
    type t_state is (IDLE, WORD0, WORD1, WORD2, WORD3, WORD4);
    signal state         : t_state := IDLE;
    signal word_count    : unsigned(2 downto 0) := (others => '0');
    signal sample_count  : unsigned(15 downto 0) := (others => '0');
    signal cycle_count   : unsigned(3 downto 0) := (others => '0');
    signal pkt_cnt       : unsigned(31 downto 0) := (others => '0');
    signal ovf_cnt       : unsigned(15 downto 0) := (others => '0');
    signal tvalid_int    : std_logic := '0';
    signal tlast_int     : std_logic := '0';
    signal tdata_int     : std_logic_vector(31 downto 0) := (others => '0');
    -- Latched sample data
    signal s_ang         : unsigned(15 downto 0) := (others => '0');
    signal s_speed       : unsigned(15 downto 0) := (others => '0');
    signal s_di          : std_logic_vector(7 downto 0) := (others => '0');
    signal s_adc1        : unsigned(11 downto 0) := (others => '0');
    signal s_adc2        : unsigned(11 downto 0) := (others => '0');
    signal s_adc3        : unsigned(11 downto 0) := (others => '0');
    signal s_adc4        : unsigned(11 downto 0) := (others => '0');
    signal s_adc5        : unsigned(11 downto 0) := (others => '0');
    signal s_adc6        : unsigned(11 downto 0) := (others => '0');
    signal last_sample   : std_logic := '0';
begin

    p_pack : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= IDLE;
                tvalid_int   <= '0';
                tlast_int    <= '0';
                pkt_cnt      <= (others => '0');
                ovf_cnt      <= (others => '0');
                sample_count <= (others => '0');
                cycle_count  <= (others => '0');
                last_sample  <= '0';
            else
                -- z_edge resets cycle counter
                if z_edge = '1' then
                    sample_count <= (others => '0');
                    cycle_count  <= (others => '0');
                end if;

                -- Overflow: trig_pulse arrives but not in IDLE state
                if trig_pulse = '1' and state /= IDLE then
                    if ovf_cnt /= (ovf_cnt'range => '1') then
                        ovf_cnt <= ovf_cnt + 1;
                    end if;
                end if;

                case state is
                    when IDLE =>
                        tvalid_int <= '0';
                        tlast_int  <= '0';
                        if trig_pulse = '1' then
                            -- Check if DMA is ready
                            if m_axis_tready = '1' or tvalid_int = '0' then
                                -- Latch sample data
                                s_ang   <= ang_deg;
                                s_speed <= speed_rpm_fast;
                                s_di    <= di_ch;
                                s_adc1  <= adc_ch1;
                                s_adc2  <= adc_ch2;
                                s_adc3  <= adc_ch3;
                                s_adc4  <= adc_ch4;
                                s_adc5  <= adc_ch5;
                                s_adc6  <= adc_ch6;
                                -- Determine if this is the last sample in buffer
                                sample_count <= sample_count + 1;
                                if sample_count + 1 >= resize(dma_buffer_size, 16) * to_unsigned(720, 16) then
                                    last_sample  <= '1';
                                    sample_count <= (others => '0');
                                    cycle_count  <= cycle_count + 1;
                                else
                                    last_sample <= '0';
                                end if;
                                state <= WORD0;
                            else
                                -- Overflow
                                if ovf_cnt /= (ovf_cnt'range => '1') then
                                    ovf_cnt <= ovf_cnt + 1;
                                end if;
                            end if;
                        end if;

                    when WORD0 =>
                        tvalid_int <= '1';
                        tlast_int  <= '0';
                        tdata_int  <= std_logic_vector(s_ang) & std_logic_vector(s_speed);
                        if m_axis_tready = '1' then
                            state <= WORD1;
                        end if;

                    when WORD1 =>
                        tdata_int  <= s_di & x"000000";
                        if m_axis_tready = '1' then
                            state <= WORD2;
                        end if;

                    when WORD2 =>
                        tdata_int <= x"0" & std_logic_vector(s_adc1) &
                                     x"0" & std_logic_vector(s_adc2);
                        if m_axis_tready = '1' then
                            state <= WORD3;
                        end if;

                    when WORD3 =>
                        tdata_int <= x"0" & std_logic_vector(s_adc3) &
                                     x"0" & std_logic_vector(s_adc4);
                        if m_axis_tready = '1' then
                            state <= WORD4;
                        end if;

                    when WORD4 =>
                        tdata_int <= x"0" & std_logic_vector(s_adc5) &
                                     x"0" & std_logic_vector(s_adc6);
                        tlast_int <= last_sample;
                        if m_axis_tready = '1' then
                            pkt_cnt <= pkt_cnt + 1;
                            state   <= IDLE;
                            if last_sample = '1' then
                                tlast_int <= '0';
                            end if;
                        end if;

                    when others =>
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process p_pack;

    m_axis_tdata  <= tdata_int;
    m_axis_tvalid <= tvalid_int;
    m_axis_tlast  <= tlast_int;
    pkt_count     <= pkt_cnt;
    ovf_count     <= ovf_cnt;

end architecture rtl;
