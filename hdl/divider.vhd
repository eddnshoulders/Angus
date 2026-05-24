library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- divider
--
-- Sequential non-restoring divider with optional caching.
-- VHDL translation of divider.v by Yigit Suoglu (CERN-OHL-W licence).
--
-- Algorithm:
--   PREP: shift divisor_op left until shifting again would exceed dividend_op
--         count shifts in shift_cnt
--   CALC: shift divisor_op right shift_cnt times
--         subtract divisor_op from dividend_op when possible
--         build quotient one bit per cycle
--   IDLE: result valid, wait for next start
--
-- Caching: if same dividend/divisor as previous, skip calculation
-- Zero divide: sets zero_err, valid goes high immediately
-- =============================================================================

entity divider is
    generic (
        WIDTH    : integer := 32;
        CACHING  : integer := 0;
        INIT_VLD : integer := 0
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        start     : in  std_logic;
        dividend  : in  unsigned(WIDTH - 1 downto 0);
        divisor   : in  unsigned(WIDTH - 1 downto 0);
        quotient  : out unsigned(WIDTH - 1 downto 0);
        remainder : out unsigned(WIDTH - 1 downto 0);
        zero_err  : out std_logic;
        valid     : out std_logic
    );
end entity divider;

architecture rtl of divider is

    type state_t is (IDLE, PREP, CALC);
    signal state         : state_t := IDLE;

    -- Working registers (extra bit for divisor to detect overflow)
    signal dividend_op   : unsigned(WIDTH - 1 downto 0) := (others => '0');
    signal divisor_op    : unsigned(WIDTH downto 0)     := (others => '0');
    signal quotient_reg  : unsigned(WIDTH - 1 downto 0) := (others => '0');

    -- Shift counter
    signal shift_cnt     : unsigned(7 downto 0) := (others => '0');

    -- Flags
    signal zero_divide   : std_logic;
    signal use_cache     : std_logic;
    signal start_calc    : std_logic;
    signal do_subtract   : std_logic;
    signal stop_shift    : std_logic;
    signal zero_err_r    : std_logic := '0';
    signal valid_en      : std_logic := '0';

    -- Cache registers
    signal div_cached    : unsigned(WIDTH - 1 downto 0) := (others => '0');
    signal dvd_cached    : unsigned(WIDTH - 1 downto 0) := (others => '0');

    -- Shifted divisor for stop_shift check
    signal divisor_op_sh : unsigned(WIDTH downto 0);

