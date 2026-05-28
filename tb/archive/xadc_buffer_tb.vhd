library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- xadc_buffer_tb
--
-- Tests xadc_buffer.vhd
-- Simulates xADC Wizard in event mode:
--   sample_pulse → xadc_convst → xADC starts conversion
--   eoc fires once per channel as each channel completes
--   eos fires once after all channels complete
--   xadc_do valid at each eoc, xadc_channel identifies which channel
--
-- Tests:
--   1: Reset state - adc_data all zero
--   2: Single conversion sequence - all channels latched on eos
--   3: Multiple conversions - data updates correctly
--   4: convst follows sample_pulse
--   5: DRP outputs tied to safe defaults
-- =============================================================================

entity xadc_buffer_tb is
end entity xadc_buffer_tb;

architecture sim of xadc_buffer_tb is

    constant CLK_PERIOD  : time    := 10 ns;
    constant NUM_CHANNELS: integer := 8;

    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';

    -- xADC Wizard inputs to buffer
    signal xadc_do          : std_logic_vector(15 downto 0) := (others => '0');
    signal xadc_channel     : std_logic_vector(4 downto 0)  := (others => '0');
    signal xadc_eoc         : std_logic := '0';
    signal xadc_eos         : std_logic := '0';
    signal xadc_busy        : std_logic := '0';

    -- xADC Wizard outputs from buffer
    signal xadc_convst      : std_logic;
    signal xadc_dclk        : std_logic;
    signal xadc_den         : std_logic;
    signal xadc_dwe         : std_logic;
    signal xadc_daddr       : std_logic_vector(6 downto 0);
    signal xadc_di          : std_logic_vector(15 downto 0);

    -- sample_trigger interface
    signal sample_pulse     : std_logic := '0';

    -- Output
    signal adc_data         : std_logic_vector(NUM_CHANNELS * 16 - 1 downto 0);
    signal conversion_count : unsigned(31 downto 0);

    signal sim_done         : boolean := false;
    signal test_num         : integer := 0;

    -- Simulate one full xADC conversion sequence
    -- Fires eoc for each channel, then eos
    -- channel_base: first channel number (0x10 for VAUX0)
    procedure do_conversion(
        signal xadc_do_s      : out std_logic_vector(15 downto 0);
        signal xadc_channel_s : out std_logic_vector(4 downto 0);
        signal xadc_eoc_s     : out std_logic;
        signal xadc_eos_s     : out std_logic;
        signal xadc_busy_s    : out std_logic;
        constant n_chan        : in  integer;
        constant channel_base : in  integer;
        constant clk_p        : in  time
    ) is
    begin
        xadc_busy_s <= '1';
        for i in 0 to n_chan - 1 loop
            -- Set channel and data one full cycle before eoc
            -- giving p_ch_decode time to register ch_idx and ch_valid
            wait for clk_p * 5;
            xadc_channel_s <= std_logic_vector(
                               to_unsigned(channel_base + i, 5));
            xadc_do_s      <= std_logic_vector(
                               to_unsigned((i + 1) * 256, 16));
            wait for clk_p;   -- one full cycle for ch_decode to register
            xadc_eoc_s <= '1';
            wait for clk_p;
            xadc_eoc_s <= '0';
        end loop;
        -- End of sequence
        wait for clk_p / 2;
        xadc_eos_s  <= '1';
        wait for clk_p;
        xadc_eos_s  <= '0';
        xadc_busy_s <= '0';
        wait for clk_p;
    end procedure do_conversion;

