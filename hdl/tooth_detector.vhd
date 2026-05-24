library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tooth_detector is
    generic (
        CLK_FREQ_HZ     : integer := 100_000_000;
        DEBOUNCE_CYCLES : integer := 5;
        TIMEOUT_CYCLES  : integer := 100_000_000   -- 1 second at 100MHz
    );
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        crank_in       : in  std_logic;
        edge_rising    : in  std_logic;             -- '1' = rising, '0' = falling
        tooth_detected : out std_logic;
        tooth_period   : out unsigned(31 downto 0);
        signal_present : out std_logic
    );
end entity tooth_detector;

architecture rtl of tooth_detector is

    -- Input synchronisation (2FF metastability chain)
    signal crank_sync0   : std_logic := '0';
    signal crank_sync1   : std_logic := '0';

    -- Debounce
    signal crank_prev    : std_logic := '0';
    signal debounce_cnt  : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal crank_stable  : std_logic := '0';

    -- Edge detection
    signal crank_db_prev : std_logic := '0';
    signal edge_detected : std_logic := '0';

    -- Period measurement
    signal period_cnt    : unsigned(31 downto 0) := (others => '0');

    -- Timeout
    signal timeout_cnt   : unsigned(31 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- Input synchronisation
    -- Two flip-flop metastability chain on async input
    -- -------------------------------------------------------------------------
    p_sync : process(clk)
    begin
        if rising_edge(clk) then
            crank_sync0 <= crank_in;
            crank_sync1 <= crank_sync0;
        end if;
    end process p_sync;

    -- -------------------------------------------------------------------------
    -- Debounce
    -- Input must be stable for DEBOUNCE_CYCLES before accepted
    -- -------------------------------------------------------------------------
    p_debounce : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                debounce_cnt <= 0;
                crank_stable <= '0';
                crank_prev   <= '0';
            else
                if crank_sync1 /= crank_prev then
                    debounce_cnt <= 0;
                    crank_prev   <= crank_sync1;
                elsif debounce_cnt < DEBOUNCE_CYCLES then
                    debounce_cnt <= debounce_cnt + 1;
                else
                    crank_stable <= crank_sync1;
                end if;
            end if;
        end if;
    end process p_debounce;

    -- -------------------------------------------------------------------------
    -- Edge detection on debounced signal
    -- Runtime selectable polarity via edge_rising port
    -- -------------------------------------------------------------------------
    p_edge : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                crank_db_prev <= '0';
                edge_detected <= '0';
            else
                crank_db_prev <= crank_stable;

                edge_detected <=
                    (crank_stable and not crank_db_prev and edge_rising) or
                    (not crank_stable and crank_db_prev and not edge_rising);
            end if;
        end if;
    end process p_edge;

    -- -------------------------------------------------------------------------
    -- Period measurement
    -- Free-running counter latched on each accepted edge
    -- Counter saturates at max value rather than wrapping
    -- -------------------------------------------------------------------------
    p_period : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                period_cnt     <= (others => '0');
                tooth_period   <= (others => '0');
                tooth_detected <= '0';
            else
                tooth_detected <= '0';

                if edge_detected = '1' then
                    tooth_period   <= period_cnt;
                    period_cnt     <= (others => '0');
                    tooth_detected <= '1';
                else
                    if period_cnt /= (period_cnt'range => '1') then
                        period_cnt <= period_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_period;

    -- -------------------------------------------------------------------------
    -- Timeout / signal present
    -- signal_present goes low if no tooth within TIMEOUT_CYCLES
    -- -------------------------------------------------------------------------
    p_timeout : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                timeout_cnt    <= (others => '0');
                signal_present <= '0';
            else
                if edge_detected = '1' then
                    timeout_cnt    <= (others => '0');
                    signal_present <= '1';
                elsif timeout_cnt < to_unsigned(TIMEOUT_CYCLES, 32) then
                    timeout_cnt <= timeout_cnt + 1;
                else
                    signal_present <= '0';
                end if;
            end if;
        end if;
    end process p_timeout;

end architecture rtl;