library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- pll.vhd  (v3)
--
-- NCO + PI loop for high-resolution engine angle tracking.
-- Internal unit: _angfac -- unsigned 32-bit fraction of one crank revolution.
-- Full scale (0xFFFFFFFF) = 360 crank degrees.
--
-- Phase error:
--   pll_err_angfac = nco_accum - angle_angfac
--   angle_angfac is the tooth-snap output of angle.vhd, already registered.
--   No multiply required -- angle.vhd has already done the tooth position
--   calculation (edge_count * nco_ab_inc). Using it directly removes the
--   duplicate ab_count * nco_ab_inc that was the source of the timing
--   violation (two cascaded DSP multiplies in one clock period).
--
-- PI loop (updates at each ab_edge):
--   P term: phase_err_int * kp   (registered error, 1-tooth lag)
--   I term: accumulated (phase_err_int * ab_period * ki)
--           ab_period is used as the integration dt to give consistent
--           integral gain across varying engine speeds.
--   nco_inc = angle_nco_clk_inc +/- pi_corr  (bounded by pll_corr_max)
--
-- PI pipeline (to keep DSP multiplies off critical path):
--   Stage 1: phase_err_int * ab_period  (at ab_edge)
--   Stage 2: result * ki                (next clock)
--   Stage 3: accumulate into i_term     (clock after that)
--   P term uses same registered phase_err_int -- all terms act on previous
--   ab_edge error, consistent 1-tooth lag throughout.
--
-- Reset behaviour:
--   nco_accum resets to 0 on every z_edge (one crank revolution boundary).
--   NCO and PI state held at 0 until sync_full = 1.
--   nco_inc pre-loaded with angle_nco_clk_inc when sync_full = 0 so the
--   NCO starts at the correct speed immediately on sync.
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
        z_edge            : in  std_logic;
        -- Angle position (from angle.vhd -- avoids duplicate tooth-pos multiply)
        angle_angfac      : in  unsigned(31 downto 0);
        -- Per-clock increment (from angle.vhd)
        angle_nco_clk_inc : in  unsigned(31 downto 0);
        -- PI config
        pll_kp            : in  unsigned(15 downto 0);
        pll_ki            : in  unsigned(15 downto 0);
        pll_corr_dir      : in  std_logic;
        pll_corr_max      : in  unsigned(15 downto 0);
        -- Outputs
        pll_angfac        : out unsigned(31 downto 0);
        pll_div_valid     : out std_logic;
        pll_nco_inc       : out unsigned(31 downto 0);
        pll_nco_accum     : out unsigned(31 downto 0);
        pll_err_angfac    : out signed(31 downto 0);
        pll_p_term        : out signed(31 downto 0);
        pll_i_term        : out signed(31 downto 0);
        pll_pi_corr       : out signed(31 downto 0)
    );
end entity pll;

architecture rtl of pll is

    signal nco_accum_int  : unsigned(31 downto 0) := (others => '0');
    signal nco_inc_int    : unsigned(31 downto 0) := (others => '0');
    signal phase_err_int  : signed(31 downto 0)   := (others => '0');
    signal p_term_int     : signed(31 downto 0)   := (others => '0');
    signal i_term_int     : signed(63 downto 0)   := (others => '0');
    signal pi_corr_int    : signed(31 downto 0)   := (others => '0');

    signal i_upd_pipe     : signed(63 downto 0)   := (others => '0');
    signal i_pipe_valid   : std_logic              := '0';
    signal i_ki_pipe      : signed(63 downto 0)   := (others => '0');
    signal i_ki_valid     : std_logic              := '0';

    signal corr_max_s     : signed(32 downto 0);

begin

    corr_max_s <= signed(resize(pll_corr_max, 33));

    p_pll : process(clk)
        variable p_t      : signed(48 downto 0);
        variable i_scaled : signed(47 downto 0);
        variable i_ki     : signed(63 downto 0);
        variable corr     : signed(32 downto 0);
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

                -- NCO runs every clock
                nco_accum_int <= nco_accum_int + nco_inc_int;

                -- z_edge: reset accumulator each crank revolution
                if z_edge = '1' then
                    nco_accum_int <= (others => '0');
                end if;

                -- ab_edge: compute phase error and update PI loop.
                -- Phase error is a simple subtraction -- angle.vhd already
                -- computed the expected tooth position (edge_count * nco_ab_inc)
                -- and exported it as angle_angfac. No multiply needed here.
                if ab_edge = '1' then

                    phase_err_int <= signed(nco_accum_int) - signed(angle_angfac);

                    -- P term uses registered phase_err_int (previous ab_edge).
                    -- One multiply per clock, off the critical path.
                    p_t := phase_err_int * signed(resize(pll_kp, 17));
                    p_term_int <= p_t(48 downto 17);

                    -- I term stage 1: phase_err_int * ab_period.
                    -- Uses registered error (same sample as P term).
                    i_upd_pipe   <= phase_err_int * signed(resize(ab_period, 32));
                    i_pipe_valid <= '1';

                    -- nco_inc update using pi_corr_int from previous ab_edge
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

                -- I term stage 2: scale by ki
                i_ki_valid <= '0';
                if i_pipe_valid = '1' then
                    i_pipe_valid <= '0';
                    i_scaled     := i_upd_pipe(63 downto 16);
                    i_ki         := i_scaled * signed(resize(pll_ki, 16));
                    i_ki_pipe    <= i_ki;
                    i_ki_valid   <= '1';
                end if;

                -- I term stage 3: accumulate
                if i_ki_valid = '1' then
                    i_term_int <= i_term_int + i_ki_pipe;
                end if;

            else
                nco_accum_int <= (others => '0');
                nco_inc_int   <= angle_nco_clk_inc;
                i_term_int    <= (others => '0');
                i_pipe_valid  <= '0';
                i_ki_valid    <= '0';
            end if;
        end if;
    end process p_pll;

    pll_angfac     <= nco_accum_int;
    pll_nco_accum  <= nco_accum_int;
    pll_div_valid  <= sync_full;
    pll_nco_inc    <= nco_inc_int;
    pll_err_angfac <= phase_err_int;
    pll_p_term     <= p_term_int;
    pll_i_term     <= i_term_int(63 downto 32);
    pll_pi_corr    <= pi_corr_int;

end architecture rtl;
