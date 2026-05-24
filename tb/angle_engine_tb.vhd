library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity angle_engine_tb is
end entity angle_engine_tb;

architecture sim of angle_engine_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD        : time    := 1000 ns;   -- 1MHz sim clock
    constant N_TEETH           : integer := 60;

    constant TOOTH_PERIOD_1000 : time    := 1_000_000 ns;
    constant TOOTH_PERIOD_2000 : time    :=   500_000 ns;

    -- At 1MHz clock:
    -- 1000 RPM tooth period = 1000 cycles
    -- 2000 RPM tooth period = 500 cycles
    constant EXP_TOOTH_1000    : integer := 1_000;
    constant EXP_TOOTH_2000    : integer :=   500;

    -- 720 degree cycle / 60 teeth = 12 degrees per tooth = 120 x 0.1 degree steps
    constant ANGLE_PER_TOOTH   : integer := 120;
    constant ANGLE_TOL         : integer := 15;

    -- Full cycle: 60 teeth + 3 gap = 63 tooth periods
    constant CYCLE_1000 : time := TOOTH_PERIOD_1000 * N_TEETH;
    constant CYCLE_2000 : time := TOOTH_PERIOD_2000 * N_TEETH;

    -- Sync states
    constant ST_UNSYNC         : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP      : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRANK     : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL      : std_logic_vector(2 downto 0) := "011";

    -- PLL gains
    constant KP_DEFAULT        : unsigned(15 downto 0) := x"0100";
    constant KI_DEFAULT        : unsigned(15 downto 0) := x"0010";
    constant MAX_CORR_DEFAULT  : unsigned(15 downto 0) := x"0400";

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal ab             : std_logic := '0';
    signal z              : std_logic := '0';
    signal tooth_period   : unsigned(31 downto 0) := (others => '0');
    signal sync_state     : std_logic_vector(2 downto 0) := ST_UNSYNC;
    signal kp             : unsigned(15 downto 0) := KP_DEFAULT;
    signal ki             : unsigned(15 downto 0) := KI_DEFAULT;
    signal max_correction : unsigned(15 downto 0) := MAX_CORR_DEFAULT;
    signal raw_angle      : unsigned(15 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done       : boolean   := false;
    signal test_num       : integer   := 0;
    signal crank_run      : std_logic := '0';
    signal crank_period   : time      := TOOTH_PERIOD_1000;

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
    dut : entity work.angle_engine
        generic map (
            CLK_FREQ_HZ => 1_000_000,
            N_TEETH     => N_TEETH
        )
        port map (
            clk            => clk,
            rst            => rst,
            ab             => ab,
            z              => z,
            tooth_period   => tooth_period,
            sync_state     => sync_state,
            kp             => kp,
            ki             => ki,
            max_correction => max_correction,
            raw_angle      => raw_angle
        );

    -- -------------------------------------------------------------------------
    -- tooth_period: tracks crank_period in clock cycles
    -- -------------------------------------------------------------------------
    p_tooth_period : process
    begin
        loop
            tooth_period <= to_unsigned(crank_period / CLK_PERIOD, 32);
            wait for CLK_PERIOD;
        end loop;
    end process p_tooth_period;

    -- -------------------------------------------------------------------------
    -- AB/Z pattern generator
    -- Simulates output of crank_input directly
    -- Z pulse fires at start of each cycle, one tooth period wide
    -- AB toggles once per tooth period
    -- Gap: 3 tooth periods with no AB toggle after last tooth
    -- -------------------------------------------------------------------------
    p_ab_gen : process
        variable t_half : time;
    begin
        loop
            if crank_run = '0' then
                ab <= '0';
                z  <= '0';
                wait until crank_run = '1';
            end if;

            t_half := crank_period / 2;

            -- Z pulse at start of cycle, one tooth period wide
            z  <= '1';
            ab <= not ab; wait for t_half;
            ab <= not ab; wait for t_half;
            z  <= '0';

            -- Remaining N_TEETH-1 teeth, no gap, continuous
            for i in 1 to N_TEETH - 1 loop
                if crank_run = '0' then
                    ab <= '0';
                    exit;
                end if;
                ab <= not ab; wait for t_half;
                ab <= not ab; wait for t_half;
            end loop;

            -- No gap here - interpolated pulses already filled it in crank_input
        end loop;
    end process p_ab_gen;

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable angle_start : integer;
        variable angle_end   : integer;
        variable angle_diff  : integer;
        variable angle_error : integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num   <= 1;

        rst        <= '1';
        sync_state <= ST_UNSYNC;
        crank_run  <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert raw_angle = 0
            report "FAIL T1: raw_angle should be 0 after reset, got " &
                   integer'image(to_integer(raw_angle))
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: No angle movement in UNSYNC
        -- --------------------------------------------------------------------
        report "TEST 2: No angle movement in UNSYNC";
        test_num   <= 2;

        sync_state   <= ST_UNSYNC;
        crank_period <= TOOTH_PERIOD_1000;
        crank_run    <= '1';
        wait for CYCLE_1000;

        assert raw_angle = 0
            report "FAIL T2: raw_angle should stay 0 in UNSYNC, got " &
                   integer'image(to_integer(raw_angle))
            severity failure;

        crank_run <= '0';
        report "TEST 2: PASS";
        wait for 10 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: Angle increments in SYNC_CRANK
        -- --------------------------------------------------------------------
        report "TEST 3: Angle increments in SYNC_CRANK";
        test_num   <= 3;

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        sync_state   <= ST_SYNC_CRANK;
        crank_period <= TOOTH_PERIOD_1000;
        crank_run    <= '1';

        -- Allow PLL to lock over 3 cycles
        wait for CYCLE_1000 * 3;

        assert to_integer(raw_angle) > 0
            report "FAIL T3: raw_angle should be non-zero in SYNC_CRANK"
            severity failure;
        assert to_integer(raw_angle) < 7200
            report "FAIL T3: raw_angle should be less than 7200, got " &
                   integer'image(to_integer(raw_angle))
            severity failure;

        report "TEST 3: PASS - raw_angle = " &
               integer'image(to_integer(raw_angle));

        -- --------------------------------------------------------------------
        -- TEST 4: Z pulse resets angle to 0
        -- --------------------------------------------------------------------
        report "TEST 4: Z pulse resets angle to 0";
        test_num <= 4;

        wait until z = '1';
        wait for 3 * CLK_PERIOD;

        assert to_integer(raw_angle) < ANGLE_TOL
            report "FAIL T4: raw_angle should be near 0 after Z, got " &
                   integer'image(to_integer(raw_angle))
            severity failure;

        report "TEST 4: PASS - raw_angle after Z = " &
               integer'image(to_integer(raw_angle));

        -- --------------------------------------------------------------------
        -- TEST 5: Angle increment per tooth
        -- --------------------------------------------------------------------
        report "TEST 5: Angle increment per tooth at 1000 RPM";
        test_num <= 5;

        -- Sync to Z for clean measurement
        wait until z = '1';
        wait for 3 * CLK_PERIOD;
        angle_start := to_integer(raw_angle);

        wait for TOOTH_PERIOD_1000;
        angle_end := to_integer(raw_angle);

        angle_diff  := angle_end - angle_start;
        angle_error := abs(angle_diff - ANGLE_PER_TOOTH);

        assert angle_error <= ANGLE_TOL
            report "FAIL T5: angle per tooth = " &
                   integer'image(angle_diff) &
                   " expected " & integer'image(ANGLE_PER_TOOTH) &
                   " tolerance " & integer'image(ANGLE_TOL)
            severity failure;

        report "TEST 5: PASS - angle per tooth = " &
               integer'image(angle_diff) &
               " (expected " & integer'image(ANGLE_PER_TOOTH) & ")";

        -- --------------------------------------------------------------------
        -- TEST 6: Full cycle angle range
        -- Angle should approach 7200 before Z then reset to 0
        -- --------------------------------------------------------------------
        report "TEST 6: Full cycle angle range";
        test_num <= 6;

        wait until z = '1';
        wait for 3 * CLK_PERIOD;

        -- Wait to just before gap ends (last tooth position)
        wait for TOOTH_PERIOD_1000 * (N_TEETH - 1);
        angle_end := to_integer(raw_angle);

        assert angle_end > 7200 - (ANGLE_TOL * 10)
            report "FAIL T6: angle near end of teeth = " &
                   integer'image(angle_end) &
                   " expected near 7200"
            severity failure;

        -- Wait for Z and check reset
        wait until z = '1';
        wait for 3 * CLK_PERIOD;

        assert to_integer(raw_angle) < ANGLE_TOL
            report "FAIL T6: angle after Z = " &
                   integer'image(to_integer(raw_angle)) &
                   " expected near 0"
            severity failure;

        report "TEST 6: PASS - max angle = " & integer'image(angle_end);

        -- --------------------------------------------------------------------
        -- TEST 7: RPM change - angle rate updates correctly
        -- --------------------------------------------------------------------
        report "TEST 7: RPM change 1000 to 2000 RPM";
        test_num <= 7;

        crank_period <= TOOTH_PERIOD_2000;

        -- Allow 3 cycles to settle
        wait for CYCLE_2000 * 3;

        wait until z = '1';
        wait for 3 * CLK_PERIOD;
        angle_start := to_integer(raw_angle);

        wait for TOOTH_PERIOD_2000;
        angle_end := to_integer(raw_angle);

        angle_diff  := angle_end - angle_start;
        angle_error := abs(angle_diff - ANGLE_PER_TOOTH);

        assert angle_error <= ANGLE_TOL
            report "FAIL T7: angle per tooth at 2000 RPM = " &
                   integer'image(angle_diff) &
                   " expected " & integer'image(ANGLE_PER_TOOTH)
            severity failure;

        report "TEST 7: PASS - angle per tooth at 2000 RPM = " &
               integer'image(angle_diff);

        -- --------------------------------------------------------------------
        -- TEST 8: Free-wheel through gap
        -- Angle should continue advancing during gap
        -- --------------------------------------------------------------------
        report "TEST 8: Angle monotonically increasing through full cycle";
        test_num <= 8;

        crank_period <= TOOTH_PERIOD_1000;
        wait for CYCLE_1000 * 2;

        -- Sync to Z
        wait until z = '1';
        wait for 3 * CLK_PERIOD;

        -- Sample angle at each tooth and verify it increases
        angle_start := to_integer(raw_angle);
        for i in 1 to N_TEETH loop
            wait for TOOTH_PERIOD_1000;
            angle_end := to_integer(raw_angle);

            -- Allow for Z reset at end of cycle
            if angle_end < angle_start and i < N_TEETH then
                assert false
                    report "FAIL T8: angle decreased at tooth " &
                        integer'image(i) &
                        " from " & integer'image(angle_start) &
                        " to " & integer'image(angle_end)
                    severity failure;
            end if;
            angle_start := angle_end;
        end loop;

        report "TEST 8: PASS - angle monotonically increasing";

        -- --------------------------------------------------------------------
        -- TEST 9: Sync gate freezes angle in UNSYNC
        -- --------------------------------------------------------------------
        report "TEST 9: Sync gate - angle freezes in UNSYNC";
        test_num <= 9;

        sync_state <= ST_UNSYNC;
        wait for 5 * CLK_PERIOD;

        angle_start := to_integer(raw_angle);
        wait for CYCLE_1000;
        angle_end := to_integer(raw_angle);

        assert angle_end = angle_start
            report "FAIL T9: angle should not change in UNSYNC, " &
                   "start = " & integer'image(angle_start) &
                   " end = " & integer'image(angle_end)
            severity failure;

        crank_run <= '0';
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All angle_engine tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;