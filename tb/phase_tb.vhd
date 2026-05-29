library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity phase_tb is end entity;
architecture sim of phase_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk        : std_logic := '0';
    signal done       : boolean := false;
    signal rst        : std_logic := '1';
    signal ref_edge   : std_logic := '0';
    signal angle_deg  : unsigned(15 downto 0) := (others => '0');
    signal z_edge     : std_logic := '0';
    signal ref_ang    : unsigned(15 downto 0) := to_unsigned(1800, 16); -- 180 deg
    signal ref_tol    : unsigned(15 downto 0) := to_unsigned(600, 16);  -- 60 deg
    signal tdc_off    : unsigned(15 downto 0) := (others => '0');
    signal ph_raw     : std_logic;
    signal ph_ref_det : std_logic;
    signal ph_ref_ok  : std_logic;
    signal ph_ref_found: std_logic;
    signal ph_inv     : std_logic;
    signal ph_inv_l   : std_logic;
    signal ph_ang_corr: unsigned(15 downto 0);
    signal ph_eng     : std_logic;
    signal ph_ang_eng : unsigned(15 downto 0);
    signal det_cnt    : unsigned(15 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.phase port map(clk=>clk, rst=>rst, ref_edge=>ref_edge,
        angle_deg=>angle_deg, z_edge=>z_edge, phase_ref_ang=>ref_ang,
        phase_ref_tol=>ref_tol, tdc_offset=>tdc_off, phase_raw=>ph_raw,
        phase_ref_det=>ph_ref_det, phase_ref_ok=>ph_ref_ok,
        phase_ref_found=>ph_ref_found, phase_inv=>ph_inv, phase_inv_latch=>ph_inv_l,
        phase_ang_corr=>ph_ang_corr, phase_eng=>ph_eng, phase_ang_eng=>ph_ang_eng,
        phase_ref_det_cnt=>det_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;

        -- T1: phase_raw=0 for angle<3600, 1 for >=3600
        angle_deg <= to_unsigned(1800, 16); wait for CLK_PERIOD;
        assert ph_raw = '0' report "FAIL T1: phase_raw at 1800" severity failure;
        angle_deg <= to_unsigned(3600, 16); wait for CLK_PERIOD;
        assert ph_raw = '1' report "FAIL T1: phase_raw at 3600" severity failure;
        report "T1: PASS";

        -- T2: ref_edge in window1 -> phase_ref_det, phase_inv=0, phase_ref_found latched
        angle_deg <= to_unsigned(1800, 16); wait for CLK_PERIOD;
        ref_edge <= '1'; wait for CLK_PERIOD;
        -- phase_ref_det is high on the cycle after ref_edge fires
        assert ph_ref_det = '1' report "FAIL T2: phase_ref_det not set" severity failure;
        ref_edge <= '0'; wait for CLK_PERIOD;
        assert ph_ref_found = '1' report "FAIL T2: phase_ref_found not latched" severity failure;
        assert ph_inv_l = '0'     report "FAIL T2: phase_inv_latch wrong" severity failure;
        assert ph_ref_ok = '1'    report "FAIL T2: phase_ref_ok not set" severity failure;
        report "T2: PASS";

        -- T3: phase_ang_eng = 0 before phase_ref_found (already found, test tdc_offset)
        -- With tdc_offset=0: phase_ang_eng = angle_deg
        assert to_integer(ph_ang_eng) = 1800
            report "FAIL T3: phase_ang_eng wrong: " & integer'image(to_integer(ph_ang_eng)) severity failure;
        report "T3: PASS";

        -- T4: ref_edge in window2 (1800+3600=5400 deg) -> phase_inv=1
        -- Reset first
        rst <= '1'; wait for CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;
        angle_deg <= to_unsigned(5400, 16); wait for CLK_PERIOD;
        ref_edge <= '1'; wait for CLK_PERIOD; ref_edge <= '0'; wait for CLK_PERIOD;
        wait for CLK_PERIOD;
        assert ph_ref_found = '1' report "FAIL T4: phase_ref_found not set" severity failure;
        assert ph_inv_l = '1'     report "FAIL T4: phase_inv_latch not 1 for window2" severity failure;
        report "T4: PASS";

        -- T5: phase_ref_ok=0 after 3 z_edges without detection
        rst <= '1'; wait for CLK_PERIOD; rst <= '0'; wait for CLK_PERIOD;
        -- First establish ref_found
        angle_deg <= to_unsigned(1800, 16); wait for CLK_PERIOD;
        ref_edge <= '1'; wait for CLK_PERIOD; ref_edge <= '0'; wait for 2 * CLK_PERIOD;
        -- Fire 4 z_edges without ref_edge (1st updates prev, next 3 are misses)
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for 5 * CLK_PERIOD;
        assert ph_ref_ok = '0' report "FAIL T5: phase_ref_ok not cleared after 3 z without det" severity failure;
        report "T5: PASS";

        report "All phase tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
