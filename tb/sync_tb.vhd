library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- sync_tb
--
-- Testbench for sync module.
-- Drives AB/Z and ref signals directly.
-- Tests all state transitions, AB counting, sync loss and phase fault.
-- =============================================================================

entity sync_tb is
end entity sync_tb;

architecture sim of sync_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 1000 ns;
    constant N_AB_PULSES  : integer := 30;

    constant TOOTH_PERIOD : time    := 1_000_000 ns;
    constant CYCLE_TIME   : time    := TOOTH_PERIOD * N_AB_PULSES;

    -- Sync state encoding (must match sync.vhd)
    constant ST_UNSYNC    : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRANK: std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL : std_logic_vector(2 downto 0) := "011";

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';
    signal ab               : std_logic := '0';
    signal z                : std_logic := '0';
    signal signal_present   : std_logic := '0';
    signal ref_detected     : std_logic := '0';
    signal sync_offset      : std_logic := '0';
    signal fault_clear      : std_logic := '0';
    signal sync_state       : std_logic_vector(2 downto 0);
    signal sync_loss_count  : unsigned(15 downto 0);
    signal phase_fault_count: unsigned(15 downto 0);
    signal phase_fault      : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done         : boolean   := false;
    signal test_num         : integer   := 0;
    signal test_step        : integer   := 0;
    signal crank_run        : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Generate one complete AB/Z cycle (N_AB_PULSES uniform AB edges, Z at start)
    -- No gap - simulates crank_input output with interpolation
    -- -------------------------------------------------------------------------
    procedure gen_cycle(
        signal ab_sig  : inout std_logic;
        signal z_sig   : out   std_logic;
        constant teeth : in    integer;
        constant period: in    time
    ) is
        constant t_half : time := period / 2;
    begin
        z_sig  <= '1';
        ab_sig <= not ab_sig; wait for t_half;
        ab_sig <= not ab_sig; wait for t_half;
        z_sig  <= '0';

        for i in 1 to teeth - 1 loop
            ab_sig <= not ab_sig; wait for t_half;
            ab_sig <= not ab_sig; wait for t_half;
        end loop;
    end procedure gen_cycle;

    procedure gen_ab(
        signal ab_sig   : inout std_logic;
        constant pulses : in    integer;
        constant period : in    time
    ) is
        constant t_half : time := period / 2;
    begin   
        for i in 1 to pulses - 1 loop
            ab_sig <= not ab_sig; wait for t_half;
            ab_sig <= not ab_sig; wait for t_half;
        end loop;
    end procedure gen_ab;

