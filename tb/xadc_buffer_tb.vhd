library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- xadc_buffer_tb.vhd
--
-- Tests the xadc_buffer DRP read FSM.
--
-- Simulates the XADC Wizard IP behaviour:
--   - convst (sample_pulse) triggers a conversion cycle
--   - busy goes high, then eoc fires with channel_out after ~10 clocks
--   - den assertion triggers drdy after 2 clocks with do data
--   - eos fires after eoc, latching adc_data
--
-- Key timing bug tested:
--   p_ch_decode registers xadc_channel (1 clock delay). xadc_eoc is a
--   1-clock pulse coincident with channel_out. Without registering eoc,
--   ch_valid arrives 1 clock AFTER eoc so the FSM never sees both '1'.
--   Fix: register xadc_eoc in p_ch_decode to align with ch_valid.
--
-- Tests:
--   T1: Calibration channel (0x08) - FSM stays in IDLE (ignored)
--   T2: VAUX1 channel (0x11) - full FSM cycle, adc_data populated
--   T3: Multiple conversions - consistent behaviour
--   T4: drp_daddr correct (0x11 for VAUX1)
-- =============================================================================

entity xadc_buffer_tb is end entity;

architecture sim of xadc_buffer_tb is

    constant CLK_PERIOD  : time := 10 ns;
    constant BUSY_CYCLES : integer := 10;
    constant DRP_LATENCY : integer := 2;   -- drdy fires N clocks after den

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal sim_done     : boolean   := false;

    -- XADC Wizard model outputs (driven by p_xadc_model)
    signal xadc_do      : std_logic_vector(15 downto 0) := (others => '0');
    signal xadc_drdy    : std_logic := '0';
    signal xadc_channel : std_logic_vector(4 downto 0) := (others => '0');
    signal xadc_eoc     : std_logic := '0';
    signal xadc_eos     : std_logic := '0';
    signal xadc_busy    : std_logic := '0';

    -- DUT outputs
    signal xadc_convst  : std_logic;
    signal xadc_dclk    : std_logic;
    signal xadc_den     : std_logic;
    signal xadc_dwe     : std_logic;
    signal xadc_daddr   : std_logic_vector(6 downto 0);
    signal xadc_di      : std_logic_vector(15 downto 0);
    signal drp_state_out: std_logic_vector(1 downto 0);
    signal adc_data     : std_logic_vector(15 downto 0);
    signal conv_count   : unsigned(31 downto 0);

    -- Stimulus control
    signal sample_pulse : std_logic := '0';
    signal test_num     : integer   := 0;

    -- XADC model control
    signal model_channel : std_logic_vector(4 downto 0) := (others => '0');
    signal model_do      : std_logic_vector(15 downto 0) := (others => '0');
    signal model_trigger : std_logic := '0';

    -- Toggle signal for den detection (same pattern as integration_tb)

