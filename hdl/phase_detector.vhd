library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- phase_detector
--
-- Detects which revolution of the 4-stroke cycle a phase reference pulse
-- (cam sensor or pressure peak flag) occurs on, using tooth-based angle_raw.
--
-- Checks angle_raw against two bands when ref_pulse rises:
--   Band A: expected_cam_ang +/- window_tolerance
--           → phase_offset = 0 (cam on first crank rotation)
--   Band B: (expected_cam_ang + 3600) mod 7200 +/- window_tolerance
--           → phase_offset = 1 (cam on second crank rotation)
--   Outside both bands: ref_pulse ignored
--
-- angle_corr is the TDC-corrected engine angle:
--   phase_offset=0: angle_corr = (angle_raw + tdc_offset) mod 7200
--   phase_offset=1: angle_corr = (angle_raw + 3600 + tdc_offset) mod 7200
--
-- angle_raw is tooth-based (from angle_calc) - stable regardless of NCO.
-- All angles in 0.1 degree steps (0-7199 per 720 degree cycle).
-- =============================================================================

entity phase_detector is
    port (
        clk                  : in  std_logic;
        rst                  : in  std_logic;

        -- Tooth-based angle from angle_calc (0-7199, 0.1 deg steps)
        angle_raw            : in  unsigned(15 downto 0);

        -- 4-stroke phase from angle_calc (0=1st rotation, 1=2nd rotation)
        phase                : in  std_logic;

        -- Reference pulse (from ref_sel: cam_input or peak_detector)
        ref_pulse            : in  std_logic;

        -- Configuration from AXI (runtime configurable)
        expected_cam_ang     : in  unsigned(15 downto 0);  -- 0-7199, 0.1 deg
        window_tolerance     : in  unsigned(15 downto 0);  -- 0-7199, 0.1 deg
        tdc_offset           : in  unsigned(15 downto 0);  -- 0-7199, 0.1 deg

        -- Outputs
        ref_detected         : out std_logic;
        phase_offset         : out std_logic;   -- 0=Band A, 1=Band B

        -- Corrected engine angle (tooth-based, TDC-corrected, 4-stroke referenced)
        angle_corr           : out unsigned(15 downto 0);  -- 0-7199

        -- Debug outputs
        ref_edge_pulse       : out std_logic;            -- pulse on every ref_pulse rising edge
        ref_angle            : out unsigned(15 downto 0) -- angle_raw latched at ref_pulse
    );
end entity phase_detector;

architecture rtl of phase_detector is

    constant CYCLE_STEPS  : unsigned(15 downto 0) := to_unsigned(7200, 16);
    constant HALF_CYCLE   : unsigned(15 downto 0) := to_unsigned(3600, 16);

    signal ref_prev          : std_logic := '0';
    signal phase_offset_r    : std_logic := '0';
    signal ref_det           : std_logic := '0';
    signal ref_edge_int      : std_logic := '0';
    signal ref_angle_int     : unsigned(15 downto 0) := (others => '0');

    -- Input pipeline registers to break long nets from axi_lite_regs
    signal cam_ang_reg       : unsigned(15 downto 0) := (others => '0');
    signal tol_reg           : unsigned(15 downto 0) := (others => '0');
    signal tdc_reg           : unsigned(15 downto 0) := (others => '0');
    signal band_b_centre     : unsigned(15 downto 0) := (others => '0');

    -- angle_corr calculation
    signal angle_corr_int    : unsigned(15 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Helper: true if angle is within tolerance of centre (wraparound aware)
    -- -------------------------------------------------------------------------
    function in_band(
        angle     : unsigned(15 downto 0);
        centre    : unsigned(15 downto 0);
        tolerance : unsigned(15 downto 0)
    ) return boolean is
        variable diff : unsigned(15 downto 0);
    begin
        if angle >= centre then
            diff := angle - centre;
        else
            diff := centre - angle;
        end if;
        if diff > HALF_CYCLE then
            diff := CYCLE_STEPS - diff;
        end if;
        return diff <= tolerance;
    end function;

begin

    -- -------------------------------------------------------------------------
    -- Input pipeline registers - break long nets from axi_lite_regs
    -- -------------------------------------------------------------------------
    p_input_reg : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cam_ang_reg   <= (others => '0');
                tol_reg       <= (others => '0');
                tdc_reg       <= (others => '0');
                band_b_centre <= (others => '0');
            else
                cam_ang_reg <= expected_cam_ang;
                tol_reg     <= window_tolerance;
                tdc_reg     <= tdc_offset;
                if expected_cam_ang >= HALF_CYCLE then
                    band_b_centre <= expected_cam_ang - HALF_CYCLE;
                else
                    band_b_centre <= expected_cam_ang + HALF_CYCLE;
                end if;
            end if;
        end if;
    end process p_input_reg;

    -- -------------------------------------------------------------------------
    -- Reference pulse detection and band check
    -- -------------------------------------------------------------------------
    p_detect : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ref_prev      <= '0';
                ref_det       <= '0';
                phase_offset_r <= '0';
                ref_edge_int  <= '0';
                ref_angle_int <= (others => '0');
            else
                ref_prev     <= ref_pulse;
                ref_det      <= '0';
                ref_edge_int <= '0';

                if ref_pulse = '1' and ref_prev = '0' then
                    -- Latch angle on every ref edge (before band check, for debug)
                    ref_edge_int  <= '1';
                    ref_angle_int <= angle_raw;

                    if in_band(angle_raw, cam_ang_reg, tol_reg) then
                        -- Band A: ref on first crank rotation
                        ref_det        <= '1';
                        phase_offset_r <= '0';

                    elsif in_band(angle_raw, band_b_centre, tol_reg) then
                        -- Band B: ref on second crank rotation
                        ref_det        <= '1';
                        phase_offset_r <= '1';

                    end if;
                    -- Outside both bands: ignored
                end if;
            end if;
        end if;
    end process p_detect;

    -- -------------------------------------------------------------------------
    -- angle_corr: TDC-corrected engine angle, 4-stroke referenced
    -- phase_offset=0: angle_corr = (angle_raw + tdc_offset) mod 7200
    -- phase_offset=1: angle_corr = (angle_raw + 3600 + tdc_offset) mod 7200
    -- Updated every clock cycle
    -- -------------------------------------------------------------------------
    p_angle_corr : process(clk)
        variable raw_offset : unsigned(16 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                angle_corr_int <= (others => '0');
            else
                if phase_offset_r = '0' then
                    raw_offset := resize(angle_raw, 17) + resize(tdc_reg, 17);
                else
                    raw_offset := resize(angle_raw, 17) + resize(tdc_reg, 17) +
                                  to_unsigned(3600, 17);
                end if;
                -- Modulo 7200
                if raw_offset >= 7200 then
                    angle_corr_int <= resize(raw_offset - 7200, 16);
                else
                    angle_corr_int <= resize(raw_offset, 16);
                end if;
            end if;
        end if;
    end process p_angle_corr;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    ref_detected   <= ref_det;
    phase_offset   <= phase_offset_r;
    angle_corr     <= angle_corr_int;
    ref_edge_pulse <= ref_edge_int;
    ref_angle      <= ref_angle_int;

end architecture rtl;
