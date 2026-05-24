library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity signal_conditioner is
    generic (
        DEBOUNCE_CYCLES : integer := 5
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        raw_signal      : in  std_logic;
        clean_signal    : out std_logic;
        signal_stable   : out std_logic
    );
end entity signal_conditioner;

architecture rtl of signal_conditioner is

    -- 2FF metastability chain
    signal sync0        : std_logic := '0';
    signal sync1        : std_logic := '0';

    -- Debounce
    signal sig_prev     : std_logic := '0';
    signal debounce_cnt : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal stable_int   : std_logic := '0';
    signal in_debounce  : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- 2FF synchroniser
    -- -------------------------------------------------------------------------
    p_sync : process(clk)
    begin
        if rising_edge(clk) then
            sync0 <= raw_signal;
            sync1 <= sync0;
        end if;
    end process p_sync;

    -- -------------------------------------------------------------------------
    -- Debounce
    -- Input must be stable for DEBOUNCE_CYCLES before clean_signal follows
    -- signal_stable is low during the debounce window
    -- -------------------------------------------------------------------------
    p_debounce : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                debounce_cnt <= 0;
                stable_int   <= '0';
                sig_prev     <= '0';
                in_debounce  <= '0';
            else
                if sync1 /= sig_prev then
                    -- Input changed, restart debounce counter
                    debounce_cnt <= 0;
                    sig_prev     <= sync1;
                    in_debounce  <= '1';
                elsif debounce_cnt < DEBOUNCE_CYCLES then
                    debounce_cnt <= debounce_cnt + 1;
                else
                    -- Stable for long enough, pass through
                    stable_int  <= sync1;
                    in_debounce <= '0';
                end if;
            end if;
        end if;
    end process p_debounce;

    -- Drive outputs
    clean_signal  <= stable_int;
    signal_stable <= not in_debounce;

end architecture rtl;