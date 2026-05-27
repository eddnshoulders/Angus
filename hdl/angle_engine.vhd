library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle_engine
--
-- Digital PLL producing a high-resolution angle signal from AB/Z input.
-- Works with the common AB/Z interface from crank_input or enc_input.
--
-- Resolution: 0.1 degrees (0-7199 per 720 degree cycle)
--
-- PLL structure:
--   Phase detector: measures error between expected and actual AB edge position
--   Loop filter:    PI (proportional + integral)
--   NCO:            32-bit accumulator, frequency word updated each AB edge
--
-- NCO scaling:
--   Full scale (2^32) represents one complete 360 degree crank revolution
--   steps_per_tooth = 0xFFFFFFFF / n_teeth (computed on config_apply)
--   nco_inc = steps_per_tooth / ab_period (per-clock increment)
--   Bresenham fractional accumulator eliminates rounding error
--
-- ab_period is measured internally between AB edges (replaces tooth_period input)
--
-- angle_hires output:
--   phase_engine=0: 0-3599 (first crank rotation, 0-360 deg)
--   phase_engine=1: 3600-7199 (second crank rotation, 360-720 deg)
--
-- Only active when synced='1' (from sync module)
-- =============================================================================

entity angle_engine is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- From ang_sel (crank_input or enc_input)
        ab             : in  std_logic;
        z              : in  std_logic;

        -- From sync module
        synced         : in  std_logic;
        phase_engine   : in  std_logic;  -- 0=1st rotation, 1=2nd rotation

        -- Configuration (latched on config_apply)
        n_teeth        : in  unsigned(7 downto 0);
        config_apply   : in  std_logic;

        -- PLL tuning from PS (runtime configurable)
        kp             : in  unsigned(15 downto 0);
        ki             : in  unsigned(15 downto 0);
        max_correction : in  unsigned(15 downto 0);
        correction_dir : in  std_logic;

        -- Output: 0-7199, units of 0.1 degrees, 4-stroke referenced
        angle_hires    : out unsigned(15 downto 0);

        -- Debug outputs
        div_valid_out   : out std_logic;
        nco_inc_out     : out unsigned(31 downto 0);
        nco_accum_out   : out unsigned(31 downto 0);
        phase_error_out : out signed(31 downto 0);
        correction_out  : out signed(31 downto 0)
    );
end entity angle_engine;

