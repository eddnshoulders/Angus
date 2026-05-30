library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle.vhd  (v2)
--
-- Tooth-based crank angle with optional Bresenham interpolation.
-- Internal domain: 32-bit unsigned accumulator (0 = 0 deg, 2^32-1 = 720 deg).
-- Output domain:   16-bit unsigned, 0-7199, 0.1 deg/LSB.
--
-- Startup (one shot, after rst released):
--   angle_nco_ab_inc = 0xFFFFFFFF / (ppr_conf * 2)
--   Computed by divider instance u_div_startup (CACHING=1 -- runs once).
--   Dividend = 0xFFFFFFFF, Divisor = ppr_conf * 2.
--   This is the 2^32-fraction that ONE tooth edge represents.
--
-- Per ab_edge:
--   1. Snap nco_accum to (edge_count * angle_nco_ab_inc)
--   2. Increment edge_count
--   3. If angle_interp_en='1': start divider u_div_tooth
--      angle_nco_clk_inc = angle_nco_ab_inc / ab_period
--      (the 2^32-fraction to advance per clock between teeth)
--
-- Between ab_edges (when angle_interp_en='1' and clk_inc_valid='1'):
--   nco_accum += angle_nco_clk_inc (every clock)
--
-- Per z_edge (every 2nd resets for 720 deg cycle):
--   edge_count = 0, nco_accum = 0, phase_int toggles
--
-- Output:
--   angle_deg = (nco_accum * 7200) >> 32  [0-7199, 0.1 deg/LSB]
--   angle_nco_ab_inc: output to pll.vhd and axi read register
--   angle_nco_clk_inc: output to pll.vhd as base NCO frequency word
--
-- Design constraint: minimum crank wheel 36-1
--   (ppr_conf >= 35, ab_period >= ~10000 clocks @ 10000 RPM)
-- =============================================================================

entity angle is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        -- Angle source (from src_sel)
        ab_edge          : in  std_logic;
        z_edge           : in  std_logic;
        ab_period        : in  unsigned(31 downto 0);
        ppr_conf         : in  unsigned(7 downto 0);
        -- Config
        angle_interp_en  : in  std_logic;
        -- Outputs
        angle_deg        : out unsigned(15 downto 0);
        angle_nco_ab_inc : out unsigned(31 downto 0);  -- per-tooth increment
        angle_nco_clk_inc: out unsigned(31 downto 0)   -- per-clock increment
    );
end entity angle;

architecture rtl of angle is

    -- =========================================================================
    -- Startup divider: angle_nco_ab_inc = 0xFFFFFFFF / (ppr_conf * 2)
    -- =========================================================================
    signal startup_start    : std_logic := '0';
    signal startup_dividend : unsigned(31 downto 0) := (others => '1');
    signal startup_divisor  : unsigned(31 downto 0) := (others => '0');
    signal startup_quotient : unsigned(31 downto 0);
    signal startup_valid    : std_logic;
    signal nco_ab_inc_int   : unsigned(31 downto 0) := (others => '0');
    signal startup_done     : std_logic := '0';
    signal rst_prev         : std_logic := '1';

    -- =========================================================================
    -- Per-tooth divider: angle_nco_clk_inc = angle_nco_ab_inc / ab_period
    -- =========================================================================
    signal tooth_start      : std_logic := '0';
    signal tooth_quotient   : unsigned(31 downto 0);
    signal tooth_valid      : std_logic;
    signal nco_clk_inc_int  : unsigned(31 downto 0) := (others => '0');
    signal clk_inc_valid    : std_logic := '0';

    -- =========================================================================
    -- Accumulator and angle tracking
    -- =========================================================================
    signal nco_accum        : unsigned(31 downto 0) := (others => '0');
    signal edge_count       : unsigned(7 downto 0)  := (others => '0');
    signal z_phase_cnt      : unsigned(1 downto 0)  := (others => '0');
    signal angle_deg_reg    : unsigned(15 downto 0) := (others => '0');

    -- =========================================================================
    -- Output conversion: (nco_accum * 7200) >> 32
    -- =========================================================================
    function ang_convert(accum : unsigned(31 downto 0)) return unsigned is
        variable prod : unsigned(47 downto 0);
    begin
        prod := accum * to_unsigned(7200, 16);
        return prod(47 downto 32);
    end function;

