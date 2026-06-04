library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- tdc_tb.vhd  (v3)
--
-- Unit testbench for tdc.vhd.
-- Full scale 0xFFFFFFFF = 360 crank degrees.
-- Engine cycle: 2 × 360 = 720 degrees (two crank revolutions).
--
-- TDC at 0 deg:   tdc_offset = 0.       phase_eng=0, ang_angfac=0   -> tdc_deg=0
-- TDC at 90 deg:  tdc_offset = 2^32/4.  phase_eng=0, ang_angfac=2^32/4 -> tdc_deg=0
-- TDC at 360 deg: tdc_offset = 0, phase=1. phase_eng=1, ang_angfac=0 -> tdc_deg=0
-- =============================================================================

entity tdc_tb is
end entity tdc_tb;

architecture sim of tdc_tb is

    constant CLK_PERIOD : time := 10 ns;

    -- Angfac constants
    -- 0xFFFFFFFF / 4 = 1073741823  (~quarter revolution = 90 crank deg)
    constant QUARTER_C  : unsigned(31 downto 0) := x"3FFFFFFF";
    constant HALF_C     : unsigned(31 downto 0) := x"7FFFFFFF";
    constant FULL_C     : unsigned(31 downto 0) := x"FFFFFFFF";

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal ang_angfac : unsigned(31 downto 0) := (others => '0');
    signal phase_eng  : std_logic := '0';
    signal tdc_offset : unsigned(31 downto 0) := (others => '0');
    signal tdc_deg    : unsigned(15 downto 0);

    signal sim_done : boolean := false;
    signal test_num : integer := 0;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.tdc
        port map (
            clk        => clk,
            rst        => rst,
            ang_angfac => ang_angfac,
            phase_eng  => phase_eng,
            tdc_offset => tdc_offset,
            tdc_deg    => tdc_deg
        );

    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset -- output held at 0
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert tdc_deg = to_unsigned(0, 16)
            report "FAIL T1: tdc_deg should be 0 after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: No offset, engine at start of cycle (0 deg)
        -- tdc_offset=0, phase=0, ang_angfac=0 -> tdc_deg=0
        -- --------------------------------------------------------------------
        report "TEST 2: Zero offset, zero position -> tdc_deg = 0";
        test_num <= 2;

        tdc_offset <= (others => '0');
        phase_eng  <= '0';
        ang_angfac <= (others => '0');
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert tdc_deg = to_unsigned(0, 16)
            report "FAIL T2: tdc_deg should be 0, got " &
                   integer'image(to_integer(tdc_deg))
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: TDC at exactly 90 crank degrees
        -- tdc_offset = QUARTER_C.
        -- At the moment of TDC: phase=0, ang_angfac=QUARTER_C.
        -- tdc_pos = QUARTER_C - QUARTER_C = 0. tdc_deg = 0.
        -- --------------------------------------------------------------------
        report "TEST 3: TDC at 90 crank degrees (offset = quarter full scale)";
        test_num <= 3;

        tdc_offset <= QUARTER_C;
        phase_eng  <= '0';
        ang_angfac <= QUARTER_C;
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert tdc_deg = to_unsigned(0, 16)
            report "FAIL T3: tdc_deg should be 0 at TDC position, got " &
                   integer'image(to_integer(tdc_deg))
            severity failure;
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: 180 deg after TDC = tdc_deg = 1800
        -- tdc_offset = QUARTER_C (TDC at 90 crank deg).
        -- At 90+180=270 crank deg: phase=0, ang_angfac=QUARTER_C*3.
        -- tdc_pos = 3*QUARTER - QUARTER = 2*QUARTER.
        -- tdc_deg = 2*QUARTER * 7200 / 2^33 = 7200/2 = 3600. Wait...
        -- 2*QUARTER = HALF = 0x7FFFFFFF.
        -- tdc_deg = 0x7FFFFFFF * 7200 / 2^33 = 7200/2 ~= 3600. ok (180 deg = 1800 in 0.1deg)
        -- --------------------------------------------------------------------
        report "TEST 4: 180 deg after TDC -> tdc_deg = 1800";
        test_num <= 4;

        tdc_offset <= QUARTER_C;   -- TDC at 90 crank deg
        phase_eng  <= '0';
        ang_angfac <= HALF_C + QUARTER_C;  -- 270 crank deg
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        -- tdc_pos = (0 & (3*QUARTER_C)) - (0 & QUARTER_C) = 2*QUARTER = HALF
        -- tdc_deg = HALF * 7200 / 2^33 ~= 1800 (with ±1 rounding)
        assert to_integer(tdc_deg) >= 1798 and to_integer(tdc_deg) <= 1802
            report "FAIL T4: tdc_deg should be ~1800, got " &
                   integer'image(to_integer(tdc_deg))
            severity failure;
        report "TEST 4: PASS - tdc_deg = " & integer'image(to_integer(tdc_deg));

        -- --------------------------------------------------------------------
        -- TEST 5: Wrap across revolution boundary
        -- TDC at 350 crank deg (10 deg before Z).
        -- tdc_offset = 350/360 * 2^32 ~= 0xF0F0F0F0 (approximately).
        -- With phase=0, ang_angfac=0 (at Z): eng_pos=0.
        -- tdc_pos = (0 - 0xF0F0F0F0) mod 2^33 = 2^33 - 0xF0F0F0F0
        --         = 0x200000000 - 0xF0F0F0F0 = 0x10F0F0F10 -> truncated to 33 bits
        --         = 0x0F0F0F10 ~= 10/360 * 2^32 ~= 10 deg worth of angfac
        -- tdc_deg = 0x0F0F0F10 * 7200 / 2^33 ~= 100 (10 deg = 100 in 0.1 deg units)
        -- Use HALF_C as TDC offset for cleaner arithmetic.
        -- TDC at 180 crank deg (offset=HALF). At phase=1, ang_angfac=0:
        -- eng_pos = {1, 0x00000000} = 0x100000000 = 2^32.
        -- tdc_pos = 2^32 - HALF = 0x100000000 - 0x7FFFFFFF = 0x80000001.
        -- tdc_deg = 0x80000001 * 7200 / 2^33 ~= 3600 (180 deg). ok
        -- --------------------------------------------------------------------
        report "TEST 5: Wrap across Z edge -- phase=1, ang_angfac=0, offset=HALF";
        test_num <= 5;

        tdc_offset <= HALF_C;   -- TDC at 180 crank deg (phase 0)
        phase_eng  <= '1';      -- now in phase 1 (second revolution)
        ang_angfac <= (others => '0');  -- at Z edge of second revolution
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        -- tdc_pos = {1,0} - HALF = 2^32 - 0x7FFFFFFF = 0x80000001
        -- tdc_deg = 0x80000001 * 7200 / 2^33 ~= 3600 (180.0 deg)
        assert to_integer(tdc_deg) >= 1798 and to_integer(tdc_deg) <= 1802
            report "FAIL T5: tdc_deg should be ~1800, got " &
                   integer'image(to_integer(tdc_deg))
            severity failure;
        report "TEST 5: PASS (1800 = 180 deg after TDC) - tdc_deg = " & integer'image(to_integer(tdc_deg));

        -- --------------------------------------------------------------------
        -- TEST 6: Full engine cycle range -- end of cycle is 7199
        -- At the end of phase 1 (ang_angfac=FULL, tdc_offset=0):
        -- eng_pos = {1, 0xFFFFFFFF} = 0x1FFFFFFFF.
        -- tdc_deg = 0x1FFFFFFFF * 7200 / 2^33 ~= 7199. ok
        -- --------------------------------------------------------------------
        report "TEST 6: End of engine cycle -> tdc_deg ~= 7199";
        test_num <= 6;

        tdc_offset <= (others => '0');
        phase_eng  <= '1';
        ang_angfac <= FULL_C;
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert to_integer(tdc_deg) >= 7197 and to_integer(tdc_deg) <= 7199
            report "FAIL T6: tdc_deg should be ~7199, got " &
                   integer'image(to_integer(tdc_deg))
            severity failure;
        report "TEST 6: PASS - tdc_deg = " & integer'image(to_integer(tdc_deg));

        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All tdc tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
