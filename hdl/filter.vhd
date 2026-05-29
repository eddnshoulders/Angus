library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- filter.vhd
-- 2FF metastability synchroniser followed by debounce filter.
-- debounce_cycles: input must be stable for this many clocks before
-- clean follows. Runtime configurable from AXI register (default 5=50ns).
-- =============================================================================
entity filter is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        raw             : in  std_logic;
        debounce_cycles : in  unsigned(15 downto 0);
        clean           : out std_logic
    );
end entity filter;

architecture rtl of filter is
    signal sync0        : std_logic := '0';
    signal sync1        : std_logic := '0';
    signal sig_prev     : std_logic := '0';
    signal debounce_cnt : unsigned(15 downto 0) := (others => '0');
    signal clean_int    : std_logic := '0';
begin
    p_sync : process(clk)
    begin
        if rising_edge(clk) then
            sync0 <= raw;
            sync1 <= sync0;
        end if;
    end process;

    p_debounce : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                debounce_cnt <= (others => '0');
                clean_int    <= '0';
                sig_prev     <= '0';
            else
                if sync1 /= sig_prev then
                    debounce_cnt <= (others => '0');
                    sig_prev     <= sync1;
                elsif debounce_cnt < debounce_cycles then
                    debounce_cnt <= debounce_cnt + 1;
                else
                    clean_int <= sync1;
                end if;
            end if;
        end if;
    end process;

    clean <= clean_int;
end architecture rtl;
