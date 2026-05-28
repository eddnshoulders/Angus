library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- signal_conditioner
--
-- 2FF metastability synchroniser followed by a debounce filter.
-- debounce_cycles: input must be stable for this many clocks before
-- clean_signal follows. Runtime configurable from AXI register.
-- Default 5 cycles (50ns @ 100MHz). Increase for noisy signals.
-- =============================================================================

entity signal_conditioner is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        raw_signal       : in  std_logic;
        debounce_cycles  : in  unsigned(15 downto 0);  -- runtime configurable
        clean_signal     : out std_logic;
        signal_stable    : out std_logic
    );
end entity signal_conditioner;

architecture rtl of signal_conditioner is

    -- 2FF metastability chain
    signal sync0        : std_logic := '0';
    signal sync1        : std_logic := '0';

    -- Debounce
    signal sig_prev     : std_logic := '0';
    signal debounce_cnt : unsigned(15 downto 0) := (others => '0');
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
    -- Input must be stable for debounce_cycles before clean_signal follows
    -- signal_stable is low during the debounce window
    -- -------------------------------------------------------------------------
    p_debounce : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                debounce_cnt <= (others => '0');
                stable_int   <= '0';
                sig_prev     <= '0';
                in_debounce  <= '0';
            else
                if sync1 /= sig_prev then
                    -- Input changed, restart debounce counter
                    debounce_cnt <= (others => '0');
                    sig_prev     <= sync1;
                    in_debounce  <= '1';
                elsif debounce_cnt < debounce_cycles then
                    debounce_cnt <= debounce_cnt + 1;
                else
                    -- Stable for long enough, pass through
                    stable_int  <= sync1;
                    in_debounce <= '0';
                end if;
            end if;
        end if;
    end process p_debounce;

    clean_signal  <= stable_int;
    signal_stable <= not in_debounce;

end architecture rtl;
