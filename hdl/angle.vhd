library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle.vhd
-- Tooth-based crank angle with Bresenham linear interpolation.
-- angle_deg: 0-7199, 0.1 deg/LSB over 720 deg (2 crank revolutions).
-- First z_edge after reset sets origin (angle=0, phase=0).
-- angle_phase toggles on each subsequent z_edge.
-- degrees_per_edge = 7200 / (ppr_conf * 2) -- both edges of ab counted.
-- Bresenham: frac_accum += degrees_per_edge per clock;
--            when frac_accum >= ab_period: interp++, frac_accum -= ab_period.
-- =============================================================================
entity angle is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        ab_edge        : in  std_logic;  -- from src_sel (both edges)
        z_edge         : in  std_logic;  -- from src_sel
        ab_period      : in  unsigned(31 downto 0);
        ppr_conf       : in  unsigned(7 downto 0);
        angle_deg      : out unsigned(15 downto 0);
        angle_phase    : out std_logic
    );
end entity angle;

architecture rtl of angle is
    -- degrees_per_edge = 7200 / (ppr_conf * 2)
    -- For ppr=60: 7200/120 = 60
    signal deg_per_edge  : unsigned(15 downto 0) := to_unsigned(60, 16);
    signal first_z_seen  : std_logic := '0';
    signal edge_count    : unsigned(7 downto 0)  := (others => '0');
    signal base_angle    : unsigned(15 downto 0) := (others => '0');
    signal interp        : unsigned(15 downto 0) := (others => '0');
    signal frac_accum    : unsigned(31 downto 0) := (others => '0');
    signal phase_int     : std_logic := '0';
    signal angle_raw     : unsigned(15 downto 0) := (others => '0');
begin

    -- degrees_per_edge lookup (combinatorial)
    process(ppr_conf)
    begin
        case to_integer(ppr_conf) is
            when 36  => deg_per_edge <= to_unsigned(100, 16);
            when 58  => deg_per_edge <= to_unsigned(62,  16);
            when 60  => deg_per_edge <= to_unsigned(60,  16);
            when 72  => deg_per_edge <= to_unsigned(50,  16);
            when 90  => deg_per_edge <= to_unsigned(40,  16);
            when 120 => deg_per_edge <= to_unsigned(30,  16);
            when others => deg_per_edge <= to_unsigned(60, 16);
        end case;
    end process;

    p_angle : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                first_z_seen <= '0';
                edge_count   <= (others => '0');
                base_angle   <= (others => '0');
                interp       <= (others => '0');
                frac_accum   <= (others => '0');
                phase_int    <= '0';
            else
                if z_edge = '1' then
                    if first_z_seen = '0' then
                        -- First Z: set origin
                        first_z_seen <= '1';
                        phase_int    <= '0';
                        base_angle   <= (others => '0');
                        interp       <= (others => '0');
                        frac_accum   <= (others => '0');
                        edge_count   <= (others => '0');
                    else
                        -- Subsequent Z: toggle phase
                        phase_int <= not phase_int;
                        if phase_int = '1' then
                            -- Second Z of pair: reset for new 720 deg cycle
                            base_angle <= (others => '0');
                            interp     <= (others => '0');
                            frac_accum <= (others => '0');
                            edge_count <= (others => '0');
                        end if;
                    end if;

                elsif ab_edge = '1' and first_z_seen = '1' then
                    -- Snap base angle, reset interpolation
                    base_angle <= resize(edge_count * deg_per_edge, 16);
                    interp     <= (others => '0');
                    frac_accum <= (others => '0');
                    edge_count <= edge_count + 1;

                elsif first_z_seen = '1' and ab_period > 0 then
                    -- Bresenham interpolation
                    if frac_accum + deg_per_edge >= ab_period then
                        if interp < deg_per_edge - 1 then
                            interp <= interp + 1;
                        end if;
                        frac_accum <= frac_accum + deg_per_edge - ab_period;
                    else
                        frac_accum <= frac_accum + deg_per_edge;
                    end if;
                end if;
            end if;
        end if;
    end process p_angle;

    angle_raw  <= base_angle + interp;
    angle_deg  <= angle_raw;
    angle_phase <= phase_int;
end architecture rtl;