begin

    -- =========================================================================
    -- Clock
    -- =========================================================================
    p_clk : process begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop; wait;
    end process;

    -- =========================================================================
    -- DUT
    -- =========================================================================
    u_dut : entity work.xadc_buffer
        generic map (NUM_CHANNELS => 1)
        port map (
            clk              => clk,
            rst              => rst,
            xadc_do          => xadc_do,
            xadc_drdy        => xadc_drdy,
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
            drp_state_out    => drp_state_out,
            adc_data         => adc_data,
            conversion_count => conv_count);

    -- =========================================================================
    -- XADC Wizard model
    -- Simulates one conversion cycle per model_trigger toggle:
    --   busy goes high -> BUSY_CYCLES clocks -> eoc fires with model_channel
    --   -> 1 clock -> eos fires
    -- =========================================================================
    p_xadc_model : process
        variable prev_trigger : std_logic := '0';
    begin
        xadc_busy    <= '0';
        xadc_eoc     <= '0';
        xadc_eos     <= '0';
        xadc_channel <= (others => '0');

        loop
            wait until rising_edge(clk);
            wait for 1 ns;

            -- Detect new conversion trigger
            if model_trigger /= prev_trigger then
                prev_trigger := model_trigger;

                -- Busy period
                xadc_busy <= '1';
                for i in 1 to BUSY_CYCLES loop
                    wait until rising_edge(clk); wait for 1 ns;
                end loop;
                xadc_busy <= '0';

                -- EOC: channel and eoc fire simultaneously for 1 clock
                xadc_channel <= model_channel;
                xadc_eoc     <= '1';
                wait until rising_edge(clk); wait for 1 ns;
                xadc_eoc     <= '0';

                -- EOS fires 1 clock after EOC
                xadc_eos <= '1';
                wait until rising_edge(clk); wait for 1 ns;
                xadc_eos <= '0';
            end if;

            exit when sim_done;
        end loop;
        wait;
    end process p_xadc_model;

    -- =========================================================================
    -- DRP read response model -- clocked polling (reliable for DUT outputs)
    -- =========================================================================
    p_drp_model : process
        variable den_prev : std_logic := '0';
    begin
        loop
            wait until rising_edge(clk);
            wait for 1 ns;
            -- Detect rising edge of xadc_den
            if xadc_den = '1' and den_prev = '0' then
                -- Respond with drdy after DRP_LATENCY clocks
                for i in 1 to DRP_LATENCY loop
                    wait until rising_edge(clk);
                end loop;
                wait for 1 ns;
                xadc_do   <= model_do;
                xadc_drdy <= '1';
                wait until rising_edge(clk); wait for 1 ns;
                xadc_drdy <= '0';
            end if;
            den_prev := xadc_den;
            exit when sim_done;
        end loop;
        wait;
    end process p_drp_model;


    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim : process

        procedure do_pulse is begin
            sample_pulse <= '1'; wait for CLK_PERIOD;
            sample_pulse <= '0';
        end procedure;

        procedure trigger_conversion(
            channel : std_logic_vector(4 downto 0);
            do_val  : std_logic_vector(15 downto 0)) is
        begin
            model_channel <= channel;
            model_do      <= do_val;
            model_trigger <= not model_trigger;  -- toggle to trigger model
            do_pulse;
        end procedure;

        procedure wait_clocks(n : integer) is begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
            wait for 1 ns;
        end procedure;

    begin
        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD;

        -- ==================================================================
        -- T1: Calibration channel (0x08) - FSM must stay in IDLE
        -- xadc_channel = 0x08, FSM should ignore it
        -- ==================================================================
        test_num <= 1;
        report "TEST 1: Calibration channel (0x08) ignored by FSM";

        trigger_conversion("01000", x"DEAD"); -- channel 0x08

        -- Wait for model to complete (busy + eoc + eos + drp latency + margin)
        wait_clocks(BUSY_CYCLES + 10);

        assert drp_state_out = "00"
            report "FAIL T1: FSM left IDLE on calibration channel, state=" &
                   integer'image(to_integer(unsigned(drp_state_out)))
            severity failure;
        assert conv_count = 0
            report "FAIL T1: conversion_count should be 0, got " &
                   integer'image(to_integer(conv_count))
            severity failure;
        assert adc_data = x"0000"
            report "FAIL T1: adc_data should be 0, got " &
                   integer'image(to_integer(unsigned(adc_data)))
            severity failure;
        report "TEST 1: PASS - calibration channel correctly ignored";

        wait_clocks(5);

        -- ==================================================================
        -- T2: VAUX1 channel (0x11) - full FSM cycle
        -- FSM must cycle IDLE->ISSUE_READ->WAIT_DRDY->IDLE
        -- adc_data must be populated after eos
        -- ==================================================================
        test_num <= 2;
        report "TEST 2: VAUX1 channel (0x11) - full FSM cycle";

        trigger_conversion("10001", x"A5B0"); -- channel 0x11, do=0xA5B0

        -- Wait for full cycle to complete
        wait_clocks(BUSY_CYCLES + DRP_LATENCY + 10);

        assert drp_state_out = "00"
            report "FAIL T2: FSM not back in IDLE after conversion, state=" &
                   integer'image(to_integer(unsigned(drp_state_out)))
            severity failure;
        assert conv_count = 1
            report "FAIL T2: conversion_count should be 1, got " &
                   integer'image(to_integer(conv_count))
            severity failure;
        assert adc_data = x"A5B0"
            report "FAIL T2: adc_data=" & integer'image(to_integer(unsigned(adc_data))) &
                   " expected 0xA5B0=42416"
            severity failure;
        report "TEST 2: PASS - VAUX1 conversion complete, adc_data=0xA5B0";

        wait_clocks(5);

        -- ==================================================================
        -- T3: drp_daddr correct for VAUX1 (must be 0x11)
        -- ==================================================================
        test_num <= 3;
        report "TEST 3: drp_daddr = 0x11 for VAUX1";

        trigger_conversion("10001", x"1234"); -- channel 0x11

        -- Wait for den to fire then check daddr
        wait until rising_edge(clk) and xadc_den = '1' for 500 ms;
        wait for 1 ns;
        assert xadc_daddr = "0010001"  -- 0x11
            report "FAIL T3: daddr=" &
                   integer'image(to_integer(unsigned(xadc_daddr))) &
                   " expected 0x11=17"
            severity failure;
        report "TEST 3: PASS - drp_daddr=0x11 correct";

        wait_clocks(BUSY_CYCLES + DRP_LATENCY + 10);

        -- ==================================================================
        -- T4: Multiple conversions - conv_count increments correctly
        -- ==================================================================
        test_num <= 4;
        report "TEST 4: Multiple conversions - conv_count correct";

        for i in 1 to 5 loop
            trigger_conversion("10001",
                std_logic_vector(to_unsigned(i * 256, 16)));
            wait_clocks(BUSY_CYCLES + DRP_LATENCY + 10);
        end loop;

        assert conv_count = 7  -- 2 from T2/T3 + 5 here
            report "FAIL T4: conv_count=" &
                   integer'image(to_integer(conv_count)) &
                   " expected 7"
            severity failure;
        report "TEST 4: PASS - conv_count=" &
               integer'image(to_integer(conv_count));

        -- ==================================================================
        report "========================================";
        report "All xadc_buffer tests PASS";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
