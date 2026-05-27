library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
--use ieee.fixed_pkg.all;

-- =============================================================================
-- crank_input
--
-- Converts a conditioned n-m tooth wheel signal into an encoder-equivalent
-- AB/Z interface for downstream sync and angle engine blocks.
--
-- Signal flow:
--   clean_signal edges → period measurement → tooth counting
--   period_cnt timeout → gap_detected, z_armed
--   Next real edge_pulse with z_armed → Z fires, tooth_count resets to 0
--   tooth_count = LAST_REAL-1 on edge_pulse → interpolator fills gap with AB
--
-- Z accuracy: tied to gap_detected timeout and first real edge after gap
-- Interpolation: best-effort AB fill during gap, independent of Z
-- =============================================================================

entity crank_input is
    generic (
        CLK_FREQ_HZ : integer := 100_000_000
    );
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- From signal_conditioner
        clean_signal      : in  std_logic;
        signal_stable     : in  std_logic;

        -- Runtime configuration
        edge_select       : in  std_logic;              -- '0' falling, '1' rising
        gap_threshold     : in  unsigned(7 downto 0);   -- 1.7 fixed point, default 0xC0 = 1.5x
        n_teeth           : in  unsigned(7 downto 0);   -- total teeth including missing
        n_missing         : in  unsigned(7 downto 0);   -- number of missing teeth

        -- Encoder-equivalent outputs
        ab                : out std_logic;              -- toggles on real and interpolated edges
        z                 : out std_logic;              -- pulse on first real edge after gap
        tooth_period      : out unsigned(31 downto 0);  -- last measured tooth period
        tooth_count       : out unsigned(7 downto 0);   -- 0 to N_TEETH-N_MISSING-1
        gap_detected      : out std_logic;              -- high during gap, for crank_sync
        signal_present    : out std_logic;

        -- Debug outputs
        edge_pulse_out    : out std_logic;              -- one pulse per detected tooth edge
        gap_period        : out unsigned(31 downto 0)   -- gap width latched at gap detection
    );
end entity crank_input;

