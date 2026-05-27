library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library std;
use std.env.all;

-- =============================================================================
-- angle_calc_tb
--
-- Tests tooth-based angle calculation and interpolation.
-- Uses a stub divider (combinational) to avoid dependency on divider.vhd.
-- =============================================================================

entity angle_calc_tb is
end entity angle_calc_tb;

architecture sim of angle_calc_tb is

    constant CLK_PERIOD   : time    := 10 ns;   -- 100MHz
    constant N_TEETH      : integer := 60;
    constant N_MISSING    : integer := 2;
    constant TOOTH_PERIOD : integer := 1000;     -- 1000 cycles per tooth (fast sim)
    constant DEG_PER_TOOTH: integer := 7200 / N_TEETH;  -- 120 for 60 teeth

    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal sim_done       : boolean   := false;
    signal test_num       : integer   := 0;

    -- DUT inputs
    signal ab             : std_logic := '0';
    signal z              : std_logic := '0';
    signal tooth_period_s : unsigned(31 downto 0) := to_unsigned(TOOTH_PERIOD, 32);
    signal tooth_count    : unsigned(7 downto 0)  := (others => '0');
    signal signal_present : std_logic := '0';
    signal n_teeth_s      : unsigned(7 downto 0)  := to_unsigned(N_TEETH, 8);
    signal config_apply   : std_logic := '0';

    -- Divider stub signals
    signal div_start      : std_logic;
    signal div_dividend   : unsigned(31 downto 0);
    signal div_divisor    : unsigned(31 downto 0);
    signal div_quotient   : unsigned(31 downto 0) := (others => '0');
    signal div_valid      : std_logic := '0';

    -- DUT outputs
    signal angle_raw      : unsigned(15 downto 0);
    signal phase          : std_logic;

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
    -- Stub divider - combinational with 2-cycle latency
    -- -------------------------------------------------------------------------
    p_div_stub : process(clk)
        variable pending : std_logic := '0';
        variable result  : unsigned(31 downto 0);
        variable count   : integer := 0;
    begin
        if rising_edge(clk) then
            div_valid <= '0';
            if div_start = '1' then
                if div_divisor /= 0 then
                    result := div_dividend / div_divisor;
                else
                    result := (others => '0');
                end if;
                pending := '1';
                count   := 2;
            end if;
            if pending = '1' then
                if count = 0 then
                    div_quotient <= result;
                    div_valid    <= '1';
                    pending      := '0';
                else
                    count := count - 1;
                end if;
            end if;
        end if;
    end process p_div_stub;

    -- -------------------------------------------------------------------------
    -- DUT
    -- -------------------------------------------------------------------------
    dut : entity work.angle_calc
        port map (
            clk            => clk,
            rst            => rst,
            ab             => ab,
            z              => z,
            tooth_period   => tooth_period_s,
            tooth_count    => tooth_count,
            signal_present => signal_present,
            n_teeth        => n_teeth_s,
            div_start      => div_start,
            div_dividend   => div_dividend,
            div_divisor    => div_divisor,
            div_quotient   => div_quotient,
            div_valid      => div_valid,
            config_apply   => config_apply,
            angle_raw      => angle_raw,
            phase          => phase
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process

        procedure pulse_config_apply is
        begin
            config_apply <= '1';
            wait for CLK_PERIOD;
            config_apply <= '0';
            -- Wait for divider to complete (stub takes ~4 cycles)
            wait for 10 * CLK_PERIOD;
        end procedure;

        procedure fire_ab_edge(count : unsigned(7 downto 0)) is
        begin
            tooth_count <= count;
            ab          <= not ab;
            wait for CLK_PERIOD;
        end procedure;

        procedure fire_z_edge is
        begin
            z <= '1';
            wait for CLK_PERIOD;
            z <= '0';
            wait for CLK_PERIOD;
        end procedure;

        variable angle_start  : integer;
        variable angle_end    : integer;
        variable angle_diff   : integer;

    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset - outputs at zero
        -- --------------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: Reset behaviour";
        rst   <= '1';
        wait for 20 * CLK_PERIOD;
        rst   <= '0';
        wait for 5 * CLK_PERIOD;

        assert to_integer(angle_raw) = 0
            report "FAIL T1: angle_raw should be 0 after reset, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;
        assert phase = '0'
            report "FAIL T1: phase should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Config apply sets degrees_per_tooth correctly
        -- 7200 / 60 = 120
        -- --------------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: Config apply - degrees_per_tooth = 7200/60 = 120";

        n_teeth_s <= to_unsigned(60, 8);
        pulse_config_apply;

        -- Fire tooth 0 with signal_present
        signal_present <= '1';
        fire_ab_edge(to_unsigned(0, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 0
            report "FAIL T2: angle at tooth 0 should be 0, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        -- Fire tooth 1 - should be 120 (1 * 120)
        fire_ab_edge(to_unsigned(1, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 120
            report "FAIL T2: angle at tooth 1 should be 120, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        -- Fire tooth 10 - should be 1200 (10 * 120)
        fire_ab_edge(to_unsigned(10, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 1200
            report "FAIL T2: angle at tooth 10 should be 1200, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Interpolation advances correctly between tooth edges
        -- At tooth 0, angle=0. Over TOOTH_PERIOD clocks should advance to ~120
        -- --------------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: Interpolation between tooth edges";

        fire_ab_edge(to_unsigned(0, 8));
        wait for CLK_PERIOD;
        angle_start := to_integer(angle_raw);  -- should be 0

        -- Wait half a tooth period
        wait for (TOOTH_PERIOD / 2) * CLK_PERIOD;
        angle_end := to_integer(angle_raw);

        -- Should be approximately halfway through one tooth (60 steps)
        assert angle_end >= 55 and angle_end <= 65
            report "FAIL T3: angle at half-tooth should be ~60, got " &
                   integer'image(angle_end)
            severity failure;

        -- Wait full tooth period
        wait for (TOOTH_PERIOD / 2) * CLK_PERIOD;
        angle_end := to_integer(angle_raw);

        -- Should be approximately one full tooth (119 max - interp stops at dpt-1)
        assert angle_end >= 115 and angle_end <= 119
            report "FAIL T3: angle at end of tooth should be ~119, got " &
                   integer'image(angle_end)
            severity failure;

        report "TEST 3: PASS - interpolated to " &
               integer'image(angle_end) & " by end of tooth";

        -- --------------------------------------------------------------------
        -- TEST 4: Phase starts at 0, toggles on each Z pulse
        -- --------------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: Phase toggles on Z pulse";

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        wait for 2 * CLK_PERIOD;
        pulse_config_apply;
        signal_present <= '1';

        assert phase = '0'
            report "FAIL T4: phase should be 0 after reset"
            severity failure;

        -- First Z - defines phase 0, no toggle
        fire_z_edge;
        wait for 2 * CLK_PERIOD;

        assert phase = '0'
            report "FAIL T4: phase should still be 0 after first Z"
            severity failure;

        -- Second Z - should toggle to 1
        fire_z_edge;
        wait for 2 * CLK_PERIOD;

        assert phase = '1'
            report "FAIL T4: phase should be 1 after second Z"
            severity failure;

        -- Third Z - should toggle back to 0
        fire_z_edge;
        wait for 2 * CLK_PERIOD;

        assert phase = '0'
            report "FAIL T4: phase should be 0 after third Z"
            severity failure;

        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: signal_present=0 resets angle to 0
        -- --------------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: signal_present=0 resets angle";

        -- Get a non-zero angle
        fire_ab_edge(to_unsigned(10, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 1200
            report "FAIL T5 setup: angle should be 1200 before test"
            severity failure;

        -- Remove signal
        signal_present <= '0';
        wait for 2 * CLK_PERIOD;

        assert to_integer(angle_raw) = 0
            report "FAIL T5: angle should be 0 when signal_present=0, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: Different n_teeth - 36 teeth, 200 deg/tooth
        -- --------------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: 36-tooth wheel - 7200/36 = 200 deg/tooth";

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        wait for 2 * CLK_PERIOD;

        n_teeth_s <= to_unsigned(36, 8);
        pulse_config_apply;
        signal_present <= '1';

        fire_ab_edge(to_unsigned(0, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 0
            report "FAIL T6: angle at tooth 0 should be 0"
            severity failure;

        fire_ab_edge(to_unsigned(1, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 200
            report "FAIL T6: angle at tooth 1 should be 200 (7200/36), got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        fire_ab_edge(to_unsigned(5, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 1000
            report "FAIL T6: angle at tooth 5 should be 1000, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: tooth_period updates correctly between tooth edges
        -- Simulate acceleration - tooth_period shrinks each tooth
        -- Verify interpolation uses the updated tooth_period
        -- --------------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: tooth_period updates between tooth edges";

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        wait for 2 * CLK_PERIOD;
        n_teeth_s <= to_unsigned(60, 8);
        pulse_config_apply;
        signal_present <= '1';

        -- Tooth 0 at period 1000
        tooth_period_s <= to_unsigned(1000, 32);
        fire_ab_edge(to_unsigned(0, 8));
        wait for CLK_PERIOD;

        -- Wait half of 1000 cycles - should be at ~60
        wait for 500 * CLK_PERIOD;
        assert to_integer(angle_raw) >= 55 and to_integer(angle_raw) <= 65
            report "FAIL T7: at half of 1000-cycle tooth, angle should be ~60, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        -- Tooth 1 at period 800 (faster)
        tooth_period_s <= to_unsigned(800, 32);
        fire_ab_edge(to_unsigned(1, 8));
        wait for CLK_PERIOD;

        -- Immediately after ab_edge, base_angle should be 120
        assert to_integer(angle_raw) = 120
            report "FAIL T7: at tooth 1 edge, angle should be 120, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        -- Wait half of 800 cycles - should be at ~60 into this tooth (120+60=180)
        wait for 400 * CLK_PERIOD;
        assert to_integer(angle_raw) >= 175 and to_integer(angle_raw) <= 185
            report "FAIL T7: at half of 800-cycle tooth, angle should be ~180, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        -- Tooth 2 at period 800 - verify full tooth advance
        tooth_period_s <= to_unsigned(800, 32);
        fire_ab_edge(to_unsigned(2, 8));
        wait for CLK_PERIOD;

        assert to_integer(angle_raw) = 240
            report "FAIL T7: at tooth 2 edge, angle should be 240, got " &
                   integer'image(to_integer(angle_raw))
            severity failure;

        report "TEST 7: PASS - tooth_period update verified";
        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All angle_calc tests complete";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
