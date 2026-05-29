library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- pll.vhd  (v2 first draft)
-- NCO + PI loop for high-resolution engine angle.
--
-- nco_inc_base = pll_nco_ab_inc (pre-calculated at startup from axi_lite_regs)
-- At each ab_edge: phase error calculated, PI correction computed, nco_inc updated.
-- nco_accum runs every clock: nco_accum += nco_inc.
-- Resets every 2nd z_edge (720 deg boundary).
--
-- Output: pll_ang_hires = (nco_accum * 7200) >> 32, range 0-7199, 0.1 deg/LSB
-- Held at 0 until sync_full=1.
--
-- pll_cycle_ab_count: increments on ab_edge, resets every 2nd z_edge.
-- pll_phase_err = nco_accum - (pll_cycle_ab_count * pll_nco_ab_inc)
-- =============================================================================
entity pll is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        sync_full        : in  std_logic;
        phase_eng        : in  std_logic;
        ab_edge          : in  std_logic;
        ab_period        : in  unsigned(31 downto 0);
        z_edge           : in  std_logic;
        pll_nco_ab_inc   : in  unsigned(31 downto 0);
        pll_kp           : in  unsigned(15 downto 0);
        pll_ki           : in  unsigned(15 downto 0);
        pll_corr_dir     : in  std_logic;
        pll_corr_max     : in  unsigned(15 downto 0);
        pll_ang_hires    : out unsigned(15 downto 0);
        pll_div_valid    : out std_logic;
        pll_nco_inc      : out unsigned(31 downto 0);
        pll_nco_accum    : out unsigned(31 downto 0);
        pll_phase_err    : out signed(31 downto 0);
        pll_p_term       : out signed(31 downto 0);
        pll_i_term       : out signed(31 downto 0);
        pll_pi_corr      : out signed(31 downto 0);
        pll_cycle_ab_count: out unsigned(7 downto 0)
    );
end entity pll;

architecture rtl of pll is

    function ang_conv_v(accum : unsigned(31 downto 0)) return unsigned is
        variable prod : unsigned(47 downto 0);
    begin
        prod := accum * to_unsigned(7200, 16);
        return prod(47 downto 32);
    end function;
    signal nco_accum_int  : unsigned(31 downto 0) := (others => '0');
    signal nco_inc_int    : unsigned(31 downto 0) := (others => '0');
    signal cycle_ab_cnt   : unsigned(7 downto 0)  := (others => '0');
    signal z_phase_cnt    : unsigned(1 downto 0)  := (others => '0');
    signal phase_err_int  : signed(31 downto 0)   := (others => '0');
    signal p_term_int     : signed(31 downto 0)   := (others => '0');
    signal i_term_int     : signed(63 downto 0)   := (others => '0');
    signal pi_corr_int    : signed(31 downto 0)   := (others => '0');
    signal ang_hires_int  : unsigned(15 downto 0) := (others => '0');
    signal corr_max_s     : signed(32 downto 0);
begin

    corr_max_s <= signed(resize(pll_corr_max, 33));

    p_pll : process(clk)
        variable err    : signed(31 downto 0);
        variable p_t    : signed(48 downto 0);
        variable i_upd  : signed(63 downto 0);  -- phase_error * ab_period
        variable i_scaled: signed(47 downto 0);  -- i_upd >> 16
        variable i_ki   : signed(63 downto 0);  -- i_scaled * ki
        variable i_t    : signed(63 downto 0);  -- accumulated i_term
        variable corr   : signed(32 downto 0);
        variable exp_acc: unsigned(79 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_accum_int <= (others => '0');
                nco_inc_int   <= (others => '0');
                cycle_ab_cnt  <= (others => '0');
                z_phase_cnt   <= (others => '0');
                phase_err_int <= (others => '0');
                p_term_int    <= (others => '0');
                i_term_int    <= (others => '0');
                pi_corr_int   <= (others => '0');
                ang_hires_int <= (others => '0');
            elsif sync_full = '1' then
                -- NCO runs every clock
                nco_accum_int <= nco_accum_int + nco_inc_int;

                -- z_edge: reset every 2nd z
                if z_edge = '1' then
                    if z_phase_cnt = "01" then
                        -- 2nd z_edge: reset
                        cycle_ab_cnt  <= (others => '0');
                        z_phase_cnt   <= (others => '0');
                        nco_accum_int <= (others => '0');
                    else
                        z_phase_cnt <= z_phase_cnt + 1;
                    end if;
                end if;

                -- ab_edge: update PI and nco_inc
                if ab_edge = '1' then
                    cycle_ab_cnt <= cycle_ab_cnt + 1;

                    -- Phase error
                    exp_acc := resize(cycle_ab_cnt, 40) * resize(pll_nco_ab_inc, 40);
                    err := signed(nco_accum_int) - signed(exp_acc(39 downto 8));  -- lower 32 of meaningful bits
                    phase_err_int <= err;

                    -- P term: err * kp (kp 0-65535 treated as positive)
                    p_t := err * signed(resize(pll_kp, 17));
                    p_term_int <= p_t(47 downto 16);

                    -- I term: simplified - accumulate err*ki
                    -- I term with variable dt = ab_period
                    -- Step 1: phase_error * ab_period -> 64-bit
                    i_upd   := err * signed(resize(ab_period, 32));
                    -- Step 2: scale down by 16 to keep width manageable
                    i_scaled := i_upd(63 downto 16);
                    -- Step 3: multiply by ki
                    i_ki    := i_scaled * signed(resize(pll_ki, 16));
                    -- Step 4: accumulate (upper 32 bits used for correction)
                    i_t     := i_term_int + i_ki;
                    i_term_int <= i_t;

                    -- PI correction
                    corr := resize(p_t(47 downto 16), 33) + resize(i_t(63 downto 32), 33);
                    if corr > corr_max_s then
                        corr := corr_max_s;
                    elsif corr < -corr_max_s then
                        corr := -corr_max_s;
                    end if;
                    pi_corr_int <= corr(31 downto 0);

                    -- Update nco_inc = nco_ab_inc +/- correction
                    pi_corr_int <= corr(31 downto 0);
                    if pll_corr_dir = '1' then
                        if unsigned(corr(31 downto 0)) <= pll_nco_ab_inc then
                            nco_inc_int <= pll_nco_ab_inc + unsigned(corr(31 downto 0));
                        else
                            nco_inc_int <= pll_nco_ab_inc;
                        end if;
                    else
                        if unsigned(corr(31 downto 0)) <= pll_nco_ab_inc then
                            nco_inc_int <= pll_nco_ab_inc - unsigned(corr(31 downto 0));
                        else
                            nco_inc_int <= pll_nco_ab_inc;
                        end if;
                    end if;
                end if;

                -- Output angle conversion: (nco_accum * 7200) >> 32
                -- Use top variable already declared
                ang_hires_int <= ang_conv_v(nco_accum_int);

            else
                nco_accum_int <= (others => '0');
                nco_inc_int   <= pll_nco_ab_inc;  -- pre-load for fast lock on sync
                ang_hires_int <= (others => '0');
            end if;
        end if;
    end process p_pll;

    pll_ang_hires      <= ang_hires_int;
    pll_div_valid      <= '1' when sync_full = '1' else '0';
    pll_nco_inc        <= nco_inc_int;
    pll_nco_accum      <= nco_accum_int;
    pll_phase_err      <= phase_err_int;
    pll_p_term         <= p_term_int;
    pll_i_term         <= i_term_int(63 downto 32);
    pll_pi_corr        <= pi_corr_int;
    pll_cycle_ab_count <= cycle_ab_cnt;

end architecture rtl;
