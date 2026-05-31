library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- crank.vhd  (v2 -- adapted directly from archive crank_input.vhd)
--
-- Converts a conditioned crank wheel signal into AB/Z encoder-equivalent
-- outputs for downstream sync and angle blocks.
--
-- Signal flow:
--   crank_clean edges -> period measurement -> tooth counting
--   period_cnt timeout -> gap_det, z_armed
--   Next real edge_pulse with z_armed -> Z fires, tooth_count resets to 0
--   tooth_count = last_real on edge_pulse -> interpolator fills gap with AB
--
-- Key architectural properties (preserved from archive):
--   - edge_pulse is REGISTERED (1 cycle after physical edge). All downstream
--     processes see the same edge consistently. This avoids same-cycle races
--     between z_edge firing and ab_count resetting.
--   - crank_z (z_int) is held high for one tooth period, not a 1-clock strobe.
--     crank_z_edge is a separate 1-clock strobe on the rising edge of z_int.
--   - gap_det arms z on its RISING EDGE (not on the post-gap tooth), via
--     gap_det_prev tracking.
--   - Interpolation starts at last_real = n_teeth - n_missing - 2 to account
--     for the 1-cycle registered edge_pulse scheduling lag.
--   - crank_signal_ok gates gap detection, preventing false gaps during startup.
--
-- Added vs archive:
--   crank_ab_count: total AB edges per revolution (real + interpolated).
--     Resets to 0 on z_armed edge. Sync checks at z_int rising edge window.
--   crank_z_edge: 1-clock strobe on rising edge of z_int (for sync block).
-- =============================================================================

entity crank is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- From filter
        crank_clean      : in  std_logic;

        -- Startup config
        crank_edge_sel   : in  std_logic;
        crank_gap_thresh : in  unsigned(7 downto 0);
        crank_n_teeth    : in  unsigned(7 downto 0);
        crank_n_missing  : in  unsigned(7 downto 0);

        -- Outputs
        crank_ab_edge    : out std_logic;            -- 1-clock strobe per real edge
        crank_z_edge     : out std_logic;            -- 1-clock strobe on z rising edge
        crank_ppr_conf   : out unsigned(7 downto 0); -- = n_teeth
        crank_tooth_period : out unsigned(31 downto 0);
        crank_gap_period   : out unsigned(31 downto 0);
        crank_tooth_count  : out unsigned(7 downto 0);
        crank_ab_count     : out unsigned(7 downto 0);
        crank_gap_det      : out std_logic;
        crank_signal_ok_out: out std_logic;
        crank_ab           : out std_logic;
        crank_z            : out std_logic
    );
end entity crank;

architecture rtl of crank is

    constant MAX_32    : unsigned(31 downto 0) := (others => '1');

    -- last_real: tooth_cnt at which interpolator triggers
    -- = n_teeth - n_missing - 2 (accounts for 1-cycle edge_pulse lag)
    signal last_real      : unsigned(7 downto 0) := to_unsigned(56, 8);

    -- Edge detection
    signal clean_prev     : std_logic := '0';
    signal edge_pulse     : std_logic := '0';  -- REGISTERED: 1 cycle after physical edge

    -- Period measurement
    signal period_cnt     : unsigned(31 downto 0) := (others => '0');
    signal current_period : unsigned(31 downto 0) := (others => '0');
    signal last_period    : unsigned(31 downto 0) := (others => '0');
    signal edge_seen      : std_logic := '0';
    signal period_valid   : std_logic := '0';

    -- Gap detection and Z arming
    signal gap_det_int    : std_logic := '0';
    signal gap_det_prev   : std_logic := '0';
    signal gap_period_int : unsigned(31 downto 0) := (others => '0');
    signal z_armed        : std_logic := '0';

    -- Tooth counting
    signal tooth_cnt      : unsigned(7 downto 0) := (others => '0');

    -- Interpolator
    signal interp_active  : std_logic := '0';
    signal interp_cnt     : integer range 0 to 7 := 0;
    signal interp_timer   : unsigned(31 downto 0) := (others => '0');
    signal interp_period  : unsigned(31 downto 0) := (others => '0');
    signal interp_pulse   : std_logic := '0';

    -- Z pulse
    signal z_int          : std_logic := '0';
    signal z_int_prev     : std_logic := '0';
    signal z_timer        : unsigned(31 downto 0) := (others => '0');

    -- AB output and count
    signal ab_int         : std_logic := '0';
    signal ab_count_int   : unsigned(7 downto 0) := (others => '0');

    -- Signal present / timeout
    signal timeout_cnt    : unsigned(31 downto 0) := (others => '0');
    signal timeout_limit  : unsigned(31 downto 0) := MAX_32;
    signal sig_present    : std_logic := '0';

