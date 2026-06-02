library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity pll_tb is
end entity pll_tb;

architecture sim of pll_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- At 60 teeth, 100MHz:
    --   angle_nco_ab_inc = 2^32 / 60 = 71582788
    --   At 1000 RPM, tooth period = 100MHz / (1000/60 * 60) = 100000 clocks
    --   angle_nco_clk_inc = nco_ab_inc / ab_period = 71582788 / 100000 = 715
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD    : time    := 10 ns;
    constant PPR           : integer := 60;
    constant AB_PERIOD_C   : integer := 100000;
    constant NCO_AB_INC_C  : integer := 71582788;
    constant NCO_CLK_INC_C : integer := 715;   -- = 71582788 / 100000

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal sync_full    : std_logic := '0';
    signal phase_eng    : std_logic := '0';
    signal ab_edge      : std_logic := '0';
    signal ab_per       : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_C, 32);
    signal z_edge       : std_logic := '0';
    signal nco_ab_inc_s : unsigned(31 downto 0) := to_unsigned(NCO_AB_INC_C, 32);
    signal nco_clk_inc_s: unsigned(31 downto 0) := to_unsigned(NCO_CLK_INC_C, 32);
    signal kp           : unsigned(15 downto 0) := to_unsigned(0, 16);
    signal ki           : unsigned(15 downto 0) := to_unsigned(0, 16);
    signal corr_dir     : std_logic := '0';
    signal corr_max     : unsigned(15 downto 0) := to_unsigned(1000, 16);
    signal ang_hires    : unsigned(15 downto 0);
    signal div_valid    : std_logic;
    signal nco_inc_o    : unsigned(31 downto 0);
    signal nco_accum    : unsigned(31 downto 0);
    signal phase_err    : signed(31 downto 0);
    signal p_term       : signed(31 downto 0);
    signal i_term       : signed(31 downto 0);
    signal pi_corr      : signed(31 downto 0);
    signal cycle_cnt    : unsigned(7 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire ab_edge strobe and wait for divider to complete
    -- The tooth divider is 32-bit sequential -- allow 40 cycles
    -- -------------------------------------------------------------------------
    procedure fire_ab(
        signal   ab  : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        ab <= '1'; wait until rising_edge(c);
        ab <= '0';
        wait for 40 * 10 ns;   -- allow divider to complete
    end procedure fire_ab;

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
    dut : entity work.pll
        port map (
            clk               => clk,
            rst               => rst,
            sync_full         => sync_full,
            phase_eng         => phase_eng,
            ab_edge           => ab_edge,
            ab_period         => ab_per,
            z_edge            => z_edge,
            pll_nco_ab_inc    => nco_ab_inc_s,
            angle_nco_clk_inc => nco_clk_inc_s,
            pll_kp            => kp,
            pll_ki            => ki,
            pll_corr_dir      => corr_dir,
            pll_corr_max      => corr_max,
            pll_ang_hires     => ang_hires,
            pll_div_valid     => div_valid,
            pll_nco_inc       => nco_inc_o,
            pll_nco_accum     => nco_accum,
            pll_phase_err     => phase_err,
            pll_p_term        => p_term,
            pll_i_term        => i_term,
            pll_pi_corr       => pi_corr,
            pll_cycle_ab_count => cycle_cnt
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable accum_prev : unsigned(31 downto 0);
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: NCO held at zero until sync_full asserted
        -- --------------------------------------------------------------------
        report "TEST 1: NCO held at zero before sync_full";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD;
        wait for 1 ns;

        assert nco_accum = to_unsigned(0, 32)
            report "FAIL T1: nco_accum should be 0 before sync_full"
            severity failure;
        assert div_valid = '0'
            report "FAIL T1: div_valid should be 0 before sync_full"
            severity failure;

        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: NCO starts accumulating after sync_full and first ab_edge
        -- After one ab_edge, nco_inc is seeded by angle_nco_clk_inc;
        -- nco_accum should advance each clock
        -- --------------------------------------------------------------------
        report "TEST 2: NCO accumulates after sync_full + ab_edge";
        test_num <= 2;

        sync_full <= '1';
        wait for 2 * CLK_PERIOD;
        fire_ab(ab_edge, clk);
        wait for 10 * CLK_PERIOD;
        wait for 1 ns;

        assert nco_accum > to_unsigned(0, 32)
            report "FAIL T2: NCO not accumulating after sync_full + ab_edge"
            severity failure;

        report "TEST 2: PASS - nco_accum = " &
               integer'image(to_integer(nco_accum));

        -- --------------------------------------------------------------------
        -- TEST 3: div_valid high while sync_full=1
        -- --------------------------------------------------------------------
        report "TEST 3: div_valid high during sync_full";
        test_num <= 3;

        assert div_valid = '1'
            report "FAIL T3: div_valid should be high during sync_full"
            severity failure;
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: nco_inc is seeded from angle_nco_clk_inc
        -- With kp=ki=0 there is no PI correction, so nco_inc = nco_clk_inc_s
        -- --------------------------------------------------------------------
        report "TEST 4: nco_inc = angle_nco_clk_inc with kp=ki=0";
        test_num <= 4;

        fire_ab(ab_edge, clk);
        wait for 1 ns;

        assert nco_inc_o = nco_clk_inc_s
            report "FAIL T4: nco_inc wrong: " &
                   integer'image(to_integer(nco_inc_o)) &
                   " expected " & integer'image(NCO_CLK_INC_C)
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: cycle_ab_count resets to 0 on 2nd z_edge
        -- cycle_ab_count counts AB edges per pair of z_edges
        -- --------------------------------------------------------------------
        report "TEST 5: cycle_ab_count resets on 2nd z_edge";
        test_num <= 5;

        -- Fire a few ab_edges to accumulate a count
        fire_ab(ab_edge, clk);
        fire_ab(ab_edge, clk);
        fire_ab(ab_edge, clk);

        -- First z_edge: does not reset
        fire_z(z_edge, clk);
        fire_ab(ab_edge, clk);
        fire_ab(ab_edge, clk);

        -- Second z_edge: should reset count
        fire_z(z_edge, clk);
        wait for 1 ns;
        assert to_integer(cycle_cnt) = 0
            report "FAIL T5: cycle_ab_count not reset on 2nd z_edge, got " &
                   integer'image(to_integer(cycle_cnt))
            severity failure;
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: NCO accumulator advances at rate nco_inc per clock
        -- Sample accum, wait N clocks, verify advance = N * nco_inc
        -- --------------------------------------------------------------------
        report "TEST 6: NCO advance rate = nco_inc per clock";
        test_num <= 6;

        fire_ab(ab_edge, clk);   -- seed nco_inc fresh
        wait until rising_edge(clk);
        wait for 1 ns;
        accum_prev := nco_accum;

        wait until rising_edge(clk);
        wait for 1 ns;

        assert nco_accum = accum_prev + nco_inc_o
            report "FAIL T6: NCO advance wrong: delta=" &
                   integer'image(to_integer(nco_accum) -
                                 to_integer(accum_prev)) &
                   " expected " & integer'image(to_integer(nco_inc_o))
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: sync_full=0 stops NCO (accumulator freezes)
        -- --------------------------------------------------------------------
        report "TEST 7: sync_full=0 freezes NCO";
        test_num <= 7;

        sync_full <= '0';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;
        accum_prev := nco_accum;
        wait for 5 * CLK_PERIOD;
        wait for 1 ns;

        assert nco_accum = to_unsigned(0, 32)
            report "FAIL T7: NCO should be 0 when sync_full=0"
            severity failure;
        report "TEST 7: PASS";

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
        variable prev_accum : unsigned(31 downto 0) := (others => '0');
    begin
        if rising_edge(clk) then
            if nco_accum /= prev_accum and div_valid = '1' then
                null;   -- NCO running normally -- no noise
            end if;
            prev_accum := nco_accum;
        end if;
    end process p_monitor;

end architecture sim;
