library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- phase.vhd
-- Phase detection and engine angle calculation.
--
-- phase_raw: 0 when angle_deg in [0,3599], 1 when in [3600,7199]
--
-- Window detection on ref_edge:
--   window1 = phase_ref_ang +/- phase_ref_tol
--   window2 = (phase_ref_ang + 3600) % 7200 +/- phase_ref_tol
--   ref_edge in window1: phase_inv=0, phase_ref_det=1
--   ref_edge in window2: phase_inv=1, phase_ref_det=1
--   First phase_ref_det: latch phase_inv -> phase_inv_latch, phase_ref_found=1
--
-- phase_ang_corr = (angle_deg + phase_inv_latch*3600) % 7200
-- phase_ang_eng  = (phase_ang_corr + tdc_offset) % 7200  [held 0 until phase_ref_found]
-- phase_eng      = phase_raw XOR phase_inv_latch
--
-- phase_ref_ok:
--   Set 1 when phase_ref_det=1 and phase_inv=phase_inv_latch (correct window)
--   Set 0 when phase_ref_det=1 and phase_inv/=phase_inv_latch (wrong window)
--   Set 0 if 3 z_edges pass without phase_ref_det incrementing
-- =============================================================================
entity phase is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        ref_edge        : in  std_logic;
        angle_deg       : in  unsigned(15 downto 0);
        z_edge          : in  std_logic;
        phase_ref_ang   : in  unsigned(15 downto 0);
        phase_ref_tol   : in  unsigned(15 downto 0);
        tdc_offset      : in  unsigned(15 downto 0);
        -- Outputs
        phase_raw       : out std_logic;
        phase_ref_det   : out std_logic;
        phase_ref_ok    : out std_logic;
        phase_ref_found : out std_logic;
        phase_inv       : out std_logic;
        phase_inv_latch : out std_logic;
        phase_ang_corr  : out unsigned(15 downto 0);
        phase_eng       : out std_logic;
        phase_ang_eng   : out unsigned(15 downto 0);
        phase_ref_det_cnt: out unsigned(15 downto 0)
    );
end entity phase;

architecture rtl of phase is
    signal phase_inv_int    : std_logic := '0';
    signal phase_inv_l_int  : std_logic := '0';
    signal phase_ref_found_int: std_logic := '0';
    signal phase_ref_ok_int : std_logic := '0';
    signal phase_ref_det_int: std_logic := '0';
    signal det_cnt_int      : unsigned(15 downto 0) := (others => '0');
    signal det_cnt_prev     : unsigned(15 downto 0) := (others => '0');
    signal z_miss_cnt       : unsigned(1 downto 0) := (others => '0');

    -- Window check: is val within centre +/- tol (mod 7200)?
    function in_window(val, centre, tol : unsigned(15 downto 0)) return boolean is
        variable lo, hi : unsigned(15 downto 0);
        variable diff   : unsigned(15 downto 0);
    begin
        if val >= centre then
            diff := val - centre;
        else
            diff := centre - val;
        end if;
        -- Handle wrap: if diff > 3600 then wrapped distance
        if diff > to_unsigned(3600, 16) then
            diff := to_unsigned(7200, 16) - diff;
        end if;
        return diff <= tol;
    end function;

    -- Modulo 7200
    function mod7200(v : unsigned(16 downto 0)) return unsigned is
    begin
        if v >= to_unsigned(7200, 17) then
            return v(15 downto 0) - to_unsigned(7200, 16);
        else
            return v(15 downto 0);
        end if;
    end function;

    signal w2_centre : unsigned(15 downto 0) := (others => '0');
    signal ang_corr_int : unsigned(15 downto 0) := (others => '0');
    signal ang_eng_int  : unsigned(15 downto 0) := (others => '0');

begin

    -- window2 centre = (phase_ref_ang + 3600) % 7200
    w2_centre <= mod7200(resize(phase_ref_ang, 17) + to_unsigned(3600, 17));

    -- phase_raw
    phase_raw <= '1' when angle_deg >= to_unsigned(3600, 16) else '0';

    -- phase_ang_corr
    ang_corr_int <= mod7200(resize(angle_deg, 17) + to_unsigned(3600, 17))
                    when phase_inv_l_int = '1' else angle_deg;
    phase_ang_corr <= ang_corr_int;

    -- phase_ang_eng (held 0 until phase_ref_found)
    ang_eng_int <= mod7200(resize(ang_corr_int, 17) + resize(tdc_offset, 17))
                   when phase_ref_found_int = '1' else (others => '0');
    phase_ang_eng <= ang_eng_int;

    -- phase_eng
    phase_eng <= (angle_deg(12)) xor phase_inv_l_int;  -- bit 12 set when >= 4096 ~ >= 3600

    p_phase : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_inv_int     <= '0';
                phase_inv_l_int   <= '0';
                phase_ref_found_int <= '0';
                phase_ref_ok_int  <= '0';
                phase_ref_det_int <= '0';
                det_cnt_int       <= (others => '0');
                det_cnt_prev      <= (others => '0');
                z_miss_cnt        <= (others => '0');
            else
                phase_ref_det_int <= '0';

                -- z_edge: check for missed ref detections
                if z_edge = '1' then
                    if det_cnt_int = det_cnt_prev then
                        -- No new ref detection since last z_edge
                        z_miss_cnt <= z_miss_cnt + 1;
                        if z_miss_cnt >= "10" then  -- 3rd consecutive miss
                            phase_ref_ok_int <= '0';
                            z_miss_cnt <= (others => '0');
                        end if;
                    else
                        z_miss_cnt   <= (others => '0');
                        det_cnt_prev <= det_cnt_int;
                    end if;
                end if;

                -- ref_edge detection
                if ref_edge = '1' then
                    if in_window(angle_deg, phase_ref_ang, phase_ref_tol) then
                        phase_inv_int <= '0';
                        phase_ref_det_int <= '1';
                        det_cnt_int <= det_cnt_int + 1;
                        if phase_ref_found_int = '0' then
                            phase_inv_l_int <= '0';
                            phase_ref_found_int <= '1';
                        end if;
                        if phase_inv_l_int = '0' then
                            phase_ref_ok_int <= '1';
                        else
                            phase_ref_ok_int <= '0';
                        end if;
                    elsif in_window(angle_deg, w2_centre, phase_ref_tol) then
                        phase_inv_int <= '1';
                        phase_ref_det_int <= '1';
                        det_cnt_int <= det_cnt_int + 1;
                        if phase_ref_found_int = '0' then
                            phase_inv_l_int <= '1';
                            phase_ref_found_int <= '1';
                        end if;
                        if phase_inv_l_int = '1' then
                            phase_ref_ok_int <= '1';
                        else
                            phase_ref_ok_int <= '0';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_phase;

    phase_inv       <= phase_inv_int;
    phase_inv_latch <= phase_inv_l_int;
    phase_ref_found <= phase_ref_found_int;
    phase_ref_ok    <= phase_ref_ok_int;
    phase_ref_det   <= phase_ref_det_int;
    phase_ref_det_cnt <= det_cnt_int;

end architecture rtl;
