library ieee;
use ieee.std_logic_1164.all;

-- =============================================================================
-- ref_sel
--
-- Selects between cam_input and peak_detector as the phase reference source.
-- sel='0': cam_input (default)
-- sel='1': peak_detector (ADC Ch0 pressure peak, future)
-- =============================================================================

entity ref_sel is
    port (
        sel            : in  std_logic;  -- '0'=cam, '1'=peak_detector
        cam_pulse      : in  std_logic;
        peak_pulse     : in  std_logic;
        ref_pulse      : out std_logic
    );
end entity ref_sel;

architecture rtl of ref_sel is
begin
    ref_pulse <= cam_pulse when sel = '0' else peak_pulse;
end architecture rtl;
