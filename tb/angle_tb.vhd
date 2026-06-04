library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- angle_tb.vhd  (v3)
--
-- Unit testbench for angle.vhd.
-- Internal unit is _angfac: unsigned 32-bit fraction of one crank revolution.
-- Full scale (0xFFFFFFFF) = 360 crank degrees = ppr_conf teeth.
--
-- angle_nco_ab_inc = 0xFFFFFFFF / ppr_conf
-- For PPR=60: nco_ab_inc = 0xFFFFFFFF / 60 = 71582788
--
-- angle_nco_clk_inc = nco_ab_inc / ab_period
-- For AB_PERIOD=10000: nco_clk_inc = 71582788 / 10000 = 7158
--
-- After N ab_edges: angle_angfac ≈ N * nco_ab_inc
-- After M clocks of interpolation: angle_angfac += M * nco_clk_inc
-- =============================================================================

entity angle_tb is
end entity angle_tb;

architecture sim of angle_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 10 ns;   -- 100 MHz
    constant PPR          : integer := 60;
    constant AB_PERIOD_C  : integer := 10000;
    constant NCO_AB_INC   : integer := 71582788;   -- 0xFFFFFFFF / 60
    constant NCO_CLK_INC_C : integer := 7158;        -- 71582788 / 10000

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
    signal angle_angfac : unsigned(31 downto 0);
    signal nco_ab_inc_s : unsigned(31 downto 0);
    signal nco_clk_inc  : unsigned(31 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock ab_edge strobe
    -- -------------------------------------------------------------------------
    procedure fire_ab(
        signal   s   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        s <= '1'; wait until rising_edge(c);
        wait for 1 ns;
        s <= '0';
        wait until rising_edge(c);   -- extra cycle: accumulator registered
    end procedure fire_ab;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock z_edge strobe
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
            clk               => clk,
            rst               => rst,
            ab_edge           => ab_edge_s,
            z_edge            => z_edge_s,
            ab_period         => ab_per,
            ppr_conf          => ppr_s,
            angle_interp_en   => interp_en,
            angle_angfac      => angle_angfac,
            angle_nco_ab_inc  => nco_ab_inc_s,
            angle_nco_clk_inc => nco_clk_inc
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Startup divider produces correct angle_nco_ab_inc
        -- angle_nco_ab_inc = 0xFFFFFFFF / ppr_conf = 71582788 for ppr=60.
        -- Startup divider is sequential (32-bit): allow 100 cycles.
        -- --------------------------------------------------------------------
        report "TEST 1: Startup divider -- angle_nco_ab_inc correct";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait for 100 * CLK_PERIOD;
        wait for 1 ns;

        assert nco_ab_inc_s = to_unsigned(NCO_AB_INC, 32)
            report "FAIL T1: nco_ab_inc = " &
                   integer'image(to_integer(nco_ab_inc_s)) &
                   " expected " & integer'image(NCO_AB_INC)
            severity failure;

        assert to_integer(angle_angfac) = 0
            report "FAIL T1: angle_angfac should be 0 before any z_edge"
            severity failure;

        report "TEST 1: PASS - nco_ab_inc = " &
               integer'image(to_integer(nco_ab_inc_s));

        -- --------------------------------------------------------------------
        -- TEST 2: angle_angfac stays 0 before first z_edge
        -- Even after ab_edges, angle should stay at 0 until z_edge resets it.
        -- Actually in v3: before z_edge, ab_edges DO advance the accumulator.
        -- The block is gated downstream by sync_full.
        -- Test just checks z_edge resets to 0.
        -- --------------------------------------------------------------------
        report "TEST 2: z_edge resets accumulator to 0";
        test_num <= 2;

        fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk);

        assert to_integer(angle_angfac) > 0
            report "FAIL T2: accumulator not advancing before z_edge"
            severity failure;

        fire_z(z_edge_s, clk);
        wait for 1 ns;

        assert to_integer(angle_angfac) = 0
            report "FAIL T2: angle_angfac should be 0 after z_edge, got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: ab_edges snap angle_angfac to N * nco_ab_inc after z_edge
        -- Edge 0 (first tooth after z): snaps to 0 * nco_ab_inc = 0
        -- Edge 1 (second tooth):        snaps to 1 * nco_ab_inc = 71582788
        -- Edge 5 (sixth tooth):         snaps to 5 * nco_ab_inc = 357913940
        -- --------------------------------------------------------------------
        report "TEST 3: ab_edges snap to N * nco_ab_inc";
        test_num <= 3;

        -- edge_count=0 after z_edge reset; first ab_edge snaps to 0
        fire_ab(ab_edge_s, clk);
        wait for 1 ns;

        assert to_integer(angle_angfac) = 0
            report "FAIL T3: edge 0 should snap to 0, got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        -- Second ab_edge snaps to 1 * nco_ab_inc
        fire_ab(ab_edge_s, clk);
        wait until rising_edge(clk); wait for 1 ns;

        assert to_integer(angle_angfac) >= NCO_AB_INC - 2 and
               to_integer(angle_angfac) <= NCO_AB_INC + 2
            report "FAIL T3: edge 1 should snap to ~" &
                   integer'image(NCO_AB_INC) & ", got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        -- Fire 4 more teeth (total 6 teeth fired, at edge_count 0-5)
        fire_ab(ab_edge_s, clk); fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk); fire_ab(ab_edge_s, clk);
        wait until rising_edge(clk); wait for 1 ns;

        assert to_integer(angle_angfac) >= 5 * NCO_AB_INC - 5 and
               to_integer(angle_angfac) <= 5 * NCO_AB_INC + 5
            report "FAIL T3: edge 5 should snap to ~" &
                   integer'image(5 * NCO_AB_INC) & ", got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: z_edge resets edge_count to 0 each revolution
        -- After z_edge, the next ab_edge snaps to 0 regardless of current count
        -- --------------------------------------------------------------------
        report "TEST 4: z_edge resets for new revolution";
        test_num <= 4;

        fire_z(z_edge_s, clk);
        wait for 1 ns;
        assert to_integer(angle_angfac) = 0
            report "FAIL T4: after z_edge angle_angfac should be 0"
            severity failure;

        -- First tooth of new revolution: snaps to 0
        fire_ab(ab_edge_s, clk);
        wait for 1 ns;
        assert to_integer(angle_angfac) = 0
            report "FAIL T4: first tooth of new revolution should be 0, got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        -- Second tooth: should be nco_ab_inc (edge_count=1)
        fire_ab(ab_edge_s, clk);
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(angle_angfac) >= NCO_AB_INC - 2 and
               to_integer(angle_angfac) <= NCO_AB_INC + 2
            report "FAIL T4: second tooth of new revolution should be ~nco_ab_inc"
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Simultaneous z_edge + ab_edge (first tooth after gap)
        -- nco_accum stays 0 (tooth 0 is at position 0).
        -- edge_count advances to 1 so the NEXT ab_edge snaps to 1*nco_ab_inc.
        -- --------------------------------------------------------------------
        report "TEST 5: Simultaneous z+ab -- accum=0, next tooth snaps to nco_ab_inc";
        test_num <= 5;

        -- Advance to non-zero state
        fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk);
        fire_ab(ab_edge_s, clk);
        assert to_integer(angle_angfac) > 0
            report "FAIL T5 setup: angle_angfac should be non-zero"
            severity failure;

        -- Fire z_edge and ab_edge simultaneously
        ab_edge_s <= '1';
        z_edge_s  <= '1';
        wait until rising_edge(clk);
        ab_edge_s <= '0';
        z_edge_s  <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;

        -- nco_accum = 0: tooth 0 is at position 0
        assert to_integer(angle_angfac) = 0
            report "FAIL T5: nco_accum should be 0 at tooth 0, got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        -- Next ab_edge: edge_count was 1 (not 0), so snaps to 1*nco_ab_inc
        fire_ab(ab_edge_s, clk);
        wait until rising_edge(clk); wait for 1 ns;
        assert to_integer(angle_angfac) >= NCO_AB_INC - 2 and
               to_integer(angle_angfac) <= NCO_AB_INC + 2
            report "FAIL T5: next tooth should snap to nco_ab_inc (~" &
                   integer'image(NCO_AB_INC) & "), got " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: angle_nco_clk_inc = nco_ab_inc / ab_period (with interp_en)
        -- After one ab_edge with interp_en='1', the tooth divider runs and
        -- angle_nco_clk_inc should settle to ~7158 within 60 cycles.
        -- --------------------------------------------------------------------
        report "TEST 6: angle_nco_clk_inc = nco_ab_inc / ab_period";
        test_num <= 6;

        interp_en <= '1';
        fire_z(z_edge_s, clk);
        fire_ab(ab_edge_s, clk);
        wait for 60 * CLK_PERIOD;   -- tooth divider completion + margin
        wait for 1 ns;

        assert to_integer(nco_clk_inc) >= NCO_CLK_INC_C - 2 and
               to_integer(nco_clk_inc) <= NCO_CLK_INC_C + 2
            report "FAIL T6: nco_clk_inc = " &
                   integer'image(to_integer(nco_clk_inc)) &
                   " expected ~" & integer'image(NCO_CLK_INC_C)
            severity failure;

        report "TEST 6: PASS - nco_clk_inc = " &
               integer'image(to_integer(nco_clk_inc));
        interp_en <= '0';
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: Interpolation advances angle_angfac between ab_edges
        -- After 1000 clocks of interpolation at NCO_CLK_INC_C/clock:
        -- accum += 1000 * 7158 = 7158000
        -- angle_angfac should be > 4 (at minimum, showing advancement)
        -- --------------------------------------------------------------------
        report "TEST 7: Interpolation advances angle_angfac between ab_edges";
        test_num <= 7;

        interp_en <= '1';
        fire_z(z_edge_s, clk);
        fire_ab(ab_edge_s, clk);   -- seeds tooth divider
        -- Wait: ~60 cycles divider + 1000 cycles interpolation
        wait for 1000 * CLK_PERIOD;
        wait for 1 ns;

        -- After 1000 clocks interp: accum ~= 1000 * 7158 = 7158000
        -- angle_angfac = 7158000; as fraction of full-scale: 7158000/4294967296 * 360 ~= 0.6 deg
        -- In 0.1deg units (if we were converting): ~6 units. Check angfac > 0.
        assert to_integer(angle_angfac) > 0
            report "FAIL T7: interpolation not advancing angle_angfac"
            severity failure;

        -- angle_angfac should be approximately 1000 * nco_clk_inc after divider settles
        assert to_integer(angle_angfac) >= 700 * NCO_CLK_INC_C
            report "FAIL T7: interpolation advance too small after 1000 clocks: " &
                   integer'image(to_integer(angle_angfac))
            severity failure;

        interp_en <= '0';
        report "TEST 7: PASS - angle_angfac = " &
               integer'image(to_integer(angle_angfac));

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
    p_monitor : process(angle_angfac)
    begin
        if angle_angfac'event then
            report "ANGFAC: " & integer'image(to_integer(angle_angfac)) &
                   "  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