begin

    -- =========================================================================
    -- Edge detection (registered -- 1 cycle after physical edge)
    -- =========================================================================
    p_edge : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                clean_prev <= '0';
                edge_pulse <= '0';
            else
                clean_prev <= crank_clean;
                edge_pulse <= '0';
                if crank_edge_sel = '1' then
                    if crank_clean = '1' and clean_prev = '0' then
                        edge_pulse <= '1';
                    end if;
                else
                    if crank_clean = '0' and clean_prev = '1' then
                        edge_pulse <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process p_edge;

    -- =========================================================================
    -- Period measurement
    -- =========================================================================
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

    -- =========================================================================
    -- Gap detection and Z arming
    -- gap_det_int: high while period_cnt > gap_thresh * current_period
    -- z_armed: set on rising edge of gap_det_int
    -- =========================================================================
    p_gap : process(clk)
        variable lhs : unsigned(63 downto 0);
        variable rhs : unsigned(63 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                gap_det_int  <= '0';
                gap_det_prev <= '0';
                z_armed      <= '0';
                gap_period_int <= (others => '0');
            else
                gap_det_prev <= gap_det_int;

                -- Continuous timeout comparison
                gap_det_int <= '0';
                if period_valid = '1' and sig_present = '1' then
                    lhs := resize(period_cnt, 32) * to_unsigned(128, 32);
                    rhs := resize(current_period, 32) *
                           resize(crank_gap_thresh, 32);
                    if lhs > rhs then
                        gap_det_int <= '1';
                    end if;
                end if;

                -- Arm Z on rising edge of gap_det_int
                if gap_det_int = '1' and gap_det_prev = '0' then
                    z_armed        <= '1';
                    gap_period_int <= period_cnt;
                end if;

                -- Clear z_armed when p_z fires
                if z_armed = '1' and edge_pulse = '1' then
                    z_armed <= '0';
                end if;
            end if;
        end if;
    end process p_gap;

    -- =========================================================================
    -- Tooth counting
    -- Starts on second real edge (edge_seen gates first)
    -- Resets to 0 on first real edge after gap (z_armed high)
    -- =========================================================================
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
                        if tooth_cnt = crank_n_teeth - 1 then
                            tooth_cnt <= (others => '0');
                        else
                            tooth_cnt <= tooth_cnt + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_tooth_count;

    -- =========================================================================
    -- Interpolator
    -- Triggered at tooth_cnt = last_real (= n_teeth - n_missing - 2)
    -- Fires n_missing interp_pulses at current_period intervals
    -- =========================================================================
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
                    interp_active <= '1';
                    interp_cnt    <= 0;
                    interp_timer  <= (others => '0');
                    interp_period <= current_period;
                elsif interp_active = '1' then
                    if interp_timer >= interp_period - 1 then
                        interp_pulse <= '1';
                        interp_timer <= (others => '0');
                        if interp_cnt = to_integer(crank_n_missing) - 1 then
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

    -- =========================================================================
    -- Z pulse
    -- Fires on first real edge_pulse after gap (z_armed set by p_gap)
    -- Held high for one current_period then released
    -- crank_z_edge: 1-clock strobe on rising edge of z_int
    -- =========================================================================
    p_z : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                z_int      <= '0';
                z_int_prev <= '0';
                z_timer    <= (others => '0');
            else
                z_int_prev <= z_int;
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

    -- =========================================================================
    -- AB output and AB count
    -- Toggles on every real edge_pulse and every interp_pulse
    -- ab_count_int resets to 0 when z_armed fires (same clock as z_int rises)
    -- =========================================================================
    p_ab : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_int       <= '0';
                ab_count_int <= (others => '0');
            else
                if z_armed = '1' and edge_pulse = '1' then
                    -- Z tooth: reset ab_count, toggle ab
                    ab_count_int <= to_unsigned(1, 8);  -- count the z_tooth itself
                    ab_int       <= not ab_int;
                elsif edge_pulse = '1' then
                    ab_count_int <= ab_count_int + 1;
                    ab_int       <= not ab_int;
                elsif interp_pulse = '1' then
                    ab_count_int <= ab_count_int + 1;
                    ab_int       <= not ab_int;
                end if;
            end if;
        end if;
    end process p_ab;

    -- =========================================================================
    -- Signal present / timeout
    -- =========================================================================
    p_signal_present : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                timeout_cnt   <= (others => '0');
                timeout_limit <= MAX_32;
                sig_present   <= '0';
            else
                if edge_pulse = '1' then
                    timeout_cnt <= (others => '0');
                    sig_present <= '1';
                    if period_valid = '1' then
                        timeout_limit <= resize(
                            last_period * resize(crank_n_missing + 3, 8), 32);
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

    -- =========================================================================
    -- Compute last_real from runtime config
    -- last_real = n_teeth - n_missing - 2
    -- =========================================================================
    p_last_real : process(clk)
    begin
        if rising_edge(clk) then
            if crank_n_teeth > crank_n_missing + 1 then
                last_real <= crank_n_teeth - crank_n_missing - 2;
            else
                last_real <= (others => '0');
            end if;
        end if;
    end process p_last_real;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    crank_ab           <= ab_int;
    crank_z            <= z_int;
    crank_ab_edge      <= edge_pulse;           -- registered 1-clock strobe
    crank_z_edge       <= '1' when (z_int = '1' and z_int_prev = '0') else '0';
    crank_tooth_period <= current_period;
    crank_tooth_count  <= tooth_cnt;
    crank_ab_count     <= ab_count_int;
    crank_gap_det      <= gap_det_int;
    crank_gap_period   <= gap_period_int;
    crank_ppr_conf     <= crank_n_teeth;
    crank_signal_ok_out<= sig_present;

end architecture rtl;
