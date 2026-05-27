library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity sync_tb is
end entity sync_tb;

architecture sim of sync_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant N_TEETH    : integer := 60;

    signal clk              : std_logic := '0';
    signal rst              : std_logic := '1';
    signal sim_done         : boolean   := false;
    signal test_num         : integer   := 0;

    signal ab               : std_logic := '0';
    signal z                : std_logic := '0';
    signal signal_present   : std_logic := '0';
    signal ref_detected     : std_logic := '0';
    signal phase_offset     : std_logic := '0';
    signal n_teeth_s        : unsigned(7 downto 0) := to_unsigned(N_TEETH, 8);
    signal fault_clear      : std_logic := '0';
    signal phase_fault_drop : std_logic := '0';

    signal sync_state       : std_logic_vector(2 downto 0);
    signal synced           : std_logic;
    signal phase_engine     : std_logic;
    signal sync_loss_count  : unsigned(15 downto 0);
    signal phase_fault_count: unsigned(15 downto 0);
    signal phase_fault      : std_logic;
    signal ab_count_out     : unsigned(7 downto 0);
    signal z_count_out      : unsigned(15 downto 0);

    constant ST_UNSYNC      : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP   : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRANK  : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL   : std_logic_vector(2 downto 0) := "011";

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.sync
        port map (
            clk               => clk,
            rst               => rst,
            ab                => ab,
            z                 => z,
            signal_present    => signal_present,
            ref_detected      => ref_detected,
            phase_offset      => phase_offset,
            n_teeth           => n_teeth_s,
            fault_clear       => fault_clear,
            phase_fault_drop  => phase_fault_drop,
            sync_state        => sync_state,
            synced            => synced,
            phase_engine      => phase_engine,
            sync_loss_count   => sync_loss_count,
            phase_fault_count => phase_fault_count,
            phase_fault       => phase_fault,
            ab_count_out      => ab_count_out,
            z_count_out       => z_count_out
        );

    p_stim : process

        -- Fire N_TEETH AB edges then a Z pulse (one full revolution)
        procedure do_revolution(n : integer; good_count : boolean) is
        begin
            for i in 1 to n loop
                ab <= not ab;
                wait for CLK_PERIOD;
            end loop;
            -- Z pulse
            z <= '1'; wait for CLK_PERIOD; z <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- Fire ref_detected pulse with given phase_offset
        procedure fire_ref(ph : std_logic) is
        begin
            phase_offset  <= ph;
            ref_detected  <= '1';
            wait for CLK_PERIOD;
            ref_detected  <= '0';
            wait for CLK_PERIOD;
        end procedure;

    begin

        -- T1: Reset
        test_num <= 1;
        report "TEST 1: Reset - UNSYNC";
        rst <= '1'; wait for 20 * CLK_PERIOD; rst <= '0'; wait for 5 * CLK_PERIOD;
        assert sync_state = ST_UNSYNC report "FAIL T1: should be UNSYNC" severity failure;
        assert synced = '0'           report "FAIL T1: synced should be 0" severity failure;
        assert phase_engine = '0'     report "FAIL T1: phase_engine should be 0" severity failure;
        report "TEST 1: PASS";

        -- T2: UNSYNC -> FIRST_GAP on first Z with signal_present
        test_num <= 2;
        report "TEST 2: UNSYNC -> FIRST_GAP";
        signal_present <= '1';
        z <= '1'; wait for CLK_PERIOD; z <= '0'; wait for CLK_PERIOD;
        assert sync_state = ST_FIRST_GAP
            report "FAIL T2: should be FIRST_GAP" severity failure;
        report "TEST 2: PASS";

        -- T3: FIRST_GAP -> SYNC_CRANK after correct AB count
        test_num <= 3;
        report "TEST 3: FIRST_GAP -> SYNC_CRANK";
        do_revolution(N_TEETH, true);
        assert sync_state = ST_SYNC_CRANK
            report "FAIL T3: should be SYNC_CRANK, got " &
                   integer'image(to_integer(unsigned(sync_state))) severity failure;
        report "TEST 3: PASS";

        -- T4: SYNC_CRANK maintained over multiple revolutions
        test_num <= 4;
        report "TEST 4: SYNC_CRANK maintained";
        do_revolution(N_TEETH, true);
        do_revolution(N_TEETH, true);
        assert sync_state = ST_SYNC_CRANK
            report "FAIL T4: should still be SYNC_CRANK" severity failure;
        report "TEST 4: PASS";

        -- T5: SYNC_CRANK -> SYNC_FULL on ref_detected (phase_offset=0)
        test_num <= 5;
        report "TEST 5: SYNC_CRANK -> SYNC_FULL (phase_offset=0)";
        fire_ref('0');
        assert sync_state = ST_SYNC_FULL
            report "FAIL T5: should be SYNC_FULL" severity failure;
        assert synced = '1'
            report "FAIL T5: synced should be 1" severity failure;
        assert phase_engine = '0'
            report "FAIL T5: phase_engine should be 0 (Band A)" severity failure;
        report "TEST 5: PASS";

        -- T6: phase_engine toggles on each Z pulse in SYNC_FULL
        test_num <= 6;
        report "TEST 6: phase_engine toggles on Z";
        -- Do a full revolution (N_TEETH ab edges then Z)
        do_revolution(N_TEETH, true);
        wait for 2 * CLK_PERIOD;
        assert phase_engine = '1'
            report "FAIL T6: phase_engine should be 1 after first Z" severity failure;
        do_revolution(N_TEETH, true);
        wait for 2 * CLK_PERIOD;
        assert phase_engine = '0'
            report "FAIL T6: phase_engine should toggle back to 0" severity failure;
        report "TEST 6: PASS";

        -- T7: z_count increments
        test_num <= 7;
        report "TEST 7: z_count increments";
        -- Already seen multiple Z pulses - check count is > 0
        assert to_integer(z_count_out) > 3
            report "FAIL T7: z_count should be > 3" severity failure;
        report "TEST 7: PASS - z_count = " & integer'image(to_integer(z_count_out));

        -- T8: SYNC_FULL maintained over correct revolutions
        test_num <= 8;
        report "TEST 8: SYNC_FULL maintained";
        do_revolution(N_TEETH, true);
        do_revolution(N_TEETH, true);
        assert sync_state = ST_SYNC_FULL
            report "FAIL T8: should remain SYNC_FULL" severity failure;
        report "TEST 8: PASS";

        -- T9: Wrong AB count in SYNC_FULL -> UNSYNC
        test_num <= 9;
        report "TEST 9: Wrong AB count in SYNC_FULL -> UNSYNC";
        do_revolution(N_TEETH - 5, true);  -- wrong count
        assert sync_state = ST_UNSYNC
            report "FAIL T9: should be UNSYNC after wrong count" severity failure;
        assert to_integer(sync_loss_count) > 0
            report "FAIL T9: sync_loss_count should have incremented" severity failure;
        report "TEST 9: PASS";

        -- T10: Reacquisition after sync loss
        test_num <= 10;
        report "TEST 10: Reacquisition after sync loss";
        z <= '1'; wait for CLK_PERIOD; z <= '0'; wait for CLK_PERIOD;
        assert sync_state = ST_FIRST_GAP
            report "FAIL T10: should be FIRST_GAP" severity failure;
        do_revolution(N_TEETH, true);
        assert sync_state = ST_SYNC_CRANK
            report "FAIL T10: should reacquire SYNC_CRANK" severity failure;
        fire_ref('1');  -- this time phase_offset=1
        assert sync_state = ST_SYNC_FULL
            report "FAIL T10: should reacquire SYNC_FULL" severity failure;
        assert phase_engine = '1'
            report "FAIL T10: phase_engine should be 1 (Band B this time)" severity failure;
        report "TEST 10: PASS";

        -- T11: signal_present=0 drops to UNSYNC
        test_num <= 11;
        report "TEST 11: signal_present=0 drops to UNSYNC";
        signal_present <= '0';
        wait for 2 * CLK_PERIOD;
        assert sync_state = ST_UNSYNC
            report "FAIL T11: should be UNSYNC" severity failure;
        report "TEST 11: PASS";

        -- T12: fault_clear clears phase_fault
        test_num <= 12;
        report "TEST 12: fault_clear clears phase_fault";
        -- Get back to SYNC_FULL
        signal_present <= '1';
        z <= '1'; wait for CLK_PERIOD; z <= '0'; wait for CLK_PERIOD;
        do_revolution(N_TEETH, true);
        fire_ref('0');  -- locked_phase = 0
        assert sync_state = ST_SYNC_FULL severity failure;
        -- Fire ref with wrong phase_offset
        fire_ref('1');
        wait for 2 * CLK_PERIOD;
        assert phase_fault = '1'
            report "FAIL T12: phase_fault should be set" severity failure;
        -- Clear it
        fault_clear <= '1'; wait for CLK_PERIOD; fault_clear <= '0';
        wait for 2 * CLK_PERIOD;
        assert phase_fault = '0'
            report "FAIL T12: phase_fault should be cleared" severity failure;
        report "TEST 12: PASS";

        -- T13: n_teeth runtime configurable (36 teeth)
        test_num <= 13;
        report "TEST 13: n_teeth=36 runtime configurable";
        rst <= '1'; wait for 5 * CLK_PERIOD; rst <= '0'; wait for 2 * CLK_PERIOD;
        n_teeth_s      <= to_unsigned(36, 8);
        signal_present <= '1';
        z <= '1'; wait for CLK_PERIOD; z <= '0'; wait for CLK_PERIOD;
        assert sync_state = ST_FIRST_GAP severity failure;
        do_revolution(36, true);
        assert sync_state = ST_SYNC_CRANK
            report "FAIL T13: should be SYNC_CRANK with 36 teeth" severity failure;
        report "TEST 13: PASS";

        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All sync tests complete";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;
