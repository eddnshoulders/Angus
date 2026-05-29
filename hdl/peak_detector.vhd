library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- peak_detector.vhd
-- Gradient-based peak detector for ADC Ch0 (pressure sensor).
-- Detects positive peak by looking for sign change in gradient:
--   gradient = sample[n] - sample[n-1]
--   peak when gradient goes from positive to negative (or zero)
-- Outputs peak_edge: 1-clock strobe on each detected peak.
-- =============================================================================
entity peak_detector is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        adc_data   : in  unsigned(11 downto 0);
        adc_valid  : in  std_logic;  -- strobe when new ADC sample ready
        peak_edge  : out std_logic
    );
end entity peak_detector;

architecture rtl of peak_detector is
    signal prev_sample  : unsigned(11 downto 0) := (others => '0');
    signal prev_grad_pos: std_logic := '0';  -- previous gradient was positive
    signal peak_int     : std_logic := '0';
begin
    p_peak : process(clk)
        variable grad_pos : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                prev_sample   <= (others => '0');
                prev_grad_pos <= '0';
                peak_int      <= '0';
            else
                peak_int <= '0';
                if adc_valid = '1' then
                    -- Gradient sign: positive if current > previous
                    if adc_data > prev_sample then
                        grad_pos := '1';
                    else
                        grad_pos := '0';
                    end if;
                    -- Peak: gradient was positive, now non-positive
                    if prev_grad_pos = '1' and grad_pos = '0' then
                        peak_int <= '1';
                    end if;
                    prev_grad_pos <= grad_pos;
                    prev_sample   <= adc_data;
                end if;
            end if;
        end if;
    end process p_peak;

    peak_edge <= peak_int;
end architecture rtl;
