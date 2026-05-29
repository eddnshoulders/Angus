library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- ang_sel.vhd
-- Selects between tooth-based angle_deg and PLL pll_ang_hires.
-- sel=0: angle_deg (tooth-based), sel=1: pll_ang_hires
-- Startup config, latched on config_apply.
-- =============================================================================
entity ang_sel is
    port (
        sel           : in  std_logic;
        angle_deg_in  : in  unsigned(15 downto 0);
        pll_ang_hires : in  unsigned(15 downto 0);
        ang_deg       : out unsigned(15 downto 0)
    );
end entity ang_sel;

architecture rtl of ang_sel is
begin
    ang_deg <= angle_deg_in when sel = '0' else pll_ang_hires;
end architecture rtl;
