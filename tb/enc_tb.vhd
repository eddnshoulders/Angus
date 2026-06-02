library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity enc_tb is
end entity enc_tb;

architecture sim of enc_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD : time    := 10 ns;   -- 100 MHz
    constant N_PPR_C    : integer := 100;

    -- -------------------------------------------------------------------------
    -- DUT signals
    -- -------------------------------------------------------------------------
    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal a_clean  : std_logic := '0';
    signal b_clean  : std_logic := '0';
    signal z_clean  : std_logic := '0';
    signal ab_sel   : unsigned(1 downto 0) := "00";   -- 0=rising, 1=falling, 2=both
    signal z_sel    : std_logic := '0';               -- 0=rising
    signal n_ppr    : unsigned(15 downto 0) := to_unsigned(N_PPR_C, 16);
    signal ab_edge  : std_logic;
    signal z_edge   : std_logic;
    signal ppr_conf : unsigned(7 downto 0);
    signal ab_period: unsigned(31 downto 0);
    signal ab_count : unsigned(7 downto 0);
    signal a_count  : unsigned(7 downto 0);
    signal b_count  : unsigned(7 downto 0);
    signal sig_ok   : std_logic;
    signal fault_cnt: unsigned(7 downto 0);

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done : boolean := false;
    signal test_num : integer := 0;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock rising edge on the given channel
    -- -------------------------------------------------------------------------
    procedure fire_rising(
        signal   ch  : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        ch <= '1';
        wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_rising;

    -- -------------------------------------------------------------------------
    -- Fire a 1-clock falling edge on the given channel
    -- -------------------------------------------------------------------------
    procedure fire_falling(
        signal   ch  : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        ch <= '0';
        wait until rising_edge(c);
        wait for 1 ns;
    end procedure fire_falling;

    -- -------------------------------------------------------------------------
    -- Fire a z pulse (rising edge)
    -- -------------------------------------------------------------------------
    procedure fire_z(
        signal   z   : out std_logic;
        signal   c   : in  std_logic
    ) is
    begin
        z <= '1';
        wait until rising_edge(c);
        z <= '0';
        wait until rising_edge(c);
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
    dut : entity work.enc
        port map (
            clk           => clk,
            rst           => rst,
            a_clean       => a_clean,
            b_clean       => b_clean,
            z_clean       => z_clean,
            enc_ab_edge_sel => ab_sel,
            enc_z_edge_sel  => z_sel,
            enc_n_ppr       => n_ppr,
            enc_ab_edge     => ab_edge,
            enc_z_edge      => z_edge,
            enc_ppr_conf    => ppr_conf,
            enc_ab_period   => ab_period,
            enc_ab_count    => ab_count,
            enc_a_count     => a_count,
            enc_b_count     => b_count,
            enc_signal_ok   => sig_ok,
            enc_fault_count => fault_cnt
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset behaviour
        -- --------------------------------------------------------------------
        report "TEST 1: Reset behaviour";
        test_num <= 1;

        rst <= '1';
        wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait for 2 * CLK_PERIOD;
        wait for 1 ns;

        assert ab_edge = '0'
            report "FAIL T1: ab_edge should be low after reset"
            severity failure;
        assert ab_count = to_unsigned(0, 8)
            report "FAIL T1: ab_count should be zero after reset"
            severity failure;

        report "TEST 1: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: ppr_conf is lower 8 bits of enc_n_ppr
        -- --------------------------------------------------------------------
        report "TEST 2: ppr_conf passthrough";
        test_num <= 2;

        assert ppr_conf = to_unsigned(N_PPR_C, 8)
            report "FAIL T2: ppr_conf wrong: " &
                   integer'image(to_integer(ppr_conf)) &
                   " expected " & integer'image(N_PPR_C)
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Rising edge on A fires ab_edge (ab_sel=0 rising)
        -- ab_edge is a 1-clock strobe; falling edge of A must be ignored
        -- --------------------------------------------------------------------
        report "TEST 3: A rising edge detected, 1-clock strobe, A falling ignored";
        test_num <= 3;

        ab_sel <= "00";   -- rising edge
        fire_rising(a_clean, clk);
        assert ab_edge = '1'
            report "FAIL T3: ab_edge not fired on A rising"
            severity failure;

        wait until rising_edge(clk);
        wait for 1 ns;
        assert ab_edge = '0'
            report "FAIL T3: ab_edge not a 1-clock strobe"
            severity failure;

        fire_falling(a_clean, clk);   -- falling -- should be ignored with ab_sel=0
        assert ab_edge = '0'
            report "FAIL T3: A falling triggered ab_edge with ab_sel=rising"
            severity failure;

        report "TEST 3: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Rising edge on B also fires ab_edge
        -- --------------------------------------------------------------------
        report "TEST 4: B rising edge fires ab_edge";
        test_num <= 4;

        fire_rising(b_clean, clk);
        assert ab_edge = '1'
            report "FAIL T4: ab_edge not fired on B rising"
            severity failure;
        b_clean <= '0';

        report "TEST 4: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: ab_sel=both fires on rising AND falling edges
        -- --------------------------------------------------------------------
        report "TEST 5: ab_sel=both fires on rising and falling";
        test_num <= 5;

        ab_sel <= "10";   -- both edges

        fire_rising(a_clean, clk);    -- rising -- should fire
        assert ab_edge = '1'
            report "FAIL T5: ab_edge not fired on A rising with ab_sel=both"
            severity failure;

        wait until rising_edge(clk);
        wait for 1 ns;
        fire_falling(a_clean, clk);   -- falling -- should also fire
        assert ab_edge = '1'
            report "FAIL T5: ab_edge not fired on A falling with ab_sel=both"
            severity failure;

        ab_sel <= "00";   -- restore rising
        report "TEST 5: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: a_count and b_count track independently
        -- a_count increments only on A edges; b_count only on B edges
        -- --------------------------------------------------------------------
        report "TEST 6: a_count and b_count track independently";
        test_num <= 6;

        -- Reset to get clean counts
        rst <= '1'; wait for 3 * CLK_PERIOD; rst <= '0';
        wait for 2 * CLK_PERIOD;
        ab_sel <= "00";   -- rising

        -- Fire 3 A edges
        fire_rising(a_clean, clk); a_clean <= '0'; wait for CLK_PERIOD;
        fire_rising(a_clean, clk); a_clean <= '0'; wait for CLK_PERIOD;
        fire_rising(a_clean, clk); a_clean <= '0'; wait for CLK_PERIOD;

        -- Fire 2 B edges
        fire_rising(b_clean, clk); b_clean <= '0'; wait for CLK_PERIOD;
        fire_rising(b_clean, clk); b_clean <= '0'; wait for CLK_PERIOD;

        wait for 1 ns;
        assert a_count = to_unsigned(3, 8)
            report "FAIL T6: a_count wrong: " &
                   integer'image(to_integer(a_count)) & " expected 3"
            severity failure;
        assert b_count = to_unsigned(2, 8)
            report "FAIL T6: b_count wrong: " &
                   integer'image(to_integer(b_count)) & " expected 2"
            severity failure;
        assert ab_count = to_unsigned(5, 8)
            report "FAIL T6: ab_count wrong: " &
                   integer'image(to_integer(ab_count)) & " expected 5"
            severity failure;

        report "TEST 6: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: z_edge (rising) resets ab_count, a_count, b_count to zero
        -- --------------------------------------------------------------------
        report "TEST 7: z_edge resets all counts";
        test_num <= 7;

        z_sel <= '0';   -- rising z edge
        -- Check z_edge BEFORE z_clean goes low (it's a 1-clock strobe)
        z_clean <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        assert z_edge = '1'
            report "FAIL T7: z_edge not fired on z_clean rising"
            severity failure;
        z_clean <= '0';
        wait until rising_edge(clk); wait for 1 ns;
        assert z_edge = '0'
            report "FAIL T7: z_edge not a 1-clock strobe"
            severity failure;
        assert ab_count = to_unsigned(0, 8)
            report "FAIL T7: ab_count not reset on z_edge: " &
                   integer'image(to_integer(ab_count))
            severity failure;
        assert a_count = to_unsigned(0, 8)
            report "FAIL T7: a_count not reset on z_edge"
            severity failure;
        assert b_count = to_unsigned(0, 8)
            report "FAIL T7: b_count not reset on z_edge"
            severity failure;

        report "TEST 7: PASS";
        wait for 3 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 8: z_sel=falling, z fires on falling edge of z_clean
        -- --------------------------------------------------------------------
        -- TEST 9: ab_period updates correctly after two edges with known spacing
        -- Note: enc_fault_count is a placeholder always returning 0 (not yet
        -- implemented). ab_period measurement is tested instead.
        -- --------------------------------------------------------------------
        report "TEST 9: ab_period updates after two ab_edges";
        test_num <= 9;

        rst <= '1'; wait for 3 * CLK_PERIOD; rst <= '0';
        wait for 2 * CLK_PERIOD;
        ab_sel <= "00";   -- rising edge

        -- Fire two rising edges with a known 20-clock gap
        fire_rising(a_clean, clk);
        a_clean <= '0';
        wait for 20 * CLK_PERIOD;
        fire_rising(a_clean, clk);
        a_clean <= '0';
        wait for 3 * CLK_PERIOD;
        wait for 1 ns;

        assert to_integer(ab_period) >= 18 and to_integer(ab_period) <= 22
            report "FAIL T9: ab_period wrong: " &
                   integer'image(to_integer(ab_period)) & " expected ~20"
            severity failure;
        report "TEST 9: PASS - ab_period = " &
               integer'image(to_integer(ab_period));

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All enc tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

    -- -------------------------------------------------------------------------
    -- Monitor
    -- -------------------------------------------------------------------------
    p_monitor : process(ab_edge, z_edge)
    begin
        if ab_edge = '1' then
            report "AB_EDGE: a=" & std_logic'image(a_clean) &
                   " b=" & std_logic'image(b_clean) &
                   " ab_cnt=" & integer'image(to_integer(ab_count)) &
                   " test=" & integer'image(test_num);
        end if;
        if z_edge = '1' then
            report "Z_EDGE  test=" & integer'image(test_num);
        end if;
    end process p_monitor;

end architecture sim;
