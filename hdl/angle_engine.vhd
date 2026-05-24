library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle_engine
--
-- Digital PLL producing a high-resolution angle signal from AB/Z input.
-- Works with the common AB/Z interface from crank_input or encoder_input.
--
-- Resolution: 0.1 degrees (0-7199 per 720 degree cycle)
--
-- PLL structure:
--   Phase detector: linear, measures error between expected and actual AB edge
--   Loop filter:    PI (proportional + integral)
--   NCO:            32-bit accumulator, frequency word updated each AB edge
--
-- NCO scaling:
--   Full scale (2^32) represents one complete 720 degree cycle
--   nco_inc = STEPS_PER_TOOTH / tooth_period
--           = 71582788 / tooth_period
--
-- Frequency word calculation:
--   Uses divider entity (sequential shift-subtract, variable latency).
--   Triggered on each AB edge. Previous nco_inc held until new result valid.
--   PI loop corrects residual phase error between updates.
--   Latency: 20-65 cycles. Tooth period: 12500+ cycles. Always completes.
--
-- Output angle:
--   Multiply-shift: raw_angle = nco_accum * 7200 >> 32
--   Pipelined 2 stages. Uses DSP48 for 32x32 multiply.
--
-- On Z pulse: accumulator resets to 0
-- On AB edge: phase error measured, NCO frequency corrected
-- Between AB edges: NCO free-wheels at current frequency
--
-- sync_state gates operation:
--   Only runs in SYNC_CRANK or SYNC_FULL
--   Accumulator and integrator reset otherwise
-- =============================================================================

entity angle_engine is
    generic (
        CLK_FREQ_HZ    : integer := 100_000_000;
        N_TEETH        : integer := 60
    );
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- From crank_input
        ab             : in  std_logic;
        z              : in  std_logic;
        tooth_period   : in  unsigned(31 downto 0);

        -- Sync state gate (from sync module)
        sync_state     : in  std_logic_vector(2 downto 0);

        -- PLL tuning from PS (runtime configurable)
        kp             : in  unsigned(15 downto 0);
        ki             : in  unsigned(15 downto 0);
        max_correction : in  unsigned(15 downto 0);

        -- Output: 0-7199, units of 0.1 degrees
        raw_angle      : out unsigned(15 downto 0)
    );
end entity angle_engine;

