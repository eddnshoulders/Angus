library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- peak_detector.vhd
-- Tell-tale peak detector with hysteresis band.
--
-- Algorithm:
--   Track rolling maximum:
--     if adc_val > max_val: max_val = adc_val
--   Detect peak when signal drops below hysteresis threshold:
--     if adc_val < (max_val - peak_hyst): fire peak_edge, reset max_val to 0
--
-- Reset on z_edge: clears max_val and disarms, preventing spurious detection
-- at the start of each new engine cycle.
--
-- peak_edge pulse width is peak_pulse_cycles clocks.
--
-- Used for phase reference detection when cam signal is absent.
-- Accuracy only needs to fall within the phase window (phase_ref_ang +/- tol).
-- =============================================================================
entity peak_detector is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        adc_val          : in  unsigned(11 downto 0);
        z_edge           : in  std_logic;
        peak_hyst        : in  unsigned(15 downto 0);
        peak_pulse_cycles: in  unsigned(15 downto 0);
        peak_edge        : out std_logic
    );
end entity peak_detector;

architecture rtl of peak_detector is
    signal max_val      : unsigned(11 downto 0) := (others => '0');
    signal armed        : std_logic := '0';
    signal peak_int     : std_logic := '0';
    signal pulse_cnt    : unsigned(15 downto 0) := (others => '0');
    -- Threshold: max_val - peak_hyst (saturates at 0)
    signal threshold    : unsigned(15 downto 0);
begin

    -- Combinatorial threshold calculation (saturating subtract)
    threshold <= (others => '0') when resize(max_val, 16) < peak_hyst
                 else resize(max_val, 16) - peak_hyst;

    p_peak : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                max_val   <= (others => '0');
                armed     <= '0';
                peak_int  <= '0';
                pulse_cnt <= (others => '0');
            else
                -- z_edge: reset for new engine cycle
                if z_edge = '1' then
                    max_val  <= (others => '0');
                    armed    <= '0';
                end if;

                -- Pulse width counter (self-clearing)
                if peak_int = '1' then
                    if pulse_cnt >= peak_pulse_cycles - 1 then
                        peak_int  <= '0';
                        pulse_cnt <= (others => '0');
                    else
                        pulse_cnt <= pulse_cnt + 1;
                    end if;
                end if;

                -- Track maximum (arms detector once signal rises above 0)
                if adc_val > max_val then
                    max_val <= adc_val;
                    armed   <= '1';
                end if;

                -- Detect fall below threshold
                if armed = '1' and peak_int = '0' then
                    if resize(adc_val, 16) < threshold then
                        peak_int <= '1';
                        pulse_cnt <= (others => '0');
                        max_val  <= (others => '0');
                        armed    <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process p_peak;

    peak_edge <= peak_int;

end architecture rtl;
