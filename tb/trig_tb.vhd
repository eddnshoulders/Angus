library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity trig_tb is
end entity trig_tb;

architecture sim of trig_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- Trigger fires on every change of ang_deg (every 0.1 degree step)
    -- when decimation=1.  Pulse width is trig_pulse_width clocks.
    -- trig_pulse_count resets on z_edge.
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 10 ns;
    constant PULSE_WIDTH  : integer := 5;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal ang_deg  : unsigned(15 downto 0) := (others => '0');
    signal z_edge   : std_logic := '0';
    signal decim    : unsigned(15 downto 0) := to_unsigned(1, 16);
    signal pw       : unsigned(15 downto 0) := to_unsigned(PULSE_WIDTH, 16);
    signal trig_p   : std_logic;
    signal trig_cnt : unsigned(31 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done  : boolean := false;
    signal test_num  : integer := 0;
    signal pulse_count: integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a z_edge strobe
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   z   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_z;

begin

    -- -------------------------------------------------------------------------
    -- Clock generation
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
    -- DUT instantiation
    -- -------------------------------------------------------------------------
    dut : entity work.trig
        port map (
            clk              => clk,
            rst              => rst,
            ang_deg          => ang_deg,
            z_edge           => z_edge,
            trig_decimation  => decim,
            trig_pulse_width => pw,
            trig_pulse       => trig_p,
            trig_pulse_count => trig_cnt
        );

    -- -------------------------------------------------------------------------
    -- Pulse counter monitor
    -- -------------------------------------------------------------------------
    -- Count only rising edges of trig_pulse, not every high clock
    p_monitor : process(clk)
        variable prev : std_logic := '0';
    begin
        if rising_edge(clk) then
            if trig_p = '1' and prev = '0' then
                pulse_count <= pulse_count + 1;
            end if;
            prev := trig_p;
        end if;
    end process p_monitor;

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable count_start : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert trig_p = '0'
            report "FAIL T1: trig_pulse should be low after reset"
            severity failure;
        assert to_integer(trig_cnt) = 0
            report "FAIL T1: trig_pulse_count should be 0 after reset"
            severity failure;

        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: decimation=1, pulse fires on every ang_deg increment
        -- --------------------------------------------------------------------
        report "TEST 2: decimation=1 fires on every angle increment";
        test_num <= 2;

        decim <= to_unsigned(1, 16);
        -- Each step must wait > PULSE_WIDTH clocks so the pulse expires before
        -- the next increment (otherwise the pulse is restarted and no new rising edge)
        count_start := pulse_count;

        ang_deg <= to_unsigned(1, 16); wait for (PULSE_WIDTH + 2) * CLK_PERIOD;
        ang_deg <= to_unsigned(2, 16); wait for (PULSE_WIDTH + 2) * CLK_PERIOD;
        ang_deg <= to_unsigned(3, 16); wait for (PULSE_WIDTH + 2) * CLK_PERIOD;
        ang_deg <= to_unsigned(4, 16); wait for (PULSE_WIDTH + 2) * CLK_PERIOD;
        ang_deg <= to_unsigned(5, 16); wait for (PULSE_WIDTH + 2) * CLK_PERIOD;

        assert pulse_count - count_start = 5
            report "FAIL T2: expected 5 pulses with decim=1, got " &
                   integer'image(pulse_count - count_start)
            severity failure;

        report "TEST 2: PASS - " & integer'image(pulse_count - count_start) & " pulses";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: No pulse when ang_deg unchanged
        -- --------------------------------------------------------------------
        report "TEST 3: No pulse when ang_deg unchanged";
        test_num <= 3;

        -- Angle held at 5
        count_start := pulse_count;
        wait for 10 * CLK_PERIOD;
        wait for 1 ns;

        assert pulse_count = count_start
            report "FAIL T3: pulse fired with no angle change"
            severity failure;

        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: Pulse width = trig_pulse_width clocks
        -- --------------------------------------------------------------------
        report "TEST 4: Pulse width = trig_pulse_width clocks";
        test_num <= 4;

        ang_deg <= to_unsigned(6, 16);
        wait until trig_p = '1';
        wait for 1 ns;

        wait for (PULSE_WIDTH - 2) * CLK_PERIOD;
        wait for 1 ns;
        assert trig_p = '1'
            report "FAIL T4: pulse ended before trig_pulse_width clocks"
            severity failure;

        wait for 2 * CLK_PERIOD;
        wait for 1 ns;
        assert trig_p = '0'
            report "FAIL T4: pulse did not end after trig_pulse_width clocks"
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: decimation=3, pulse every 3rd angle increment
        -- --------------------------------------------------------------------
        report "TEST 5: decimation=3 fires on every 3rd increment";
        test_num <= 5;

        decim <= to_unsigned(3, 16);
        wait for 2 * CLK_PERIOD;   -- let new decim register
        count_start := pulse_count;

        -- Step 9 times: expect exactly 3 pulses
        for i in 7 to 15 loop
            ang_deg <= to_unsigned(i, 16);
            wait for 2 * CLK_PERIOD;
        end loop;
        wait for 2 * CLK_PERIOD;

        assert pulse_count - count_start = 3
            report "FAIL T5: expected 3 pulses with decim=3 and 9 steps, got " &
                   integer'image(pulse_count - count_start)
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: trig_pulse_count resets on z_edge
        -- --------------------------------------------------------------------
        report "TEST 6: trig_pulse_count resets on z_edge";
        test_num <= 6;

        -- Verify count is non-zero first
        assert to_integer(trig_cnt) > 0
            report "FAIL T6: trig_count should be non-zero before z_edge"
            severity failure;

        fire_z(z_edge, clk);
        wait for 1 ns;

        assert to_integer(trig_cnt) = 0
            report "FAIL T6: trig_count not reset on z_edge, got " &
                   integer'image(to_integer(trig_cnt))
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: Angle wraparound 7199 -> 0 fires a pulse (decim=1)
        -- --------------------------------------------------------------------
        report "TEST 7: Angle wraparound 7199 -> 0 fires a pulse";
        test_num <= 7;

        decim <= to_unsigned(1, 16);
        ang_deg <= to_unsigned(7199, 16);
        wait for (PULSE_WIDTH + 2) * CLK_PERIOD;  -- let prior pulse expire

        count_start := pulse_count;
        ang_deg <= to_unsigned(0, 16);
        wait for (PULSE_WIDTH + 2) * CLK_PERIOD;  -- let wraparound pulse fire

        assert pulse_count - count_start = 1
            report "FAIL T7: should fire on 7199 -> 0 wraparound"
            severity failure;

        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All trig tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
