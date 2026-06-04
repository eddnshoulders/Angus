library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- phase.vhd  (v3)
--
-- Engine phase detection from a cam (or peak) reference edge.
-- Internal unit: _angfac -- unsigned 32-bit fraction of one crank revolution.
-- All degree conversion is performed in angus_regs.py on the PS side.
--
-- Window detection:
--   ref_edge is expected when: phase_ref_min <= angle_angfac <= phase_ref_max.
--   The window boundaries are computed in angus_regs.py from the user-configured
--   degree values and the current nco_ab_inc scaling, then written as angfac
--   values to the AXI registers.
--
--   Design constraint: the detection window must not span the crank Z edge
--   (i.e., phase_ref_min > 0 and phase_ref_max < 0xFFFFFFFF).
--   This is always satisfied on correctly designed cam profiles -- the cam
--   distinguishing edge is placed well clear of the crank gap. angus_regs.py
--   also clamps window boundaries to enforce this.
--
-- phase_eng: indicates which crank revolution (engine phase) we are in.
--   Held at 0 until phase_ref_found = 1.
--   On first detection: phase_eng latched to phase_ref_phase.
--   On every z_edge thereafter: phase_eng toggles.
--
--   Note on simultaneous z_edge + ref_edge:
--   If the first detection and a z_edge arrive at the same clock (which would
--   place the cam edge at 0 deg, violating the window constraint), the toggle
--   gate (phase_ref_found = '0') prevents the z_edge from toggling, and
--   phase_eng is set correctly from the detection. In all subsequent cycles,
--   z_edge fires (toggles phase_eng) before or after the ref_edge -- never at
--   the same clock given the window constraint.
--
-- phase_ref_ok:
--   Set 1 on each valid ref_edge detection in window.
--   Set 0 after 3 consecutive z_edges without a new detection.
--   The cam fires once per engine cycle (every 2 crank revolutions), so one
--   z_edge per 2 will normally see no detection increment -- this is correct.
--   Three consecutive non-incrementing z_edges (~1.5 missed engine cycles)
--   indicates a lost cam signal.
--
-- phase_ref_angfac: latches angle_angfac at each detection (debug/diagnostics).
-- =============================================================================

entity phase is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        -- Reference edge (from ref_sel)
        ref_edge         : in  std_logic;
        -- Angular position (from angle.vhd)
        angle_angfac     : in  unsigned(31 downto 0);
        -- Crank revolution boundary (from src_sel)
        z_edge           : in  std_logic;
        -- Detection window config (startup, set via AXI, computed by angus_regs.py)
        phase_ref_min    : in  unsigned(31 downto 0);  -- window lower bound (angfac)
        phase_ref_max    : in  unsigned(31 downto 0);  -- window upper bound (angfac)
        phase_ref_phase  : in  std_logic;              -- expected phase_eng value at detection
        -- Outputs
        phase_ref_det    : out std_logic;              -- 1-clock strobe: ref detected in window
        phase_ref_ok     : out std_logic;              -- 1 = cam detection healthy
        phase_ref_found  : out std_logic;              -- latched 1 on first detection
        phase_eng        : out std_logic;              -- engine phase: 0 or 1
        phase_ref_angfac : out unsigned(31 downto 0);  -- angle_angfac at last detection
        phase_ref_det_cnt: out unsigned(15 downto 0)   -- cumulative detection count
    );
end entity phase;

