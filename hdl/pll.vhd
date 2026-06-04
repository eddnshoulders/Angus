library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- pll.vhd  (v3)
--
-- NCO + PI loop for high-resolution engine angle tracking.
-- Internal unit: _angfac -- unsigned 32-bit fraction of one crank revolution.
-- Full scale (0xFFFFFFFF) = 360 crank degrees.
-- All degree conversion is performed in angus_regs.py on the PS side.
--
-- The NCO accumulates angle_nco_clk_inc every clock, corrected by the PI loop
-- at each ab_edge. The PI correction steers the NCO to stay aligned with
-- the tooth-based accumulator from angle.vhd.
--
-- Phase error:
--   pll_err_angfac = nco_accum - (ab_count * angle_nco_ab_inc)
--   Calculated at each ab_edge using the current ab_count from src_sel.
--   This is the signed deviation of the PLL accumulator from the expected
--   tooth-snap position.
--
-- PI loop (updates at each ab_edge):
--   P term: pll_err_angfac * kp  (1-tooth lag on registered error)
--   I term: accumulated (pll_err_angfac * ab_period * ki)
--           ab_period is used as the integration dt to give consistent
--           integral gain across varying engine speeds.
--   nco_inc = angle_nco_clk_inc +/- pi_corr  (bounded by pll_corr_max)
--   Direction: pll_corr_dir=1 adds correction, pll_corr_dir=0 subtracts.
--
-- Reset behaviour:
--   nco_accum resets to 0 on every z_edge (one crank revolution boundary).
--   NCO and PI state held at 0 until sync_full = 1.
--   nco_inc pre-loaded with angle_nco_clk_inc when sync_full = 0 so the
--   NCO starts at the correct speed immediately on sync.
--
-- PI pipeline (to keep DSP multiplies off the critical path):
--   Stage 1: err * ab_period  (at ab_edge)
--   Stage 2: result * ki      (next clock)
--   Stage 3: accumulate into i_term  (clock after that)
--   P term uses registered phase_err_int (1-tooth lag, consistent with I lag)
-- =============================================================================

entity pll is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;
        -- Sync gating
        sync_full         : in  std_logic;
        -- Source signals (from src_sel)
        ab_edge           : in  std_logic;
        ab_period         : in  unsigned(31 downto 0);
        ab_count          : in  unsigned(7 downto 0);
        z_edge            : in  std_logic;
        -- Increments from angle.vhd
        angle_nco_ab_inc  : in  unsigned(31 downto 0);  -- angfac per tooth edge
        angle_nco_clk_inc : in  unsigned(31 downto 0);  -- angfac per clock
        -- PI config
        pll_kp            : in  unsigned(15 downto 0);
        pll_ki            : in  unsigned(15 downto 0);
        pll_corr_dir      : in  std_logic;              -- 0=subtract, 1=add correction
        pll_corr_max      : in  unsigned(15 downto 0);
        -- Outputs
        pll_angfac        : out unsigned(31 downto 0);  -- NCO position (angfac)
        pll_div_valid     : out std_logic;              -- 1 when sync_full=1
        pll_nco_inc       : out unsigned(31 downto 0);  -- current NCO increment per clock
        pll_nco_accum     : out unsigned(31 downto 0);  -- NCO accumulator (= pll_angfac)
        pll_err_angfac    : out signed(31 downto 0);    -- signed phase error (angfac units)
        pll_p_term        : out signed(31 downto 0);    -- proportional term
        pll_i_term        : out signed(31 downto 0);    -- integral term (upper 32 of 64)
        pll_pi_corr       : out signed(31 downto 0)     -- PI correction applied to nco_inc
    );
end entity pll;

architecture rtl of pll is

    -- =========================================================================
    -- Internal state
    -- =========================================================================
    signal nco_accum_int  : unsigned(31 downto 0) := (others => '0');
    signal nco_inc_int    : unsigned(31 downto 0) := (others => '0');
    signal phase_err_int  : signed(31 downto 0)   := (others => '0');
    signal p_term_int     : signed(31 downto 0)   := (others => '0');
    signal i_term_int     : signed(63 downto 0)   := (others => '0');
    signal pi_corr_int    : signed(31 downto 0)   := (others => '0');

    -- PI pipeline stage 1: err * ab_period
    signal i_upd_pipe     : signed(63 downto 0)   := (others => '0');
    signal i_pipe_valid   : std_logic              := '0';

    -- PI pipeline stage 2: scaled * ki
    signal i_ki_pipe      : signed(63 downto 0)   := (others => '0');
    signal i_ki_valid     : std_logic              := '0';

    -- Correction limit as signed for comparisons
    signal corr_max_s     : signed(32 downto 0);

