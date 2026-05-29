library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity pll_tb is end entity;
architecture sim of pll_tb is
    constant CLK_PERIOD   : time    := 10 ns;
    constant PPR          : integer := 60;
    constant AB_PERIOD_C  : integer := 10000;  -- 100MHz/10000 = 10000Hz tooth = 600RPM*60teeth
    -- nco_ab_inc = 2^32 / 60 = 71582788
    constant C_NCO_AB_INC : integer := 71582788;

    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal sync_full  : std_logic := '0';
    signal phase_eng  : std_logic := '0';
    signal ab_edge    : std_logic := '0';
    signal ab_per     : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_C, 32);
    signal z_edge     : std_logic := '0';
    signal nco_ab_inc_s : unsigned(31 downto 0) := to_unsigned(C_NCO_AB_INC, 32);
    signal kp         : unsigned(15 downto 0) := to_unsigned(0, 16);
    signal ki         : unsigned(15 downto 0) := to_unsigned(0, 16);
    signal corr_dir   : std_logic := '0';
    signal corr_max   : unsigned(15 downto 0) := to_unsigned(65535, 16);
    signal ang_hires  : unsigned(15 downto 0);
    signal div_valid  : std_logic;
    signal nco_inc_o  : unsigned(31 downto 0);
    signal nco_accum  : unsigned(31 downto 0);
    signal phase_err  : signed(31 downto 0);
    signal p_term     : signed(31 downto 0);
    signal i_term     : signed(31 downto 0);
    signal pi_corr    : signed(31 downto 0);
    signal cycle_cnt  : unsigned(7 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.pll port map(clk=>clk, rst=>rst, sync_full=>sync_full,
        phase_eng=>phase_eng, ab_edge=>ab_edge, ab_period=>ab_per, z_edge=>z_edge,
        pll_nco_ab_inc=>nco_ab_inc_s, pll_kp=>kp, pll_ki=>ki, pll_corr_dir=>corr_dir,
        pll_corr_max=>corr_max, pll_ang_hires=>ang_hires, pll_div_valid=>div_valid,
        pll_nco_inc=>nco_inc_o, pll_nco_accum=>nco_accum, pll_phase_err=>phase_err,
        pll_p_term=>p_term, pll_i_term=>i_term, pll_pi_corr=>pi_corr,
        pll_cycle_ab_count=>cycle_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: NCO held at 0 until sync_full
        assert to_integer(nco_accum) = 0 report "FAIL T1: nco running before sync_full" severity failure;
        report "T1: PASS";

        -- T2: NCO starts on sync_full, accumulates after ab_edge seeds nco_inc
        report "T2 starting";
        sync_full <= '1'; wait for 2 * CLK_PERIOD;
        report "T2 firing ab_edge";
        ab_edge <= '1'; wait for CLK_PERIOD; ab_edge <= '0';
        report "T2 waiting";
        wait for 50 * CLK_PERIOD;  -- wait for divider(32) + margin
        report "T2 check";
        assert nco_accum > to_unsigned(0, 32) report "FAIL T2: NCO not running after sync_full" severity failure;
        report "T2: PASS";

        -- T3: div_valid is high whenever sync_full=1 (simplified design)
        -- nco_inc should be pll_nco_ab_inc after an ab_edge
        ab_edge <= '1'; wait for CLK_PERIOD; ab_edge <= '0';
        wait for 5 * CLK_PERIOD;
        assert div_valid = '1' report "FAIL T3: div_valid not high during sync" severity failure;
        -- nco_inc starts as pll_nco_ab_inc = 71582788
        assert nco_inc_o = to_unsigned(71582788, 32)
            report "FAIL T3: nco_inc not equal to pll_nco_ab_inc" severity failure;
        report "T3: PASS";

        -- T4: cycle_ab_count resets on every 2nd z_edge
        -- Fire 2 z_edges, count should be 0 after 2nd
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for 2 * CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for 2 * CLK_PERIOD;
        assert to_integer(cycle_cnt) = 0 report "FAIL T4: count not reset on 2nd z, got " & integer'image(to_integer(cycle_cnt)) severity failure;
        report "T4: PASS";

        -- T5: ang_hires output (basic sanity check - let NCO run)
        -- After many cycles nco_accum should be large, ang_hires should be non-zero
        wait for 100 * CLK_PERIOD;
        assert to_integer(ang_hires) > 0 report "FAIL T5: ang_hires is 0" severity failure;
        report "T5: PASS";

        report "All pll tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
