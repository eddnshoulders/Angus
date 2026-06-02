library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity angle_tb is
end entity angle_tb;

architecture sim of angle_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- angle_nco_ab_inc = 0xFFFFFFFF / (ppr * 2) = 0xFFFFFFFF / 120 = 35791394
    -- angle_deg = (nco_accum * 7200) >> 32
    -- At edge N: nco_accum snaps to N * nco_ab_inc
    --   Edge 1: accum = 35791394, angle_deg = (35791394 * 7200) >> 32 = 60
    --   Edge 6: accum = 214748364, angle_deg = 360
    --   Edge 60: accum = 2147483640, angle_deg = 3600
    -- angle_nco_clk_inc = nco_ab_inc / ab_period = 35791394 / 10000 = 3579
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD  : time    := 10 ns;
    constant PPR         : integer := 60;
    constant AB_PERIOD_C : integer := 10000;
    constant NCO_AB_INC  : integer := 35791394;   -- 0xFFFFFFFF / 120
    constant NCO_CLK_INC_C : integer := 3579;       -- 35791394 / 10000

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal ab_edge_s    : std_logic := '0';
    signal z_edge_s     : std_logic := '0';
    signal ab_per       : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_C, 32);
    signal ppr_s        : unsigned(7 downto 0)  := to_unsigned(PPR, 8);
    signal interp_en    : std_logic := '0';
    signal angle_deg    : unsigned(15 downto 0);
    signal nco_ab_inc_s : unsigned(31 downto 0);
    signal nco_clk_inc  : unsigned(31 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire an ab_edge strobe and wait for output to update (registered)
    -- -------------------------------------------------------------------------
    procedure fire_ab(
        signal   s   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        s <= '1'; wait until rising_edge(c);
        wait for 1 ns;
        s <= '0';
        wait until rising_edge(c);   -- extra cycle for registered angle_deg
    end procedure fire_ab;

    -- -------------------------------------------------------------------------
    -- Fire a z_edge strobe and wait for output to update (registered)
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   s   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        s <= '1'; wait until rising_edge(c);
        wait for 1 ns;
        s <= '0';
        wait until rising_edge(c);
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
    dut : entity work.angle
        port map (
            clk              => clk,
            rst              => rst,
            ab_edge          => ab_edge_s,
            z_edge           => z_edge_s,
            ab_period        => ab_per,
            ppr_conf         => ppr_s,
            angle_interp_en  => interp_en,
            angle_deg        => angle_deg,
            angle_nco_ab_inc => nco_ab_inc_s,
            angle_nco_clk_inc => nco_clk_inc
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Startup divider produces correct angle_nco_ab_inc
        -- angle_nco_ab_inc = 0xFFFFFFFF / (ppr * 2) = 35791394 for ppr=60
        -- Divider is 32-bit sequential; allow 70 cycles to complete
        -- --------------------------------------------------------------------
        report "TEST 1: Startup divider - angle_nco_ab_inc correct";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait for 100 * CLK_PERIOD;   -- divider completion + margin
        wait for 1 ns;

        assert nco_ab_inc_s = to_unsigned(NCO_AB_INC, 32)
            report "FAIL T1: nco_ab_inc wrong: " &
                   integer'image(to_integer(nco_ab_inc_s)) &
                   " expected " & integer'image(NCO_AB_INC)
            severity failure;

        assert to_integer(angle_deg) = 0
            report "FAIL T1: angle_deg should be 0 before first z_edge"
            severity failure;

        report "TEST 1: PASS - nco_ab_inc = " &
               integer'image(to_integer(nco_ab_inc_s));

        -- --------------------------------------------------------------------
        -- TEST 2: First ab_edge before 2nd z_edge does not advance angle
        -- angle block requires 2 z_edges before it tracks
        -- --------------------------------------------------------------------
        report "TEST 2: angle stays 0 before 2nd z_edge";
        test_num <= 2;

        fire_ab(ab_edge_s, clk);
        wait for 1 ns;
        assert to_integer(angle_deg) = 0
            report "FAIL T2: angle should be 0 before 2nd z_edge"
            severity failure;

        -- First z_edge: angle still locked at 0
        fire_z(z_edge_s, clk);
        wait for 1 ns;
        assert to_integer(angle_deg) = 0
            report "FAIL T2: angle should be 0 after 1st z_edge"
            severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: After 2nd z_edge, ab_edges advance angle_deg
        -- Edge 1 after 2nd z: angle_deg = 60 (= 1 * 35791394 * 7200 >> 32)
        -- Edge 6 after 2nd z: angle_deg = 360
        -- --------------------------------------------------------------------
        report "TEST 3: ab_edges advance angle_deg after 2nd z_edge";
        test_num <= 3;

        -- 2nd z_edge: tracking starts
        fire_z(z_edge_s, clk);
        wait for 1 ns;

        -- Edge 0 after 2nd z: snap to 0
        fire_ab(ab_edge_s, clk);
        wait for 1 ns;
        assert to_integer(angle_deg) = 0
            report "FAIL T3: edge 0 should give angle 0, got " &
                   integer'image(to_integer(angle_deg))
            severity failure;

        -- Edge 1: angle = 60
        fire_ab(ab_edge_s, clk);
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(angle_deg) >= 59 and to_integer(angle_deg) <= 61
            report "FAIL T3: edge 1 should give ~60 deg, got " &
                   integer'image(to_integer(angle_deg))
            severity failure;

        -- Edges 2-5: angle = 360 by edge 6
        fire_ab(ab_edge_s, clk); fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk); fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk);   -- edge 6
        wait until rising_edge(clk); wait for 1 ns;

        assert to_integer(angle_deg) >= 358 and to_integer(angle_deg) <= 362
            report "FAIL T3: edge 6 should give ~360 deg, got " &
                   integer'image(to_integer(angle_deg))
            severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: 2nd z_edge resets edge_count and accumulator to 0
        -- The NEXT 2nd z_edge (3rd total) should reset; first z_edge should not
        -- --------------------------------------------------------------------
        report "TEST 4: 2nd z_edge (in pair) resets accumulator";
        test_num <= 4;

        -- We've had 2 z_edges and are tracking.
        -- Fire a 3rd z_edge: first of new pair -- should NOT reset
        fire_z(z_edge_s, clk);
        wait for 1 ns;
        assert to_integer(angle_deg) >= 358
            report "FAIL T4: 1st z_edge of pair reset accumulator (should not)"
            severity failure;

        -- Fire 4th z_edge: 2nd of new pair -- should reset to 0
        fire_z(z_edge_s, clk);
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(angle_deg) = 0
            report "FAIL T4: 2nd z_edge of pair did not reset accumulator, got " &
                   integer'image(to_integer(angle_deg))
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Interpolation advances angle between ab_edges
        -- Enable interp_en; after one ab_edge triggers the tooth divider,
        -- angle_deg should advance each clock between edges
        -- --------------------------------------------------------------------
        report "TEST 5: Interpolation advances angle between ab_edges";
        test_num <= 5;

        interp_en <= '1';

        -- Trigger tooth divider with an ab_edge
        fire_ab(ab_edge_s, clk);
        -- Wait for tooth divider (32 cycles) + a few clocks of accumulation
        wait for 1000 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(angle_deg) > 0
            report "FAIL T5: interpolation not advancing angle"
            severity failure;


        report "TEST 5: PASS";
        interp_en <= '0';
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: angle_nco_clk_inc = nco_ab_inc / ab_period
        -- = 35791394 / 10000 = 3579 (within 1 LSB)
        -- --------------------------------------------------------------------
        report "TEST 6: angle_nco_clk_inc = nco_ab_inc / ab_period";
        test_num <= 6;

        -- Trigger tooth divider
        interp_en <= '1';
        fire_ab(ab_edge_s, clk);
        wait for 60 * CLK_PERIOD;   -- divider completion
        wait for 1 ns;

        assert to_integer(nco_clk_inc) >= NCO_CLK_INC_C - 2 and
               to_integer(nco_clk_inc) <= NCO_CLK_INC_C + 2
            report "FAIL T6: nco_clk_inc wrong: " &
                   integer'image(to_integer(nco_clk_inc)) &
                   " expected ~" & integer'image(NCO_CLK_INC_C)
            severity failure;

        interp_en <= '0';
        report "TEST 6: PASS - nco_clk_inc = " &
               integer'image(to_integer(nco_clk_inc));

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All angle tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(angle_deg)
    begin
        if angle_deg'event then
            report "ANGLE: " & integer'image(to_integer(angle_deg)) &
                   " deg  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
