library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- trig.vhd  (v3)
--
-- Angle-domain sample trigger (prescaler).
-- Monitors ang_angfac for advancement past fixed angular step boundaries.
-- Fires trig_pulse (1-clock strobe) every trig_decimation steps.
--
-- Angular step size:
--   STEP_SIZE = 2^32 / 3600 = 1_193_325  (one 0.1-degree equivalent per revolution)
--   This is constant regardless of PPR, matching v2 behaviour where ang_deg
--   was always 0.1 deg/LSB.
--
-- Step detection:
--   A running threshold is maintained. When ang_angfac >= threshold the step
--   boundary has been crossed. The threshold advances by STEP_SIZE each step.
--   Both threshold and trig_count reset on z_edge.
--
-- trig_pulse is a 1-clock strobe (no configurable pulse width in v3 --
-- pulse widening for scope visibility is handled by debug counters in top.vhd).
--
-- trig_count: total trigger pulses fired since last z_edge. Resets on z_edge.
-- =============================================================================

entity trig is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        ang_angfac      : in  unsigned(31 downto 0);
        z_edge          : in  std_logic;
        trig_decimation : in  unsigned(15 downto 0);
        trig_pulse      : out std_logic;
        trig_count      : out unsigned(31 downto 0)
    );
end entity trig;

architecture rtl of trig is

    -- 2^32 / 3600 = 1_193_324  (one 0.1 deg-equivalent step in angfac units)
    constant STEP_SIZE : unsigned(31 downto 0) := to_unsigned(1_193_324, 32);

    signal threshold    : unsigned(31 downto 0) := STEP_SIZE;
    signal decim_cnt    : unsigned(15 downto 0) := (others => '0');
    signal pulse_cnt    : unsigned(31 downto 0) := (others => '0');
    signal pulse_int    : std_logic             := '0';

begin

    p_trig : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                threshold  <= STEP_SIZE;
                decim_cnt  <= (others => '0');
                pulse_cnt  <= (others => '0');
                pulse_int  <= '0';
            else
                pulse_int <= '0';   -- default: strobe is 1 clock wide

                -- z_edge: reset step tracking for new revolution
                if z_edge = '1' then
                    threshold <= STEP_SIZE;
                    decim_cnt <= (others => '0');
                    pulse_cnt <= (others => '0');

                -- Step boundary crossed: ang_angfac has advanced past threshold
                elsif ang_angfac >= threshold then
                    -- Advance threshold to next step boundary (wraps naturally)
                    threshold <= threshold + STEP_SIZE;

                    -- Decimate: fire every trig_decimation steps
                    if decim_cnt >= trig_decimation - 1 then
                        decim_cnt <= (others => '0');
                        pulse_int <= '1';
                        pulse_cnt <= pulse_cnt + 1;
                    else
                        decim_cnt <= decim_cnt + 1;
                    end if;
                end if;

            end if;
        end if;
    end process p_trig;

    trig_pulse <= pulse_int;
    trig_count <= pulse_cnt;

end architecture rtl;
