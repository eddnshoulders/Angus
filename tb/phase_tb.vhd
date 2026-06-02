library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity phase_tb is
end entity phase_tb;

architecture sim of phase_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- angle domain: 0-7199 = 0-719.9 degrees (0.1 deg per LSB)
    -- phase_ref_ang=1800: window centred at 180.0 degrees
    -- phase_ref_tol=600:  window spans 120 degrees (180 ± 60)
    -- w2_centre = (phase_ref_ang + 3600) mod 7200 = 5400 (540.0 deg)
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time    := 10 ns;
    constant REF_ANG_C  : integer := 1800;   -- 180.0 deg
    constant REF_TOL_C  : integer := 600;    -- ±60.0 deg

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';
    signal ref_edge    : std_logic := '0';
    signal angle_deg   : unsigned(15 downto 0) := (others => '0');
    signal z_edge      : std_logic := '0';
    signal ref_ang     : unsigned(15 downto 0) := to_unsigned(REF_ANG_C, 16);
    signal ref_tol     : unsigned(15 downto 0) := to_unsigned(REF_TOL_C, 16);
    signal tdc_off     : unsigned(15 downto 0) := (others => '0');
    signal ph_raw      : std_logic;
    signal ph_ref_det  : std_logic;
    signal ph_ref_ok   : std_logic;
    signal ph_ref_found: std_logic;
    signal ph_inv      : std_logic;
    signal ph_inv_l    : std_logic;
    signal ph_ang_corr : unsigned(15 downto 0);
    signal ph_eng      : std_logic;
    signal ph_ang_eng  : unsigned(15 downto 0);
    signal det_cnt     : unsigned(15 downto 0);
    signal ref_angle_s : unsigned(15 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a ref_edge strobe at the given angle
    -- -------------------------------------------------------------------------
    procedure fire_ref(
        signal   ang     : out unsigned(15 downto 0);
        signal   ref     : out std_logic;
        signal   c   : in  std_logic;
        constant ang_val : in  integer
    ) is
    begin
        ang <= to_unsigned(ang_val, 16);
        wait until rising_edge(c);
        ref <= '1';
        wait until rising_edge(c);
        ref <= '0';
        wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_ref;

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

    -- -------------------------------------------------------------------------
    -- Reset and wait for outputs to clear
    -- -------------------------------------------------------------------------
    procedure do_reset(
        signal rst : out std_logic;
        signal ref : out std_logic;
        signal z   : out std_logic
    ) is
    begin
        rst <= '1';
        ref <= '0';
        z   <= '0';
        wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait for 2 * CLK_PERIOD;
    end procedure do_reset;

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
    dut : entity work.phase
        port map (
            clk              => clk,
            rst              => rst,
            ref_edge         => ref_edge,
            angle_deg        => angle_deg,
            z_edge           => z_edge,
            phase_ref_ang    => ref_ang,
            phase_ref_tol    => ref_tol,
            tdc_offset       => tdc_off,
            phase_raw        => ph_raw,
            phase_ref_det    => ph_ref_det,
            phase_ref_ok     => ph_ref_ok,
            phase_ref_found  => ph_ref_found,
            phase_inv        => ph_inv,
            phase_inv_latch  => ph_inv_l,
            phase_ang_corr   => ph_ang_corr,
            phase_eng        => ph_eng,
            phase_eng_ang    => ph_ang_eng,
            phase_ref_det_cnt => det_cnt,
            ref_angle        => ref_angle_s
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: phase_raw follows angle_deg
        -- phase_raw=0 for angle < 3600 (first crank revolution)
        -- phase_raw=1 for angle >= 3600 (second crank revolution)
        -- --------------------------------------------------------------------
        report "TEST 1: phase_raw follows angle_deg";
        test_num <= 1;

        do_reset(rst, ref_edge, z_edge);

        angle_deg <= to_unsigned(1800, 16); wait for 2 * CLK_PERIOD;
        assert ph_raw = '0'
            report "FAIL T1: phase_raw should be 0 at 1800 (first revolution)"
            severity failure;

        angle_deg <= to_unsigned(3600, 16); wait for 2 * CLK_PERIOD;
        assert ph_raw = '1'
            report "FAIL T1: phase_raw should be 1 at 3600 (second revolution)"
            severity failure;

        angle_deg <= to_unsigned(7199, 16); wait for 2 * CLK_PERIOD;
        assert ph_raw = '1'
            report "FAIL T1: phase_raw should be 1 at 7199"
            severity failure;

        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: ref_edge in window 1 (around ref_ang=1800, tol=600)
        -- Fires at 1800 -> phase_ref_det, phase_ref_ok, phase_ref_found, inv=0
        -- --------------------------------------------------------------------
        report "TEST 2: ref_edge in window 1 -> phase_ref_found, inv=0";
        test_num <= 2;

        do_reset(rst, ref_edge, z_edge);

        -- Check phase_ref_det WHILE ref_edge is still high (it's a 1-clock strobe)
        angle_deg <= to_unsigned(1800, 16);
        wait for CLK_PERIOD;
        ref_edge <= '1';
        wait for CLK_PERIOD; wait for 1 ns;  -- phase_ref_det fires this clock
        assert ph_ref_det = '1'
            report "FAIL T2: phase_ref_det not set" severity failure;
        ref_edge <= '0';
        wait for CLK_PERIOD; wait for 1 ns;  -- ref_found, ok, inv_l latch
        assert ph_ref_ok = '1'
            report "FAIL T2: phase_ref_ok not set" severity failure;
        assert ph_ref_found = '1'
            report "FAIL T2: phase_ref_found not latched" severity failure;
        assert ph_inv_l = '0'
            report "FAIL T2: phase_inv_latch should be 0 for window 1" severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: ref_edge in window 2 (w2_centre=5400, tol=600)
        -- Fires at 5400 -> phase_ref_found, inv=1
        -- --------------------------------------------------------------------
        report "TEST 3: ref_edge in window 2 -> inv=1";
        test_num <= 3;

        do_reset(rst, ref_edge, z_edge);

        fire_ref(angle_deg, ref_edge, clk, 5400);

        assert ph_ref_found = '1'
            report "FAIL T3: phase_ref_found not set for window 2" severity failure;
        assert ph_inv_l = '1'
            report "FAIL T3: phase_inv_latch should be 1 for window 2" severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: ref_edge outside both windows -> no detection
        -- --------------------------------------------------------------------
        report "TEST 4: ref_edge outside windows -> no detection";
        test_num <= 4;

        do_reset(rst, ref_edge, z_edge);

        -- Fire at 3600 (halfway between windows, outside both)
        fire_ref(angle_deg, ref_edge, clk, 3600);

        assert ph_ref_found = '0'
            report "FAIL T4: phase_ref_found should not be set outside windows"
            severity failure;
        assert ph_ref_det = '0'
            report "FAIL T4: phase_ref_det should not be set outside windows"
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: ref_angle output latches angle_deg at detection
        -- --------------------------------------------------------------------
        report "TEST 5: ref_angle latches angle_deg at detection";
        test_num <= 5;

        do_reset(rst, ref_edge, z_edge);

        -- Fire ref_edge at a specific angle
        fire_ref(angle_deg, ref_edge, clk, 1500);   -- within window (1800±600)

        assert to_integer(ref_angle_s) = 1500
            report "FAIL T5: ref_angle wrong: " &
                   integer'image(to_integer(ref_angle_s)) & " expected 1500"
            severity failure;

        -- Angle changes but ref_angle stays latched
        angle_deg <= to_unsigned(2000, 16); wait for 3 * CLK_PERIOD;
        assert to_integer(ref_angle_s) = 1500
            report "FAIL T5: ref_angle changed after detection (should be latched)"
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: phase_ref_ok goes low after 3 z_edges without detection
        -- --------------------------------------------------------------------
        report "TEST 6: phase_ref_ok drops after 3 z_edges without ref_edge";
        test_num <= 6;

        do_reset(rst, ref_edge, z_edge);

        -- Establish ref_found
        fire_ref(angle_deg, ref_edge, clk, 1800);
        assert ph_ref_ok = '1'
            report "FAIL T6 setup: phase_ref_ok not set" severity failure;

        -- Fire 4 z_edges without ref_edge (1st updates prev, next 3 are misses)
        fire_z(z_edge, clk);
        fire_z(z_edge, clk);
        fire_z(z_edge, clk);
        fire_z(z_edge, clk);
        wait for 5 * CLK_PERIOD;

        assert ph_ref_ok = '0'
            report "FAIL T6: phase_ref_ok not cleared after 3 z_edges without detection"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: phase_eng_ang with tdc_offset
        -- With tdc_offset=300 (30 deg) and ref at 1800:
        -- phase_eng_ang should be (1800 + 300) mod 7200 = 2100
        -- --------------------------------------------------------------------
        report "TEST 7: phase_eng_ang includes tdc_offset";
        test_num <= 7;

        do_reset(rst, ref_edge, z_edge);
        tdc_off <= to_unsigned(300, 16);   -- 30.0 degrees

        fire_ref(angle_deg, ref_edge, clk, 1800);
        wait for 2 * CLK_PERIOD;

        assert to_integer(ph_ang_eng) = 2100
            report "FAIL T7: phase_eng_ang wrong: " &
                   integer'image(to_integer(ph_ang_eng)) &
                   " expected 2100"
            severity failure;

        tdc_off <= (others => '0');   -- restore
        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All phase tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(ph_ref_det, ph_ref_ok, ph_ref_found)
    begin
        if ph_ref_det = '1' then
            report "REF_DET: angle=" & integer'image(to_integer(angle_deg)) &
                   " inv=" & std_logic'image(ph_inv) &
                   " ok=" & std_logic'image(ph_ref_ok) &
                   " test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
