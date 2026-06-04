library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- ang_sel.vhd  (v3)
--
-- Selects the angfac position stream fed to trig and pack.
--   sel=0: angle_angfac  -- tooth-based (with optional Bresenham interpolation)
--   sel=1: pll_angfac    -- PLL-corrected NCO output
--
-- Startup config, latched on config_apply.
-- Purely combinatorial -- no clock required.
-- =============================================================================

entity ang_sel is
    port (
        sel           : in  std_logic;
        angle_angfac  : in  unsigned(31 downto 0);   -- from angle.vhd
        pll_angfac    : in  unsigned(31 downto 0);   -- from pll.vhd
        ang_angfac    : out unsigned(31 downto 0)    -- to trig.vhd and pack.vhd
    );
end entity ang_sel;

architecture rtl of ang_sel is
begin
    ang_angfac <= angle_angfac when sel = '0' else pll_angfac;
end architecture rtl;
