library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity fault_tb is
end entity fault_tb;

architecture sim of fault_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD    : time    := 10 ns;
    constant N_TEETH       : integer := 60;
    constant N_MISSING     : integer := 2;
    constant MAX_RPM_VAL   : integer := 6000;
    constant PLL_THRESH_VAL: integer := 1000000;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal fault_clear   : std_logic := '0';
    signal src_sel_s     : std_logic := '0';
    signal ref_sel_s     : std_logic := '0';
    signal ab_count_s    : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal ppr_conf_s    : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal max_rpm_s     : unsigned(15 downto 0) := to_unsigned(MAX_RPM_VAL, 16);
    signal cam_tooth_cnt : unsigned(7 downto 0) := to_unsigned(1, 8);
    signal cam_n_teeth_s : unsigned(7 downto 0) := to_unsigned(1, 8);
    signal z_edge        : std_logic := '0';
    signal crank_tooth   : unsigned(7 downto 0) := to_unsigned(58, 8);
    signal crank_ab      : unsigned(7 downto 0) := to_unsigned(60, 8);
    signal crank_n_teeth : unsigned(7 downto 0) := to_unsigned(N_TEETH, 8);
    signal crank_n_miss  : unsigned(7 downto 0) := to_unsigned(N_MISSING, 8);
    signal crank_z       : std_logic := '0';
    signal speed_rpm     : unsigned(15 downto 0) := to_unsigned(3000, 16);
    signal pll_err       : signed(31 downto 0) := (others => '0');
    signal pll_thresh    : unsigned(31 downto 0) := to_unsigned(PLL_THRESH_VAL, 32);
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

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock z_edge strobe
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

    procedure fire_crank_z(
        signal   z   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_crank_z;

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
    dut : entity work.fault
        port map (
            clk               => clk,
            rst               => rst,
            fault_clear       => fault_clear,
            src_sel           => src_sel_s,
            ref_sel           => ref_sel_s,
            cam_tooth_count   => cam_tooth_cnt,
            cam_n_teeth       => cam_n_teeth_s,
            z_edge            => z_edge,
            crank_tooth_count => crank_tooth,
            crank_ab_count    => crank_ab,
            crank_n_teeth     => crank_n_teeth,
            crank_n_missing   => crank_n_miss,
            crank_z_edge      => crank_z,
            ab_count          => ab_count_s,
            ppr_conf          => ppr_conf_s,
            speed_rpm_slow    => speed_rpm,
            max_rpm           => max_rpm_s,
            pll_phase_err     => pll_err,
            pll_phase_err_thresh => pll_thresh,
            sync_full         => sync_full,
            phase_fault_drop  => ph_fault_drop,
            phase_ref_ok      => ph_ref_ok,
            fault_flags       => fault_flags,
            cam_fault_count   => cam_cnt,
            crank_fault_count => crank_cnt,
            phase_fault_count => phase_cnt,
            ab_fault_count    => ab_cnt,
            speed_fault_count => speed_cnt,
            pll_err_count     => pll_cnt
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: No faults after reset with all inputs nominal
        -- --------------------------------------------------------------------
        report "TEST 1: No faults with nominal inputs";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0';
        sync_full <= '1';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert fault_flags = x"00000000"
            report "FAIL T1: unexpected fault flags: " &
                   integer'image(to_integer(unsigned(fault_flags)))
            severity failure;
        assert to_integer(crank_cnt) = 0
            report "FAIL T1: crank_cnt should be 0"
            severity failure;
        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: Crank tooth count fault on crank_z_edge with wrong count
        -- Expected: crank_tooth_count = n_teeth - n_missing = 58
        -- --------------------------------------------------------------------
        report "TEST 2: Crank tooth fault on wrong tooth count at crank_z_edge";
        test_num <= 2;

        crank_tooth <= to_unsigned(50, 8);   -- wrong (expected 58)
        fire_crank_z(crank_z, clk);
        -- crank_tooth_fault is a one-clock strobe (cleared by default each clock)
        -- check crank_cnt (sticky counter) not fault_flags(1)
        wait for 1 ns;
        assert to_integer(crank_cnt) = 1
            report "FAIL T2: crank_cnt should be 1 after fault, got " &
                   integer'image(to_integer(crank_cnt))
            severity failure;

        -- Verify correct count does not fault
        crank_tooth <= to_unsigned(58, 8);   -- correct
        fire_crank_z(crank_z, clk);
        assert to_integer(crank_cnt) = 1
            report "FAIL T2: crank_cnt incremented on correct tooth count"
            severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: Phase fault on falling edge of phase_ref_ok
        -- --------------------------------------------------------------------
        report "TEST 3: Phase fault on phase_ref_ok falling edge";
        test_num <= 3;

        ph_ref_ok <= '0';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(phase_cnt) = 1
            report "FAIL T3: phase_cnt wrong: " &
                   integer'image(to_integer(phase_cnt)) & " expected 1"
            severity failure;

        ph_ref_ok <= '1';
        -- Second fall should increment again
        wait for 2 * CLK_PERIOD;
        ph_ref_ok <= '0';
        wait for 2 * CLK_PERIOD;
        assert to_integer(phase_cnt) = 2
            report "FAIL T3: phase_cnt not incrementing on each phase_ref_ok fall"
            severity failure;
        ph_ref_ok <= '1';

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: PLL phase error fault when |pll_phase_err| > threshold
        -- --------------------------------------------------------------------
        report "TEST 4: PLL phase error fault";
        test_num <= 4;

        pll_err <= to_signed(2000000, 32);   -- > PLL_THRESH_VAL
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert fault_flags(4) = '1'
            report "FAIL T4: pll_err_fault not set"
            severity failure;
        assert to_integer(pll_cnt) >= 1
            report "FAIL T4: pll_cnt not incremented"
            severity failure;

        -- Verify negative error also triggers
        pll_err <= to_signed(-2000000, 32);
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;
        assert fault_flags(4) = '1'
            report "FAIL T4: pll_err_fault not set for negative error"
            severity failure;

        pll_err <= (others => '0');
        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Speed fault when speed_rpm_slow > max_rpm
        -- --------------------------------------------------------------------
        report "TEST 5: Speed fault when RPM exceeds max_rpm";
        test_num <= 5;

        speed_rpm <= to_unsigned(MAX_RPM_VAL + 1000, 16);   -- over limit
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert fault_flags(3) = '1'
            report "FAIL T5: speed_fault not set"
            severity failure;
        assert to_integer(speed_cnt) >= 1
            report "FAIL T5: speed_cnt not incremented"
            severity failure;

        speed_rpm <= to_unsigned(3000, 16);   -- restore
        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: fault_clear resets all counters and flags
        -- --------------------------------------------------------------------
        report "TEST 6: fault_clear resets all counters";
        test_num <= 6;

        -- All counters have accumulated from T2-T5
        wait for 2 * CLK_PERIOD;
        fault_clear <= '1';
        wait for CLK_PERIOD;
        fault_clear <= '0';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(crank_cnt) = 0
            report "FAIL T6: crank_cnt not cleared"
            severity failure;
        assert to_integer(phase_cnt) = 0
            report "FAIL T6: phase_cnt not cleared"
            severity failure;
        assert to_integer(pll_cnt) = 0
            report "FAIL T6: pll_cnt not cleared"
            severity failure;
        assert to_integer(speed_cnt) = 0
            report "FAIL T6: speed_cnt not cleared"
            severity failure;
        assert fault_flags = x"00000000"
            report "FAIL T6: fault_flags not cleared"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: Cam fault gated when ref_sel=1 (peak detector selected)
        -- With ref_sel=1, cam_fault should not fire even on wrong count
        -- --------------------------------------------------------------------
        report "TEST 7: Cam fault gated when ref_sel=1";
        test_num <= 7;

        ref_sel_s     <= '1';
        cam_tooth_cnt <= to_unsigned(2, 8);   -- wrong (expected 1)

        -- Fire 2 z_edges (cam checks at every 2nd z)
        fire_z(z_edge, clk);
        fire_z(z_edge, clk);
        wait for 1 ns;

        assert to_integer(cam_cnt) = 0
            report "FAIL T7: cam_fault fired despite ref_sel=1"
            severity failure;

        ref_sel_s     <= '0';
        cam_tooth_cnt <= to_unsigned(1, 8);   -- restore

        report "TEST 7: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 8: ab_fault_count increments when ab_count != ppr_conf at z_edge
        -- --------------------------------------------------------------------
        report "TEST 8: ab_fault on ab_count mismatch at z_edge";
        test_num <= 8;

        ab_count_s <= to_unsigned(45, 8);   -- wrong (expected 60)
        fire_z(z_edge, clk);
        wait for 1 ns;

        assert to_integer(ab_cnt) = 1
            report "FAIL T8: ab_fault_count wrong: " &
                   integer'image(to_integer(ab_cnt)) & " expected 1"
            severity failure;

        -- Correct count should not fault
        ab_count_s <= to_unsigned(60, 8);
        fire_z(z_edge, clk);
        assert to_integer(ab_cnt) = 1
            report "FAIL T8: ab_fault_count incremented on correct count"
            severity failure;

        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All fault tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(fault_flags)
    begin
        if fault_flags /= x"00000000" then
            report "FAULT_FLAGS: 0x" &
                   integer'image(to_integer(unsigned(fault_flags))) &
                   "  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
