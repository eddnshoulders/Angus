library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- crank.vhd
-- Crank trigger wheel signal processing.
-- Outputs:
--   crank_ab_edge    : 1-clock strobe on every detected tooth edge (real only)
--   crank_z_edge     : 1-clock strobe on first edge after gap (z reference)
--   crank_ppr_conf   : pass-through of crank_n_teeth for src_sel
--   crank_tooth_period: period between consecutive tooth edges (clock cycles)
--   crank_tooth_count: real tooth count per revolution (resets on z)
--   crank_ab_count   : all ab edges per revolution including interpolated
--   crank_gap_det    : '1' while gap is currently detected
--   crank_signal_ok  : '1' when signal is present (edges arriving)
--   crank_ab         : toggles on each ab edge (real and interpolated)
--   crank_z          : high from first edge after gap until next ab edge
--
-- Gap detection: current inter-edge time > gap_threshold * last_tooth_period
-- gap_threshold is 1.7 fixed point: 0xC0 = 1.5x
-- Missing tooth interpolation: generates ab edges at expected tooth period
-- =============================================================================
entity crank is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;
        crank_clean       : in  std_logic;
        crank_edge_sel    : in  std_logic;  -- 0=falling, 1=rising
        crank_gap_thresh  : in  unsigned(7 downto 0);
        crank_n_teeth     : in  unsigned(7 downto 0);
        crank_n_missing   : in  unsigned(7 downto 0);
        crank_ab_edge     : out std_logic;
        crank_z_edge      : out std_logic;
        crank_ppr_conf    : out unsigned(7 downto 0);
        crank_tooth_period: out unsigned(31 downto 0);
        crank_tooth_count : out unsigned(7 downto 0);
        crank_ab_count    : out unsigned(7 downto 0);
        crank_gap_det     : out std_logic;
        crank_signal_ok   : out std_logic;
        crank_ab          : out std_logic;
        crank_z           : out std_logic
    );
end entity crank;

architecture rtl of crank is
    signal clean_prev       : std_logic := '0';

    -- Period measurement
    signal period_cnt       : unsigned(31 downto 0) := (others => '0');
    signal last_period      : unsigned(31 downto 0) := (others => '1');
    signal tooth_period_int : unsigned(31 downto 0) := (others => '0');

    -- Gap detection
    signal gap_thresh_ext   : unsigned(39 downto 0);  -- last_period * gap_threshold
    signal edge_det_reg    : std_logic := '0';  -- registered edge_det for external use
    signal gap_det_int      : std_logic := '0';

    -- Post-gap state
    signal z_armed          : std_logic := '0';
    signal z_int            : std_logic := '0';
    signal z_edge_int       : std_logic := '0';

    -- Tooth counting
    signal tooth_cnt        : unsigned(7 downto 0) := (others => '0');
    signal ab_cnt           : unsigned(7 downto 0) := (others => '0');
    signal ab_int           : std_logic := '0';
    signal ab_edge_int      : std_logic := '0';

    -- Interpolation
    signal interp_en        : std_logic := '0';
    signal interp_cnt       : unsigned(7 downto 0) := (others => '0');
    signal interp_accum     : unsigned(31 downto 0) := (others => '0');
    signal missing_teeth    : unsigned(7 downto 0) := (others => '0');

    -- Signal present watchdog
    signal sig_timer        : unsigned(31 downto 0) := (others => '0');
    signal signal_ok_int    : std_logic := '0';

