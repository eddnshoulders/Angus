library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- peak_detector (stub)
--
-- Placeholder for gradient-based ADC Ch0 pressure peak detector.
-- Will detect TDC from in-cylinder pressure trace when implemented.
-- Output tied low until implemented.
-- =============================================================================

entity peak_detector is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        adc_data       : in  unsigned(15 downto 0);
        adc_valid      : in  std_logic;
        peak_pulse     : out std_logic
    );
end entity peak_detector;

architecture rtl of peak_detector is
begin
    peak_pulse <= '0';  -- stub
end architecture rtl;
