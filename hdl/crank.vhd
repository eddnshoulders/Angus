library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- crank.vhd  (v2)
--
-- Directly adapted from archive/crank_input.vhd -- internal logic unchanged.
-- Interface changes only:
--   entity name:    crank_input       -> crank
--   clean_signal    -> crank_clean
--   signal_stable   -> removed (sig_present used internally for gap gating)
--   crank_edge_sel  -> crank_edge_sel (unchanged)
--   gap_threshold   -> crank_gap_thresh
--   n_teeth         -> crank_n_teeth
--   n_missing       -> crank_n_missing
--   ab_crank        -> crank_ab
--   z_crank         -> crank_z
--   tooth_period    -> crank_tooth_period
--   tooth_count     -> crank_tooth_count
--   gap_detected    -> crank_gap_det
--   signal_present  -> crank_signal_ok
--   edge_pulse_out  -> crank_ab_edge
--   gap_period      -> crank_gap_period
--   ppr_crank       -> crank_ppr_conf
--
-- Added outputs (not in archive):
--   crank_z_edge    -- 1-clock strobe on rising edge of z_crank (for sync block)
--   crank_ab_count  -- AB edges per revolution (real + interpolated), reset on z
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

        -- Encoder-equivalent outputs
        crank_ab         : out std_logic;
        crank_z          : out std_logic;
        crank_z_edge     : out std_logic;            -- 1-clock strobe on z rising edge
        crank_ab_edge    : out std_logic;
        crank_tooth_period : out unsigned(31 downto 0);
        crank_gap_period   : out unsigned(31 downto 0);
        crank_tooth_count  : out unsigned(7 downto 0);
        crank_ab_count     : out unsigned(7 downto 0);
        crank_ppr_conf     : out unsigned(7 downto 0);
        crank_gap_det      : out std_logic;
        crank_signal_ok    : out std_logic
    );
end entity crank;

architecture rtl of crank is

    constant MAX_32    : unsigned(31 downto 0) := (others => '1');
    signal last_real   : unsigned(7 downto 0) := to_unsigned(56, 8);

    signal clean_prev     : std_logic := '0';
    signal edge_pulse     : std_logic := '0';

    signal period_cnt     : unsigned(31 downto 0) := (others => '0');
    signal current_period : unsigned(31 downto 0) := (others => '0');
    signal last_period    : unsigned(31 downto 0) := (others => '0');
    signal edge_seen      : std_logic := '0';
    signal period_valid   : std_logic := '0';

    signal gap_det        : std_logic := '0';
    signal gap_det_prev   : std_logic := '0';
    signal gap_period_int : unsigned(31 downto 0) := (others => '0');
    signal z_armed        : std_logic := '0';

    signal tooth_cnt      : unsigned(7 downto 0) := (others => '0');

    signal interp_active  : std_logic := '0';
    signal interp_cnt     : integer range 0 to 7 := 0;
    signal interp_timer   : unsigned(31 downto 0) := (others => '0');
    signal interp_period  : unsigned(31 downto 0) := (others => '0');
    signal interp_pulse   : std_logic := '0';

    signal z_int          : std_logic := '0';
    signal z_int_prev     : std_logic := '0';
    signal z_timer        : unsigned(31 downto 0) := (others => '0');

    signal ab_int         : std_logic := '0';
    signal ab_count_int   : unsigned(7 downto 0) := (others => '0');

    signal timeout_cnt    : unsigned(31 downto 0) := (others => '0');
    signal timeout_limit  : unsigned(31 downto 0) := MAX_32;
    signal sig_present    : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- Edge detection (unchanged from archive)
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- Period measurement (unchanged from archive)
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
    -- Gap detection and Z arming (unchanged from archive, uses sig_present)
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

                gap_det <= '0';
                if period_valid = '1' and sig_present = '1' then
                    lhs := resize(period_cnt, 32) * to_unsigned(128, 32);
                    rhs := resize(current_period, 32) *
                           resize(crank_gap_thresh, 32);
                    if lhs > rhs then
                        gap_det <= '1';
                    end if;
                end if;

                if gap_det = '1' and gap_det_prev = '0' then
                    z_armed        <= '1';
                    gap_period_int <= period_cnt;
                end if;

                if z_armed = '1' and edge_pulse = '1' then
                    z_armed <= '0';
                end if;
            end if;
        end if;
    end process p_gap;

    -- -------------------------------------------------------------------------
    -- Tooth counting (unchanged from archive)
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

    -- -------------------------------------------------------------------------
    -- Interpolator (unchanged from archive)
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

    -- -------------------------------------------------------------------------
    -- Z pulse (unchanged from archive, plus z_int_prev for z_edge strobe)
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- AB output (unchanged from archive, plus ab_count_int)
    -- -------------------------------------------------------------------------
    p_ab : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_int       <= '0';
                ab_count_int <= (others => '0');
            else
                -- Reset ab_count on z (z_armed + edge_pulse)
                if z_armed = '1' and edge_pulse = '1' then
                    ab_count_int <= to_unsigned(1, 8);
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

    -- -------------------------------------------------------------------------
    -- Signal present (unchanged from archive)
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

    -- -------------------------------------------------------------------------
    -- last_real (unchanged from archive)
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    crank_ab           <= ab_int;
    crank_z            <= z_int;
    crank_z_edge       <= '1' when (z_int = '1' and z_int_prev = '0') else '0';
    crank_ab_edge      <= edge_pulse or interp_pulse;
    crank_tooth_period <= current_period;
    crank_tooth_count  <= tooth_cnt;
    crank_ab_count     <= ab_count_int;
    crank_gap_det      <= gap_det;
    crank_gap_period   <= gap_period_int;
    crank_ppr_conf     <= crank_n_teeth;
    crank_signal_ok    <= sig_present;

end architecture rtl;
