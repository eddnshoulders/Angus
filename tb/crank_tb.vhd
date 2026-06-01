library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity crank_tb is end entity;
architecture sim of crank_tb is
    constant CLK_PERIOD   : time    := 10 ns;
    constant TOOTH_PERIOD : integer := 100;  -- 100 clocks per tooth
    constant N_TEETH      : integer := 8;    -- 8 total teeth (6 real + 2 missing)
    constant N_MISSING    : integer := 2;
    -- gap_threshold 0xC0 = 192 = 1.5 in 1.7 fp
    -- gap fires when period_cnt * 128 >= last_period * 192
    -- = period_cnt >= last_period * 1.5
    -- So gap fires after 150 clocks (1.5 * 100)

    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal clean      : std_logic := '0';
    signal edge_sel   : std_logic := '1';
    signal gap_thresh : unsigned(7 downto 0) := x"C0";
    signal n_teeth_s  : unsigned(7 downto 0) := to_unsigned(N_TEETH, 8);
    signal n_missing_s: unsigned(7 downto 0) := to_unsigned(N_MISSING, 8);
    signal ab_edge    : std_logic;
    signal z_edge     : std_logic;
    signal ppr_conf   : unsigned(7 downto 0);
    signal tooth_per  : unsigned(31 downto 0);
    signal tooth_cnt  : unsigned(7 downto 0);
    signal ab_cnt     : unsigned(7 downto 0);
    signal gap_det    : std_logic;
    signal gap_period : unsigned(31 downto 0);
    signal signal_ok  : std_logic;
    signal crank_ab   : std_logic;
    signal crank_z    : std_logic;

    -- Generate tooth pulse
    procedure fire_tooth(signal s : out std_logic; signal c : in std_logic;
                         n_clk : integer) is
    begin
        s <= '1'; wait until rising_edge(c); s <= '0';
        for i in 1 to n_clk-1 loop wait until rising_edge(c); end loop;
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.crank port map(clk=>clk, rst=>rst, crank_clean=>clean,
        crank_edge_sel=>edge_sel, crank_gap_thresh=>gap_thresh,
        crank_n_teeth=>n_teeth_s, crank_n_missing=>n_missing_s,
        crank_ab_edge=>ab_edge, crank_z_edge=>z_edge, crank_ppr_conf=>ppr_conf,
        crank_tooth_period=>tooth_per, crank_tooth_count=>tooth_cnt,
        crank_ab_count=>ab_cnt, crank_gap_det=>gap_det, crank_gap_period=>gap_period,
        crank_signal_ok=>signal_ok,
        crank_ab=>crank_ab, crank_z=>crank_z);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: ppr_conf is pass-through of n_teeth
        assert ppr_conf = to_unsigned(N_TEETH, 8) report "FAIL T1: ppr_conf" severity failure;
        report "T1: PASS";

        -- T2: ab_edge fires on each tooth edge, tooth_period updated
        -- Drive rising edge on clean
        -- ab_edge_int fires on the clock edge where edge_det is detected
        -- concurrent assignment updates ab_edge in same delta cycle
        clean <= '1';
        wait until rising_edge(clk);  -- edge detected here
        wait for 1 ns;                 -- allow delta cycles to propagate
        assert ab_edge = '1' report "FAIL T2: ab_edge not fired on rising edge" severity failure;
        clean <= '0'; wait until rising_edge(clk);
        wait for 1 ns;
        assert ab_edge = '0' report "FAIL T2: ab_edge lasted > 1 clock" severity failure;
        report "T2: PASS";

        -- T3: gap detected after gap period
        -- Fire 5 normal teeth, then wait for gap (>1.5x tooth_period)
        for i in 1 to 5 loop
            fire_tooth(clean, clk, TOOTH_PERIOD);
        end loop;
        -- Now wait for gap: 150+ clocks without edge
        wait for 160 * CLK_PERIOD;
        assert gap_det = '1' report "FAIL T3: gap_det not set" severity failure;
        report "T3: PASS";

        -- T4: z_edge fires on first tooth after gap
        -- edge_pulse registered (1 cycle), z_int rises on edge_pulse+z_armed (1 more cycle)
        -- z_edge = 1-clock strobe on z_int rising = 2 cycles after physical edge
        clean <= '1';
        wait until rising_edge(clk);  -- physical edge
        wait until rising_edge(clk);  -- edge_pulse+z_int rise, z_edge fires, ab_edge fires
        wait for 1 ns;
        -- z_edge and ab_edge fire 1 cycle apart (registered edge_pulse)
        -- At this point: z_edge=1, ab_edge=0 (ab_edge fired one cycle earlier)
        assert z_edge = '1' report "FAIL T4: z_edge not fired after gap" severity failure;
        clean <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert z_edge = '0' report "FAIL T4: z_edge not 1-clock strobe" severity failure;
        report "T4: PASS";

        -- T5: gap_period latched at detection (approx TOOTH_PERIOD * gap_thresh / 128)
        -- At TOOTH_PERIOD=100, gap_thresh=0xC0=192: fires at ~150 clocks
        -- gap_period should be approximately 150 (within a few clocks)
        wait for 5 * CLK_PERIOD;  -- let gap_period stabilise after T3
        assert gap_period >= to_unsigned(140, 32) and gap_period <= to_unsigned(165, 32)
            report "FAIL T5: gap_period out of expected range: " &
                   integer'image(to_integer(gap_period)) severity failure;
        report "T5: PASS";

        report "All crank tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
