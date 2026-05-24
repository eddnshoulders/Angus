library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity angle_offset_tb is
end entity angle_offset_tb;

architecture sim of angle_offset_tb is

    constant CLK_PERIOD  : time := 1000 ns;

    signal clk           : std_logic := '0';
    signal raw_angle     : unsigned(15 downto 0) := (others => '0');
    signal sync_offset   : std_logic := '0';
    signal tdc_offset    : unsigned(15 downto 0) := (others => '0');
    signal crank_angle   : unsigned(15 downto 0);
    signal engine_angle  : unsigned(15 downto 0);

    signal sim_done      : boolean := false;
    signal test_num      : integer := 0;

    procedure check(
        signal   crank   : in  unsigned(15 downto 0);
        signal   engine  : in  unsigned(15 downto 0);
        constant exp_c   : in  integer;
        constant exp_e   : in  integer;
        constant test    : in  string
    ) is
    begin
        assert to_integer(crank) = exp_c
            report "FAIL " & test & ": crank_angle = " &
                   integer'image(to_integer(crank)) &
                   " expected " & integer'image(exp_c)
            severity failure;
        assert to_integer(engine) = exp_e
            report "FAIL " & test & ": engine_angle = " &
                   integer'image(to_integer(engine)) &
                   " expected " & integer'image(exp_e)
            severity failure;
    end procedure check;

begin

    -- -------------------------------------------------------------------------
    -- Clock (just for sequencing, block is combinational)
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
    dut : entity work.angle_offset
        port map (
            raw_angle    => raw_angle,
            sync_offset  => sync_offset,
            tdc_offset   => tdc_offset,
            crank_angle  => crank_angle,
            engine_angle => engine_angle
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: No offsets, passthrough
        -- --------------------------------------------------------------------
        test_num    <= 1;
        report "TEST 1: No offsets - passthrough";
        raw_angle   <= to_unsigned(1000, 16);
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(0, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 1000, 1000, "T1");
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: sync_offset = 1, no TDC offset
        -- raw = 100 (10.0 deg), crank = 100 + 3600 = 3700
        -- --------------------------------------------------------------------
        test_num    <= 2;
        report "TEST 2: sync_offset = 1, no TDC offset";
        raw_angle   <= to_unsigned(100, 16);
        sync_offset <= '1';
        tdc_offset  <= to_unsigned(0, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 3700, 3700, "T2");
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: sync_offset = 1 with wraparound
        -- raw = 4000 (400.0 deg), crank = 4000 + 3600 = 7600 mod 7200 = 400
        -- --------------------------------------------------------------------
        test_num    <= 3;
        report "TEST 3: sync_offset = 1 with wraparound";
        raw_angle   <= to_unsigned(4000, 16);
        sync_offset <= '1';
        tdc_offset  <= to_unsigned(0, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 400, 400, "T3");
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: TDC offset applied, no sync_offset
        -- raw = 1000, tdc = 200, engine = 1200
        -- --------------------------------------------------------------------
        test_num    <= 4;
        report "TEST 4: TDC offset, no sync_offset";
        raw_angle   <= to_unsigned(1000, 16);
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(200, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 1000, 1200, "T4");
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: TDC offset with wraparound
        -- raw = 7000, tdc = 500, engine = 7500 mod 7200 = 300
        -- --------------------------------------------------------------------
        test_num    <= 5;
        report "TEST 5: TDC offset with wraparound";
        raw_angle   <= to_unsigned(7000, 16);
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(500, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 7000, 300, "T5");
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: Both offsets applied
        -- raw = 500, sync adds 3600 → crank = 4100
        -- tdc = 300 → engine = 4400
        -- --------------------------------------------------------------------
        test_num    <= 6;
        report "TEST 6: Both offsets applied";
        raw_angle   <= to_unsigned(500, 16);
        sync_offset <= '1';
        tdc_offset  <= to_unsigned(300, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 4100, 4400, "T6");
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: Both offsets with double wraparound
        -- raw = 3700, sync adds 3600 → 7300 mod 7200 = 100 (crank)
        -- tdc = 7100 → 100 + 7100 = 7200 mod 7200 = 0 (engine)
        -- --------------------------------------------------------------------
        test_num    <= 7;
        report "TEST 7: Both offsets with double wraparound";
        raw_angle   <= to_unsigned(3700, 16);
        sync_offset <= '1';
        tdc_offset  <= to_unsigned(7100, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 100, 0, "T7");
        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- TEST 8: Boundary - raw = 0, sync_offset = 0, tdc = 0
        -- --------------------------------------------------------------------
        test_num    <= 8;
        report "TEST 8: Boundary - all zero";
        raw_angle   <= to_unsigned(0, 16);
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(0, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 0, 0, "T8");
        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- TEST 9: Boundary - raw = 7199 (maximum)
        -- --------------------------------------------------------------------
        test_num    <= 9;
        report "TEST 9: Boundary - raw = 7199";
        raw_angle   <= to_unsigned(7199, 16);
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(0, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 7199, 7199, "T9");
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- TEST 10: Boundary - raw = 7199, tdc = 1 → engine = 0
        -- --------------------------------------------------------------------
        test_num    <= 10;
        report "TEST 10: Boundary - raw = 7199, tdc = 1";
        raw_angle   <= to_unsigned(7199, 16);
        sync_offset <= '0';
        tdc_offset  <= to_unsigned(1, 16);
        wait for CLK_PERIOD;

        check(crank_angle, engine_angle, 7199, 0, "T10");
        report "TEST 10: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for CLK_PERIOD;
        report "========================================";
        report "All angle_offset tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;