architecture rtl of phase is

    -- =========================================================================
    -- Registered config inputs (break AXI register from detection logic)
    -- =========================================================================
    signal phase_ref_min_r    : unsigned(31 downto 0) := (others => '0');
    signal phase_ref_max_r    : unsigned(31 downto 0) := (others => '1');
    signal phase_ref_phase_r  : std_logic             := '0';

    -- =========================================================================
    -- Internal state
    -- =========================================================================
    signal phase_eng_int      : std_logic             := '0';
    signal phase_ref_found_int: std_logic             := '0';
    signal phase_ref_ok_int   : std_logic             := '0';
    signal phase_ref_det_int  : std_logic             := '0';
    signal phase_ref_angfac_int : unsigned(31 downto 0) := (others => '0');
    signal det_cnt_int        : unsigned(15 downto 0) := (others => '0');
    signal det_cnt_prev       : unsigned(15 downto 0) := (others => '0');
    signal z_miss_cnt         : unsigned(1 downto 0)  := (others => '0');

    -- =========================================================================
    -- Window check: true when angfac falls within the configured detection band
    -- =========================================================================
    function in_window(
        angfac  : unsigned(31 downto 0);
        win_min : unsigned(31 downto 0);
        win_max : unsigned(31 downto 0)
    ) return boolean is
    begin
        return angfac >= win_min and angfac <= win_max;
    end function;

begin

    -- =========================================================================
    -- Phase detection process
    -- =========================================================================
    p_phase : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_ref_min_r     <= (others => '0');
                phase_ref_max_r     <= (others => '1');
                phase_ref_phase_r   <= '0';
                phase_eng_int       <= '0';
                phase_ref_found_int <= '0';
                phase_ref_ok_int    <= '0';
                phase_ref_det_int   <= '0';
                phase_ref_angfac_int <= (others => '0');
                det_cnt_int         <= (others => '0');
                det_cnt_prev        <= (others => '0');
                z_miss_cnt          <= (others => '0');
            else
                -- Register config inputs each clock
                phase_ref_min_r   <= phase_ref_min;
                phase_ref_max_r   <= phase_ref_max;
                phase_ref_phase_r <= phase_ref_phase;

                phase_ref_det_int <= '0';   -- default: strobe is 1 clock wide

                -- -------------------------------------------------------
                -- z_edge: toggle phase_eng each crank revolution, and
                -- track missed detections for phase_ref_ok health.
                -- -------------------------------------------------------
                if z_edge = '1' then

                    -- Toggle phase_eng once phase is established
                    if phase_ref_found_int = '1' then
                        phase_eng_int <= not phase_eng_int;
                    end if;

                    -- Miss counting: det_cnt should increment every 2
                    -- z_edges (one engine cycle). Flag as a miss only when
                    -- det_cnt has not changed since the previous z_edge.
                    -- Three consecutive misses clear phase_ref_ok.
                    if det_cnt_int = det_cnt_prev then
                        if z_miss_cnt = "10" then
                            phase_ref_ok_int <= '0';
                            z_miss_cnt       <= (others => '0');
                        else
                            z_miss_cnt <= z_miss_cnt + 1;
                        end if;
                    else
                        z_miss_cnt   <= (others => '0');
                        det_cnt_prev <= det_cnt_int;
                    end if;

                end if;

                -- -------------------------------------------------------
                -- ref_edge: window detection.
                -- On first detection: latch phase_eng and phase_ref_found.
                -- Every detection: strobe phase_ref_det, latch angfac,
                -- increment counter, assert phase_ref_ok.
                -- -------------------------------------------------------
                if ref_edge = '1' and
                   in_window(angle_angfac, phase_ref_min_r, phase_ref_max_r) then

                    phase_ref_det_int    <= '1';
                    phase_ref_angfac_int <= angle_angfac;
                    det_cnt_int          <= det_cnt_int + 1;
                    phase_ref_ok_int     <= '1';
                    z_miss_cnt           <= (others => '0');

                    if phase_ref_found_int = '0' then
                        phase_ref_found_int <= '1';
                        phase_eng_int       <= phase_ref_phase_r;
                    end if;

                end if;

            end if;
        end if;
    end process p_phase;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    phase_ref_det     <= phase_ref_det_int;
    phase_ref_ok      <= phase_ref_ok_int;
    phase_ref_found   <= phase_ref_found_int;
    phase_eng         <= phase_eng_int;
    phase_ref_angfac  <= phase_ref_angfac_int;
    phase_ref_det_cnt <= det_cnt_int;

end architecture rtl;