architecture rtl of angle_engine is

    -- Sync state constants (must match sync.vhd)
    constant ST_UNSYNC     : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP  : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRANK : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL  : std_logic_vector(2 downto 0) := "011";

    -- Steps per tooth: 2^32 / N_TEETH = 71582788 for N=60
    -- Used as dividend for nco_inc calculation
    constant STEPS_PER_TOOTH : unsigned(31 downto 0) :=
        to_unsigned(71582788, 32);

    -- -------------------------------------------------------------------------
    -- Edge detection
    -- -------------------------------------------------------------------------
    signal ab_prev         : std_logic := '0';
    signal ab_edge         : std_logic := '0';
    signal z_prev          : std_logic := '0';
    signal z_edge          : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Divider interface
    -- dividend = STEPS_PER_TOOTH (constant)
    -- divisor  = tooth_period
    -- start    = ab_edge and synced and tooth_period /= 0
    -- nco_inc updated when div_valid = '1'
    -- -------------------------------------------------------------------------
    signal div_start       : std_logic := '0';
    signal div_valid       : std_logic := '0';
    signal div_quotient    : unsigned(31 downto 0) := (others => '0');
    signal div_remainder   : unsigned(31 downto 0) := (others => '0');
    signal div_zero_err    : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- NCO
    -- -------------------------------------------------------------------------
    signal nco_accum       : unsigned(31 downto 0) := (others => '0');
    signal nco_inc         : unsigned(31 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Phase detector
    -- -------------------------------------------------------------------------
    signal phase_error     : signed(31 downto 0)   := (others => '0');
    signal ab_edge_cnt     : unsigned(7 downto 0)  := (others => '0');

    -- -------------------------------------------------------------------------
    -- PI loop filter
    -- -------------------------------------------------------------------------
    signal integrator      : signed(47 downto 0)   := (others => '0');
    signal correction      : signed(31 downto 0)   := (others => '0');

    -- -------------------------------------------------------------------------
    -- Registered PLL tuning inputs
    -- kp, ki, max_correction come from axi_lite_regs across a long path
    -- Registering them breaks the timing path at the cost of 1 cycle latency
    -- on configuration changes (acceptable - these are slow config parameters)
    -- -------------------------------------------------------------------------
    signal kp_reg          : unsigned(15 downto 0) := (others => '0');
    signal ki_reg          : unsigned(15 downto 0) := (others => '0');
    signal mc_reg          : unsigned(15 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- PI loop filter pipeline
    -- Stage 1: compute p_term and i_term (multiplies)
    -- Stage 2: sum, scale, clamp → correction
    -- Adds one AB edge period of latency, negligible at engine speeds
    -- -------------------------------------------------------------------------
    signal pi_p_term      : signed(47 downto 0) := (others => '0');
    signal pi_i_term      : signed(47 downto 0) := (others => '0');
    signal pi_stage2      : std_logic           := '0';
    signal pi_max_corr    : signed(31 downto 0) := (others => '0');

    -- -------------------------------------------------------------------------
    -- Sync gate
    -- -------------------------------------------------------------------------
    signal synced          : std_logic := '0';

    -- -------------------------------------------------------------------------
    -- Output pipeline
    -- Stage 1: nco_accum * 7200 → 64-bit product
    -- Stage 2: product(44:32)   → 13 bits = 0-7199
    -- -------------------------------------------------------------------------
    signal angle_temp      : unsigned(63 downto 0) := (others => '0');
    signal raw_angle_int   : unsigned(15 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- Sync gate
    -- -------------------------------------------------------------------------
    synced <= '1' when (sync_state = ST_SYNC_CRANK or
                        sync_state = ST_SYNC_FULL)
              else '0';

    -- -------------------------------------------------------------------------
    -- Register PLL tuning inputs
    -- Breaks long path from axi_lite_regs to p_pi multiply
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
    p_edge : process(clk)
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
    end process p_edge;

    -- -------------------------------------------------------------------------
    -- Divider instantiation
    -- Computes nco_inc = STEPS_PER_TOOTH / tooth_period
    -- Triggered on each AB edge when synced and tooth_period valid
    -- Variable latency (20-65 cycles), always << tooth_period at any RPM
    -- CACHING=1: at constant RPM, result available in 1-2 cycles
    -- -------------------------------------------------------------------------
    div_start <= (ab_edge and synced) when
                 tooth_period /= (tooth_period'range => '0')
                 else '0';

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
            dividend  => STEPS_PER_TOOTH,
            divisor   => tooth_period,
            quotient  => div_quotient,
            remainder => div_remainder,
            zero_err  => div_zero_err,
            valid     => div_valid
        );

    -- -------------------------------------------------------------------------
    -- NCO frequency word update
    -- Latch divider result when valid
    -- Hold previous value until new result arrives
    -- -------------------------------------------------------------------------
    p_freq : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_inc <= (others => '0');
            else
                if div_valid = '1' and div_zero_err = '0' then
                    nco_inc <= div_quotient;
                end if;
            end if;
        end if;
    end process p_freq;

    -- -------------------------------------------------------------------------
    -- Phase detector
    -- Expected accumulator value at each AB edge:
    --   expected = ab_edge_cnt * STEPS_PER_TOOTH
    -- Phase error = actual - expected (signed)
    -- -------------------------------------------------------------------------
    p_phase : process(clk)
        variable expected : unsigned(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_error <= (others => '0');
                ab_edge_cnt <= (others => '0');
            else
                if z_edge = '1' then
                    ab_edge_cnt <= (others => '0');
                    phase_error <= (others => '0');
                elsif ab_edge = '1' and synced = '1' then
                    expected    := resize(ab_edge_cnt, 32) * STEPS_PER_TOOTH;
                    phase_error <= signed(nco_accum) -
                                   signed(resize(expected, 32));
                    ab_edge_cnt <= ab_edge_cnt + 1;
                end if;
            end if;
        end if;
    end process p_phase;

    -- -------------------------------------------------------------------------
    -- PI loop filter - pipelined over 2 cycles
    --
    -- Stage 1 (ab_edge cycle):
    --   Update integrator
    --   Compute p_term = phase_error * kp_reg
    --   Compute i_term = integrator >> 16 * ki_reg
    --   Latch max_corr
    --   Assert pi_stage2
    --
    -- Stage 2 (cycle after ab_edge):
    --   raw_corr = (p_term + i_term) / 256
    --   Clamp to max_corr → correction
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
                -- Stage 1: multiplies on ab_edge
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

                -- Stage 2: sum, scale, clamp
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
    -- NCO accumulator
    -- Increments by nco_inc each clock (free-wheel)
    -- Phase corrected on each AB edge
    -- Reset to 0 on Z rising edge
    -- Wraps naturally at 2^32
    --
    -- Output pipeline (2 stages):
    --   Stage 1: angle_temp = nco_accum * 7200  (32x32 = 64-bit)
    --   Stage 2: raw_angle  = angle_temp(44:32) (13 bits, 0-7199)
    -- -------------------------------------------------------------------------
    p_nco : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                nco_accum     <= (others => '0');
                angle_temp    <= (others => '0');
                raw_angle_int <= (others => '0');
            else
                if z_edge = '1' then
                    nco_accum     <= (others => '0');
                    angle_temp    <= (others => '0');
                    raw_angle_int <= (others => '0');
                elsif synced = '1' then
                    if ab_edge = '1' then
                        nco_accum <= unsigned(
                            signed(nco_accum + nco_inc) - correction);
                    else
                        nco_accum <= nco_accum + nco_inc;
                    end if;

                    -- Stage 1: 32x32 → 64-bit, maps to DSP48 cascade
                    angle_temp <= nco_accum * to_unsigned(7200, 32);

                    -- Stage 2: >> 32, take 13 bits (0-7199)
                    raw_angle_int <= resize(angle_temp(44 downto 32), 16);
                end if;
            end if;
        end if;
    end process p_nco;

    raw_angle <= raw_angle_int;

end architecture rtl;