library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- xadc_buffer
--
-- Interfaces between Xilinx xADC Wizard IP and pack.
--
-- xADC configured in event mode (one-pass sequencer) with convst trigger
-- driven by trig_pulse (crank-angle-synchronised sampling).
--
-- On each convst trigger the xADC converts all enabled channels sequentially.
-- After each channel conversion eoc fires. A DRP read cycle is then issued
-- to retrieve the result from the xADC's internal register:
--   1. Assert den=1 with the channel's DRP address for one clock
--   2. Wait for drdy=1 (typically 2 clocks)
--   3. Latch do into the per-channel register
--
-- After all channels complete, eos fires and ch_latched is updated with all
-- channel values simultaneously, guaranteeing a coherent sample snapshot.
--
-- DRP address mapping: VAUX0 = 0x10, VAUX1 = 0x11 ... VAUXn = 0x10 + n
-- DO register format: [15:4] = 12-bit result, [3:0] = 0
--
-- Channel mapping (adc_data):
--   adc_data[15:0]   = VAUX0
--   adc_data[31:16]  = VAUX1  (if NUM_CHANNELS > 1)
--   ...
-- =============================================================================

entity xadc_buffer is
    generic (
        NUM_CHANNELS : integer := 1;
        CLK_FREQ_HZ  : integer := 100_000_000
    );
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- From xADC Wizard IP
        xadc_do          : in  std_logic_vector(15 downto 0);
        xadc_drdy        : in  std_logic;   -- DRP read data valid
        xadc_channel     : in  std_logic_vector(4 downto 0);
        xadc_eoc         : in  std_logic;   -- end of single channel conversion
        xadc_eos         : in  std_logic;   -- end of sequence (all channels done)
        xadc_busy        : in  std_logic;   -- conversion in progress

        -- To xADC Wizard IP
        xadc_convst      : out std_logic;   -- triggers conversion = sample_pulse
        xadc_dclk        : out std_logic;
        xadc_den         : out std_logic;
        xadc_dwe         : out std_logic;
        xadc_daddr       : out std_logic_vector(6 downto 0);
        xadc_di          : out std_logic_vector(15 downto 0);

        -- Trigger input
        sample_pulse     : in  std_logic;

        -- Output: NUM_CHANNELS x 16-bit words, latched on eos
        adc_data         : out std_logic_vector(NUM_CHANNELS * 16 - 1 downto 0);

        -- Status
        conversion_count : out unsigned(31 downto 0)
    );
end entity xadc_buffer;

architecture rtl of xadc_buffer is

    type channel_regs_t is array (0 to NUM_CHANNELS - 1) of
        std_logic_vector(15 downto 0);

    type drp_state_t is (IDLE, ISSUE_READ, WAIT_DRDY);

    signal ch_regs    : channel_regs_t := (others => (others => '0'));
    signal ch_latched : channel_regs_t := (others => (others => '0'));
    signal conv_count : unsigned(31 downto 0) := (others => '0');

    signal ch_idx     : integer range 0 to NUM_CHANNELS - 1 := 0;
    signal ch_valid   : std_logic := '0';

    signal drp_state  : drp_state_t := IDLE;
    signal drp_den    : std_logic := '0';
    signal drp_daddr  : std_logic_vector(6 downto 0) := (others => '0');
    signal drp_ch_idx : integer range 0 to NUM_CHANNELS - 1 := 0;

begin

    -- -------------------------------------------------------------------------
    -- Static DRP outputs
    -- -------------------------------------------------------------------------
    xadc_dclk <= clk;
    xadc_dwe  <= '0';       -- read only, never write
    xadc_di   <= (others => '0');
    xadc_den  <= drp_den;
    xadc_daddr <= drp_daddr;

    -- -------------------------------------------------------------------------
    -- convst: trigger xADC conversion on each sample_pulse
    -- -------------------------------------------------------------------------
    xadc_convst <= sample_pulse;

    -- -------------------------------------------------------------------------
    -- Decode xADC channel number, registered to align with eoc
    -- Auxiliary channels: 0x10 = VAUX0 ... 0x1F = VAUX15
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
    -- DRP read FSM
    -- On each eoc (aligned with ch_valid/ch_idx), issue a DRP read to
    -- retrieve the conversion result from the xADC internal register.
    --
    -- IDLE       : wait for eoc with valid channel
    -- ISSUE_READ : assert den=1, daddr=0x10+ch_idx for one clock
    -- WAIT_DRDY  : wait for drdy; latch do into ch_regs when drdy fires
    -- -------------------------------------------------------------------------
    p_drp : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                drp_state  <= IDLE;
                drp_den    <= '0';
                drp_daddr  <= (others => '0');
                drp_ch_idx <= 0;
                ch_regs    <= (others => (others => '0'));
                conv_count <= (others => '0');
            else
                drp_den <= '0';     -- default: de-assert after one clock

                case drp_state is

                    when IDLE =>
                        if xadc_eoc = '1' and ch_valid = '1' then
                            drp_ch_idx <= ch_idx;
                            drp_daddr  <= std_logic_vector(
                                to_unsigned(16#10# + ch_idx, 7));
                            drp_den    <= '1';
                            drp_state  <= ISSUE_READ;
                        end if;

                    when ISSUE_READ =>
                        -- den was asserted last clock; deassert and wait
                        drp_state <= WAIT_DRDY;

                    when WAIT_DRDY =>
                        if xadc_drdy = '1' then
                            ch_regs(drp_ch_idx) <= xadc_do;
                            if conv_count /= (conv_count'range => '1') then
                                conv_count <= conv_count + 1;
                            end if;
                            drp_state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process p_drp;

    -- -------------------------------------------------------------------------
    -- Latch all channels simultaneously on eos
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
    -- Output: pack latched channels into flat vector
    -- -------------------------------------------------------------------------
    p_output : process(ch_latched)
    begin
        for i in 0 to NUM_CHANNELS - 1 loop
            adc_data((i + 1) * 16 - 1 downto i * 16) <= ch_latched(i);
        end loop;
    end process p_output;

    conversion_count <= conv_count;

end architecture rtl;