begin

    -- =========================================================================
    -- Startup divider instance
    -- CACHING=1: same dividend/divisor every time so runs once effectively
    -- =========================================================================
    u_div_startup : entity work.divider
        generic map (WIDTH => 32, CACHING => 1, INIT_VLD => 0)
        port map (
            clk       => clk,
            rst       => rst,
            start     => startup_start,
            dividend  => startup_dividend,
            divisor   => startup_divisor,
            quotient  => startup_quotient,
            remainder => open,
            zero_err  => open,
            valid     => startup_valid
        );

    -- =========================================================================
    -- Per-tooth divider instance
    -- CACHING=1: consecutive teeth often have same period
    -- =========================================================================
    u_div_tooth : entity work.divider
        generic map (WIDTH => 32, CACHING => 1, INIT_VLD => 0)
        port map (
            clk       => clk,
            rst       => rst,
            start     => tooth_start,
            dividend  => nco_ab_inc_int,
            divisor   => ab_period,
            quotient  => tooth_quotient,
            remainder => open,
            zero_err  => open,
            valid     => tooth_valid
        );

    -- =========================================================================
    -- Startup: fire divider one cycle after rst releases
    -- =========================================================================
    p_startup : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                startup_start   <= '0';
                startup_done    <= '0';
                startup_divisor <= (others => '0');
                rst_prev        <= '1';
                nco_ab_inc_int  <= (others => '0');
            else
                startup_start <= '0';
                rst_prev      <= rst;

                -- Fire one cycle after rst releases
                if rst_prev = '1' and rst = '0' and startup_done = '0' then
                    startup_divisor  <= resize(ppr_conf * to_unsigned(2, 8), 32);
                    startup_dividend <= (others => '1');  -- 0xFFFFFFFF
                    startup_start    <= '1';
                end if;

                -- Latch result when valid
                if startup_valid = '1' and startup_done = '0' then
                    nco_ab_inc_int <= startup_quotient;
                    startup_done   <= '1';
                end if;
            end if;
        end if;
    end process p_startup;

    -- =========================================================================
    -- Main angle process
    -- =========================================================================
    p_angle : process(clk)
        variable snap : unsigned(79 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_accum      <= (others => '0');
                edge_count     <= (others => '0');
                z_phase_cnt    <= (others => '0');
                tooth_start    <= '0';
                clk_inc_valid  <= '0';
                nco_clk_inc_int <= (others => '0');
                angle_deg_reg  <= (others => '0');
            else
                tooth_start <= '0';

                -- Latch per-clock increment when tooth divider completes
                if tooth_valid = '1' then
                    nco_clk_inc_int <= tooth_quotient;
                    clk_inc_valid   <= '1';
                end if;

                -- z_edge: reset every 2nd z for 720 deg cycle
                if z_edge = '1' then
                    if z_phase_cnt = "01" then
                        edge_count  <= (others => '0');
                        nco_accum   <= (others => '0');
                        z_phase_cnt <= (others => '0');
                        clk_inc_valid <= '0';
                    else
                        z_phase_cnt <= z_phase_cnt + 1;
                    end if;
                end if;

                -- ab_edge: snap and start per-tooth divider
                if ab_edge = '1' then
                    -- Snap to exact tooth position
                    snap      := resize(edge_count, 40) * resize(nco_ab_inc_int, 40);
                    nco_accum <= snap(31 downto 0);  -- lower 32 bits (wraps correctly)
                    edge_count <= edge_count + 1;

                    -- Start per-clock increment calculation
                    if angle_interp_en = '1' and ab_period > 0 then
                        tooth_start   <= '1';
                        clk_inc_valid <= '0';  -- new tooth, old inc invalid until new one ready
                    end if;

                elsif angle_interp_en = '1' and clk_inc_valid = '1' then
                    -- Bresenham interpolation: advance accumulator each clock
                    nco_accum <= nco_accum + nco_clk_inc_int;
                end if;
                -- Register angle_deg output (breaks multiply from downstream logic)
                angle_deg_reg <= ang_convert(nco_accum);
            end if;
        end if;
    end process p_angle;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    angle_deg         <= angle_deg_reg;
    angle_nco_ab_inc  <= nco_ab_inc_int;
    angle_nco_clk_inc <= nco_clk_inc_int;

end architecture rtl;