begin

    -- -------------------------------------------------------------------------
    -- Clock
    -- -------------------------------------------------------------------------
    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    -- -------------------------------------------------------------------------
    -- DUT
    -- -------------------------------------------------------------------------
    dut : entity work.xadc_buffer
        generic map (
            NUM_CHANNELS => NUM_CHANNELS,
            CLK_FREQ_HZ  => 100_000_000
        )
        port map (
            clk              => clk,
            rst              => rst,
            xadc_do          => xadc_do,
            xadc_channel     => xadc_channel,
            xadc_eoc         => xadc_eoc,
            xadc_eos         => xadc_eos,
            xadc_busy        => xadc_busy,
            xadc_convst      => xadc_convst,
            xadc_dclk        => xadc_dclk,
            xadc_den         => xadc_den,
            xadc_dwe         => xadc_dwe,
            xadc_daddr       => xadc_daddr,
            xadc_di          => xadc_di,
            sample_pulse     => sample_pulse,
            adc_data         => adc_data,
            conversion_count => conversion_count
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- Reset
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 1: Reset state
        -- --------------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: Reset state";

        assert adc_data = (adc_data'range => '0')
            report "FAIL T1: adc_data should be zero after reset"
            severity failure;
        assert conversion_count = 0
            report "FAIL T1: conversion_count should be zero after reset"
            severity failure;
        report "TEST 1: PASS";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: convst follows sample_pulse
        -- --------------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: convst follows sample_pulse";

        sample_pulse <= '1'; wait for CLK_PERIOD;
        sample_pulse <= '0';

        assert xadc_convst = '1'
            report "FAIL T2: xadc_convst should follow sample_pulse"
            severity failure;
        report "TEST 2: PASS - convst follows sample_pulse";

        wait for CLK_PERIOD;

        assert xadc_convst = '0'
            report "FAIL T2: xadc_convst should deassert with sample_pulse"
            severity failure;

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: DRP outputs safe defaults
        -- --------------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: DRP outputs at safe defaults";

        assert xadc_den   = '0'
            report "FAIL T3: xadc_den should be 0"
            severity failure;
        assert xadc_dwe   = '0'
            report "FAIL T3: xadc_dwe should be 0"
            severity failure;
        assert xadc_daddr = "0000000"
            report "FAIL T3: xadc_daddr should be 0"
            severity failure;
        assert xadc_di    = x"0000"
            report "FAIL T3: xadc_di should be 0"
            severity failure;
        report "TEST 3: PASS - DRP outputs at safe defaults";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Single conversion sequence
        -- Channels VAUX0-7 (0x10-0x17), data = channel*256
        -- After eos, all channels latched simultaneously
        -- --------------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: Single conversion sequence";

        -- Trigger conversion
        sample_pulse <= '1'; wait for CLK_PERIOD;
        sample_pulse <= '0';

        -- Simulate xADC converting all 8 channels
        do_conversion(xadc_do, xadc_channel, xadc_eoc, xadc_eos,
                      xadc_busy, NUM_CHANNELS, 16#10#, CLK_PERIOD);

        wait for 5 * CLK_PERIOD;

        -- Check all channels latched correctly
        -- Channel 0 (VAUX0): data = 1*256 = 256 = 0x0100
        -- Channel 1 (VAUX1): data = 2*256 = 512 = 0x0200
        -- etc.
        for i in 0 to NUM_CHANNELS - 1 loop
            assert adc_data((i+1)*16-1 downto i*16) =
                   std_logic_vector(to_unsigned((i+1)*256, 16))
                report "FAIL T4: channel " & integer'image(i) &
                       " data=" &
                       integer'image(to_integer(unsigned(
                           adc_data((i+1)*16-1 downto i*16)))) &
                       " expected=" &
                       integer'image((i+1)*256)
                severity failure;
        end loop;

        assert conversion_count = NUM_CHANNELS
            report "FAIL T4: conversion_count=" &
                   integer'image(to_integer(conversion_count)) &
                   " expected=" & integer'image(NUM_CHANNELS)
            severity failure;

        report "TEST 4: PASS - all channels latched correctly";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Second conversion - data updates
        -- New data = channel * 512
        -- --------------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: Second conversion updates data";

        -- New conversion with different data
        sample_pulse <= '1'; wait for CLK_PERIOD;
        sample_pulse <= '0';

        -- Override do_conversion inline with different values
        xadc_busy <= '1';
        for i in 0 to NUM_CHANNELS - 1 loop
            wait for CLK_PERIOD * 5;
            xadc_channel <= std_logic_vector(to_unsigned(16#10# + i, 5));
            xadc_do      <= std_logic_vector(to_unsigned((i+1)*512, 16));
            wait for CLK_PERIOD;  -- one full cycle for ch_decode to register
            xadc_eoc <= '1'; wait for CLK_PERIOD;
            xadc_eoc <= '0';
        end loop;
        wait for CLK_PERIOD / 2;
        xadc_eos <= '1'; wait for CLK_PERIOD;
        xadc_eos <= '0';
        xadc_busy <= '0';

        wait for 5 * CLK_PERIOD;

        for i in 0 to NUM_CHANNELS - 1 loop
            assert adc_data((i+1)*16-1 downto i*16) =
                   std_logic_vector(to_unsigned((i+1)*512, 16))
                report "FAIL T5: channel " & integer'image(i) &
                       " not updated, got " &
                       integer'image(to_integer(unsigned(
                           adc_data((i+1)*16-1 downto i*16))))
                severity failure;
        end loop;

        report "TEST 5: PASS - data updated on second conversion";

        wait for 5 * CLK_PERIOD;

        -- Done
        report "========================================";
        report "All xadc_buffer tests PASS";
        report "========================================";

        sim_done <= true;
        wait;

    end process p_stim;

end architecture sim;