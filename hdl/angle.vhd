library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle.vhd  (v3)
--
-- Converts crank tooth edges into a 32-bit angular position accumulator
-- (angle_angfac) with optional Bresenham interpolation between teeth.
--
-- Internal unit: _angfac -- unsigned 32-bit fraction of one crank revolution.
--   Full scale (0xFFFFFFFF) = 360 crank degrees.
--   All degree conversion is performed in angus_regs.py on the PS side.
--
-- Startup (one-shot, after rst releases):
--   angle_nco_ab_inc = 0xFFFFFFFF / ppr_conf
--   Computed by u_div_startup (CACHING=1, runs once).
--   This is the angfac increment that one tooth represents.
--
-- Per ab_edge:
--   1. Snap nco_accum to (edge_count * angle_nco_ab_inc)  [exact tooth position]
--   2. Increment edge_count
--   3. If angle_interp_en='1': start u_div_tooth
--        angle_nco_clk_inc = angle_nco_ab_inc / ab_period
--        (angfac to advance per clock between teeth)
--
-- Per z_edge (every crank revolution):
--   edge_count resets to 0, nco_accum resets to 0.
--   z_edge takes priority over simultaneous ab_edge.
--   Before first z_edge: nco_accum accumulates freely from reset.
--   Downstream blocks gate on sync_full from sync.vhd.
--
-- Between ab_edges (when angle_interp_en='1' and clk_inc_valid='1'):
--   nco_accum += angle_nco_clk_inc  (every clock, Bresenham method)
--
-- Outputs:
--   angle_angfac      -- current accumulator value (0 to 0xFFFFFFFF = 0 to 360 deg)
--   angle_nco_ab_inc  -- per-tooth angfac increment, output to pll.vhd and AXI
--   angle_nco_clk_inc -- per-clock angfac increment, output to pll.vhd and AXI
--
-- Design constraint: minimum crank wheel 36-1
--   (ppr_conf >= 35, ab_period >= ~10000 clocks @ 10000 RPM)
-- =============================================================================

entity angle is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;
        -- Source signals (from src_sel)
        ab_edge           : in  std_logic;
        z_edge            : in  std_logic;
        ab_period         : in  unsigned(31 downto 0);
        ppr_conf          : in  unsigned(7 downto 0);
        -- Config
        angle_interp_en   : in  std_logic;
        -- Outputs
        angle_angfac      : out unsigned(31 downto 0);  -- angular position, 0 = 0 deg, full-scale = 360 deg
        angle_nco_ab_inc  : out unsigned(31 downto 0);  -- angfac per tooth edge
        angle_nco_clk_inc : out unsigned(31 downto 0)   -- angfac per clock (interpolation increment)
    );
end entity angle;

architecture rtl of angle is

    -- =========================================================================
    -- Startup divider: angle_nco_ab_inc = 0xFFFFFFFF / ppr_conf
    -- CACHING=1: dividend and divisor are constant after rst, so runs once.
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
    -- CACHING=1: consecutive teeth often have identical periods.
    -- =========================================================================
    signal tooth_start      : std_logic := '0';
    signal tooth_quotient   : unsigned(31 downto 0);
    signal tooth_valid      : std_logic;
    signal nco_clk_inc_int  : unsigned(31 downto 0) := (others => '0');
    signal clk_inc_valid    : std_logic := '0';

    -- =========================================================================
    -- Accumulator and tooth tracking
    -- =========================================================================
    signal nco_accum        : unsigned(31 downto 0) := (others => '0');
    signal edge_count       : unsigned(7 downto 0)  := (others => '0');

begin

    -- =========================================================================
    -- Startup divider instance
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
    -- Divisor = ppr_conf (full scale = one crank revolution = 360 deg)
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
                    startup_divisor  <= resize(ppr_conf, 32);  -- 0xFFFFFFFF / ppr_conf
                    startup_dividend <= (others => '1');        -- 0xFFFFFFFF
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
    --
    -- Priority: z_edge > ab_edge
    -- When both z_edge and ab_edge are asserted simultaneously (which occurs
    -- at the first tooth after the crank gap), z_edge resets edge_count and
    -- nco_accum and the ab_edge snap is skipped. The following ab_edge
    -- (second real tooth) snaps to edge_count=1, which is correct.
    -- =========================================================================
    p_angle : process(clk)
        variable snap : unsigned(79 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_accum       <= (others => '0');
                edge_count      <= (others => '0');
                tooth_start     <= '0';
                clk_inc_valid   <= '0';
                nco_clk_inc_int <= (others => '0');
            else
                tooth_start <= '0';

                -- Latch per-clock increment when tooth divider completes
                if tooth_valid = '1' then
                    nco_clk_inc_int <= tooth_quotient;
                    clk_inc_valid   <= '1';
                end if;

                -- -------------------------------------------------------
                -- z_edge: reset for new crank revolution (highest priority)
                -- -------------------------------------------------------
                if z_edge = '1' then
                    edge_count    <= (others => '0');
                    nco_accum     <= (others => '0');
                    clk_inc_valid <= '0';

                -- -------------------------------------------------------
                -- ab_edge: snap to exact tooth position
                -- Skipped when z_edge is simultaneously asserted.
                -- -------------------------------------------------------
                elsif ab_edge = '1' then
                    -- Snap accumulator to (edge_count × angle_nco_ab_inc).
                    -- 8-bit × 32-bit product; lower 32 bits wrap naturally
                    -- at full scale as edge_count approaches ppr_conf.
                    snap      := resize(edge_count, 40) * resize(nco_ab_inc_int, 40);
                    nco_accum <= snap(31 downto 0);
                    edge_count <= edge_count + 1;

                    -- Start per-clock increment calculation for interpolation
                    if angle_interp_en = '1' and ab_period > 0 then
                        tooth_start   <= '1';
                        clk_inc_valid <= '0';  -- old increment invalid until new one ready
                    end if;

                -- -------------------------------------------------------
                -- Between edges: Bresenham interpolation
                -- -------------------------------------------------------
                elsif angle_interp_en = '1' and clk_inc_valid = '1' then
                    nco_accum <= nco_accum + nco_clk_inc_int;
                end if;

            end if;
        end if;
    end process p_angle;

    -- =========================================================================
    -- Output assignments
    -- nco_accum is a registered signal; these are combinatorial pass-throughs.
    -- =========================================================================
    angle_angfac      <= nco_accum;
    angle_nco_ab_inc  <= nco_ab_inc_int;
    angle_nco_clk_inc <= nco_clk_inc_int;

end architecture rtl;
