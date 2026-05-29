library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity fault_tb is end entity;
architecture sim of fault_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk           : std_logic := '0';
    signal done          : boolean := false;
    signal rst           : std_logic := '1';
    signal fault_clear   : std_logic := '0';
    signal src_sel_s     : std_logic := '0';
    signal ref_sel_s     : std_logic := '0';
    signal ab_count_s    : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal ppr_conf_s    : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal max_rpm_s     : unsigned(15 downto 0) := to_unsigned(6000, 16);
    signal cam_tooth_cnt : unsigned(7 downto 0) := to_unsigned(1, 8);
    signal cam_n_teeth_s : unsigned(7 downto 0) := to_unsigned(1, 8);
    signal z_edge        : std_logic := '0';
    signal crank_tooth   : unsigned(7 downto 0) := to_unsigned(58, 8);
    signal crank_ab      : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal crank_n_teeth : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal crank_n_miss  : unsigned(7 downto 0) := to_unsigned(2, 8);
    signal crank_z       : std_logic := '0';
    signal speed_rpm     : unsigned(15 downto 0) := to_unsigned(3000, 16);
    signal pll_err       : signed(31 downto 0) := (others => '0');
    signal pll_thresh    : unsigned(31 downto 0) := to_unsigned(1000000, 32);
    signal sync_full     : std_logic := '0';
    signal ph_fault_drop : std_logic := '0';
    signal ph_ref_ok     : std_logic := '1';
    signal fault_flags   : std_logic_vector(31 downto 0);
    signal cam_cnt       : unsigned(15 downto 0);
    signal crank_cnt     : unsigned(15 downto 0);
    signal phase_cnt     : unsigned(15 downto 0);
    signal ab_cnt        : unsigned(15 downto 0);
    signal speed_cnt     : unsigned(15 downto 0);
    signal pll_cnt       : unsigned(15 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.fault port map(clk=>clk, rst=>rst, fault_clear=>fault_clear,
        src_sel=>src_sel_s, ref_sel=>ref_sel_s,
        cam_tooth_count=>cam_tooth_cnt, cam_n_teeth=>cam_n_teeth_s, z_edge=>z_edge,
        crank_tooth_count=>crank_tooth, crank_ab_count=>crank_ab,
        crank_n_teeth=>crank_n_teeth, crank_n_missing=>crank_n_miss,
        crank_z_edge=>crank_z,
        ab_count=>ab_count_s, ppr_conf=>ppr_conf_s,
        speed_rpm_slow=>speed_rpm, max_rpm=>max_rpm_s,
        pll_phase_err=>pll_err, pll_phase_err_thresh=>pll_thresh,
        sync_full=>sync_full, phase_fault_drop=>ph_fault_drop,
        phase_ref_ok=>ph_ref_ok, fault_flags=>fault_flags,
        cam_fault_count=>cam_cnt, crank_fault_count=>crank_cnt,
        phase_fault_count=>phase_cnt, ab_fault_count=>ab_cnt,
        speed_fault_count=>speed_cnt, pll_err_count=>pll_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0'; sync_full <= '1'; wait for CLK_PERIOD;

        -- T1: no faults initially
        assert fault_flags = x"00000000" report "FAIL T1: spurious faults" severity failure;
        report "T1: PASS";

        -- T2: crank tooth fault on crank_z_edge with wrong count
        crank_tooth <= to_unsigned(50, 8);  -- wrong (expected 58)
        crank_z <= '1'; wait until rising_edge(clk); wait for 1 ns;
        assert fault_flags(1) = '1' report "FAIL T2: crank_tooth_fault not set" severity failure;
        crank_z <= '0'; wait for 3 * CLK_PERIOD;
        assert to_integer(crank_cnt) = 1 report "FAIL T2: crank_cnt wrong" severity failure;
        crank_tooth <= to_unsigned(58, 8);  -- restore
        report "T2: PASS";

        -- T3: phase fault on falling edge of phase_ref_ok
        ph_ref_ok <= '0'; wait for 2 * CLK_PERIOD;
        assert to_integer(phase_cnt) = 1 report "FAIL T3: phase_cnt wrong" severity failure;
        ph_ref_ok <= '1';
        report "T3: PASS";

        -- T4: PLL phase error fault
        pll_err <= to_signed(2000000, 32);  -- > thresh
        wait for 2 * CLK_PERIOD;
        assert fault_flags(4) = '1' report "FAIL T4: pll_err_fault not set" severity failure;
        assert to_integer(pll_cnt) >= 1 report "FAIL T4: pll_cnt wrong" severity failure;
        pll_err <= (others => '0');
        report "T4: PASS";

        -- T5: fault_clear resets counters
        wait for 2 * CLK_PERIOD;
        fault_clear <= '1'; wait for CLK_PERIOD; fault_clear <= '0'; wait for CLK_PERIOD;
        assert to_integer(crank_cnt) = 0  report "FAIL T5: crank_cnt not cleared" severity failure;
        assert to_integer(phase_cnt) = 0  report "FAIL T5: phase_cnt not cleared" severity failure;
        assert to_integer(pll_cnt) = 0    report "FAIL T5: pll_cnt not cleared" severity failure;
        report "T5: PASS";

        -- T6: cam fault gated when ref_sel=1 (peak selected)
        ref_sel_s <= '1';
        cam_window_z_fire : for i in 1 to 2 loop
            z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for 3 * CLK_PERIOD;
        end loop;
        -- cam_tooth_count=1 = cam_n_teeth=1, so no fault even if ref_sel=0
        -- but with wrong count and ref_sel=1, still no fault
        cam_tooth_cnt <= to_unsigned(2, 8);  -- wrong
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for CLK_PERIOD;
        assert to_integer(cam_cnt) = 0 report "FAIL T6: cam fault despite ref_sel=1" severity failure;
        report "T6: PASS";

        -- T7: ab_fault_count increments when ab_count != ppr_conf at z_edge
        ab_count_s <= to_unsigned(45, 8);  -- wrong (expected 60)
        z_edge <= '1'; wait for CLK_PERIOD; z_edge <= '0'; wait for 2 * CLK_PERIOD;
        assert to_integer(ab_cnt) = 1 report "FAIL T7: ab_fault_count wrong" severity failure;
        ab_count_s <= to_unsigned(60, 8);
        report "T7: PASS";

        report "All fault tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
