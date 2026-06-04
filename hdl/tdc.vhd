library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- tdc.vhd  (v3)
--
-- Converts engine position ({phase_eng, ang_angfac}) to a TDC-referenced
-- degree value (tdc_deg, 0-7199, 0.1 deg/LSB, 0-719.9 deg engine cycle).
--
-- Inputs:
--   ang_angfac  -- crank position within current revolution (0 = Z edge)
--   phase_eng   -- which crank revolution (0 or 1) within the engine cycle
--   tdc_offset  -- angfac value at which engine TDC occurs relative to Z edge
--                  (computed by angus_regs.py from user-configured degrees)
--
-- Engine position (33-bit):
--   eng_pos = {phase_eng, ang_angfac}    range 0 to 2^33-1
--
-- TDC-referenced position:
--   tdc_pos = (eng_pos - tdc_offset) mod 2^33
--
-- Output conversion:
--   tdc_deg = tdc_pos * 7200 / 2^33    (0-7199)
--
-- tdc_offset is a runtime register -- applied to every sample without reset.
-- The output tdc_deg is registered (one clock latency).
-- =============================================================================

entity tdc is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        -- Inputs
        ang_angfac : in  unsigned(31 downto 0);
        phase_eng  : in  std_logic;
        tdc_offset : in  unsigned(31 downto 0);   -- angfac units (angus_regs.py converts)
        -- Output
        tdc_deg    : out unsigned(15 downto 0)    -- 0-7199, 0.1 deg/LSB
    );
end entity tdc;

architecture rtl of tdc is

    -- =========================================================================
    -- Compute tdc_deg = ((eng_pos - tdc_offset) mod 2^33) * 7200 / 2^33
    -- eng_pos is 33 bits: {phase_eng, ang_angfac}
    -- tdc_offset is 32 bits (engine TDC is always within one revolution of Z)
    -- =========================================================================
    function calc_tdc(
        angfac    : unsigned(31 downto 0);
        ph        : std_logic;
        offset    : unsigned(31 downto 0)
    ) return unsigned is
        variable eng_pos  : unsigned(32 downto 0);
        variable off_33   : unsigned(32 downto 0);
        variable tdc_pos  : unsigned(32 downto 0);
        variable prod     : unsigned(48 downto 0);   -- 33 + 16 = 49 bits
    begin
        eng_pos := ph & angfac;                      -- {phase_eng, ang_angfac}
        off_33  := '0' & offset;                     -- zero-extend to 33 bits
        if eng_pos >= off_33 then
            tdc_pos := eng_pos - off_33;
        else
            -- Wrap: (eng_pos + 2^33) - offset
            -- 2^33 as unsigned(32 downto 0) is 0 (overflows); instead compute
            -- using two's complement property: a - b mod 2^33 = a + (2^33 - b)
            -- = a + not(b) + 1 (within 33-bit arithmetic, wrap is automatic)
            tdc_pos := eng_pos + (not off_33) + 1;
        end if;
        -- tdc_pos * 7200 / 2^33 = prod[48:33]
        prod := tdc_pos * to_unsigned(7200, 16);
        return prod(48 downto 33);
    end function;

    signal tdc_deg_reg : unsigned(15 downto 0) := (others => '0');

begin

    p_tdc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tdc_deg_reg <= (others => '0');
            else
                tdc_deg_reg <= calc_tdc(ang_angfac, phase_eng, tdc_offset);
            end if;
        end if;
    end process p_tdc;

    tdc_deg <= tdc_deg_reg;

end architecture rtl;
