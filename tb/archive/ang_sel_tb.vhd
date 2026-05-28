library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- ang_sel_tb
--
-- Checks that ang_sel correctly routes all 5 signals for both sel values.
-- sel=0: crank inputs pass through
-- sel=1: enc inputs pass through
-- =============================================================================

entity ang_sel_tb is end entity;

architecture sim of ang_sel_tb is

    -- Crank stimulus
    constant CRANK_AB         : std_logic                      := '1';
    constant CRANK_Z          : std_logic                      := '0';
    constant CRANK_AB_PERIOD  : unsigned(31 downto 0)          := to_unsigned(12345, 32);
    constant CRANK_PPR        : unsigned(7 downto 0)           := to_unsigned(60, 8);
    constant CRANK_AB_COUNT   : unsigned(7 downto 0)           := to_unsigned(42, 8);
    constant CRANK_SIG_PRES   : std_logic                      := '1';

    -- Encoder stimulus (distinct values)
    constant ENC_AB           : std_logic                      := '0';
    constant ENC_Z            : std_logic                      := '1';
    constant ENC_AB_PERIOD    : unsigned(31 downto 0)          := to_unsigned(67890, 32);
    constant ENC_PPR          : unsigned(7 downto 0)           := to_unsigned(36, 8);
    constant ENC_AB_COUNT     : unsigned(7 downto 0)           := to_unsigned(18, 8);
    constant ENC_SIG_PRES     : std_logic                      := '0';

    -- DUT outputs
    signal sel            : std_logic := '0';
    signal ab             : std_logic;
    signal z              : std_logic;
    signal ab_period      : unsigned(31 downto 0);
    signal ppr            : unsigned(7 downto 0);
    signal ab_count       : unsigned(7 downto 0);
    signal signal_present : std_logic;

begin

    u_dut : entity work.ang_sel
        port map (
            sel                  => sel,
            crank_ab             => CRANK_AB,
            crank_z              => CRANK_Z,
            crank_ab_period      => CRANK_AB_PERIOD,
            crank_ppr            => CRANK_PPR,
            crank_ab_count       => CRANK_AB_COUNT,
            crank_signal_present => CRANK_SIG_PRES,
            enc_ab               => ENC_AB,
            enc_z                => ENC_Z,
            enc_ab_period        => ENC_AB_PERIOD,
            enc_ppr              => ENC_PPR,
            enc_ab_count         => ENC_AB_COUNT,
            enc_signal_present   => ENC_SIG_PRES,
            ab                   => ab,
            z                    => z,
            ab_period            => ab_period,
            ppr                  => ppr,
            ab_count             => ab_count,
            signal_present       => signal_present
        );

    p_stim : process
    begin
        -- ------------------------------------------------------------------
        -- sel=0: all crank values should appear on outputs
        -- ------------------------------------------------------------------
        sel <= '0';
        wait for 10 ns;

        assert ab             = CRANK_AB
            report "FAIL sel=0: ab should be CRANK_AB"         severity failure;
        assert z              = CRANK_Z
            report "FAIL sel=0: z should be CRANK_Z"           severity failure;
        assert ab_period      = CRANK_AB_PERIOD
            report "FAIL sel=0: ab_period should be CRANK_AB_PERIOD" severity failure;
        assert ppr            = CRANK_PPR
            report "FAIL sel=0: ppr should be CRANK_PPR"       severity failure;
        assert ab_count       = CRANK_AB_COUNT
            report "FAIL sel=0: ab_count should be CRANK_AB_COUNT" severity failure;
        assert signal_present = CRANK_SIG_PRES
            report "FAIL sel=0: signal_present should be CRANK_SIG_PRES" severity failure;

        report "PASS sel=0: all crank signals routed correctly";

        -- ------------------------------------------------------------------
        -- sel=1: all enc values should appear on outputs
        -- ------------------------------------------------------------------
        sel <= '1';
        wait for 10 ns;

        assert ab             = ENC_AB
            report "FAIL sel=1: ab should be ENC_AB"           severity failure;
        assert z              = ENC_Z
            report "FAIL sel=1: z should be ENC_Z"             severity failure;
        assert ab_period      = ENC_AB_PERIOD
            report "FAIL sel=1: ab_period should be ENC_AB_PERIOD" severity failure;
        assert ppr            = ENC_PPR
            report "FAIL sel=1: ppr should be ENC_PPR"         severity failure;
        assert ab_count       = ENC_AB_COUNT
            report "FAIL sel=1: ab_count should be ENC_AB_COUNT" severity failure;
        assert signal_present = ENC_SIG_PRES
            report "FAIL sel=1: signal_present should be ENC_SIG_PRES" severity failure;

        report "PASS sel=1: all enc signals routed correctly";

        -- ------------------------------------------------------------------
        -- Switch back to sel=0 to confirm no latching
        -- ------------------------------------------------------------------
        sel <= '0';
        wait for 10 ns;

        assert ab        = CRANK_AB
            report "FAIL sel=0 return: ab should be CRANK_AB"  severity failure;
        assert ppr       = CRANK_PPR
            report "FAIL sel=0 return: ppr should be CRANK_PPR" severity failure;

        report "PASS sel=0 return: mux switches back correctly";
        report "==============================";
        report "All ang_sel tests PASS";
        report "==============================";

        std.env.stop;
        wait;
    end process p_stim;

end architecture sim;