begin

    -- -------------------------------------------------------------------------
    -- Combinational flags
    -- -------------------------------------------------------------------------
    zero_divide    <= '1' when divisor = (divisor'range => '0') else '0';

    use_cache      <= '1' when (CACHING = 1 and
                                dividend = dvd_cached and
                                divisor  = div_cached)
                     else '0';

    start_calc     <= '1' when (zero_divide = '0' and
                                start = '1' and
                                not (CACHING = 1 and use_cache = '1'))
                     else '0';

    -- Subtract when dividend_op >= divisor_op (in CALC state)
    do_subtract    <= '1' when (state = CALC and
                                ('0' & dividend_op) >= divisor_op)
                     else '0';

    -- Stop shifting when next shift would overflow the divisor register
    -- OR when next shift would make divisor_op exceed dividend_op
    -- divisor_op is WIDTH+1 bits; if MSB of shifted value is set, overflow
    divisor_op_sh  <= shift_left(divisor_op, 1);
    stop_shift     <= '1' when (state = PREP and
                                (divisor_op_sh(WIDTH) = '1' or
                                 divisor_op_sh > ('0' & dividend_op)))
                     else '0';

    -- -------------------------------------------------------------------------
    -- Valid output
    -- -------------------------------------------------------------------------
    gen_vld_init : if INIT_VLD = 1 generate
        valid <= '1' when (state = IDLE and start = '0') else '0';
    end generate gen_vld_init;

    gen_vld_en : if INIT_VLD = 0 generate
        valid <= '1' when (valid_en = '1' and
                           start = '0' and
                           state = IDLE)
                 else '0';

        p_valid_en : process(clk)
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    valid_en <= '0';
                else
                    if start = '1' then
                        valid_en <= '1';
                    end if;
                end if;
            end if;
        end process p_valid_en;
    end generate gen_vld_en;

    -- -------------------------------------------------------------------------
    -- Zero error
    -- -------------------------------------------------------------------------
    p_zero_err : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                zero_err_r <= '0';
            else
                if start = '1' and state = IDLE then
                    zero_err_r <= zero_divide;
                end if;
            end if;
        end if;
    end process p_zero_err;

    zero_err <= zero_err_r;

    -- -------------------------------------------------------------------------
    -- Shift counter
    -- Counts up in PREP (number of shifts applied)
    -- Counts down in CALC (number of shifts remaining)
    -- -------------------------------------------------------------------------
    p_shift_cnt : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                shift_cnt <= (others => '0');
            else
                case state is
                    when IDLE => shift_cnt <= (others => '0');
                    when PREP => shift_cnt <= shift_cnt + 1;
                    when CALC => shift_cnt <= shift_cnt - 1;
                end case;
            end if;
        end if;
    end process p_shift_cnt;

    -- -------------------------------------------------------------------------
    -- Divisor operand
    -- Load on start, shift left in PREP, shift right in CALC
    -- -------------------------------------------------------------------------
    p_divisor_op : process(clk)
    begin
        if rising_edge(clk) then
            if start_calc = '1' then
                divisor_op <= '0' & divisor;
            else
                case state is
                    when PREP => divisor_op <= shift_left(divisor_op, 1);
                    when CALC => divisor_op <= shift_right(divisor_op, 1);
                    when others => null;
                end case;
            end if;
        end if;
    end process p_divisor_op;

    -- -------------------------------------------------------------------------
    -- Dividend operand (becomes remainder after calculation)
    -- Subtract divisor_op when do_subtract is set
    -- -------------------------------------------------------------------------
    p_dividend_op : process(clk)
    begin
        if rising_edge(clk) then
            if start_calc = '1' then
                dividend_op <= dividend;
            else
                if do_subtract = '1' then
                    dividend_op <= dividend_op - divisor_op(WIDTH - 1 downto 0);
                end if;
            end if;
        end if;
    end process p_dividend_op;

    -- -------------------------------------------------------------------------
    -- Quotient register
    -- Clear in PREP, shift left and append subtract bit in CALC
    -- -------------------------------------------------------------------------
    p_quotient : process(clk)
    begin
        if rising_edge(clk) then
            if state = PREP then
                quotient_reg <= (others => '0');
            elsif state = CALC then
                quotient_reg <= quotient_reg(WIDTH - 2 downto 0) & do_subtract;
            end if;
        end if;
    end process p_quotient;

    quotient  <= quotient_reg;
    remainder <= dividend_op;

    -- -------------------------------------------------------------------------
    -- State machine
    -- -------------------------------------------------------------------------
    p_state : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
            else
                case state is
                    when IDLE =>
                        if start_calc = '1' then
                            state <= PREP;
                        end if;

                    when PREP =>
                        if stop_shift = '1' then
                            state <= CALC;
                        end if;

                    when CALC =>
                        -- shift_cnt decrements each cycle from N to 0
                        -- CALC runs N+1 cycles (including cycle at shift_cnt=0)
                        -- quotient and remainder updated before IDLE transition
                        if shift_cnt = 0 then
                            state <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process p_state;

    -- -------------------------------------------------------------------------
    -- Cache
    -- -------------------------------------------------------------------------
    gen_cache : if CACHING = 1 generate
        p_cache : process(clk)
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    dvd_cached <= (others => '0');
                    div_cached <= (others => '0');
                else
                    if start_calc = '1' and state = IDLE then
                        dvd_cached <= dividend;
                        div_cached <= divisor;
                    end if;
                end if;
            end if;
        end process p_cache;
    end generate gen_cache;

end architecture rtl;