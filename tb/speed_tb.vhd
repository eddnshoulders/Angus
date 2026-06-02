library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity speed_tb is
end entity speed_tb;

architecture sim of speed_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- RPM formula: RPM = 60_000_000_000 / (period_clocks * 100MHz * 60)
    --            = 1_000_000_000 / period_clocks
    --
    -- Choosing periods that give whole-number RPM values:
    --   z_period = 6_000_000 clocks -> RPM_slow = 1_000_000_000 / 6_000_000 = ?
    --   Actually: rpm_slow = (CLK_FREQ_HZ * 60) / z_period
    --   At 100MHz: rpm_slow = 6_000_000_000 / z_period
    --   z_period = 600_000 -> rpm_slow = 10_000
    --   ab_period = 10_000  -> rpm_fast = 6e9 / (10000 * 60) = 10_000
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD        : time    := 10 ns;
    constant Z_PERIOD_10K_RPM  : integer := 600_000;
    constant AB_PERIOD_10K_RPM : integer := 10_000;
    constant EXPECTED_RPM      : integer := 10_000;

    -- Second RPM value for RPM change test
    constant Z_PERIOD_5K_RPM   : integer := 1_200_000;
    constant AB_PERIOD_5K_RPM  : integer := 20_000;
    constant EXPECTED_5K_RPM   : integer := 5_000;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal ab_edge  : std_logic := '0';
    signal z_edge   : std_logic := '0';
    signal ab_per   : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_10K_RPM, 32);
    signal ppr_s    : unsigned(7 downto 0)  := to_unsigned(60, 8);
    signal rpm_slow : unsigned(15 downto 0);
    signal rpm_fast : unsigned(15 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

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
    end procedure fire_z;

    -- -------------------------------------------------------------------------
    -- Fire an ab_edge strobe
    -- -------------------------------------------------------------------------
    procedure fire_ab(
        signal   ab  : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        ab <= '1'; wait until rising_edge(c);
        ab <= '0'; wait until rising_edge(c);
    end procedure fire_ab;

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
    dut : entity work.speed
        port map (
            clk           => clk,
            rst           => rst,
            ab_edge       => ab_edge,
            z_edge        => z_edge,
            ab_period     => ab_per,
            ppr_conf      => ppr_s,
            speed_rpm_slow => rpm_slow,
            speed_rpm_fast => rpm_fast
        );

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

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(rpm_slow) = 0
            report "FAIL T1: rpm_slow should be 0 after reset"
            severity failure;
        assert to_integer(rpm_fast) = 0
            report "FAIL T1: rpm_fast should be 0 after reset"
            severity failure;

        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: rpm_slow from two z_edges at Z_PERIOD_10K_RPM apart
        -- Speed divider takes ~16 cycles; allow 30 for margin
        -- --------------------------------------------------------------------
        report "TEST 2: rpm_slow at 10000 RPM";
        test_num <= 2;

        fire_z(z_edge, clk);
        wait for (Z_PERIOD_10K_RPM - 1) * CLK_PERIOD;
        fire_z(z_edge, clk);
        wait for 30 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(rpm_slow) = EXPECTED_RPM
            report "FAIL T2: rpm_slow = " &
                   integer'image(to_integer(rpm_slow)) &
                   " expected " & integer'image(EXPECTED_RPM)
            severity failure;
        report "TEST 2: PASS - rpm_slow = " & integer'image(to_integer(rpm_slow));

        -- --------------------------------------------------------------------
        -- TEST 3: rpm_fast from ab_period and ppr_conf
        -- rpm_fast = (CLK_FREQ_HZ * 60) / (ab_period * ppr_conf)
        --          = (100e6 * 60) / (10000 * 60) = 10000
        -- --------------------------------------------------------------------
        report "TEST 3: rpm_fast at 10000 RPM";
        test_num <= 3;

        ab_per <= to_unsigned(AB_PERIOD_10K_RPM, 32);
        fire_ab(ab_edge, clk);
        wait for 30 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(rpm_fast) = EXPECTED_RPM
            report "FAIL T3: rpm_fast = " &
                   integer'image(to_integer(rpm_fast)) &
                   " expected " & integer'image(EXPECTED_RPM)
            severity failure;
        report "TEST 3: PASS - rpm_fast = " & integer'image(to_integer(rpm_fast));

        -- --------------------------------------------------------------------
        -- TEST 4: RPM change -- both outputs update at new speed
        -- Switch from 10000 to 5000 RPM
        -- --------------------------------------------------------------------
        report "TEST 4: RPM change 10000 -> 5000 RPM";
        test_num <= 4;

        -- rpm_slow: fire two z_edges at 5000 RPM period
        fire_z(z_edge, clk);
        wait for (Z_PERIOD_5K_RPM - 1) * CLK_PERIOD;
        fire_z(z_edge, clk);
        wait for 30 * CLK_PERIOD;

        assert to_integer(rpm_slow) = EXPECTED_5K_RPM
            report "FAIL T4: rpm_slow after RPM change = " &
                   integer'image(to_integer(rpm_slow)) &
                   " expected " & integer'image(EXPECTED_5K_RPM)
            severity failure;

        -- rpm_fast: fire ab_edge with new ab_period
        ab_per <= to_unsigned(AB_PERIOD_5K_RPM, 32);
        fire_ab(ab_edge, clk);
        wait for 30 * CLK_PERIOD;

        assert to_integer(rpm_fast) = EXPECTED_5K_RPM
            report "FAIL T4: rpm_fast after RPM change = " &
                   integer'image(to_integer(rpm_fast)) &
                   " expected " & integer'image(EXPECTED_5K_RPM)
            severity failure;

        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: ppr_conf affects rpm_fast scaling
        -- With ppr=30 and same ab_period, rpm_fast should double
        -- -------------------------------------------------------------------------
        report "TEST 5: ppr_conf affects rpm_fast";
        test_num <= 5;

        ppr_s  <= to_unsigned(30, 8);
        ab_per <= to_unsigned(AB_PERIOD_10K_RPM, 32);
        fire_ab(ab_edge, clk);
        wait for 30 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(rpm_fast) = EXPECTED_RPM * 2
            report "FAIL T5: rpm_fast with ppr=30 = " &
                   integer'image(to_integer(rpm_fast)) &
                   " expected " & integer'image(EXPECTED_RPM * 2)
            severity failure;

        ppr_s <= to_unsigned(60, 8);   -- restore
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All speed tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(rpm_slow, rpm_fast)
    begin
        if rpm_slow'event or rpm_fast'event then
            report "SPEED: rpm_slow=" & integer'image(to_integer(rpm_slow)) &
                   " rpm_fast=" & integer'image(to_integer(rpm_fast)) &
                   " test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
