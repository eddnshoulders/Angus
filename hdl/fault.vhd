library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- fault.vhd
-- Centralised fault detection block.
-- Receives status signals from all blocks and generates:
--   fault_flags[31:0] - instantaneous fault flags
--     [0] cam_signal_fault
--     [1] crank_tooth_fault
--     [2] crank_ab_fault
--     [3] speed_fault
--     [4] pll_phase_err_fault
--   Fault counters for each fault type
-- fault_clear: self-clearing strobe from AXI, resets all counters
-- =============================================================================
entity fault is
    port (
        clk                : in  std_logic;
        rst                : in  std_logic;
        fault_clear        : in  std_logic;
        -- Cam inputs
        cam_tooth_count    : in  unsigned(7 downto 0);
        cam_n_teeth        : in  unsigned(7 downto 0);
        z_edge             : in  std_logic;   -- 720 deg z_edge for cam window
        -- Crank inputs
        crank_tooth_count  : in  unsigned(7 downto 0);
        crank_ab_count     : in  unsigned(7 downto 0);
        crank_n_teeth      : in  unsigned(7 downto 0);
        crank_n_missing    : in  unsigned(7 downto 0);
        crank_z_edge       : in  std_logic;
        -- Speed inputs
        speed_rpm_slow     : in  unsigned(15 downto 0);
        -- PLL inputs
        pll_phase_err      : in  signed(31 downto 0);
        pll_phase_err_thresh: in unsigned(31 downto 0);
        sync_full          : in  std_logic;
        -- Phase fault
        phase_fault_drop   : in  std_logic;
        phase_ref_ok       : in  std_logic;
        -- Outputs
        fault_flags        : out std_logic_vector(31 downto 0);
        cam_fault_count    : out unsigned(15 downto 0);
        crank_fault_count  : out unsigned(15 downto 0);
        phase_fault_count  : out unsigned(15 downto 0);
        ab_fault_count     : out unsigned(15 downto 0);
        speed_fault_count  : out unsigned(15 downto 0);
        pll_err_count      : out unsigned(15 downto 0)
    );
end entity fault;

architecture rtl of fault is
    signal cam_fault_int    : std_logic := '0';
    signal crank_tooth_fault: std_logic := '0';
    signal crank_ab_fault   : std_logic := '0';
    signal speed_fault_int  : std_logic := '0';
    signal pll_err_int      : std_logic := '0';

    signal cam_cnt          : unsigned(15 downto 0) := (others => '0');
    signal crank_cnt        : unsigned(15 downto 0) := (others => '0');
    signal phase_cnt        : unsigned(15 downto 0) := (others => '0');
    signal ab_cnt           : unsigned(15 downto 0) := (others => '0');
    signal speed_cnt        : unsigned(15 downto 0) := (others => '0');
    signal pll_cnt          : unsigned(15 downto 0) := (others => '0');

    signal phase_ref_ok_prev: std_logic := '1';
    signal z_count          : unsigned(0 downto 0) := (others => '0');
    signal cam_window_z     : std_logic := '0';

    function sat_inc(v : unsigned(15 downto 0)) return unsigned is
    begin
        if v = (v'range => '1') then return v; end if;
        return v + 1;
    end function;

begin
    p_fault : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cam_fault_int     <= '0';
                crank_tooth_fault <= '0';
                crank_ab_fault    <= '0';
                speed_fault_int   <= '0';
                pll_err_int       <= '0';
                cam_cnt           <= (others => '0');
                crank_cnt         <= (others => '0');
                phase_cnt         <= (others => '0');
                ab_cnt            <= (others => '0');
                speed_cnt         <= (others => '0');
                pll_cnt           <= (others => '0');
                phase_ref_ok_prev <= '1';
                z_count           <= (others => '0');
                cam_window_z      <= '0';
            else
                -- fault_clear resets all counters
                if fault_clear = '1' then
                    cam_cnt   <= (others => '0');
                    crank_cnt <= (others => '0');
                    phase_cnt <= (others => '0');
                    ab_cnt    <= (others => '0');
                    speed_cnt <= (others => '0');
                    pll_cnt   <= (others => '0');
                end if;

                -- Track z_edges for cam window (every 2nd z_edge = 720 deg)
                cam_fault_int <= '0';
                if z_edge = '1' then
                    z_count <= z_count + 1;
                    if z_count = "1" then
                        z_count <= (others => '0');
                        cam_window_z <= '1';
                    else
                        cam_window_z <= '0';
                    end if;
                end if;

                -- Cam fault: wrong tooth count at 720 deg boundary
                if cam_window_z = '1' then
                    cam_window_z <= '0';
                    if cam_tooth_count /= cam_n_teeth then
                        cam_fault_int <= '1';
                        cam_cnt <= sat_inc(cam_cnt);
                    end if;
                end if;

                -- Crank faults at each crank z_edge
                crank_tooth_fault <= '0';
                crank_ab_fault    <= '0';
                if crank_z_edge = '1' and sync_full = '1' then
                    if crank_tooth_count /= (crank_n_teeth - crank_n_missing) then
                        crank_tooth_fault <= '1';
                        crank_cnt <= sat_inc(crank_cnt);
                    end if;
                    if crank_ab_count /= crank_n_teeth then
                        crank_ab_fault <= '1';
                        if crank_tooth_count = (crank_n_teeth - crank_n_missing) then
                            -- Only count as separate fault if tooth count was OK
                            crank_cnt <= sat_inc(crank_cnt);
                        end if;
                    end if;
                end if;

                -- Phase fault: falling edge of phase_ref_ok
                phase_ref_ok_prev <= phase_ref_ok;
                if phase_ref_ok = '0' and phase_ref_ok_prev = '1' then
                    phase_cnt <= sat_inc(phase_cnt);
                end if;

                -- Speed fault: RPM out of range (0 < RPM < 15000)
                speed_fault_int <= '0';
                if speed_rpm_slow = 0 or speed_rpm_slow > to_unsigned(15000, 16) then
                    speed_fault_int <= '1';
                    if sync_full = '1' then
                        speed_cnt <= sat_inc(speed_cnt);
                    end if;
                end if;

                -- PLL phase error fault
                pll_err_int <= '0';
                if sync_full = '1' then
                    if pll_phase_err > signed(resize(pll_phase_err_thresh, 32)) or
                       pll_phase_err < -signed(resize(pll_phase_err_thresh, 32)) then
                        pll_err_int <= '1';
                        pll_cnt <= sat_inc(pll_cnt);
                    end if;
                end if;
            end if;
        end if;
    end process p_fault;

    fault_flags(0)  <= cam_fault_int;
    fault_flags(1)  <= crank_tooth_fault;
    fault_flags(2)  <= crank_ab_fault;
    fault_flags(3)  <= speed_fault_int;
    fault_flags(4)  <= pll_err_int;
    fault_flags(31 downto 5) <= (others => '0');

    cam_fault_count   <= cam_cnt;
    crank_fault_count <= crank_cnt;
    phase_fault_count <= phase_cnt;
    ab_fault_count    <= ab_cnt;
    speed_fault_count <= speed_cnt;
    pll_err_count     <= pll_cnt;

end architecture rtl;
