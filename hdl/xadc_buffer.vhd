library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- xadc_buffer
--
-- Interfaces between Xilinx xADC Wizard IP and sample_packer.
--
-- xADC configured in event mode with external convst trigger.
-- sample_pulse drives convst_in, triggering a full conversion sequence.
--
-- Per-channel registers are updated on each eoc pulse (one per channel).
-- All channels are latched simultaneously on eos (end of sequence), which
-- fires once after all configured channels have completed conversion.
-- This guarantees all channels are valid before latching.
--
-- DRP interface driven to safe defaults (no runtime reconfiguration needed).
--
-- Channel mapping:
--   adc_data[15:0]    = VAUX0
--   adc_data[31:16]   = VAUX1
--   ...
--   adc_data[127:112] = VAUX7
--
-- xADC DO register format: [15:4] = 12-bit result, [3:0] = 0
-- =============================================================================

entity xadc_buffer is
    generic (
        NUM_CHANNELS : integer := 8;
        CLK_FREQ_HZ  : integer := 100_000_000
    );
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- From xADC Wizard IP (s_drp expanded + status)
        xadc_do          : in  std_logic_vector(15 downto 0);
        xadc_channel     : in  std_logic_vector(4 downto 0);
        xadc_eoc         : in  std_logic;   -- end of single channel conversion
        xadc_eos         : in  std_logic;   -- end of sequence (all channels done)
        xadc_busy        : in  std_logic;   -- conversion in progress

        -- To xADC Wizard IP (DRP safe defaults + convst)
        xadc_convst      : out std_logic;   -- triggers conversion = sample_pulse
        xadc_dclk        : out std_logic;
        xadc_den         : out std_logic;
        xadc_dwe         : out std_logic;
        xadc_daddr       : out std_logic_vector(6 downto 0);
        xadc_di          : out std_logic_vector(15 downto 0);

        -- From sample_trigger
        sample_pulse     : in  std_logic;

        -- To sample_packer: 8 channels x 16 bits, latched on eos
        adc_data         : out std_logic_vector(NUM_CHANNELS * 16 - 1 downto 0);

        -- Status
        conversion_count : out unsigned(31 downto 0)
    );
end entity xadc_buffer;

architecture rtl of xadc_buffer is

    type channel_regs_t is array (0 to NUM_CHANNELS - 1) of
        std_logic_vector(15 downto 0);

    signal ch_regs    : channel_regs_t := (others => (others => '0'));
    signal ch_latched : channel_regs_t := (others => (others => '0'));
    signal conv_count : unsigned(31 downto 0) := (others => '0');

    signal ch_idx     : integer range 0 to NUM_CHANNELS - 1 := 0;
    signal ch_valid   : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- DRP interface: safe defaults, no runtime reconfiguration
    -- -------------------------------------------------------------------------
    xadc_dclk  <= clk;
    xadc_den   <= '0';
    xadc_dwe   <= '0';
    xadc_daddr <= (others => '0');
    xadc_di    <= (others => '0');

    -- -------------------------------------------------------------------------
    -- convst: trigger xADC conversion sequence on each sample_pulse
    -- -------------------------------------------------------------------------
    xadc_convst <= sample_pulse;

    -- -------------------------------------------------------------------------
    -- Decode xADC channel number
    -- Auxiliary channels: 0x10 = VAUX0 ... 0x17 = VAUX7
    -- Registered to align with eoc which fires one cycle after channel_out
    -- -------------------------------------------------------------------------
    p_ch_decode : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ch_idx   <= 0;
                ch_valid <= '0';
            else
                ch_valid <= '0';
                if unsigned(xadc_channel) >= 16#10# and
                   unsigned(xadc_channel) <= 16#10# + NUM_CHANNELS - 1 then
                    ch_idx   <= to_integer(unsigned(xadc_channel)) - 16#10#;
                    ch_valid <= '1';
                end if;
            end if;
        end if;
    end process p_ch_decode;

    -- -------------------------------------------------------------------------
    -- Update per-channel register on eoc
    -- eoc fires after each individual channel conversion
    -- ch_idx and ch_valid are registered one cycle earlier, aligned with eoc
    -- -------------------------------------------------------------------------
    p_update : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ch_regs    <= (others => (others => '0'));
                conv_count <= (others => '0');
            else
                if xadc_eoc = '1' and ch_valid = '1' then
                    ch_regs(ch_idx) <= xadc_do;
                    if conv_count /= (conv_count'range => '1') then
                        conv_count <= conv_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_update;

    -- -------------------------------------------------------------------------
    -- Latch all channels simultaneously on eos
    -- eos fires once after all channels in the sequence have completed
    -- All ch_regs are valid at this point
    -- -------------------------------------------------------------------------
    p_latch : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ch_latched <= (others => (others => '0'));
            else
                if xadc_eos = '1' then
                    ch_latched <= ch_regs;
                end if;
            end if;
        end if;
    end process p_latch;

    -- -------------------------------------------------------------------------
    -- Output: pack latched channels into flat adc_data vector
    -- -------------------------------------------------------------------------
    p_output : process(ch_latched)
    begin
        for i in 0 to NUM_CHANNELS - 1 loop
            adc_data((i + 1) * 16 - 1 downto i * 16) <= ch_latched(i);
        end loop;
    end process p_output;

    conversion_count <= conv_count;

end architecture rtl;