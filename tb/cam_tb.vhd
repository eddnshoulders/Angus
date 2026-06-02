library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity cam_tb is
end entity cam_tb;

architecture sim of cam_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time := 10 ns;   -- 100 MHz

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal cam_clean : std_logic := '0';
    signal z_edge    : std_logic := '0';
    signal edge_sel  : std_logic := '1';   -- '1'=rising  '0'=falling
    signal cam_edge  : std_logic;
    signal cam_cnt   : unsigned(7 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Apply a 1-clock cam pulse (rising or falling depending on edge_sel)
    -- and wait one clock so cam_edge has time to fire
    -- -------------------------------------------------------------------------
    procedure fire_cam(
        signal cam  : out std_logic;
        signal clk  : in  std_logic;
        constant level : in  std_logic      -- target level for the edge
    ) is
    begin
        cam <= level;
        wait until rising_edge(clk);
        wait for 1 ns;
    end procedure fire_cam;

    -- -------------------------------------------------------------------------
    -- Fire a z_edge strobe (1-clock high pulse)
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal z   : out std_logic;
        signal clk : in  std_logic
    ) is
    begin
        z <= '1';
        wait until rising_edge(clk);
        z <= '0';
        wait until rising_edge(clk);
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
    dut : entity work.cam
        port map (
            clk          => clk,
            rst          => rst,
            cam_clean    => cam_clean,
            z_edge       => z_edge,
            cam_edge_sel => edge_sel,
            cam_edge     => cam_edge,
            cam_tooth_count => cam_cnt
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- cam_edge and cam_cnt should be zero after reset
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1';
        wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert cam_edge = '0'
            report "FAIL T1: cam_edge should be low after reset"
            severity failure;
        assert cam_cnt = to_unsigned(0, 8)
            report "FAIL T1: cam_cnt should be zero after reset"
            severity failure;

        report "TEST 1: PASS";
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: Rising edge detected when edge_sel = '1'
        -- cam_edge should be a 1-clock strobe; falling edge must not trigger
        -- --------------------------------------------------------------------
        report "TEST 2: Rising edge detected, 1-clock strobe, falling edge ignored";
        test_num <= 2;

        edge_sel <= '1';
        fire_cam(cam_clean, clk, '1');    -- rising edge
        assert cam_edge = '1'
            report "FAIL T2: rising edge not detected with edge_sel=1"
            severity failure;

        wait until rising_edge(clk);
        wait for 1 ns;
        assert cam_edge = '0'
            report "FAIL T2: cam_edge not a 1-clock strobe"
            severity failure;

        fire_cam(cam_clean, clk, '0');    -- falling edge -- should be ignored
        assert cam_edge = '0'
            report "FAIL T2: falling edge triggered cam_edge with edge_sel=1"
            severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: Falling edge detected when edge_sel = '0'
        -- cam_clean currently low; go high then back low to fire falling edge
        -- --------------------------------------------------------------------
        report "TEST 3: Falling edge detected when edge_sel = 0";
        test_num <= 3;

        edge_sel  <= '0';
        cam_clean <= '1';
        wait for CLK_PERIOD;
        fire_cam(cam_clean, clk, '0');    -- falling edge
        assert cam_edge = '1'
            report "FAIL T3: falling edge not detected with edge_sel=0"
            severity failure;

        wait until rising_edge(clk);
        wait for 1 ns;
        assert cam_edge = '0'
            report "FAIL T3: cam_edge not a 1-clock strobe"
            severity failure;

        edge_sel <= '1';    -- restore to rising

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Tooth count increments on each cam_edge
        -- After T2 and T3 we have fired 2 edges (1 rising + 1 falling).
        -- cam_cnt should now be 2. Fire one more rising edge -> should be 3.
        -- --------------------------------------------------------------------
        report "TEST 4: Tooth count increments on each cam_edge";
        test_num <= 4;

        assert cam_cnt = to_unsigned(2, 8)
            report "FAIL T4: cam_cnt wrong before increment (expected 2, got " &
                   integer'image(to_integer(cam_cnt)) & ")"
            severity failure;

        fire_cam(cam_clean, clk, '1');    -- cam_clean was '0', rising edge
        assert cam_cnt = to_unsigned(3, 8)
            report "FAIL T4: cam_cnt did not increment (expected 3, got " &
                   integer'image(to_integer(cam_cnt)) & ")"
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Tooth count resets on 2nd z_edge, not 1st
        -- One full 720-deg cycle = 2 z_edges. Count must survive the 1st z
        -- and reset to zero on the 2nd.
        -- --------------------------------------------------------------------
        report "TEST 5: Tooth count resets on 2nd z_edge, not 1st";
        test_num <= 5;

        fire_z(z_edge, clk);    -- 1st z_edge of the cycle
        assert cam_cnt = to_unsigned(3, 8)
            report "FAIL T5: cam_cnt reset on 1st z_edge (should not)"
            severity failure;

        fire_z(z_edge, clk);    -- 2nd z_edge = 720-deg boundary
        assert cam_cnt = to_unsigned(0, 8)
            report "FAIL T5: cam_cnt did not reset on 2nd z_edge"
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: Consistent behaviour across multiple 720-deg cycles
        -- Fire 1 cam pulse per 720-deg cycle for 3 cycles; confirm count
        -- starts at 1 after each reset (0 after 2nd z, then 1 after cam edge)
        -- --------------------------------------------------------------------
        report "TEST 6: Consistent behaviour across multiple 720-deg cycles";
        test_num <= 6;

        for i in 1 to 3 loop
            -- Ensure cam_clean is low before firing a clean rising edge
            cam_clean <= '0';
            wait for 2 * CLK_PERIOD;
            fire_cam(cam_clean, clk, '1');    -- rising edge -- cam_edge fires
            assert cam_cnt = to_unsigned(1, 8)
                report "FAIL T6: cam_cnt should be 1 after single cam pulse, cycle " &
                       integer'image(i) & " (got " & integer'image(to_integer(cam_cnt)) & ")"
                severity failure;

            fire_z(z_edge, clk);              -- 1st z -- count held
            fire_z(z_edge, clk);              -- 2nd z -- count resets
            assert cam_cnt = to_unsigned(0, 8)
                report "FAIL T6: cam_cnt did not reset after 2nd z, cycle " &
                       integer'image(i)
                severity failure;
        end loop;

        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;

        report "========================================";
        report "All cam tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor -- reports cam_edge strobes and count changes
    -- -------------------------------------------------------------------------
    p_monitor : process(cam_edge, cam_cnt)
    begin
        if cam_edge = '1' then
            report "EDGE: cam_edge fired  cnt=" &
                   integer'image(to_integer(cam_cnt)) &
                   "  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
