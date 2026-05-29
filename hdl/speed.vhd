library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- speed.vhd
-- Calculates two engine speed values:
-- speed_rpm_slow: from z_period (time between z_edges), updated every z_edge
--   speed_rpm_slow = 60_000_000_000 / (z_period * 1000) = 60_000_000 / z_period(clk)
--   At 100MHz: z_period in clocks, 1 rev = z_period/100MHz seconds
--   RPM = 60 / (z_period/100_000_000) = 6_000_000_000 / z_period
--   Use: RPM = 6_000_000_000 / z_period -- too big for 32-bit
--   Approximate: RPM = 600_000_000 / (z_period/10) or
--   For 16-bit output cap at 65535:
--   At 1000 RPM: z_period = 6_000_000_000/1000 = 6_000_000 clocks
--   Use integer division: rpm = 6_000_000_000 / z_period
--   Since we output 16-bit: saturate at 65535

-- speed_rpm_fast: from ab_period, updated every ab_edge
--   speed_rpm_fast = 60_000_000_000 / (ab_period * ppr_conf * 1000)
--   = 6_000_000_000 / (ab_period * ppr_conf)
-- =============================================================================
entity speed is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        ab_edge       : in  std_logic;
        z_edge        : in  std_logic;
        ab_period     : in  unsigned(31 downto 0);
        ppr_conf      : in  unsigned(7 downto 0);
        speed_rpm_slow: out unsigned(15 downto 0);
        speed_rpm_fast: out unsigned(15 downto 0)
    );
end entity speed;

architecture rtl of speed is
    -- Use 100MHz clock. RPM = 60 * CLK_FREQ / z_period
    -- = 6_000_000_000 / z_period
    -- Cap at 16-bit: if result > 65535 saturate
    constant CLK_FREQ : unsigned(35 downto 0) := x"165A0BC00";

    signal z_timer    : unsigned(31 downto 0) := (others => '0');
    signal z_period   : unsigned(31 downto 0) := (others => '1');
    signal z_seen     : std_logic := '0';
    signal rpm_slow   : unsigned(15 downto 0) := (others => '0');
    signal rpm_fast   : unsigned(15 downto 0) := (others => '0');

    -- Divider signals for slow rpm
    signal div_slow_start : std_logic := '0';
    signal div_slow_busy  : std_logic := '0';
    signal div_slow_done  : std_logic := '0';
    signal div_slow_rem   : unsigned(35 downto 0) := (others => '0');
    signal div_slow_q     : unsigned(15 downto 0) := (others => '0');
    signal div_slow_shift : integer range 0 to 15 := 0;
    signal div_slow_dsor  : unsigned(31 downto 0) := (others => '1');

    -- Divider signals for fast rpm
    signal div_fast_start : std_logic := '0';
    signal div_fast_busy  : std_logic := '0';
    signal div_fast_dend  : unsigned(35 downto 0) := (others => '0');
    signal div_fast_rem   : unsigned(35 downto 0) := (others => '0');
    signal div_fast_q     : unsigned(15 downto 0) := (others => '0');
    signal div_fast_shift : integer range 0 to 15 := 0;
    signal div_fast_dsor  : unsigned(39 downto 0) := (others => '1');

begin

    -- z_period measurement
    p_z : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                z_timer   <= (others => '0');
                z_period  <= (others => '1');
                z_seen    <= '0';
                div_slow_start <= '0';
            else
                div_slow_start <= '0';
                z_timer <= z_timer + 1;
                if z_edge = '1' then
                    if z_seen = '1' then
                        z_period <= z_timer;
                        div_slow_start <= '1';
                        div_slow_dsor  <= z_timer;
                    end if;
                    z_timer <= (others => '0');
                    z_seen  <= '1';
                end if;
            end if;
        end if;
    end process p_z;

    -- ab_period based fast rpm trigger
    p_fast_trig : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                div_fast_start <= '0';
            else
                div_fast_start <= '0';
                if ab_edge = '1' and ab_period > 0 and ppr_conf > 0 then
                    div_fast_start <= '1';
                    -- dsor = ab_period * ppr_conf (cap at 36 bits)
                    div_fast_dsor <= resize(ab_period, 32) * resize(ppr_conf, 8);  -- 40-bit result
                end if;
            end if;
        end if;
    end process p_fast_trig;

    -- Slow RPM divider: 6_000_000_000 / z_period -> 16-bit result
    p_div_slow : process(clk)
        variable sv : unsigned(35 downto 0);
        variable sq : unsigned(15 downto 0);
        variable sd : unsigned(35 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                div_slow_busy <= '0';
                rpm_slow <= (others => '0');
            else
                if div_slow_start = '1' and div_slow_busy = '0' then
                    div_slow_rem   <= CLK_FREQ;
                    div_slow_q     <= (others => '0');
                    div_slow_shift <= 15;
                    div_slow_busy  <= '1';
                elsif div_slow_busy = '1' then
                    sd := resize(div_slow_dsor, 36) sll div_slow_shift;
                    sv := div_slow_rem;
                    sq := div_slow_q;
                    if sv >= sd then
                        sv := sv - sd;
                        sq(div_slow_shift) := '1';
                    end if;
                    div_slow_rem <= sv;
                    div_slow_q   <= sq;
                    if div_slow_shift = 0 then
                        div_slow_busy <= '0';
                        rpm_slow <= sq;
                    else
                        div_slow_shift <= div_slow_shift - 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_div_slow;

    -- Fast RPM divider: 6_000_000_000 / (ab_period * ppr) -> 16-bit result
    p_div_fast : process(clk)
        variable fv : unsigned(35 downto 0);
        variable fq : unsigned(15 downto 0);
        variable fd : unsigned(39 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                div_fast_busy <= '0';
                rpm_fast <= (others => '0');
            else
                if div_fast_start = '1' and div_fast_busy = '0' then
                    div_fast_rem   <= CLK_FREQ;
                    div_fast_q     <= (others => '0');
                    div_fast_shift <= 15;
                    div_fast_busy  <= '1';
                elsif div_fast_busy = '1' then
                    fd := resize(div_fast_dsor, 40) sll div_fast_shift;
                    fv := div_fast_rem;
                    fq := div_fast_q;
                    if resize(fv,40) >= fd then
                        fv := fv - fd(35 downto 0);
                        fq(div_fast_shift) := '1';
                    end if;
                    div_fast_rem <= fv;
                    div_fast_q   <= fq;
                    if div_fast_shift = 0 then
                        div_fast_busy <= '0';
                        rpm_fast <= fq;
                    else
                        div_fast_shift <= div_fast_shift - 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_div_fast;

    speed_rpm_slow <= rpm_slow;
    speed_rpm_fast <= rpm_fast;

end architecture rtl;
