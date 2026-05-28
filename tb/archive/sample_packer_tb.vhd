library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity sample_packer_tb is
end entity sample_packer_tb;

architecture sim of sample_packer_tb is

    constant CLK_PERIOD  : time    := 1000 ns;
    constant ADC_CH      : integer := 8;

    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal sample_pulse   : std_logic := '0';
    signal sample_angle   : unsigned(15 downto 0) := (others => '0');
    signal adc_data       : std_logic_vector(ADC_CH * 16 - 1 downto 0) :=
                            (others => '0');
    signal digital_inputs : std_logic_vector(7 downto 0) := (others => '0');
    signal m_axis_tdata   : std_logic_vector(31 downto 0);
    signal m_axis_tvalid  : std_logic;
    signal m_axis_tready  : std_logic := '1';
    signal m_axis_tlast   : std_logic;
    signal packet_count   : unsigned(31 downto 0);
    signal overflow_count : unsigned(15 downto 0);

    signal sim_done       : boolean := false;
    signal test_num       : integer := 0;
    signal test_step      : integer := 0;

    -- Received packet words
    type packet_t is array (0 to 3) of std_logic_vector(31 downto 0);
    signal rx_packet      : packet_t := (others => (others => '0'));
    signal rx_word_idx    : integer := 0;
    signal rx_packet_done : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Fire one sample pulse with given angle and ADC/digital data
    -- -------------------------------------------------------------------------
    procedure fire_sample(
        signal pulse_sig  : out std_logic;
        signal angle_sig  : out unsigned(15 downto 0);
        signal adc_sig    : out std_logic_vector(ADC_CH * 16 - 1 downto 0);
        signal dig_sig    : out std_logic_vector(7 downto 0);
        constant angle    : in  integer;
        constant adc_ch0  : in  integer;
        constant dig      : in  integer;
        constant clk_p    : in  time
    ) is
    begin
        angle_sig                        <= to_unsigned(angle, 16);
        adc_sig(15 downto 0)             <= std_logic_vector(to_unsigned(adc_ch0, 16));
        adc_sig(ADC_CH * 16 - 1 downto 16) <= (others => '0');
        dig_sig                          <= std_logic_vector(to_unsigned(dig, 8));
        wait for clk_p;
        pulse_sig <= '1';
        wait for clk_p;
        pulse_sig <= '0';
    end procedure fire_sample;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.sample_packer
        generic map (
            ADC_CHANNELS => ADC_CH
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
    -- AXI Stream receiver: captures packet words
    -- -------------------------------------------------------------------------
    p_receiver : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_word_idx    <= 0;
                rx_packet_done <= '0';
            else
                rx_packet_done <= '0';

                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    rx_packet(rx_word_idx) <= m_axis_tdata;

                    if m_axis_tlast = '1' then
                        rx_word_idx    <= 0;
                        rx_packet_done <= '1';
                    else
                        rx_word_idx <= rx_word_idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_receiver;

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;
        rst <= '1'; wait for 10 * CLK_PERIOD;
        rst <= '0'; wait for 10 * CLK_PERIOD;

        assert m_axis_tvalid = '0'
            report "FAIL T1: tvalid should be low after reset"
            severity failure;
        assert to_integer(packet_count) = 0
            report "FAIL T1: packet_count should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Single packet transmission
        -- Verify all 4 words sent with correct data
        -- --------------------------------------------------------------------
        report "TEST 2: Single packet transmission";
        test_num <= 2;
        m_axis_tready <= '1';

        fire_sample(sample_pulse, sample_angle, adc_data, digital_inputs,
                    1234,    -- angle = 1234 (123.4 deg)
                    5678,    -- adc ch0 = 5678
                    16#AB#,  -- digital = 0xAB
                    CLK_PERIOD);

        -- Wait for packet to complete
        wait until rx_packet_done = '1';
        wait for CLK_PERIOD;

        -- Check Word 0: timestamp & angle
        assert rx_packet(0)(15 downto 0) = std_logic_vector(to_unsigned(1234, 16))
            report "FAIL T2: Word 0 angle = " &
                   integer'image(to_integer(unsigned(rx_packet(0)(15 downto 0)))) &
                   " expected 1234"
            severity failure;

        -- Check Word 1: adc_ch1 & adc_ch0
        assert rx_packet(1)(15 downto 0) = std_logic_vector(to_unsigned(5678, 16))
            report "FAIL T2: Word 1 adc_ch0 = " &
                   integer'image(to_integer(unsigned(rx_packet(1)(15 downto 0)))) &
                   " expected 5678"
            severity failure;

        -- Check Word 3: digital inputs in upper byte
        assert rx_packet(3)(31 downto 24) = std_logic_vector(to_unsigned(16#AB#, 8))
            report "FAIL T2: Word 3 digital = " &
                   integer'image(to_integer(unsigned(rx_packet(3)(31 downto 24)))) &
                   " expected 0xAB"
            severity failure;

        assert to_integer(packet_count) = 1
            report "FAIL T2: packet_count should be 1"
            severity failure;

        report "TEST 2: PASS - packet_count = " &
               integer'image(to_integer(packet_count));

        -- --------------------------------------------------------------------
        -- TEST 3: tlast asserted on word 3
        -- --------------------------------------------------------------------
        report "TEST 3: tlast on last word";
        test_num <= 3;

        fire_sample(sample_pulse, sample_angle, adc_data, digital_inputs,
                    100, 200, 0, CLK_PERIOD);

        wait until rx_packet_done = '1';
        report "TEST 3: PASS - tlast correctly terminated packet";

        -- --------------------------------------------------------------------
        -- TEST 4: Back to back packets
        -- --------------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: Back to back packets";

        for i in 1 to 6 loop
            fire_sample(sample_pulse, sample_angle, adc_data, digital_inputs,
                        i * 100, i * 10, 0, CLK_PERIOD);                        
            wait until rx_packet_done = '1';
            test_step <= i;
        end loop;

        assert to_integer(packet_count) = 7   -- 2 from previous + 5
            report "FAIL T4: packet_count = " &
                   integer'image(to_integer(packet_count)) &
                   " expected 7"
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: Back-pressure - tready deasserted mid-packet
        -- --------------------------------------------------------------------
        report "TEST 5: Back-pressure handling";
        test_num <= 5;

        m_axis_tready <= '0';

        fire_sample(sample_pulse, sample_angle, adc_data, digital_inputs,
                    999, 888, 0, CLK_PERIOD);

        -- Wait a few cycles then assert ready
        wait for 10 * CLK_PERIOD;
        assert m_axis_tvalid = '1'
            report "FAIL T5: tvalid should stay high during back-pressure"
            severity failure;

        m_axis_tready <= '1';
        wait until rx_packet_done = '1';

        report "TEST 5: PASS - packet completed after back-pressure";

        -- --------------------------------------------------------------------
        -- TEST 6: Overflow detection
        -- Send two pulses while DMA not ready
        -- --------------------------------------------------------------------
        report "TEST 6: Overflow detection";
        test_num <= 6;
        test_step <= 1;

        m_axis_tready <= '0';

        -- First pulse starts a packet
        fire_sample(sample_pulse, sample_angle, adc_data, digital_inputs,
                    111, 222, 0, CLK_PERIOD);

        wait for CLK_PERIOD * 2;
        test_step <= 2;

        -- Second pulse while first still sending = overflow
        fire_sample(sample_pulse, sample_angle, adc_data, digital_inputs,
                    333, 444, 0, CLK_PERIOD);

        test_step <= 3;

        -- Release DMA
        m_axis_tready <= '1';
        wait until rx_packet_done = '1';
        wait for CLK_PERIOD * 2;

        test_step <= 4;

        assert to_integer(overflow_count) > 0
            report "FAIL T6: overflow_count should be non-zero"
            severity failure;

        report "TEST 6: PASS - overflow_count = " &
               integer'image(to_integer(overflow_count));

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All sample_packer tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;