begin

    -- Gap threshold: last_period * gap_thresh / 128 (1.7 fixed point)
    gap_thresh_ext <= resize(last_period, 32) * resize(crank_gap_thresh, 8);  -- 40-bit result

    p_crank : process(clk)
        variable edge_det_v : std_logic := '0';
    begin
        if rising_edge(clk) then
            if rst = '1' then
                clean_prev       <= '0';
                
                period_cnt       <= (others => '0');
                last_period      <= (others => '1');
                tooth_period_int <= (others => '0');
                gap_det_int      <= '0';
                z_armed          <= '0';
                z_int            <= '0';
                z_edge_int       <= '0';
                tooth_cnt        <= (others => '0');
                ab_cnt           <= (others => '0');
                ab_int           <= '0';
                ab_edge_int      <= '0';
                interp_en        <= '0';
                interp_cnt       <= (others => '0');
                interp_accum     <= (others => '0');
                missing_teeth    <= (others => '0');
                sig_timer        <= (others => '0');
                signal_ok_int    <= '0';
            else
                clean_prev  <= crank_clean;
                ab_edge_int <= '0';
                z_edge_int  <= '0';
                edge_det_v := '0';

                -- Edge detection (variable so it's immediately visible below)
                if crank_edge_sel = '1' then
                    if crank_clean = '1' and clean_prev = '0' then
                        edge_det_v := '1';
                    end if;
                else
                    if crank_clean = '0' and clean_prev = '1' then
                        edge_det_v := '1';
                    end if;
                end if;

                -- Period counter (always running)
                period_cnt <= period_cnt + 1;

                -- Gap detection: period_cnt * 128 > last_period * gap_thresh
                if resize(period_cnt, 40) * to_unsigned(128, 40) >= gap_thresh_ext then
                    gap_det_int <= '1';
                end if;

                -- Signal present watchdog
                sig_timer <= sig_timer + 1;
                if edge_det_v = '1' then
                    sig_timer    <= (others => '0');
                    signal_ok_int <= '1';
                end if;
                if sig_timer > x"0FFFFFFF" then
                    signal_ok_int <= '0';
                end if;

                -- Real tooth edge processing
                if edge_det_v = '1' then
                    if gap_det_int = '1' then
                        -- Post-gap: this is the reference tooth
                        tooth_period_int <= last_period;
                        last_period      <= period_cnt;
                        gap_det_int      <= '0';
                        z_armed          <= '1';
                        -- Interpolate missing teeth
                        missing_teeth <= crank_n_missing;
                        interp_cnt    <= (others => '0');
                        interp_accum  <= (others => '0');
                        interp_en     <= '1';
                        tooth_cnt     <= (others => '0');
                    else
                        -- Normal tooth
                        tooth_period_int <= period_cnt;
                        last_period      <= period_cnt;
                    end if;

                    -- Reset period counter
                    period_cnt <= (others => '0');

                    -- AB edge on real tooth
                    ab_int      <= not ab_int;
                    ab_edge_int <= '1';
                    ab_cnt      <= ab_cnt + 1;
                    tooth_cnt   <= tooth_cnt + 1;

                    -- Z pulse: fires on first tooth AFTER gap (z_armed was set last cycle)
                    -- Or fires on the gap tooth itself if gap_det was already set
                    if z_armed = '1' or gap_det_int = '1' then
                        z_int      <= '1';
                        z_edge_int <= '1';
                        z_armed    <= '0';
                        -- Reset counters on z
                        tooth_cnt  <= to_unsigned(1, 8);
                        ab_cnt     <= to_unsigned(1, 8);
                    end if;
                end if;

                -- Clear z after next edge
                if edge_det_v = '1' and z_int = '1' and z_edge_int = '0' then
                    z_int <= '0';
                end if;

                -- Missing tooth interpolation
                if interp_en = '1' and edge_det_v = '0' then
                    interp_accum <= interp_accum + 1;
                    if interp_accum >= last_period and interp_cnt < missing_teeth then
                        interp_accum <= (others => '0');
                        interp_cnt   <= interp_cnt + 1;
                        ab_int       <= not ab_int;
                        ab_edge_int  <= '1';
                        ab_cnt       <= ab_cnt + 1;
                        if interp_cnt + 1 >= missing_teeth then
                            interp_en <= '0';
                        end if;
                    end if;
                end if;
                edge_det_reg <= edge_det_v;
            end if;
        end if;
    end process p_crank;

    crank_ab_edge      <= ab_edge_int;
    crank_z_edge       <= z_edge_int;
    crank_ppr_conf     <= crank_n_teeth;
    crank_tooth_period <= tooth_period_int;
    crank_tooth_count  <= tooth_cnt;
    crank_ab_count     <= ab_cnt;
    crank_gap_det      <= gap_det_int;
    crank_signal_ok    <= signal_ok_int;
    crank_ab           <= ab_int;
    crank_z            <= z_int;

end architecture rtl;
