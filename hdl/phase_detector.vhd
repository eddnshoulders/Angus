library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- phase_detector
--
-- Detects which revolution of the 4-stroke cycle a phase reference pulse
-- (cam sensor or pressure peak flag) occurs on.
--
-- Checks raw_angle against two bands when phase_ref rises:
--   Band A: expected_phase_angle +/- phase_tolerance
--   Band B: (expected_phase_angle + 3600) mod 7200 +/- phase_tolerance
--
-- If in Band A: ref_detected pulses, sync_offset = '0' (no offset needed)
-- If in Band B: ref_detected pulses, sync_offset = '1' (add 3600)
-- If in neither band: ref ignored
--
-- sync_offset is registered and holds its value between ref pulses.
-- raw_angle is in units of 0.1 degrees (0-7199 per 720 degree cycle)
-- =============================================================================

entity phase_detector is
    port (
        clk                  : in  std_logic;
        rst                  : in  std_logic;

        -- Raw angle from angle_engine (0-7199, units of 0.1 degrees)
        raw_angle            : in  unsigned(15 downto 0);

        -- Phase reference input (cam pulse or pressure peak flag)
        phase_ref            : in  std_logic;

        -- Configuration from PS (in 0.1 degree units)
        expected_phase_angle : in  unsigned(15 downto 0);  -- 0-7199
        phase_tolerance      : in  unsigned(15 downto 0);  -- tolerance band

        -- Outputs
        ref_detected         : out std_logic;
        sync_offset          : out std_logic;   -- '0' = no offset, '1' = add 3600

        -- Debug outputs
        cam_edge_pulse       : out std_logic;            -- pulse on every cam rising edge
        cam_angle            : out unsigned(15 downto 0) -- raw_angle latched at cam edge
    );
end entity phase_detector;

architecture rtl of phase_detector is

    constant CYCLE_STEPS  : unsigned(15 downto 0) := to_unsigned(7200, 16);
    constant HALF_CYCLE   : unsigned(15 downto 0) := to_unsigned(3600, 16);

    signal ref_prev            : std_logic := '0';
    signal sync_offset_r       : std_logic := '0';
    signal ref_det             : std_logic := '0';
    signal cam_edge_int        : std_logic := '0';
    signal cam_angle_int       : unsigned(15 downto 0) := (others => '0');

    -- Input registers to break long nets from axi_lite_regs
    signal phase_ang_reg       : unsigned(15 downto 0) := (others => '0');
    signal phase_tol_reg       : unsigned(15 downto 0) := (others => '0');

    -- Band centre for band B = (expected + 3600) mod 7200
    signal band_b_centre       : unsigned(15 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Helper: returns true if angle is within tolerance of centre
    -- Handles wraparound at 0/7200
    -- -------------------------------------------------------------------------
    function in_band(
        angle     : unsigned(15 downto 0);
        centre    : unsigned(15 downto 0);
        tolerance : unsigned(15 downto 0)
    ) return boolean is
        variable diff     : unsigned(15 downto 0);
        variable neg_diff : unsigned(15 downto 0);
    begin
        if angle >= centre then
            diff := angle - centre;
        else
            diff := centre - angle;
        end if;

        -- Handle wraparound: if diff > half cycle, use the short way round
        if diff > HALF_CYCLE then
            diff := CYCLE_STEPS - diff;
        end if;

        return diff <= tolerance;
    end function;

begin

    -- Band B centre: (expected + 3600) mod 7200
    band_b_centre <= phase_ang_reg - HALF_CYCLE
                     when phase_ang_reg >= HALF_CYCLE
                     else phase_ang_reg + HALF_CYCLE;

    -- Input registers: break long nets from axi_lite_regs
    p_input_reg : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_ang_reg <= (others => '0');
                phase_tol_reg <= (others => '0');
            else
                phase_ang_reg <= expected_phase_angle;
                phase_tol_reg <= phase_tolerance;
            end if;
        end if;
    end process p_input_reg;

    -- -------------------------------------------------------------------------
    -- Phase reference detection
    -- On rising edge of phase_ref, sample raw_angle and check bands
    -- -------------------------------------------------------------------------
    p_detect : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ref_prev      <= '0';
                ref_det       <= '0';
                sync_offset_r <= '0';
                cam_edge_int  <= '0';
                cam_angle_int <= (others => '0');
            else
                ref_prev     <= phase_ref;
                ref_det      <= '0';
                cam_edge_int <= '0';

                -- Rising edge of phase_ref
                if phase_ref = '1' and ref_prev = '0' then
                    -- Latch angle and pulse cam_edge on every cam edge (before band check)
                    cam_edge_int  <= '1';
                    cam_angle_int <= raw_angle;

                    if in_band(raw_angle, phase_ang_reg,
                               phase_tol_reg) then
                        -- In Band A: correct revolution
                        ref_det       <= '1';
                        sync_offset_r <= '0';

                    elsif in_band(raw_angle, band_b_centre,
                                  phase_tol_reg) then
                        -- In Band B: other revolution
                        ref_det       <= '1';
                        sync_offset_r <= '1';

                    end if;
                    -- Outside both bands: ignore
                end if;
            end if;
        end if;
    end process p_detect;

    ref_detected   <= ref_det;
    sync_offset    <= sync_offset_r;
    cam_edge_pulse <= cam_edge_int;
    cam_angle      <= cam_angle_int;

end architecture rtl;