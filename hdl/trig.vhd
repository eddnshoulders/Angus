library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- trig.vhd
-- Angle-domain sample trigger.
-- Monitors ang_deg for increments; fires trig_pulse every trig_decimation
-- increments. Pulse width is trig_pulse_width clocks.
-- trig_pulse_count resets on z_edge, increments on each trig_pulse.
-- =============================================================================
entity trig is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        ang_deg          : in  unsigned(15 downto 0);
        z_edge           : in  std_logic;
        trig_decimation  : in  unsigned(15 downto 0);
        trig_pulse_width : in  unsigned(15 downto 0);
        trig_pulse       : out std_logic;
        trig_pulse_count : out unsigned(31 downto 0)
    );
end entity trig;

architecture rtl of trig is
    signal ang_prev      : unsigned(15 downto 0) := (others => '0');
    signal decim_cnt     : unsigned(15 downto 0) := (others => '0');
    signal pulse_cnt     : unsigned(31 downto 0) := (others => '0');
    signal pulse_width_cnt: unsigned(15 downto 0) := (others => '0');
    signal pulse_int     : std_logic := '0';
begin
    p_trig : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ang_prev       <= (others => '0');
                decim_cnt      <= (others => '0');
                pulse_cnt      <= (others => '0');
                pulse_width_cnt<= (others => '0');
                pulse_int      <= '0';
            else
                -- Reset pulse count on z_edge
                if z_edge = '1' then
                    pulse_cnt <= (others => '0');
                end if;

                -- Pulse width counter
                if pulse_int = '1' then
                    if pulse_width_cnt >= trig_pulse_width - 1 then
                        pulse_int       <= '0';
                        pulse_width_cnt <= (others => '0');
                    else
                        pulse_width_cnt <= pulse_width_cnt + 1;
                    end if;
                end if;

                -- Detect ang_deg increment and decimate
                ang_prev <= ang_deg;
                if ang_deg /= ang_prev then
                    if decim_cnt >= trig_decimation - 1 then
                        decim_cnt <= (others => '0');
                        pulse_int <= '1';
                        pulse_width_cnt <= (others => '0');
                        pulse_cnt <= pulse_cnt + 1;
                    else
                        decim_cnt <= decim_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_trig;

    trig_pulse       <= pulse_int;
    trig_pulse_count <= pulse_cnt;
end architecture rtl;