begin

    corr_max_s <= signed(resize(pll_corr_max, 33));

    -- =========================================================================
    -- PLL process
    -- =========================================================================
    p_pll : process(clk)
        variable err      : signed(31 downto 0);
        variable p_t      : signed(48 downto 0);
        variable i_scaled : signed(47 downto 0);
        variable i_ki     : signed(63 downto 0);
        variable corr     : signed(32 downto 0);
        variable exp_acc  : unsigned(39 downto 0);   -- 8-bit ab_count × 32-bit nco_ab_inc
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_accum_int  <= (others => '0');
                nco_inc_int    <= (others => '0');
                phase_err_int  <= (others => '0');
                p_term_int     <= (others => '0');
                i_term_int     <= (others => '0');
                pi_corr_int    <= (others => '0');
                i_upd_pipe     <= (others => '0');
                i_pipe_valid   <= '0';
                i_ki_pipe      <= (others => '0');
                i_ki_valid     <= '0';

            elsif sync_full = '1' then

                -- -------------------------------------------------------
                -- NCO runs every clock
                -- -------------------------------------------------------
                nco_accum_int <= nco_accum_int + nco_inc_int;

                -- -------------------------------------------------------
                -- z_edge: reset accumulator each crank revolution
                -- -------------------------------------------------------
                if z_edge = '1' then
                    nco_accum_int <= (others => '0');
                end if;

                -- -------------------------------------------------------
                -- ab_edge: calculate phase error and update PI loop
                -- nco_inc update uses pi_corr_int from the previous ab_edge
                -- (1-tooth latency -- harmless at engine speeds)
                -- -------------------------------------------------------
                if ab_edge = '1' then

                    -- Phase error: deviation from expected tooth position.
                    -- ab_count × angle_nco_ab_inc = expected accumulator value.
                    -- 8-bit × 32-bit = 40-bit; lower 32 bits wrap naturally.
                    exp_acc := ab_count * angle_nco_ab_inc;
                    err := signed(nco_accum_int) - signed(exp_acc(31 downto 0));
                    phase_err_int <= err;

                    -- P term: registered phase_err_int (1-tooth lag, consistent
                    -- with I term latency). Keeps multiply off critical path.
                    p_t := phase_err_int * signed(resize(pll_kp, 17));
                    p_term_int <= p_t(48 downto 17);

                    -- I term stage 1: queue err * ab_period for next clock
                    i_upd_pipe   <= err * signed(resize(ab_period, 32));
                    i_pipe_valid <= '1';

                    -- nco_inc update using registered pi_corr_int from
                    -- the previous ab_edge (avoids double-multiply chain)
                    corr := resize(p_term_int, 33) + resize(i_term_int(63 downto 32), 33);
                    if corr > corr_max_s then
                        corr := corr_max_s;
                    elsif corr < -corr_max_s then
                        corr := -corr_max_s;
                    end if;
                    pi_corr_int <= corr(31 downto 0);

                    if pll_corr_dir = '1' then
                        if corr >= 0 and unsigned(corr(31 downto 0)) <= angle_nco_clk_inc then
                            nco_inc_int <= angle_nco_clk_inc + unsigned(corr(31 downto 0));
                        else
                            nco_inc_int <= angle_nco_clk_inc;
                        end if;
                    else
                        if corr >= 0 and unsigned(corr(31 downto 0)) <= angle_nco_clk_inc then
                            nco_inc_int <= angle_nco_clk_inc - unsigned(corr(31 downto 0));
                        else
                            nco_inc_int <= angle_nco_clk_inc;
                        end if;
                    end if;

                end if;

                -- -------------------------------------------------------
                -- I term stage 2: scale i_upd by ki
                -- -------------------------------------------------------
                i_ki_valid   <= '0';
                if i_pipe_valid = '1' then
                    i_pipe_valid <= '0';
                    i_scaled     := i_upd_pipe(63 downto 16);
                    i_ki         := i_scaled * signed(resize(pll_ki, 16));
                    i_ki_pipe    <= i_ki;
                    i_ki_valid   <= '1';
                end if;

                -- -------------------------------------------------------
                -- I term stage 3: accumulate
                -- -------------------------------------------------------
                if i_ki_valid = '1' then
                    i_term_int <= i_term_int + i_ki_pipe;
                end if;

            else
                -- sync_full = 0: hold accum at 0, pre-load nco_inc at
                -- current speed so NCO starts at correct rate on sync
                nco_accum_int <= (others => '0');
                nco_inc_int   <= angle_nco_clk_inc;
                i_term_int    <= (others => '0');
                i_pipe_valid  <= '0';
                i_ki_valid    <= '0';
            end if;
        end if;
    end process p_pll;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    pll_angfac     <= nco_accum_int;
    pll_nco_accum  <= nco_accum_int;   -- same signal, for AXI debug readback
    pll_div_valid  <= sync_full;
    pll_nco_inc    <= nco_inc_int;
    pll_err_angfac <= phase_err_int;
    pll_p_term     <= p_term_int;
    pll_i_term     <= i_term_int(63 downto 32);
    pll_pi_corr    <= pi_corr_int;

end architecture rtl;
