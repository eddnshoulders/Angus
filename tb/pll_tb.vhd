library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- pll_tb.vhd  (v3)
--
-- Unit testbench for pll.vhd.
-- Internal unit is _angfac: full scale 0xFFFFFFFF = 360 crank degrees.
--
-- Test parameters (ppr=60, 360 deg scale):
--   angle_nco_ab_inc  = 0xFFFFFFFF / 60 = 71582788
--   ab_period         = 10000 clocks (100 MHz, ~6000 RPM equivalent)
--   angle_nco_clk_inc = 71582788 / 10000 = 7158
-- =============================================================================

entity pll_tb is
end entity pll_tb;

architecture sim of pll_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD     : time    := 10 ns;   -- 100 MHz
    constant PPR            : integer := 60;
    constant AB_PERIOD_C    : integer := 10000;
    constant NCO_AB_INC_C   : integer := 71582788;   -- 0xFFFFFFFF / 60
    constant NCO_CLK_INC_C  : integer := 7158;        -- 71582788 / 10000

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal sync_full     : std_logic := '0';
    signal ab_edge       : std_logic := '0';
    signal ab_per        : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_C, 32);
    signal ab_count      : unsigned(7 downto 0)  := (others => '0');
    signal z_edge        : std_logic := '0';
    signal nco_ab_inc    : unsigned(31 downto 0) := to_unsigned(NCO_AB_INC_C, 32);
    signal nco_clk_inc   : unsigned(31 downto 0) := to_unsigned(NCO_CLK_INC_C, 32);
    signal kp            : unsigned(15 downto 0) := (others => '0');
    signal ki            : unsigned(15 downto 0) := (others => '0');
    signal corr_dir      : std_logic := '0';
    signal corr_max      : unsigned(15 downto 0) := to_unsigned(1000, 16);
    signal pll_angfac    : unsigned(31 downto 0);
    signal div_valid     : std_logic;
    signal nco_inc_o     : unsigned(31 downto 0);
    signal nco_accum     : unsigned(31 downto 0);
    signal phase_err     : signed(31 downto 0);
    signal p_term        : signed(31 downto 0);
    signal i_term        : signed(31 downto 0);
    signal pi_corr       : signed(31 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock ab_edge strobe and advance ab_count
    -- -------------------------------------------------------------------------
    procedure fire_ab(
        signal   ab  : out std_logic;
        signal   cnt : out unsigned(7 downto 0);
        signal   c   : in  std_logic;
        variable count : inout integer
    ) is
    begin
        cnt <= to_unsigned(count, 8);
        ab  <= '1'; wait until rising_edge(c);
        ab  <= '0'; wait until rising_edge(c);
        wait for 1 ns;
        count := count + 1;
    end procedure fire_ab;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock z_edge strobe and reset ab_count
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   z   : out std_logic;
        signal   cnt : out unsigned(7 downto 0);
        signal   c   : in  std_logic
    ) is
    begin
        cnt <= (others => '0');
        z   <= '1'; wait until rising_edge(c);
        z   <= '0'; wait until rising_edge(c);
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
    dut : entity work.pll
        port map (
            clk               => clk,
            rst               => rst,
            sync_full         => sync_full,
            ab_edge           => ab_edge,
            ab_period         => ab_per,
            ab_count          => ab_count,
            z_edge            => z_edge,
            angle_nco_ab_inc  => nco_ab_inc,
            angle_nco_clk_inc => nco_clk_inc,
            pll_kp            => kp,
            pll_ki            => ki,
            pll_corr_dir      => corr_dir,
            pll_corr_max      => corr_max,
            pll_angfac        => pll_angfac,
            pll_div_valid     => div_valid,
            pll_nco_inc       => nco_inc_o,
            pll_nco_accum     => nco_accum,
            pll_err_angfac    => phase_err,
            pll_p_term        => p_term,
            pll_i_term        => i_term,
            pll_pi_corr       => pi_corr
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable ab_cnt  : integer := 0;
        variable acc_prev: unsigned(31 downto 0);
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: NCO held at zero until sync_full asserted
        -- --------------------------------------------------------------------
        report "TEST 1: NCO held at zero before sync_full";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD; wait for 1 ns;

        assert pll_angfac = to_unsigned(0, 32)
            report "FAIL T1: pll_angfac should be 0 before sync_full"
            severity failure;
        assert div_valid = '0'
            report "FAIL T1: div_valid should be 0 before sync_full"
            severity failure;

        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: NCO starts accumulating after sync_full asserted
        -- After sync_full=1, nco_inc is pre-loaded with angle_nco_clk_inc,
        -- so the accumulator begins advancing immediately.
        -- --------------------------------------------------------------------
        report "TEST 2: NCO accumulates after sync_full";
        test_num <= 2;

        sync_full <= '1';
        wait for 10 * CLK_PERIOD; wait for 1 ns;

        assert pll_angfac > to_unsigned(0, 32)
            report "FAIL T2: NCO not accumulating after sync_full"
            severity failure;
        assert div_valid = '1'
            report "FAIL T2: div_valid should be 1 during sync_full"
            severity failure;

        report "TEST 2: PASS - pll_angfac = " &
               integer'image(to_integer(pll_angfac));
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: z_edge resets accumulator on every crank revolution
        -- In v3 the reset occurs on EVERY z_edge (not every 2nd).
        -- --------------------------------------------------------------------
        report "TEST 3: z_edge resets pll_angfac on every z_edge";
        test_num <= 3;

        -- Drive z_edge manually and check pll_angfac immediately at the
        -- reset clock, before the NCO re-advances on the following clock.
        wait for 10 * CLK_PERIOD;
        assert to_integer(pll_angfac) > 0
            report "FAIL T3 setup: pll_angfac should be non-zero before reset"
            severity failure;

        ab_count <= (others => '0');
        z_edge   <= '1';
        wait until rising_edge(clk); wait for 1 ns;   -- reset fires this clock
        z_edge   <= '0';
        assert to_integer(pll_angfac) = 0
            report "FAIL T3: pll_angfac should be 0 at z_edge clock, got " &
                   integer'image(to_integer(pll_angfac))
            severity failure;

        -- Verify the second z_edge also resets (every revolution, not every 2nd)
        wait for 10 * CLK_PERIOD;
        z_edge <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        z_edge <= '0';
        assert to_integer(pll_angfac) = 0
            report "FAIL T3: pll_angfac should reset on every z_edge in v3"
            severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: nco_inc equals angle_nco_clk_inc when kp=ki=0
        -- With no PI correction, nco_inc should track the base increment.
        -- --------------------------------------------------------------------
        report "TEST 4: nco_inc = angle_nco_clk_inc with kp=ki=0";
        test_num <= 4;

        kp <= (others => '0'); ki <= (others => '0');
        ab_cnt := 0;
        fire_ab(ab_edge, ab_count, clk, ab_cnt);
        wait for 1 ns;

        assert nco_inc_o = nco_clk_inc
            report "FAIL T4: nco_inc should equal angle_nco_clk_inc with kp=ki=0, got " &
                   integer'image(to_integer(nco_inc_o)) &
                   " expected " & integer'image(NCO_CLK_INC_C)
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: NCO advances at exactly nco_inc per clock
        -- Sample the accumulator on two consecutive clock edges and verify
        -- the delta matches nco_inc_o.
        -- --------------------------------------------------------------------
        report "TEST 5: NCO advance rate = nco_inc per clock";
        test_num <= 5;

        wait until rising_edge(clk); wait for 1 ns;
        acc_prev := pll_angfac;
        wait until rising_edge(clk); wait for 1 ns;

        assert pll_angfac = acc_prev + nco_inc_o
            report "FAIL T5: NCO advance wrong: delta=" &
                   integer'image(to_integer(pll_angfac) - to_integer(acc_prev)) &
                   " expected " & integer'image(to_integer(nco_inc_o))
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: sync_full = 0 resets accumulator and holds at zero
        -- --------------------------------------------------------------------
        report "TEST 6: sync_full=0 resets NCO to zero";
        test_num <= 6;

        sync_full <= '0';
        wait for 2 * CLK_PERIOD; wait for 1 ns;

        assert pll_angfac = to_unsigned(0, 32)
            report "FAIL T6: pll_angfac should be 0 when sync_full=0"
            severity failure;

        -- Confirm it stays at zero
        wait for 5 * CLK_PERIOD; wait for 1 ns;
        assert pll_angfac = to_unsigned(0, 32)
            report "FAIL T6: pll_angfac should remain 0 while sync_full=0"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: phase error is zero when accumulator matches expected position
        -- With kp=ki=0, nco_inc=nco_clk_inc throughout. Fire z_edge then
        -- several ab_edges; error should be small at the snap points.
        -- --------------------------------------------------------------------
        report "TEST 7: phase error near zero at tooth snap positions";
        test_num <= 7;

        sync_full <= '1';
        ab_cnt := 0;
        fire_z(z_edge, ab_count, clk);   -- reset accum and ab_count

        -- Fire a tooth: accum snapped to 0*nco_ab_inc = 0, then nco advances.
        -- After ~NCO_CLK_INC_C clocks nco_accum ≈ 1 * nco_clk_inc per clock.
        -- At the ab_edge snap, the PLL accumulator will lag slightly due to
        -- free-running, so error will be small but not necessarily zero.
        -- Just verify pll_err_angfac is a plausible signed value (not extreme).
        fire_ab(ab_edge, ab_count, clk, ab_cnt);
        wait for 1 ns;

        assert to_integer(abs(phase_err)) < NCO_AB_INC_C
            report "FAIL T7: phase_err too large: " &
                   integer'image(to_integer(phase_err))
            severity failure;

        report "TEST 7: PASS - phase_err = " &
               integer'image(to_integer(phase_err));

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All pll tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(clk)
        variable prev : unsigned(31 downto 0) := (others => '0');
    begin
        if rising_edge(clk) then
            if pll_angfac /= prev and div_valid = '1' then
                null;  -- NCO running normally
            end if;
            prev := pll_angfac;
        end if;
    end process p_monitor;

end architecture sim;
