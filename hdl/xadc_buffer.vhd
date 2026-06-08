library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library unisim;
use unisim.vcomponents.all;

-- =============================================================================
-- xadc_buffer
--
-- Instantiates the Zynq-7000 XADC hard primitive directly, bypassing the
-- XADC Wizard IP to avoid Vivado IP caching and PS-XADC interface issues.
--
-- Configuration (baked into bitstream via INIT registers):
--   CFG_REG0 (0x40) = 0x0000 -- unipolar, no averaging
--   CFG_REG1 (0x41) = 0x2EF0 -- continuous sequencer, disable alarms
--   CFG_REG2 (0x42) = 0x0400 -- DCLK/4 = 25MHz ADCCLK at 100MHz DCLK
--   CHSEL1   (0x48) = 0x0001 -- calibration channel enabled
--   CHSEL2   (0x49) = 0x0002 -- VAUX1 enabled (Arduino A0 on PYNQ-Z2)
--
-- Timing: continuous sequencer + event mode (CONVST = sample_pulse).
-- Each rising edge of sample_pulse triggers one VAUX1 conversion.
-- EOC fires after each conversion. DRP FSM reads result via DRP.
--
-- DRP read sequence:
--   IDLE: wait for eoc_d='1' and ch_valid='1' (eoc_d registered to align)
--   ISSUE_READ: assert DEN=1, DADDR=0x11 for one clock
--   WAIT_DRDY: wait for DRDY=1, latch DO into ch_latched
--
-- ILA outputs: eoc, eos, busy, channel, drdy, do, den, drp_state
-- =============================================================================

entity xadc_buffer is
    generic (
        NUM_CHANNELS : integer := 1;
        CLK_FREQ_HZ  : integer := 100_000_000
    );
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- Analog inputs (VAUX1 = Arduino A0, E17/D18 on PYNQ-Z2)
        vauxp1           : in  std_logic;
        vauxn1           : in  std_logic;

        -- Conversion trigger (crank-angle synchronised)
        sample_pulse     : in  std_logic;

        -- ADC result: NUM_CHANNELS x 16-bit words
        -- Format: [15:4] = 12-bit result, [3:0] = don't care
        adc_data         : out std_logic_vector(NUM_CHANNELS * 16 - 1 downto 0);

        -- Conversion counter
        conversion_count : out unsigned(31 downto 0);

        -- ILA debug outputs
        drp_state_out    : out std_logic_vector(1 downto 0);
        xadc_eoc_out     : out std_logic;
        xadc_eos_out     : out std_logic;
        xadc_busy_out    : out std_logic;
        xadc_channel_out : out std_logic_vector(4 downto 0);
        xadc_drdy_out    : out std_logic;
        xadc_do_out      : out std_logic_vector(15 downto 0);
        xadc_den_out     : out std_logic
    );
end entity xadc_buffer;

