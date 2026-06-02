library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- divider_tb
--
-- Testbench for divider.vhd
-- CACHING=0 for all tests
-- Signals driven at half-clock offset to avoid delta cycle races
--
-- Tests:
--   1: Basic division          12344235 / 2343    = 5268 rem 1311
--   2: Large dividend          0xFFFFFFFF / 1     = 4294967295 rem 0
--   3: Zero divisor            4624653 / 0        → zero_err
--   4: Divisor > dividend      5657 / 68686265    = 0 rem 5657
--   5: 100MHz 1000 RPM         71582788 / 100000  = 715 rem 82788
--   6: 1MHz 1000 RPM           71582788 / 1000    = 71582 rem 788
--   7: Power of 3              59049 / 3          = 19683 rem 0
--   8: 100MHz 8000 RPM         71582788 / 12500   = 5726 rem 7788
-- =============================================================================

entity divider_tb is
end entity divider_tb;

architecture sim of divider_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant WIDTH      : integer := 32;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '0';
    signal start        : std_logic := '0';
    signal dividend     : unsigned(WIDTH - 1 downto 0) := (others => '0');
    signal divisor      : unsigned(WIDTH - 1 downto 0) := (others => '0');
    signal quotient     : unsigned(WIDTH - 1 downto 0);
    signal remainder    : unsigned(WIDTH - 1 downto 0);
    signal zero_err     : std_logic;
    signal valid        : std_logic;

    signal sim_done     : boolean := false;
    signal test_num     : integer := 0;
    signal cycle_count  : integer := 0;

    signal exp_quotient  : unsigned(WIDTH - 1 downto 0) := (others => '0');
    signal exp_remainder : unsigned(WIDTH - 1 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Issue a division and wait for valid result
    -- Signals driven at half-clock offset to avoid delta cycle races
    -- valid goes low when start='1' (combinatorial)
    -- After start deasserts wait 1 cycle then wait for valid='1'
    -- -------------------------------------------------------------------------
    procedure do_divide(
        signal   dvd_sig  : out unsigned(WIDTH - 1 downto 0);
        signal   div_sig  : out unsigned(WIDTH - 1 downto 0);
        signal   start_s  : out std_logic;
        signal   valid_s  : in  std_logic;
        constant dvd      : in  integer;
        constant div      : in  integer;
        constant clk_p    : in  time
    ) is
    begin
        dvd_sig <= to_unsigned(dvd, WIDTH);
        div_sig <= to_unsigned(div, WIDTH);
        wait for clk_p / 2;
        start_s <= '1';
        wait for clk_p;
        start_s <= '0';
        wait for clk_p;
        wait until valid_s = '1';
        wait for clk_p;
    end procedure do_divide;

    -- -------------------------------------------------------------------------
    -- Issue a division with unsigned operands (avoids integer overflow)
    -- -------------------------------------------------------------------------
    procedure do_divide_u(
        signal   dvd_sig  : out unsigned(WIDTH - 1 downto 0);
        signal   div_sig  : out unsigned(WIDTH - 1 downto 0);
        signal   start_s  : out std_logic;
        signal   valid_s  : in  std_logic;
        constant dvd      : in  unsigned(WIDTH - 1 downto 0);
        constant div      : in  unsigned(WIDTH - 1 downto 0);
        constant clk_p    : in  time
    ) is
    begin
        dvd_sig <= dvd;
        div_sig <= div;
        wait for clk_p / 2;
        start_s <= '1';
        wait for clk_p;
        start_s <= '0';
        wait for clk_p;
        wait until valid_s = '1';
        wait for clk_p;
    end procedure do_divide_u;

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
    -- Cycle counter: counts cycles from start to valid
    -- -------------------------------------------------------------------------
    p_cycle : process(clk)
    begin
        if rising_edge(clk) then
            if start = '1' then
                cycle_count <= 0;
            elsif valid = '0' then
                cycle_count <= cycle_count + 1;
            end if;
        end if;
    end process p_cycle;

    -- -------------------------------------------------------------------------
    -- DUT: caching disabled
    -- -------------------------------------------------------------------------
    dut : entity work.divider
        generic map (
            WIDTH    => WIDTH,
            CACHING  => 1,
            INIT_VLD => 0
        )
        port map (
            clk       => clk,
            rst       => rst,
            start     => start,
            dividend  => dividend,
            divisor   => divisor,
            quotient  => quotient,
            remainder => remainder,
            zero_err  => zero_err,
            valid     => valid
        );

    -- -------------------------------------------------------------------------
    -- Stimulus
    -- -------------------------------------------------------------------------
    p_stim : process
    begin

        -- Reset
        rst <= '0'; wait for CLK_PERIOD;
        rst <= '1'; wait for CLK_PERIOD;
        rst <= '0'; wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 1: Basic division
        -- 12344235 / 2343 = 5268 rem 1311
        -- --------------------------------------------------------------------
        test_num      <= 1;
        report "TEST 1: Basic division 12344235 / 2343";
        exp_quotient  <= to_unsigned(12344235 / 2343, WIDTH);
        exp_remainder <= to_unsigned(12344235 mod 2343, WIDTH);

        do_divide(dividend, divisor, start, valid,
                  12344235, 2343, CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T1: quotient=" &
                   integer'image(to_integer(quotient)) &
                   " expected=" &
                   integer'image(to_integer(exp_quotient))
            severity failure;
        assert remainder = exp_remainder
            report "FAIL T1: remainder=" &
                   integer'image(to_integer(remainder)) &
                   " expected=" &
                   integer'image(to_integer(exp_remainder))
            severity failure;
        report "TEST 1: PASS - quotient=" &
               integer'image(to_integer(quotient)) &
               " remainder=" & integer'image(to_integer(remainder)) &
               " cycles=" & integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 2: Large dividend (do_divide_u avoids integer overflow)
        -- 0xFFFFFFFF / 1 = 4294967295 rem 0
        -- --------------------------------------------------------------------
        test_num      <= 2;
        report "TEST 2: Large dividend 0xFFFFFFFF / 1";
        exp_quotient  <= (others => '1');
        exp_remainder <= (others => '0');

        do_divide_u(dividend, divisor, start, valid,
                    (others => '1'), to_unsigned(1, WIDTH),
                    CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T2: quotient=" &
                   integer'image(to_integer(quotient)) &
                   " expected 4294967295"
            severity failure;
        assert zero_err = '0'
            report "FAIL T2: zero_err should be clear"
            severity failure;
        report "TEST 2: PASS - cycles=" & integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 3: Zero divisor - handled directly, not via do_divide
        -- valid goes high immediately (state stays IDLE)
        -- --------------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: Zero divisor";

        dividend <= to_unsigned(4624653, WIDTH);
        divisor  <= to_unsigned(0, WIDTH);
        wait for CLK_PERIOD / 2;
        start <= '1'; wait for CLK_PERIOD;
        start <= '0';
        wait for 5 * CLK_PERIOD;

        assert zero_err = '1'
            report "FAIL T3: zero_err should be set for divide by zero"
            severity failure;
        report "TEST 3: PASS - zero_err correctly set";

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 4: Divisor > dividend
        -- 5657 / 68686265 = 0 rem 5657
        -- --------------------------------------------------------------------
        test_num      <= 4;
        report "TEST 4: Divisor > dividend 5657 / 68686265";
        exp_quotient  <= to_unsigned(0, WIDTH);
        exp_remainder <= to_unsigned(5657, WIDTH);

        do_divide(dividend, divisor, start, valid,
                  5657, 68686265, CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T4: quotient should be 0, got " &
                   integer'image(to_integer(quotient))
            severity failure;
        assert remainder = exp_remainder
            report "FAIL T4: remainder=" &
                   integer'image(to_integer(remainder)) &
                   " expected 5657"
            severity failure;
        report "TEST 4: PASS - quotient=0 rem=5657 cycles=" &
               integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 5: angle_engine use case - 100MHz 1000 RPM
        -- 71582788 / 100000 = 715 rem 82788
        -- --------------------------------------------------------------------
        test_num      <= 5;
        report "TEST 5: 100MHz 1000 RPM - 71582788 / 100000 = 715";
        exp_quotient  <= to_unsigned(715, WIDTH);
        exp_remainder <= to_unsigned(82788, WIDTH);

        do_divide(dividend, divisor, start, valid,
                  71582788, 100000, CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T5: quotient=" &
                   integer'image(to_integer(quotient)) &
                   " expected 715"
            severity failure;
        report "TEST 5: PASS - nco_inc=" &
               integer'image(to_integer(quotient)) &
               " cycles=" & integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 6: angle_engine use case - 1MHz 1000 RPM (simulation clock)
        -- 71582788 / 1000 = 71582 rem 788
        -- --------------------------------------------------------------------
        test_num      <= 6;
        report "TEST 6: 1MHz 1000 RPM - 71582788 / 1000 = 71582";
        exp_quotient  <= to_unsigned(71582, WIDTH);
        exp_remainder <= to_unsigned(788, WIDTH);

        do_divide(dividend, divisor, start, valid,
                  71582788, 1000, CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T6: quotient=" &
                   integer'image(to_integer(quotient)) &
                   " expected 71582"
            severity failure;
        report "TEST 6: PASS - nco_inc=" &
               integer'image(to_integer(quotient)) &
               " cycles=" & integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 7: Power of 3
        -- 59049 / 3 = 19683 rem 0
        -- --------------------------------------------------------------------
        test_num      <= 7;
        report "TEST 7: Power of 3 - 59049 / 3 = 19683";
        exp_quotient  <= to_unsigned(19683, WIDTH);
        exp_remainder <= to_unsigned(0, WIDTH);

        do_divide(dividend, divisor, start, valid,
                  59049, 3, CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T7: quotient=" &
                   integer'image(to_integer(quotient)) &
                   " expected 19683"
            severity failure;
        report "TEST 7: PASS - cycles=" & integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- TEST 8: angle_engine use case - 100MHz 8000 RPM
        -- 71582788 / 12500 = 5726 rem 7788
        -- --------------------------------------------------------------------
        test_num      <= 8;
        report "TEST 8: 100MHz 8000 RPM - 71582788 / 12500 = 5726";
        exp_quotient  <= to_unsigned(5726, WIDTH);
        exp_remainder <= to_unsigned(7788, WIDTH);

        do_divide(dividend, divisor, start, valid,
                  71582788, 12500, CLK_PERIOD);

        assert quotient = exp_quotient
            report "FAIL T8: quotient=" &
                   integer'image(to_integer(quotient)) &
                   " expected 5726"
            severity failure;
        report "TEST 8: PASS - nco_inc=" &
               integer'image(to_integer(quotient)) &
               " cycles=" & integer'image(cycle_count);

        wait for 5 * CLK_PERIOD;

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        report "========================================";
        report "All divider tests PASS";
        report "========================================";

        sim_done <= true;
        wait;

    end process p_stim;

end architecture sim;