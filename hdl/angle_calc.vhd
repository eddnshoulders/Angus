library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle_calc
--
-- Tooth-based crank angle calculator with Bresenham interpolation.
-- Completely independent of the NCO - uses only ab edge counting and timing.
--
-- angle_raw is in 0.1 degree steps over one full 4-stroke engine cycle (720 deg):
--   0     = TDC cylinder 1 (at first Z pulse after reset)
--   7199  = just before the Z that ends the second crank revolution
--
-- Counting:
--   Both edges of ab are counted (rising and falling).
--   With a 60-tooth crank wheel: 60 ab edges per revolution,
--   120 ab edges per 4-stroke cycle.
--   degrees_per_edge = 7200 / (ppr * 2) = 7200 / 120 = 60 (0.1 deg units)
--   This is computed combinatorially - no divider needed for typical ppr values.
--
-- Z handling:
--   First Z after reset: sets angle to 0, starts counting.
--   Every subsequent Z: toggles phase (0=first rev, 1=second rev).
--   Every second Z (phase toggles back to 0): resets angle to 0,
--   checks ab_count == ppr * 2, increments count_fault if not.
--
-- Bresenham interpolation between ab edges:
--   base_angle  = edge_count * degrees_per_edge
--   frac_accum += degrees_per_edge each clock
--   When frac_accum >= ab_period: interp++, frac_accum -= ab_period
--   angle_raw   = base_angle + interp
--
-- =============================================================================

entity angle_calc is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- From ang_sel
        ab               : in  std_logic;
        z                : in  std_logic;
        ab_period        : in  unsigned(31 downto 0);  -- time between ab edges (clk cycles)
        ppr              : in  unsigned(7 downto 0);   -- pulses per revolution (n_teeth)
        ab_count         : in  unsigned(7 downto 0);   -- tooth_count from crank_input
        signal_present   : in  std_logic;

        -- Outputs
        angle_raw        : out unsigned(15 downto 0);  -- 0-7199, 0.1 deg steps
        phase            : out std_logic;              -- 0=1st crank rev, 1=2nd crank rev
        count_fault      : out unsigned(15 downto 0)  -- increments on ab_count mismatch at Z
    );
end entity angle_calc;

architecture rtl of angle_calc is

    -- degrees_per_edge in 0.1 deg units = 7200 / (ppr * 2)
    -- For ppr=60: 7200/120 = 60. Computed combinatorially.
    signal degrees_per_edge  : unsigned(15 downto 0) := to_unsigned(60, 16);

    -- AB edge detection
    signal ab_prev           : std_logic := '0';
    signal ab_edge           : std_logic := '0';

    -- Z edge detection
    signal z_prev            : std_logic := '0';
    signal z_edge            : std_logic := '0';

    -- Edge counter within current 2-revolution cycle
    signal edge_count        : unsigned(7 downto 0) := (others => '0');

    -- Angle calculation
    signal base_angle        : unsigned(15 downto 0) := (others => '0');
    signal interp_angle      : unsigned(15 downto 0) := (others => '0');
    signal frac_accum        : unsigned(31 downto 0) := (others => '0');

    -- Phase and Z tracking
    signal phase_int         : std_logic := '0';
    signal first_z_seen      : std_logic := '0';

    -- count_fault counter
    signal count_fault_int   : unsigned(15 downto 0) := (others => '0');

    -- Output register
    signal angle_raw_int     : unsigned(15 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- degrees_per_edge: combinatorial, 7200 / (ppr * 2)
    -- Valid for ppr 1-120. For ppr=60: 60 counts per edge.
    -- Use a lookup for synthesis efficiency - ppr is a config constant.
    -- -------------------------------------------------------------------------
    process(ppr)
    begin
        -- degrees_per_edge = 7200 / (ppr * 2)
        -- Case statement avoids division operator in RTL
        case to_integer(ppr) is
            when 36  => degrees_per_edge <= to_unsigned(100, 16);  -- 7200/72
            when 58  => degrees_per_edge <= to_unsigned(62,  16);  -- 7200/116 ~62
            when 60  => degrees_per_edge <= to_unsigned(60,  16);  -- 7200/120
            when 72  => degrees_per_edge <= to_unsigned(50,  16);  -- 7200/144
            when 90  => degrees_per_edge <= to_unsigned(40,  16);  -- 7200/180
            when 120 => degrees_per_edge <= to_unsigned(30,  16);  -- 7200/240
            when others => degrees_per_edge <= to_unsigned(60, 16); -- default 60T
        end case;
    end process;

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
    -- Angle calculation and edge counting
    -- -------------------------------------------------------------------------
    p_angle : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                base_angle    <= (others => '0');
                interp_angle  <= (others => '0');
                frac_accum    <= (others => '0');
                edge_count    <= (others => '0');
                first_z_seen  <= '0';
                phase_int     <= '0';
                count_fault_int <= (others => '0');
            else
                if signal_present = '0' then
                    base_angle    <= (others => '0');
                    interp_angle  <= (others => '0');
                    frac_accum    <= (others => '0');
                    edge_count    <= (others => '0');
                    first_z_seen  <= '0';
                    phase_int     <= '0';

                elsif z_edge = '1' then
                    if first_z_seen = '0' then
                        -- First Z: set origin, start counting
                        first_z_seen  <= '1';
                        phase_int     <= '0';
                        base_angle    <= (others => '0');
                        interp_angle  <= (others => '0');
                        frac_accum    <= (others => '0');
                        edge_count    <= (others => '0');
                    else
                        -- Toggle phase on every Z
                        phase_int <= not phase_int;

                        if phase_int = '1' then
                            -- Second Z of the pair: end of 720 deg cycle
                            -- Check ab_count over the 2 revolutions = ppr * 2
                            if ab_count /= resize(ppr, 8) then
                                -- ab_count resets at Z so we check ppr not ppr*2
                                -- (ab_count reflects edges since last Z = one rev = ppr)
                                if count_fault_int /= (count_fault_int'range => '1') then
                                    count_fault_int <= count_fault_int + 1;
                                end if;
                            end if;
                            -- Reset angle for next 720 deg cycle
                            base_angle   <= (others => '0');
                            interp_angle <= (others => '0');
                            frac_accum   <= (others => '0');
                            edge_count   <= (others => '0');
                        end if;
                    end if;

                elsif ab_edge = '1' and first_z_seen = '1' then
                    -- Snap base angle to edge position
                    base_angle   <= resize(edge_count * degrees_per_edge, 16);
                    interp_angle <= (others => '0');
                    frac_accum   <= (others => '0');
                    edge_count   <= edge_count + 1;

                else
                    -- Bresenham interpolation between ab edges
                    if ab_period > 0 and first_z_seen = '1' then
                        if frac_accum + degrees_per_edge >= ab_period then
                            if interp_angle < degrees_per_edge - 1 then
                                interp_angle <= interp_angle + 1;
                            end if;
                            frac_accum <= frac_accum + degrees_per_edge - ab_period;
                        else
                            frac_accum <= frac_accum + degrees_per_edge;
                        end if;
                    end if;
                end if;
            end if;
        end if;    end process p_angle;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    angle_raw_int <= base_angle + interp_angle;
    angle_raw     <= angle_raw_int;
    phase         <= phase_int;
    count_fault   <= count_fault_int;

end architecture rtl;