architecture rtl of crank_input is

    constant MAX_32    : unsigned(31 downto 0) := (others => '1');
    -- last_real: tooth_cnt value at which interpolator starts filling the gap
    -- = n_teeth - n_missing - 2 (accounts for one cycle signal scheduling lag)
    signal last_real   : unsigned(7 downto 0) := to_unsigned(56, 8);

    -- Edge detection
    signal clean_prev     : std_logic := '0';
    signal edge_pulse     : std_logic := '0';

    -- Period measurement
    signal period_cnt     : unsigned(31 downto 0) := (others => '0');
    signal current_period : unsigned(31 downto 0) := (others => '0');
    signal last_period    : unsigned(31 downto 0) := (others => '0');
    signal edge_seen      : std_logic := '0';
    signal period_valid   : std_logic := '0';

    -- Gap detection and Z arming (p_gap owns z_armed)
    signal gap_det        : std_logic := '0';
    signal gap_det_prev   : std_logic := '0';  -- to detect rising edge of gap_det
    signal gap_period_int : unsigned(31 downto 0) := (others => '0');
    signal z_armed        : std_logic := '0';

    -- Tooth counting
    signal tooth_cnt      : unsigned(7 downto 0) := (others => '0');

    -- Interpolator (AB fill only, independent of Z)
    signal interp_active  : std_logic := '0';
    signal interp_cnt     : integer range 0 to 7 := 0;
    signal interp_timer   : unsigned(31 downto 0) := (others => '0');
    signal interp_period  : unsigned(31 downto 0) := (others => '0');
    signal interp_pulse   : std_logic := '0';

    -- Z pulse (p_z owns z_int, clears z_armed)
    signal z_int          : std_logic := '0';
    signal z_timer        : unsigned(31 downto 0) := (others => '0');

    -- AB output
    signal ab_int         : std_logic := '0';

    -- Signal present
    signal timeout_cnt    : unsigned(31 downto 0) := (others => '0');
    signal timeout_limit  : unsigned(31 downto 0) := MAX_32;
    signal sig_present    : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- Edge detection
    -- -------------------------------------------------------------------------
    p_edge : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                clean_prev <= '0';
                edge_pulse <= '0';
            else
                clean_prev <= clean_signal;
                edge_pulse <= '0';
                if edge_select = '1' then
                    if clean_signal = '1' and clean_prev = '0' then
                        edge_pulse <= '1';
                    end if;
                else
                    if clean_signal = '0' and clean_prev = '1' then
                        edge_pulse <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process p_edge;

    -- -------------------------------------------------------------------------
    -- Period measurement
    -- -------------------------------------------------------------------------
    p_period : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                period_cnt     <= (others => '0');
                current_period <= (others => '0');
                last_period    <= (others => '0');
                edge_seen      <= '0';
                period_valid   <= '0';
            else
                if sig_present = '0' and timeout_cnt >= timeout_limit then
                    period_cnt     <= (others => '0');
                    current_period <= (others => '0');
                    last_period    <= (others => '0');
                    edge_seen      <= '0';
                    period_valid   <= '0';
                elsif edge_pulse = '1' then
                    edge_seen      <= '1';
                    last_period    <= current_period;
                    current_period <= period_cnt;
                    period_cnt     <= (others => '0');
                    if current_period /= (current_period'range => '0') then
                        period_valid <= '1';
                    end if;
                else
                    if period_cnt /= MAX_32 then
                        period_cnt <= period_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_period;

    -- -------------------------------------------------------------------------
    -- Gap detection and Z arming
    -- gap_det: high while period_cnt > gap_threshold * current_period
    -- z_armed: set on rising edge of gap_det, cleared by p_z on next edge_pulse
    -- -------------------------------------------------------------------------
    p_gap : process(clk)
        variable lhs : unsigned(63 downto 0);
        variable rhs : unsigned(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                gap_det      <= '0';
                gap_det_prev <= '0';
                z_armed      <= '0';
            else
                gap_det_prev <= gap_det;

                -- Continuous timeout comparison
                gap_det <= '0';
                if period_valid = '1' and signal_stable = '1' then
                    lhs := resize(period_cnt, 32) * to_unsigned(128, 32);
                    rhs := resize(current_period, 32) *
                           resize(gap_threshold, 32);
                    if lhs > rhs then
                        gap_det <= '1';
                    end if;
                end if;

                -- Arm Z on rising edge of gap_det
                if gap_det = '1' and gap_det_prev = '0' then
                    z_armed       <= '1';
                    gap_period_int <= period_cnt;
                end if;

                -- Clear z_armed when p_z fires (edge_pulse with z_armed)
                if z_armed = '1' and edge_pulse = '1' then
                    z_armed <= '0';
                end if;
            end if;
        end if;
    end process p_gap;

    -- -------------------------------------------------------------------------
    -- Tooth counting
    -- Starts on second real edge (edge_seen gates first edge)
    -- Resets to 0 on first real edge after gap (z_armed high)
    -- -------------------------------------------------------------------------
    p_tooth_count : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tooth_cnt <= (others => '0');
            else
                if edge_pulse = '1' and edge_seen = '1' then
                    if z_armed = '1' then
                        tooth_cnt <= (others => '0');
                    else
                        if tooth_cnt = n_teeth - 1 then
                            tooth_cnt <= (others => '0');
                        else
                            tooth_cnt <= tooth_cnt + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_tooth_count;

    -- -------------------------------------------------------------------------
    -- Interpolator
    -- Triggered when tooth_cnt = LAST_REAL on edge_pulse
    -- (LAST_REAL accounts for one cycle signal scheduling lag)
    -- Fires N_MISSING interp_pulses at current_period intervals
    -- Only affects AB, independent of Z timing
    -- -------------------------------------------------------------------------
    p_interp : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                interp_active <= '0';
                interp_cnt    <= 0;
                interp_timer  <= (others => '0');
                interp_period <= (others => '0');
                interp_pulse  <= '0';
            else
                interp_pulse <= '0';

                if edge_pulse = '1' and
                   to_integer(tooth_cnt) = to_integer(last_real) and
                   period_valid = '1' and
                   interp_active = '0' then
                    -- Start interpolation on last real tooth
                    -- current_period pre-update value used (one tooth lag, acceptable)
                    interp_active <= '1';
                    interp_cnt    <= 0;
                    interp_timer  <= (others => '0');
                    interp_period <= current_period;

                elsif interp_active = '1' then
                    if interp_timer >= interp_period - 1 then
                        interp_pulse <= '1';
                        interp_timer <= (others => '0');
                        if interp_cnt = to_integer(n_missing) - 1 then
                            interp_active <= '0';
                        else
                            interp_cnt <= interp_cnt + 1;
                        end if;
                    else
                        interp_timer <= interp_timer + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_interp;

    -- -------------------------------------------------------------------------
    -- Z pulse
    -- Fires on first real edge_pulse after gap (z_armed set by p_gap)
    -- Held high for one current_period then released
    -- -------------------------------------------------------------------------
    p_z : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                z_int   <= '0';
                z_timer <= (others => '0');
            else
                if z_armed = '1' and edge_pulse = '1' then
                    z_int   <= '1';
                    z_timer <= (others => '0');
                elsif z_int = '1' then
                    if z_timer >= current_period - 1 then
                        z_int   <= '0';
                        z_timer <= (others => '0');
                    else
                        z_timer <= z_timer + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_z;

    -- -------------------------------------------------------------------------
    -- AB output
    -- Toggles on every real edge_pulse and every interp_pulse
    -- -------------------------------------------------------------------------
    p_ab : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_int <= '0';
            else
                if edge_pulse = '1' or interp_pulse = '1' then
                    ab_int <= not ab_int;
                end if;
            end if;
        end if;
    end process p_ab;

    -- -------------------------------------------------------------------------
    -- Signal present
    -- -------------------------------------------------------------------------
    p_signal_present : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                timeout_cnt   <= (others => '0');
                timeout_limit <= MAX_32;
                sig_present   <= '0';
            else
                if edge_pulse = '1' then
                    timeout_cnt   <= (others => '0');
                    sig_present   <= '1';
                    if period_valid = '1' then
                        timeout_limit <= resize(
                            last_period * resize(n_missing + 3, 8), 32);
                    end if;
                elsif timeout_cnt < timeout_limit then
                    timeout_cnt <= timeout_cnt + 1;
                else
                    sig_present   <= '0';
                    timeout_limit <= MAX_32;
                    timeout_cnt   <= (others => '0');
                end if;
            end if;
        end if;
    end process p_signal_present;

    -- -------------------------------------------------------------------------
    -- Compute last_real from runtime n_teeth / n_missing
    -- -------------------------------------------------------------------------
    p_last_real : process(clk)
    begin
        if rising_edge(clk) then
            if n_teeth > n_missing + 1 then
                last_real <= n_teeth - n_missing - 2;
            else
                last_real <= (others => '0');
            end if;
        end if;
    end process p_last_real;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    ab             <= ab_int;
    z              <= z_int;
    tooth_period   <= current_period;
    tooth_count    <= tooth_cnt;
    gap_detected   <= gap_det;
    signal_present <= sig_present;
    edge_pulse_out <= edge_pulse;
    gap_period     <= gap_period_int;

end architecture rtl;