architecture rtl of angle_engine is

    -- -------------------------------------------------------------------------
    -- steps_per_tooth: 0xFFFFFFFF / n_teeth, computed on config_apply
    -- Default 71582788 for 60 teeth (0xFFFFFFFF / 60 = 71582788)
    -- -------------------------------------------------------------------------
    signal steps_per_tooth   : unsigned(31 downto 0) := to_unsigned(71582788, 32);
    signal spt_pending        : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Edge detection
    -- -------------------------------------------------------------------------
    signal ab_prev            : std_logic := '0';
    signal ab_edge            : std_logic := '0';
    signal z_prev             : std_logic := '0';
    signal z_edge             : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- AB period measurement (replaces tooth_period input)
    -- -------------------------------------------------------------------------
    signal ab_timer           : unsigned(31 downto 0) := (others => '0');
    signal ab_period          : unsigned(31 downto 0) := (others => '1');

    -- -------------------------------------------------------------------------
    -- Divider interface
    -- Two uses:
    --   1. On config_apply: dividend=0xFFFFFFFF, divisor=n_teeth → steps_per_tooth
    --   2. On ab_edge:      dividend=steps_per_tooth, divisor=ab_period → nco_inc
    -- Muxed by div_mode
    -- -------------------------------------------------------------------------
    signal div_start          : std_logic := '0';
    signal div_valid          : std_logic := '0';
    signal div_quotient       : unsigned(31 downto 0) := (others => '0');
    signal div_remainder      : unsigned(31 downto 0) := (others => '0');
    signal div_zero_err       : std_logic := '0';
    signal div_dividend_s     : unsigned(31 downto 0) := (others => '0');
    signal div_divisor_s      : unsigned(31 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- NCO
    -- -------------------------------------------------------------------------
    signal nco_accum          : unsigned(31 downto 0) := (others => '0');
    signal nco_inc            : unsigned(31 downto 0) := (others => '0');
    signal nco_remainder      : unsigned(31 downto 0) := (others => '0');
    signal ab_edge_d          : std_logic := '0';  -- ab_edge delayed one cycle for divider
    signal frac_accum         : unsigned(31 downto 0) := (others => '0');
    signal div_result_used    : std_logic := '1';  -- prevents double-latching of div result

    -- -------------------------------------------------------------------------
    -- Phase detector
    -- -------------------------------------------------------------------------
    signal phase_error        : signed(31 downto 0)  := (others => '0');
    signal ab_edge_cnt        : unsigned(7 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- PI loop filter
    -- -------------------------------------------------------------------------
    signal integrator         : signed(47 downto 0) := (others => '0');
    signal correction         : signed(31 downto 0) := (others => '0');
    signal kp_reg             : unsigned(15 downto 0) := (others => '0');
    signal ki_reg             : unsigned(15 downto 0) := (others => '0');
    signal mc_reg             : unsigned(15 downto 0) := (others => '0');
    signal pi_p_term          : signed(47 downto 0) := (others => '0');
    signal pi_i_term          : signed(47 downto 0) := (others => '0');
    signal pi_stage2          : std_logic := '0';
    signal pi_max_corr        : signed(31 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Output pipeline
    -- -------------------------------------------------------------------------
    signal angle_temp         : unsigned(63 downto 0) := (others => '0');
    signal angle_raw_int      : unsigned(15 downto 0) := (others => '0');
    signal angle_hires_int    : unsigned(15 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- Register PLL tuning inputs
    -- -------------------------------------------------------------------------
    p_reg_gains : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                kp_reg <= (others => '0');
                ki_reg <= (others => '0');
                mc_reg <= (others => '0');
            else
                kp_reg <= kp;
                ki_reg <= ki;
                mc_reg <= max_correction;
            end if;
        end if;
    end process p_reg_gains;

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
                if ab /= ab_prev then ab_edge <= '1'; end if;
                if z = '1' and z_prev = '0' then z_edge <= '1'; end if;
            end if;
        end if;
    end process p_edges;

    -- -------------------------------------------------------------------------
    -- AB period measurement
    -- -------------------------------------------------------------------------
    p_ab_period : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_timer  <= (others => '0');
                ab_period <= (others => '1');
            else
                if ab_edge = '1' then
                    ab_period <= ab_timer;
                    ab_timer  <= (others => '0');
                else
                    ab_timer <= ab_timer + 1;
                end if;
            end if;
        end if;
    end process p_ab_period;

    -- -------------------------------------------------------------------------
    -- Divider instantiation
    -- Shared between steps_per_tooth (config_apply) and nco_inc (ab_edge)
    -- -------------------------------------------------------------------------
    u_divider : entity work.divider
        generic map (
            WIDTH    => 32,
            CACHING  => 0,
            INIT_VLD => 0
        )
        port map (
            clk       => clk,
            rst       => rst,
            start     => div_start,
            dividend  => div_dividend_s,
            divisor   => div_divisor_s,
            quotient  => div_quotient,
            remainder => div_remainder,
            zero_err  => div_zero_err,
            valid     => div_valid
        );

    p_div_ctrl : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                div_start        <= '0';
                div_dividend_s   <= (others => '0');
                div_divisor_s    <= (others => '0');
                spt_pending      <= '0';
                steps_per_tooth  <= to_unsigned(71582788, 32);
                ab_edge_d        <= '0';
                nco_inc          <= (others => '0');
                nco_remainder    <= (others => '0');
                div_result_used  <= '1';
            else
                div_start <= '0';
                ab_edge_d <= ab_edge;

                -- config_apply: compute steps_per_tooth = 0xFFFFFFFF / n_teeth
                if config_apply = '1' then
                    div_start        <= '1';
                    div_dividend_s   <= x"FFFFFFFF";
                    div_divisor_s    <= resize(n_teeth, 32);
                    spt_pending      <= '1';
                    div_result_used  <= '0';

                -- One cycle after ab_edge: ab_period now holds updated value
                elsif ab_edge_d = '1' and synced = '1' and
                      spt_pending = '0' and
                      ab_period /= (ab_period'range => '0') then
                    div_start        <= '1';
                    div_dividend_s   <= steps_per_tooth;
                    div_divisor_s    <= ab_period;
                    div_result_used  <= '0';
                end if;

                -- Latch divider result once (div_valid stays high, only take first edge)
                if div_valid = '1' and div_zero_err = '0' and div_result_used = '0' then
                    div_result_used <= '1';
                    if spt_pending = '1' then
                        steps_per_tooth <= div_quotient;
                        spt_pending     <= '0';
                    else
                        nco_inc       <= div_quotient;
                        nco_remainder <= div_remainder;
                    end if;
                end if;
            end if;
        end if;
    end process p_div_ctrl;

    -- -------------------------------------------------------------------------
    -- Phase detector
    -- Expected = ab_edge_cnt * steps_per_tooth
    -- Error = nco_accum - expected (in unsigned space, cast to signed)
    -- -------------------------------------------------------------------------
    p_phase : process(clk)
        variable expected   : unsigned(63 downto 0);
        variable expected32 : unsigned(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_error <= (others => '0');
                ab_edge_cnt <= (others => '0');
            else
                if z_edge = '1' then
                    ab_edge_cnt <= (others => '0');
                    phase_error <= signed(nco_accum);
                elsif ab_edge = '1' and synced = '1' then
                    expected    := resize(ab_edge_cnt, 32) * steps_per_tooth;
                    expected32  := resize(expected, 32);
                    phase_error <= signed(nco_accum - expected32);
                    ab_edge_cnt <= ab_edge_cnt + 1;
                end if;
            end if;
        end if;
    end process p_phase;

    -- -------------------------------------------------------------------------
    -- PI loop filter - 2 stage pipeline
    -- -------------------------------------------------------------------------
    p_pi : process(clk)
        variable raw_corr : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' or synced = '0' then
                integrator  <= (others => '0');
                correction  <= (others => '0');
                pi_p_term   <= (others => '0');
                pi_i_term   <= (others => '0');
                pi_max_corr <= (others => '0');
                pi_stage2   <= '0';
            else
                pi_stage2 <= '0';
                if ab_edge = '1' then
                    integrator  <= integrator + resize(phase_error, 48);
                    pi_p_term   <= resize(phase_error, 32) *
                                   signed(resize(kp_reg, 16));
                    pi_i_term   <= resize(integrator(47 downto 16), 32) *
                                   signed(resize(ki_reg, 16));
                    pi_max_corr <= signed(resize(mc_reg, 32));
                    pi_stage2   <= '1';
                end if;

                if pi_stage2 = '1' then
                    raw_corr := (pi_p_term + pi_i_term) / 256;
                    if raw_corr > resize(pi_max_corr, 48) then
                        correction <= pi_max_corr;
                    elsif raw_corr < -resize(pi_max_corr, 48) then
                        correction <= -pi_max_corr;
                    else
                        correction <= resize(raw_corr, 32);
                    end if;
                end if;
            end if;
        end if;
    end process p_pi;

    -- -------------------------------------------------------------------------
    -- NCO accumulator with Bresenham fractional interpolation
    -- -------------------------------------------------------------------------
    p_nco : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_accum     <= (others => '0');
                frac_accum    <= (others => '0');
                angle_temp    <= (others => '0');
                angle_raw_int <= (others => '0');
            else
                if synced = '1' then
                    if ab_edge = '1' then
                        frac_accum <= (others => '0');
                        if correction_dir = '0' then
                            nco_accum <= unsigned(
                                signed(nco_accum + nco_inc) - correction);
                        else
                            nco_accum <= unsigned(
                                signed(nco_accum + nco_inc) + correction);
                        end if;
                    else
                        -- Bresenham fractional accumulator
                        if frac_accum + nco_remainder >= ab_period then
                            nco_accum  <= nco_accum + nco_inc + 1;
                            frac_accum <= frac_accum + nco_remainder - ab_period;
                        else
                            nco_accum  <= nco_accum + nco_inc;
                            frac_accum <= frac_accum + nco_remainder;
                        end if;
                    end if;

                    -- Stage 1: 32x32 → 64-bit multiply
                    angle_temp <= nco_accum * to_unsigned(3600, 32);

                    -- Stage 2: >> 32, take 13 bits (0-3599 per crank revolution)
                    angle_raw_int <= resize(angle_temp(43 downto 32), 16);
                end if;
            end if;
        end if;
    end process p_nco;

    -- -------------------------------------------------------------------------
    -- angle_hires: apply phase_engine offset for 4-stroke referencing
    -- phase_engine=0: 0-3599 (first rotation)
    -- phase_engine=1: 3600-7199 (second rotation)
    -- -------------------------------------------------------------------------
    p_angle_hires : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                angle_hires_int <= (others => '0');
            else
                if phase_engine = '0' then
                    angle_hires_int <= angle_raw_int;
                else
                    angle_hires_int <= angle_raw_int + 3600;
                end if;
            end if;
        end if;
    end process p_angle_hires;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    angle_hires     <= angle_hires_int;
    div_valid_out   <= div_valid;
    nco_inc_out     <= nco_inc;
    nco_accum_out   <= nco_accum;
    phase_error_out <= phase_error;
    correction_out  <= correction;

end architecture rtl;
