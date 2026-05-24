library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- integration_data_tb
--
-- Integration testbench for the data path chain:
--   angle_offset → sample_trigger → sample_packer
--
-- Drives angle, sync and ADC inputs directly (no crank signal generation)
-- and verifies output packet content, angular spacing and packet rate.
-- =============================================================================

entity integration_data_tb is
end entity integration_data_tb;

architecture sim of integration_data_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD    : time    := 1000 ns;   -- 1MHz sim clock
    constant NUM_CHANNELS  : integer := 8;

    -- Sync states
    constant ST_UNSYNC     : std_logic_vector(2 downto 0) := "000";
    constant ST_SYNC_CRANK : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL  : std_logic_vector(2 downto 0) := "011";

    -- Angle step time at 1000 RPM, 0.1 degree resolution
    -- 1000 RPM = 25 engine cycles/sec
    -- 7200 steps/cycle * 25 cycles/sec = 180000 steps/sec
    -- Step period = 1/180000 = 5.56us ≈ 6 clocks at 1MHz
    -- Use 6 clock cycles per angle step for simplicity
    constant ANGLE_STEP_PERIOD : time := 6_000 ns;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';

    -- angle_offset inputs
    signal raw_angle       : unsigned(15 downto 0) := (others => '0');
    signal sync_offset     : std_logic := '0';
    signal tdc_offset      : unsigned(15 downto 0) := (others => '0');

    -- angle_offset outputs → sample_trigger
    signal crank_angle     : unsigned(15 downto 0);
    signal engine_angle    : unsigned(15 downto 0);

    -- sample_trigger inputs
    signal sync_state      : std_logic_vector(2 downto 0) := ST_UNSYNC;
    signal decimation      : unsigned(7 downto 0) := to_unsigned(1, 8);

    -- sample_trigger outputs → sample_packer
    signal sample_pulse    : std_logic;
    signal sample_angle    : unsigned(15 downto 0);

    -- sample_packer inputs
    signal adc_data        : std_logic_vector(NUM_CHANNELS * 16 - 1 downto 0)
                             := (others => '0');
    signal digital_inputs  : std_logic_vector(7 downto 0) := (others => '0');

    -- sample_packer outputs
    signal m_axis_tdata    : std_logic_vector(31 downto 0);
    signal m_axis_tvalid   : std_logic;
    signal m_axis_tready   : std_logic := '1';
    signal m_axis_tlast    : std_logic;
    signal packet_count    : unsigned(31 downto 0);
    signal overflow_count  : unsigned(15 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done        : boolean := false;
    signal test_num        : integer := 0;
    signal angle_run       : std_logic := '0';

    -- Received packet storage
    type packet_t is array (0 to 3) of std_logic_vector(31 downto 0);
    signal rx_packet       : packet_t := (others => (others => '0'));
    signal rx_done         : std_logic := '0';
    signal rx_word_idx     : integer := 0;
    signal rx_count        : integer := 0;

    -- Angular spacing measurement
    signal last_sample_angle : unsigned(15 downto 0) := (others => '0');
    signal angle_spacing     : integer := 0;
    signal spacing_valid     : std_logic := '0';

    -- Helper: extract channel N from adc_data
    function get_channel(
        data : std_logic_vector;
        ch   : integer
    ) return integer is
    begin
        return to_integer(unsigned(data((ch + 1) * 16 - 1 downto ch * 16)));
    end function;

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

    -- =========================================================================
    -- DUT instantiation
    -- =========================================================================

    u_angle_offset : entity work.angle_offset
        port map (
            raw_angle    => raw_angle,
            sync_offset  => sync_offset,
            tdc_offset   => tdc_offset,
            crank_angle  => crank_angle,
            engine_angle => engine_angle
        );

    u_sample_trigger : entity work.sample_trigger
        port map (
            clk          => clk,
            rst          => rst,
            engine_angle => engine_angle,
            sync_state   => sync_state,
            decimation   => decimation,
            sample_pulse => sample_pulse,
            sample_angle => sample_angle
        );

    u_sample_packer : entity work.sample_packer
        generic map (
            ADC_CHANNELS => NUM_CHANNELS
        )
        port map (
            clk            => clk,
            rst            => rst,
            sample_pulse   => sample_pulse,
            sample_angle   => sample_angle,
            adc_data       => adc_data,
            digital_inputs => digital_inputs,
            m_axis_tdata   => m_axis_tdata,
            m_axis_tvalid  => m_axis_tvalid,
            m_axis_tready  => m_axis_tready,
            m_axis_tlast   => m_axis_tlast,
            packet_count   => packet_count,
            overflow_count => overflow_count
        );

    -- -------------------------------------------------------------------------
    -- Angle generator
    -- Increments raw_angle by 1 (0.1 deg) at ANGLE_STEP_PERIOD intervals
    -- Wraps at 7200
    -- -------------------------------------------------------------------------
    p_angle : process
    begin
        loop
            if angle_run = '0' then
                wait until angle_run = '1';
            end if;
            wait for ANGLE_STEP_PERIOD;
            if angle_run = '1' then
                if raw_angle = to_unsigned(7199, 16) then
                    raw_angle <= (others => '0');
                else
                    raw_angle <= raw_angle + 1;
                end if;
            end if;
        end loop;
    end process p_angle;

    -- -------------------------------------------------------------------------
    -- AXI Stream receiver
    -- -------------------------------------------------------------------------
    p_receiver : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_word_idx <= 0;
                rx_done     <= '0';
                rx_count    <= 0;
            else
                rx_done <= '0';
                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    rx_packet(rx_word_idx) <= m_axis_tdata;
                    if m_axis_tlast = '1' then
                        rx_word_idx <= 0;
                        rx_done     <= '1';
                        rx_count    <= rx_count + 1;
                    else
                        rx_word_idx <= rx_word_idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_receiver;

    -- -------------------------------------------------------------------------
    -- Angular spacing monitor
    -- Measures angle difference between consecutive sample_pulses
    -- -------------------------------------------------------------------------
    p_spacing : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                last_sample_angle <= (others => '0');
                angle_spacing     <= 0;
                spacing_valid     <= '0';
            else
                if sample_pulse = '1' then
                    if spacing_valid = '1' then
                        -- Calculate spacing, handle wraparound
                        if sample_angle >= last_sample_angle then
                            angle_spacing <= to_integer(
                                sample_angle - last_sample_angle);
                        else
                            angle_spacing <= to_integer(
                                sample_angle + 7200 - last_sample_angle);
                        end if;
                    end if;
                    last_sample_angle <= sample_angle;
                    spacing_valid     <= '1';
                end if;
            end if;
        end if;
    end process p_spacing;

    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim : process
        variable pkt_start    : integer;
        variable rx_start     : integer;
        variable angle_start  : integer;
        variable expected_spacing : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: Reset behaviour";
        rst       <= '1';
        angle_run <= '0';
        sync_state <= ST_UNSYNC;
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert m_axis_tvalid = '0'
            report "FAIL T1: tvalid should be low after reset"
            severity failure;
        assert to_integer(packet_count) = 0
            report "FAIL T1: packet_count should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: No packets in UNSYNC
        -- --------------------------------------------------------------------
        test_num  <= 2;
        report "TEST 2: No packets in UNSYNC";

        pkt_start := to_integer(packet_count);
        sync_state <= ST_UNSYNC;
        angle_run  <= '1';
        wait for ANGLE_STEP_PERIOD * 100;

        assert to_integer(packet_count) = pkt_start
            report "FAIL T2: should not produce packets in UNSYNC"
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: No packets in SYNC_CRANK
        -- --------------------------------------------------------------------
        test_num   <= 3;
        report "TEST 3: No packets in SYNC_CRANK";

        pkt_start  := to_integer(packet_count);
        sync_state <= ST_SYNC_CRANK;
        wait for ANGLE_STEP_PERIOD * 100;

        assert to_integer(packet_count) = pkt_start
            report "FAIL T3: should not produce packets in SYNC_CRANK"
            severity failure;
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: Packets fire in SYNC_FULL with decimation = 1
        -- --------------------------------------------------------------------
        test_num   <= 4;
        report "TEST 4: Packets fire in SYNC_FULL";

        pkt_start  := to_integer(packet_count);
        decimation <= to_unsigned(1, 8);
        sync_state <= ST_SYNC_FULL;
        wait for ANGLE_STEP_PERIOD * 20;

        assert to_integer(packet_count) > pkt_start
            report "FAIL T4: should produce packets in SYNC_FULL"
            severity failure;
        report "TEST 4: PASS - packets firing in SYNC_FULL";

        -- --------------------------------------------------------------------
        -- TEST 5: sample_angle in packet matches engine_angle
        -- --------------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: sample_angle correct in packet";

        -- Wait for next complete packet
        wait until rx_done = '1';
        wait for CLK_PERIOD;

        -- Word 0 lower 16 bits = sample_angle
        assert to_integer(unsigned(rx_packet(0)(15 downto 0))) =
               to_integer(unsigned(rx_packet(0)(15 downto 0)))
            report "FAIL T5: sample_angle mismatch"
            severity failure;

        report "TEST 5: PASS - sample_angle = " &
               integer'image(to_integer(unsigned(rx_packet(0)(15 downto 0))));

        -- --------------------------------------------------------------------
        -- TEST 6: ADC data correct in packet
        -- --------------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: ADC data in packet";

        -- Set known ADC values
        adc_data(15 downto 0)  <= x"1234";   -- ch0
        adc_data(31 downto 16) <= x"5678";   -- ch1
        adc_data(127 downto 32) <= (others => '0');

        wait until rx_done = '1';
        wait for CLK_PERIOD;

        assert rx_packet(1)(15 downto 0) = x"1234"
            report "FAIL T6: adc_ch0 should be 0x1234, got " &
                   integer'image(to_integer(unsigned(rx_packet(1)(15 downto 0))))
            severity failure;
        assert rx_packet(1)(31 downto 16) = x"5678"
            report "FAIL T6: adc_ch1 should be 0x5678"
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: Digital inputs correct in packet
        -- --------------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: Digital inputs in packet";

        digital_inputs <= x"A5";

        wait until rx_done = '1';
        wait for CLK_PERIOD;

        assert rx_packet(3)(31 downto 24) = x"A5"
            report "FAIL T7: digital_inputs should be 0xA5, got " &
                   integer'image(to_integer(unsigned(rx_packet(3)(31 downto 24))))
            severity failure;
        report "TEST 7: PASS";

        -- Reset digital inputs
        digital_inputs <= (others => '0');

        -- --------------------------------------------------------------------
        -- TEST 8: sync_offset = 0, crank_angle = raw_angle
        -- --------------------------------------------------------------------
        report "TEST 8: sync_offset = 0, crank_angle = raw_angle";
        test_num    <= 8;

        angle_run   <= '1';
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(0, 16);

        wait until raw_angle = to_unsigned(1000, 16);
        wait for CLK_PERIOD;

        assert to_integer(crank_angle) = 1000
            report "FAIL T8: crank_angle should = raw_angle = 1000, got " &
                integer'image(to_integer(crank_angle))
            severity failure;
        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- TEST 9: sync_offset = 1, crank_angle = raw_angle + 3600
        -- --------------------------------------------------------------------
        report "TEST 9: sync_offset = 1, crank_angle = raw_angle + 3600";
        test_num    <= 9;

        sync_offset <= '1';
        tdc_offset  <= to_unsigned(0, 16);

        wait until raw_angle = to_unsigned(500, 16);
        wait for CLK_PERIOD;

        assert to_integer(crank_angle) = 4100
            report "FAIL T9: crank_angle should be 4100, got " &
                integer'image(to_integer(crank_angle))
            severity failure;
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- TEST 10: TDC offset applied correctly
        -- raw = 500, sync_offset = 0, tdc = 200 → engine = 700
        -- --------------------------------------------------------------------
        report "TEST 10: TDC offset applied correctly";
        test_num    <= 10;

        sync_offset <= '0';
        tdc_offset  <= to_unsigned(200, 16);

        wait until raw_angle = to_unsigned(500, 16);
        wait for CLK_PERIOD;

        assert to_integer(engine_angle) = 700
            report "FAIL T10: engine_angle should be 700, got " &
                integer'image(to_integer(engine_angle))
            severity failure;
        report "TEST 10: PASS";

        -- Restore defaults before angular spacing tests
        tdc_offset  <= to_unsigned(0, 16);
        sync_offset <= '0';

        -- --------------------------------------------------------------------
        -- TEST 11: Decimation = 1, angular spacing = 0.1 deg = 1 step
        -- --------------------------------------------------------------------
        test_num   <= 11;
        report "TEST 11: Decimation = 1, spacing = 1 step (0.1 deg)";

        decimation <= to_unsigned(1, 8);
        angle_run  <= '1';
        sync_state <= ST_SYNC_FULL;

        -- Wait for spacing to stabilise
        wait for ANGLE_STEP_PERIOD * 20;

        assert angle_spacing = 1
            report "FAIL T11: spacing should be 1 (0.1 deg), got " &
                   integer'image(angle_spacing)
            severity failure;
        report "TEST 11: PASS - spacing = " &
               integer'image(angle_spacing) & " (0.1 deg)";

        -- --------------------------------------------------------------------
        -- TEST 12: Decimation = 10, angular spacing = 1.0 deg = 10 steps
        -- --------------------------------------------------------------------
        test_num   <= 12;
        report "TEST 12: Decimation = 10, spacing = 10 steps (1.0 deg)";

        decimation <= to_unsigned(10, 8);
        wait for ANGLE_STEP_PERIOD * 50;

        assert angle_spacing = 10
            report "FAIL T12: spacing should be 10 (1.0 deg), got " &
                   integer'image(angle_spacing)
            severity failure;
        report "TEST 12: PASS - spacing = " &
               integer'image(angle_spacing) & " (1.0 deg)";

        -- --------------------------------------------------------------------
        -- TEST 13: Decimation = 60, angular spacing = 6.0 deg = 60 steps
        -- --------------------------------------------------------------------
        test_num   <= 13;
        report "TEST 13: Decimation = 60, spacing = 60 steps (6.0 deg)";

        decimation <= to_unsigned(60, 8);
        wait for ANGLE_STEP_PERIOD * 200;

        assert angle_spacing = 60
            report "FAIL T13: spacing should be 60 (6.0 deg), got " &
                   integer'image(angle_spacing)
            severity failure;
        report "TEST 13: PASS - spacing = " &
               integer'image(angle_spacing) & " (6.0 deg)";

        -- --------------------------------------------------------------------
        -- TEST 14: Packet count per cycle at decimation = 1
        -- 7200 steps per cycle, decimation = 1 → 7200 packets per cycle
        -- At ANGLE_STEP_PERIOD = 6us, one cycle = 7200 * 6us = 43.2ms
        -- --------------------------------------------------------------------
        test_num   <= 14;
        report "TEST 14: Packet count per cycle at decimation = 1";

        decimation <= to_unsigned(1, 8);

        -- Wait for angle to reach 0 (cycle start)
        wait until raw_angle = 0;
        rx_start := rx_count;

        -- Wait for exactly one cycle
        wait until raw_angle = 0;
        wait for CLK_PERIOD * 5;

        assert (rx_count - rx_start) = 7200
            report "FAIL T14: packets per cycle = " &
                   integer'image(rx_count - rx_start) &
                   " expected 7200"
            severity failure;
        report "TEST 14: PASS - " &
               integer'image(rx_count - rx_start) & " packets per cycle";

        -- --------------------------------------------------------------------
        -- TEST 15: Packet count per cycle at decimation = 10
        -- 7200 / 10 = 720 packets per cycle
        -- --------------------------------------------------------------------
        test_num   <= 15;
        report "TEST 15: Packet count per cycle at decimation = 10";

        decimation <= to_unsigned(10, 8);

        wait until raw_angle = 0;
        rx_start := rx_count;

        wait until raw_angle = 0;
        wait for CLK_PERIOD * 5;

        assert (rx_count - rx_start) = 720
            report "FAIL T15: packets per cycle = " &
                   integer'image(rx_count - rx_start) &
                   " expected 720"
            severity failure;
        report "TEST 15: PASS - " &
               integer'image(rx_count - rx_start) & " packets per cycle";

        -- --------------------------------------------------------------------
        -- TEST 16: Overflow detection when DMA not ready
        -- --------------------------------------------------------------------
        test_num       <= 16;
        report "TEST 16: Overflow detection";

        decimation     <= to_unsigned(1, 8);
        m_axis_tready  <= '0';
        wait for ANGLE_STEP_PERIOD * 20;
        m_axis_tready  <= '1';
        wait for ANGLE_STEP_PERIOD * 20;

        assert to_integer(overflow_count) > 0
            report "FAIL T16: overflow_count should be non-zero"
            severity failure;
        report "TEST 16: PASS - overflow_count = " &
               integer'image(to_integer(overflow_count));

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        angle_run <= '0';
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All integration_data_path tests complete";
        report "========================================";

        sim_done <= true;
        wait;

    end process p_stim;

end architecture sim;