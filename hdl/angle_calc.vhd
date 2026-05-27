library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle_calc
--
-- Tooth-based crank angle calculator with linear interpolation.
-- Completely independent of the NCO - uses only tooth counting and timing.
--
-- angle_raw is in 0.1 degree steps over one full engine cycle (720 degrees):
--   0 = TDC cylinder 1 first stroke (at first Z pulse)
--   7199 = just before next Z
--
-- At each ab_edge:
--   base_angle = tooth_count * degrees_per_tooth
--   interp resets to 0
--
-- Between ab_edges (Bresenham interpolation):
--   Each clock: frac_accum += degrees_per_tooth
--   When frac_accum >= tooth_period: interp++, frac_accum -= tooth_period
--   angle_raw = base_angle + interp
--
-- phase toggles each Z pulse after first valid rotation (ab_count = n_teeth).
--   phase=0: first crank rotation (0-360 deg)
--   phase=1: second crank rotation (360-720 deg)
--
-- degrees_per_tooth = 7200 / n_teeth is computed via the shared divider
-- on config_apply and latched. Default 120 for 60-tooth wheel.
--
-- =============================================================================

entity angle_calc is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- Angle source inputs (from ang_sel mux)
        ab               : in  std_logic;
        z                : in  std_logic;
        tooth_period     : in  unsigned(31 downto 0);
        tooth_count      : in  unsigned(7 downto 0);
        signal_present   : in  std_logic;

        -- Configuration (from axi_lite_regs, latched on config_apply)
        n_teeth          : in  unsigned(7 downto 0);

        -- Divider interface (shared divider in top level)
        -- Compute degrees_per_tooth = 7200 / n_teeth on config_apply
        div_start        : out std_logic;
        div_dividend     : out unsigned(31 downto 0);
        div_divisor      : out unsigned(31 downto 0);
        div_quotient     : in  unsigned(31 downto 0);
        div_valid        : in  std_logic;

        -- Config apply pulse - triggers degrees_per_tooth recalculation
        config_apply     : in  std_logic;

        -- Outputs
        angle_raw        : out unsigned(15 downto 0);  -- 0-7199, 0.1 deg steps
        phase            : out std_logic               -- 0=1st rotation, 1=2nd rotation
    );
end entity angle_calc;

architecture rtl of angle_calc is

    -- Degrees per tooth in 0.1 deg units (7200 / n_teeth)
    -- Default 120 for 60-tooth wheel
    signal degrees_per_tooth : unsigned(15 downto 0) := to_unsigned(120, 16);

    -- Divider trigger
    signal div_start_int     : std_logic := '0';
    signal div_pending       : std_logic := '0';

    -- AB edge detection
    signal ab_prev           : std_logic := '0';
    signal ab_edge           : std_logic := '0';

    -- Z edge detection
    signal z_prev            : std_logic := '0';
    signal z_edge            : std_logic := '0';

    -- Angle calculation
    signal base_angle        : unsigned(15 downto 0) := (others => '0');
    signal interp_angle      : unsigned(15 downto 0) := (others => '0');
    signal frac_accum        : unsigned(31 downto 0) := (others => '0');
    signal interp_timer      : unsigned(31 downto 0) := (others => '0');

    -- Phase tracking
    signal phase_int         : std_logic := '0';
    signal first_z_seen      : std_logic := '0';

    -- Output register
    signal angle_raw_int     : unsigned(15 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- Edge detection
    -- -------------------------------------------------------------------------
    p_edges : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_prev <= '0';
                ab_edge <= '0';
                z_prev  <= '0';
                z_edge  <= '0';
            else
                ab_prev <= ab;
                z_prev  <= z;
                ab_edge <= '0';
                z_edge  <= '0';
                if ab /= ab_prev then
                    ab_edge <= '1';
                end if;
                if z = '1' and z_prev = '0' then
                    z_edge <= '1';
                end if;
            end if;
        end if;
    end process p_edges;

    -- -------------------------------------------------------------------------
    -- Trigger divider to compute degrees_per_tooth = 7200 / n_teeth
    -- on config_apply pulse
    -- -------------------------------------------------------------------------
    p_div_trigger : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                div_start_int <= '0';
                div_pending   <= '0';
            else
                div_start_int <= '0';
                if config_apply = '1' and div_pending = '0' then
                    div_start_int <= '1';
                    div_pending   <= '1';
                end if;
                if div_valid = '1' and div_pending = '1' then
                    degrees_per_tooth <= div_quotient(15 downto 0);
                    div_pending       <= '0';
                end if;
            end if;
        end if;
    end process p_div_trigger;

    div_start    <= div_start_int;
    div_dividend <= to_unsigned(7200, 32);
    div_divisor  <= resize(n_teeth, 32);

    -- -------------------------------------------------------------------------
    -- Angle calculation - Bresenham interpolation between tooth edges
    -- -------------------------------------------------------------------------
    p_angle : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                base_angle    <= (others => '0');
                interp_angle  <= (others => '0');
                frac_accum    <= (others => '0');
                interp_timer  <= (others => '0');
            else
                if signal_present = '0' then
                    -- No signal - hold at zero
                    base_angle   <= (others => '0');
                    interp_angle <= (others => '0');
                    frac_accum   <= (others => '0');
                    interp_timer <= (others => '0');

                elsif ab_edge = '1' then
                    -- Tooth edge: snap base angle to tooth_count * degrees_per_tooth
                    base_angle   <= resize(tooth_count * degrees_per_tooth, 16);
                    interp_angle <= (others => '0');
                    frac_accum   <= (others => '0');
                    interp_timer <= (others => '0');

                else
                    -- Between teeth: Bresenham interpolation
                    interp_timer <= interp_timer + 1;

                    if tooth_period > 0 then
                        if frac_accum + degrees_per_tooth >= tooth_period then
                            -- Advance interpolated angle by 1 step
                            if interp_angle < degrees_per_tooth - 1 then
                                interp_angle <= interp_angle + 1;
                            end if;
                            frac_accum <= frac_accum + degrees_per_tooth - tooth_period;
                        else
                            frac_accum <= frac_accum + degrees_per_tooth;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_angle;

    -- Combine base and interpolated angle
    angle_raw_int <= base_angle + interp_angle;

    -- -------------------------------------------------------------------------
    -- Phase tracking - toggles on Z pulse after first valid rotation
    -- -------------------------------------------------------------------------
    p_phase : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_int    <= '0';
                first_z_seen <= '0';
            else
                if signal_present = '0' then
                    phase_int    <= '0';
                    first_z_seen <= '0';
                elsif z_edge = '1' then
                    if first_z_seen = '0' then
                        -- First Z pulse - define phase 0, don't toggle yet
                        first_z_seen <= '1';
                        phase_int    <= '0';
                    else
                        -- Subsequent Z pulses - toggle phase
                        phase_int <= not phase_int;
                    end if;
                end if;
            end if;
        end if;
    end process p_phase;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    angle_raw <= angle_raw_int;
    phase     <= phase_int;

end architecture rtl;
