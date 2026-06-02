library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity sync_tb is
end entity sync_tb;

architecture sim of sync_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- States: 0=STOPPED, 1=MOVING, 2=CRANK_SYNC, 3=FULL_SYNC
    -- Transition rules:
    --   STOPPED -> MOVING on first ab_edge
    --   MOVING  -> CRANK_SYNC on 2nd z_edge with ab_count = ppr_conf
    --   MOVING  -> stays MOVING on 2nd z_edge if ab_count wrong (fault++)
    --   CRANK_SYNC -> FULL_SYNC when phase_ref_found='1'
    --   Any state -> STOPPED on rst
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time    := 10 ns;
    constant PPR        : integer := 60;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal ab_edge   : std_logic := '0';
    signal z_edge    : std_logic := '0';
    signal ppr_conf  : unsigned(7 downto 0) := to_unsigned(PPR, 8);
    signal ab_count  : unsigned(7 downto 0) := to_unsigned(PPR, 8);
    signal ref_found : std_logic := '0';
    signal sync_state: unsigned(1 downto 0);
    signal sync_full : std_logic;
    signal fault_cnt : unsigned(15 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock strobe
    -- -------------------------------------------------------------------------
    procedure pulse(
        signal   s   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        s <= '1'; wait until rising_edge(c);
        s <= '0'; wait until rising_edge(c);
    end procedure pulse;

    -- -------------------------------------------------------------------------
    -- Fire z_edge with ab_count pre-set one cycle before (sync registers ab_count)
    -- -------------------------------------------------------------------------
    procedure fire_z_good(
        signal   z       : out std_logic;
        signal   ab_cnt  : out unsigned(7 downto 0);
        signal   c   : in  std_logic;
        constant cnt_val : in  integer
    ) is
    begin
        ab_cnt <= to_unsigned(cnt_val, 8);
        wait until rising_edge(c);   -- let ab_count_r register
        z <= '1'; wait until rising_edge(c);
        z <= '0'; wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_z_good;

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
    dut : entity work.sync
        port map (
            clk             => clk,
            rst             => rst,
            ab_edge         => ab_edge,
            z_edge          => z_edge,
            ppr_conf        => ppr_conf,
            ab_count        => ab_count,
            phase_ref_found => ref_found,
            sync_state      => sync_state,
            sync_full       => sync_full,
            sync_fault_count => fault_cnt
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: STOPPED state after reset
        -- --------------------------------------------------------------------
        report "TEST 1: STOPPED state after reset";
        test_num <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(sync_state) = 0
            report "FAIL T1: should be STOPPED (0), got " &
                   integer'image(to_integer(sync_state))
            severity failure;
        assert sync_full = '0'
            report "FAIL T1: sync_full should be 0 in STOPPED"
            severity failure;

        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: STOPPED -> MOVING on first ab_edge
        -- --------------------------------------------------------------------
        report "TEST 2: STOPPED -> MOVING on first ab_edge";
        test_num <= 2;

        pulse(ab_edge, clk);
        wait for CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(sync_state) = 1
            report "FAIL T2: should be MOVING (1), got " &
                   integer'image(to_integer(sync_state))
            severity failure;

        report "TEST 2: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: MOVING -- z_edge alone does not leave MOVING state
        -- Only the 2nd z_edge with correct ab_count causes the transition
        -- --------------------------------------------------------------------
        report "TEST 3: First z_edge does not leave MOVING";
        test_num <= 3;

        fire_z_good(z_edge, ab_count, clk, PPR);
        assert to_integer(sync_state) = 1
            report "FAIL T3: should still be MOVING after 1st z_edge, got " &
                   integer'image(to_integer(sync_state))
            severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: MOVING -> CRANK_SYNC on 2nd z_edge with correct ab_count
        -- ab_count must be set one cycle before z_edge (registered in sync)
        -- --------------------------------------------------------------------
        report "TEST 4: MOVING -> CRANK_SYNC on 2nd z_edge with correct ab_count";
        test_num <= 4;

        fire_z_good(z_edge, ab_count, clk, PPR);
        assert to_integer(sync_state) = 2
            report "FAIL T4: should be CRANK_SYNC (2), got " &
                   integer'image(to_integer(sync_state))
            severity failure;

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: Wrong ab_count at z_edge increments fault_count
        -- and stays in CRANK_SYNC (does not drop back to MOVING)
        -- --------------------------------------------------------------------
        report "TEST 5: Wrong ab_count at z_edge increments fault_count";
        test_num <= 5;

        fire_z_good(z_edge, ab_count, clk, 45);   -- wrong count
        wait for 1 ns;

        assert to_integer(fault_cnt) = 1
            report "FAIL T5: fault_cnt wrong: " &
                   integer'image(to_integer(fault_cnt)) & " expected 1"
            severity failure;
        assert to_integer(sync_state) = 2
            report "FAIL T5: should stay in CRANK_SYNC after one bad count"
            severity failure;

        -- Correct count should not fault
        fire_z_good(z_edge, ab_count, clk, PPR);
        assert to_integer(fault_cnt) = 1
            report "FAIL T5: fault_cnt incremented on correct ab_count"
            severity failure;

        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: CRANK_SYNC -> FULL_SYNC when phase_ref_found='1'
        -- --------------------------------------------------------------------
        report "TEST 6: CRANK_SYNC -> FULL_SYNC on phase_ref_found";
        test_num <= 6;

        assert sync_full = '0'
            report "FAIL T6: sync_full should be 0 in CRANK_SYNC"
            severity failure;

        ref_found <= '1';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(sync_state) = 3
            report "FAIL T6: should be FULL_SYNC (3), got " &
                   integer'image(to_integer(sync_state))
            severity failure;
        assert sync_full = '1'
            report "FAIL T6: sync_full should be 1 in FULL_SYNC"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: FULL_SYNC stays with correct z_edges; no additional faults
        -- --------------------------------------------------------------------
        report "TEST 7: FULL_SYNC maintained with correct z_edges";
        test_num <= 7;

        fire_z_good(z_edge, ab_count, clk, PPR);
        fire_z_good(z_edge, ab_count, clk, PPR);
        wait for 1 ns;

        assert to_integer(sync_state) = 3
            report "FAIL T7: should stay in FULL_SYNC, got " &
                   integer'image(to_integer(sync_state))
            severity failure;
        assert to_integer(fault_cnt) = 1   -- still 1 from T5
            report "FAIL T7: fault_cnt changed unexpectedly"
            severity failure;

        report "TEST 7: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 8: Reset returns to STOPPED from any state
        -- --------------------------------------------------------------------
        report "TEST 8: Reset returns to STOPPED from FULL_SYNC";
        test_num <= 8;

        rst <= '1'; wait for 3 * CLK_PERIOD;
        rst <= '0'; wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(sync_state) = 0
            report "FAIL T8: should be STOPPED after reset, got " &
                   integer'image(to_integer(sync_state))
            severity failure;
        assert sync_full = '0'
            report "FAIL T8: sync_full should be 0 after reset"
            severity failure;
        assert to_integer(fault_cnt) = 0
            report "FAIL T8: fault_cnt should clear on reset"
            severity failure;

        report "TEST 8: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All sync tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(sync_state)
        constant states : string := "STOPPED MOVING  CRANK_S FULL_SY";
    begin
        report "STATE -> " & integer'image(to_integer(sync_state)) &
               "  sync_full=" & std_logic'image(sync_full) &
               "  fault=" & integer'image(to_integer(fault_cnt)) &
               "  test=" & integer'image(test_num);
    end process p_monitor;

end architecture sim;