architecture rtl of xadc_buffer is

    -- -------------------------------------------------------------------------
    -- XADC primitive internal signals
    -- -------------------------------------------------------------------------
    signal xadc_do      : std_logic_vector(15 downto 0);
    signal xadc_drdy    : std_logic;
    signal xadc_channel : std_logic_vector(4 downto 0);
    signal xadc_eoc     : std_logic;
    signal xadc_eos     : std_logic;
    signal xadc_busy    : std_logic;

    signal vauxp_vec    : std_logic_vector(15 downto 0) := (others => '0');
    signal vauxn_vec    : std_logic_vector(15 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- DRP FSM
    -- -------------------------------------------------------------------------
    type drp_state_t is (IDLE, ISSUE_READ, WAIT_DRDY);

    signal drp_state  : drp_state_t := IDLE;
    signal drp_den    : std_logic := '0';
    signal drp_dwe    : std_logic := '0';
    signal drp_daddr  : std_logic_vector(6 downto 0) := (others => '0');
    signal drp_di     : std_logic_vector(15 downto 0) := (others => '0');
    signal drp_ch_idx : integer range 0 to NUM_CHANNELS - 1 := 0;

    -- -------------------------------------------------------------------------
    -- Channel decode
    -- -------------------------------------------------------------------------
    signal ch_idx     : integer range 0 to NUM_CHANNELS - 1 := 0;
    signal ch_valid   : std_logic := '0';
    signal xadc_eoc_d : std_logic := '0';  -- registered to align with ch_valid

    -- -------------------------------------------------------------------------
    -- Output registers
    -- -------------------------------------------------------------------------
    type channel_regs_t is array (0 to NUM_CHANNELS - 1) of
        std_logic_vector(15 downto 0);
    signal ch_latched : channel_regs_t := (others => (others => '0'));
    signal conv_count : unsigned(31 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- VAUX input vector -- only VAUX1 connected
    -- -------------------------------------------------------------------------
    vauxp_vec(1) <= vauxp1;
    vauxn_vec(1) <= vauxn1;

    -- -------------------------------------------------------------------------
    -- XADC primitive instantiation
    --
    -- INIT_41 = 0x2EF0: bits[15:12]=0x2 (continuous seq), bits[11:4]=0xEF
    --           (disable alarms), bit[3:0]=0 (calibration enable)
    -- INIT_42 = 0x0400: bits[9:8]=4 -- DCLK divider = 4 (25MHz ADCCLK)
    -- INIT_48 = 0x0001: bit[0] = calibration channel enable
    -- INIT_49 = 0x0002: bit[1] = VAUX1 enable
    -- -------------------------------------------------------------------------
    U_XADC : XADC
        generic map (
            INIT_40           => X"0000",   -- CFG_REG0: unipolar, no averaging
            INIT_41           => X"2EF0",   -- CFG_REG1: continuous seq, disable alarms
            INIT_42           => X"0400",   -- CFG_REG2: DCLK/4 = 25MHz ADCCLK
            INIT_43           => X"0000",
            INIT_44           => X"0000",
            INIT_45           => X"0000",
            INIT_46           => X"0000",
            INIT_47           => X"0000",
            INIT_48           => X"0001",   -- CHSEL1: calibration enabled
            INIT_49           => X"0002",   -- CHSEL2: VAUX1 enabled
            INIT_4A           => X"0000",   -- no averaging
            INIT_4B           => X"0000",
            INIT_4C           => X"0000",   -- unipolar mode
            INIT_4D           => X"0000",
            INIT_4E           => X"0000",   -- default acquisition time
            INIT_4F           => X"0000",
            INIT_50           => X"B5ED",   -- OT upper alarm 125C (default)
            INIT_51           => X"5999",   -- VCCINT upper alarm 1.05V
            INIT_52           => X"A147",   -- VCCAUX upper alarm 1.89V
            INIT_53           => X"DDDD",   -- OT reset 70C
            INIT_54           => X"A93A",   -- temp lower alarm reset 60C
            INIT_55           => X"5111",   -- VCCINT lower 0.95V
            INIT_56           => X"91EB",   -- VCCAUX lower 1.71V
            INIT_57           => X"AE4E",   -- OT lower reset 70C
            INIT_58           => X"5999",   -- VCCBRAM upper 1.05V
            INIT_5C           => X"5111",   -- VCCBRAM lower 0.95V
            SIM_MONITOR_FILE  => "design.txt"
        )
        port map (
            DCLK      => clk,
            RESET     => rst,
            CONVST    => sample_pulse,
            CONVSTCLK => '0',
            VAUXP     => vauxp_vec,
            VAUXN     => vauxn_vec,
            VP        => '0',
            VN        => '0',
            DO        => xadc_do,
            DRDY      => xadc_drdy,
            CHANNEL   => xadc_channel,
            EOC       => xadc_eoc,
            EOS       => xadc_eos,
            BUSY      => xadc_busy,
            OT        => open,
            ALM       => open,
            DEN       => drp_den,
            DWE       => drp_dwe,
            DADDR     => drp_daddr,
            DI        => drp_di,
            MUXADDR   => open
        );

    -- -------------------------------------------------------------------------
    -- ILA outputs
    -- -------------------------------------------------------------------------
    xadc_eoc_out     <= xadc_eoc;
    xadc_eos_out     <= xadc_eos;
    xadc_busy_out    <= xadc_busy;
    xadc_channel_out <= xadc_channel;
    xadc_drdy_out    <= xadc_drdy;
    xadc_do_out      <= xadc_do;
    xadc_den_out     <= drp_den;

    drp_state_out <= "00" when drp_state = IDLE       else
                     "01" when drp_state = ISSUE_READ  else
                     "10"; -- WAIT_DRDY

    -- -------------------------------------------------------------------------
    -- Channel decode: registered to align with eoc
    -- VAUX1 = channel address 0x11. ch_valid delayed 1 clock from channel.
    -- xadc_eoc_d also delayed 1 clock to align with ch_valid.
    -- -------------------------------------------------------------------------
    p_ch_decode : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ch_idx     <= 0;
                ch_valid   <= '0';
                xadc_eoc_d <= '0';
            else
                ch_valid   <= '0';
                xadc_eoc_d <= xadc_eoc;
                if unsigned(xadc_channel) >= 16#11# and
                   unsigned(xadc_channel) <= 16#11# + NUM_CHANNELS - 1 then
                    ch_idx   <= to_integer(unsigned(xadc_channel)) - 16#11#;
                    ch_valid <= '1';
                end if;
            end if;
        end if;
    end process p_ch_decode;

    -- -------------------------------------------------------------------------
    -- DRP read FSM
    -- Reads conversion result from XADC status register after each EOC.
    -- -------------------------------------------------------------------------
    p_drp : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                drp_state  <= IDLE;
                drp_den    <= '0';
                drp_dwe    <= '0';
                drp_daddr  <= (others => '0');
                drp_di     <= (others => '0');
                drp_ch_idx <= 0;
                ch_latched <= (others => (others => '0'));
                conv_count <= (others => '0');
            else
                drp_den <= '0';
                drp_dwe <= '0';

                case drp_state is

                    when IDLE =>
                        if xadc_eoc_d = '1' and ch_valid = '1' then
                            drp_ch_idx <= ch_idx;
                            drp_daddr  <= std_logic_vector(
                                to_unsigned(16#11# + ch_idx, 7));
                            drp_den    <= '1';
                            drp_state  <= ISSUE_READ;
                        end if;

                    when ISSUE_READ =>
                        drp_state <= WAIT_DRDY;

                    when WAIT_DRDY =>
                        if xadc_drdy = '1' then
                            ch_latched(drp_ch_idx) <= xadc_do;
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