begin

    -- -------------------------------------------------------------------------
    -- Clock
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
    -- DUT
    -- -------------------------------------------------------------------------
    dut : entity work.sync
        generic map (
            CLK_FREQ_HZ => 1_000_000,
            N_AB_PULSES     => N_AB_PULSES
        )
        port map (
            clk               => clk,
            rst               => rst,
            ab                => ab,
            z                 => z,
            signal_present    => signal_present,
            ref_detected      => ref_detected,
            sync_offset       => sync_offset,
            fault_clear       => fault_clear,
            sync_state        => sync_state,
            sync_loss_count   => sync_loss_count,
            phase_fault_count => phase_fault_count,
            phase_fault       => phase_fault,
            ab_count_out      => open
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
        variable loss_count_start : integer;
        variable fault_count_start: integer;
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour - power up in UNSYNC
        -- --------------------------------------------------------------------
        report "TEST 1: Reset / power-up state";
        test_num <= 1;

        rst            <= '1';
        signal_present <= '0';
        ab             <= '0';
        z              <= '0';
        ref_detected   <= '0';
        fault_clear    <= '0';
        wait for 10 * CLK_PERIOD;
        rst <= '0';
        wait for 10 * CLK_PERIOD;

        assert sync_state = ST_UNSYNC
            report "FAIL T1: should be UNSYNC after reset"
            severity failure;
        assert phase_fault = '0'
            report "FAIL T1: phase_fault should be clear after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: UNSYNC → stays UNSYNC without signal_present
        -- Z pulse without signal_present should not advance state
        -- --------------------------------------------------------------------
        report "TEST 2: Z pulse without signal_present stays in UNSYNC";
        test_num <= 2;

        signal_present <= '0';
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_UNSYNC
            report "FAIL T2: should stay UNSYNC without signal_present"
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: UNSYNC → FIRST_GAP on first Z with signal_present
        -- --------------------------------------------------------------------
        report "TEST 3: UNSYNC to FIRST_GAP on first Z with signal_present";
        test_num <= 3;

        signal_present <= '1';

        -- Drive Z high for one cycle then check state
        z <= '1'; wait for CLK_PERIOD * 2;
        z <= '0'; wait for 5 * CLK_PERIOD;

        assert sync_state = ST_FIRST_GAP
            report "FAIL T3: should be FIRST_GAP after first Z with signal_present"
            severity failure;
        report "TEST 3: PASS";

        -- Reset for next test
        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: FIRST_GAP → SYNC_CRANK on correct AB count
        -- --------------------------------------------------------------------
        report "TEST 4: FIRST_GAP to SYNC_CRANK on correct AB count";
        test_num <= 4;
        test_step <= 1;
        signal_present <= '1';

        gen_ab(ab, 10, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        wait for 5 * CLK_PERIOD;

        test_step <= 2;

        assert sync_state = ST_FIRST_GAP
            report "FAIL T4 setup: should be in FIRST_GAP"
            severity failure;

        -- Second cycle: N_AB_PULSES AB edges then Z → SYNC_CRANK
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        --wait for 5 * CLK_PERIOD;

        test_step <= 3;

        assert sync_state = ST_SYNC_CRANK
            report "FAIL T4: should be SYNC_CRANK(2) after correct AB count, got " &
                   integer'image(to_integer(unsigned(sync_state)))
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: FIRST_GAP → stays FIRST_GAP on wrong AB count
        -- --------------------------------------------------------------------
        report "TEST 5: FIRST_GAP stays in FIRST_GAP on wrong AB count";
        test_num <= 5;
        test_step <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        signal_present <= '1';
        loss_count_start := to_integer(sync_loss_count);

        -- Two cycles: both with wrong AB count
        gen_cycle(ab, z, N_AB_PULSES-6, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES-25, TOOTH_PERIOD);
        
        test_step <= 2;

        assert sync_state = ST_FIRST_GAP
            report "FAIL T5: should stay in FIRST_GAP on wrong count"
            severity failure;
        assert to_integer(sync_loss_count) > loss_count_start
            report "FAIL T5: sync_loss_count should have incremented"
            severity failure;
        report "TEST 5: PASS - sync_loss_count = " &
               integer'image(to_integer(sync_loss_count));

        -- --------------------------------------------------------------------
        -- TEST 6: SYNC_CRANK → SYNC_FULL on ref_detected
        -- --------------------------------------------------------------------
        report "TEST 6: SYNC_CRANK to SYNC_FULL on ref_detected";
        test_num <= 6;
        test_step <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        signal_present <= '1';
        sync_offset    <= '0';

        -- Get to SYNC_CRANK
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        wait for 5 * CLK_PERIOD;

        test_step <= 2;

        assert sync_state = ST_SYNC_CRANK
            report "FAIL T6 setup: should be in SYNC_CRANK"
            severity failure;

        -- Send ref pulse
        ref_detected <= '1'; wait for CLK_PERIOD * 2;
        ref_detected <= '0';
        wait for 5 * CLK_PERIOD;

        test_step <= 3;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T6: should be SYNC_FULL after ref_detected"
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: SYNC_FULL with correct offset ref - no fault
        -- --------------------------------------------------------------------
        report "TEST 7: SYNC_FULL correct ref - no phase fault";
        test_num <= 7;

        -- Already in SYNC_FULL with locked_offset = '0'
        -- Send another ref with same offset
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        sync_offset  <= '0';
        ref_detected <= '1'; wait for CLK_PERIOD * 2;
        ref_detected <= '0';
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T7: should stay in SYNC_FULL"
            severity failure;
        assert phase_fault = '0'
            report "FAIL T7: phase_fault should not be set for correct ref"
            severity failure;
        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- TEST 8: SYNC_FULL with wrong offset ref - phase fault latches
        -- --------------------------------------------------------------------
        report "TEST 8: SYNC_FULL wrong ref offset - phase fault";
        test_num <= 8;

        fault_count_start := to_integer(phase_fault_count);

        -- Send ref with wrong offset
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        sync_offset  <= '1';   -- wrong, locked to '0'
        ref_detected <= '1'; wait for CLK_PERIOD * 2;
        ref_detected <= '0';
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T8: should stay in SYNC_FULL despite phase fault"
            severity failure;
        assert phase_fault = '1'
            report "FAIL T8: phase_fault should be set"
            severity failure;
        assert to_integer(phase_fault_count) > fault_count_start
            report "FAIL T8: phase_fault_count should have incremented"
            severity failure;
        report "TEST 8: PASS - phase_fault_count = " &
               integer'image(to_integer(phase_fault_count));

        -- --------------------------------------------------------------------
        -- TEST 9: fault_clear clears phase_fault
        -- --------------------------------------------------------------------
        report "TEST 9: fault_clear clears phase_fault";
        test_num <= 9;

        fault_clear <= '1'; wait for CLK_PERIOD * 2;
        fault_clear <= '0';
        wait for 5 * CLK_PERIOD;

        assert phase_fault = '0'
            report "FAIL T9: phase_fault should be cleared"
            severity failure;
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- TEST 10: signal_present loss returns to UNSYNC from SYNC_FULL
        -- --------------------------------------------------------------------
        report "TEST 10: signal_present loss returns to UNSYNC";
        test_num <= 10;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T10 setup: should be in SYNC_FULL"
            severity failure;

        signal_present <= '0';
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_UNSYNC
            report "FAIL T10: should be UNSYNC on signal_present loss"
            severity failure;
        report "TEST 10: PASS";

        -- --------------------------------------------------------------------
        -- TEST 11: Wrong AB count in SYNC_FULL → UNSYNC, sync_loss increments
        -- --------------------------------------------------------------------
        report "TEST 11: Wrong AB count in SYNC_FULL causes UNSYNC";
        test_num <= 11;
        test_step <= 1;

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        signal_present <= '1';
        sync_offset    <= '0';

        -- Get to SYNC_FULL
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        ref_detected <= '1'; wait for CLK_PERIOD * 2;
        ref_detected <= '0';
        wait for 5 * CLK_PERIOD;

        test_step <= 2;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T11 setup: should be in SYNC_FULL"
            severity failure;

        loss_count_start := to_integer(sync_loss_count);

        -- Send cycle with wrong AB count
        gen_cycle(ab, z, N_AB_PULSES - 6, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES - 25, TOOTH_PERIOD);
        
        test_step <= 3;

        assert sync_state = ST_UNSYNC
            report "FAIL T11: should be UNSYNC after wrong AB count"
            severity failure;
        assert to_integer(sync_loss_count) > loss_count_start
            report "FAIL T11: sync_loss_count should have incremented"
            severity failure;
        report "TEST 11: PASS - sync_loss_count = " &
               integer'image(to_integer(sync_loss_count));

        -- --------------------------------------------------------------------
        -- TEST 12: Full reacquisition after sync loss
        -- --------------------------------------------------------------------
        report "TEST 12: Full reacquisition after sync loss";
        test_num <= 12;

        -- Should be in UNSYNC from test 11
        assert sync_state = ST_UNSYNC
            report "FAIL T12 setup: should be in UNSYNC"
            severity failure;

        sync_offset <= '0';

        -- Reacquire: two good cycles then ref
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_SYNC_CRANK
            report "FAIL T12: should be SYNC_CRANK after reacquisition"
            severity failure;

        ref_detected <= '1'; wait for CLK_PERIOD * 2;
        ref_detected <= '0';
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T12: should reach SYNC_FULL after reacquisition"
            severity failure;
        report "TEST 12: PASS";

        -- --------------------------------------------------------------------
        -- TEST 13: Phase offset '1' (other revolution) also reaches SYNC_FULL
        -- --------------------------------------------------------------------
        report "TEST 13: sync_offset = 1 reaches SYNC_FULL";
        test_num <= 13;

        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0';
        signal_present <= '1';
        sync_offset    <= '1';   -- other revolution

        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        gen_cycle(ab, z, N_AB_PULSES, TOOTH_PERIOD);
        ref_detected <= '1'; wait for CLK_PERIOD * 2;
        ref_detected <= '0';
        wait for 5 * CLK_PERIOD;

        assert sync_state = ST_SYNC_FULL
            report "FAIL T13: should reach SYNC_FULL with sync_offset = 1"
            severity failure;
        report "TEST 13: PASS";

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

end architecture sim;