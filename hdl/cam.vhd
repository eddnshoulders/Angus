library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- cam.vhd
-- Edge detection for cam sensor signal.
-- cam_edge_sel: 0=falling, 1=rising.
-- Counts cam edges between z_edge strobes (counts per 2 crank revolutions).
-- cam_tooth_count resets on every second z_edge (720 deg cycle boundary).
-- =============================================================================
entity cam is
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;
        cam_clean    : in  std_logic;
        z_edge       : in  std_logic;  -- from src_sel
        cam_edge_sel : in  std_logic;  -- 0=falling, 1=rising
        cam_edge     : out std_logic;
        cam_tooth_count : out unsigned(7 downto 0)
    );
end entity cam;

architecture rtl of cam is
    signal cam_prev      : std_logic := '0';
    signal cam_edge_int  : std_logic := '0';
    signal tooth_cnt     : unsigned(7 downto 0) := (others => '0');
    signal z_count       : unsigned(0 downto 0) := (others => '0');
begin
    p_cam : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cam_prev     <= '0';
                cam_edge_int <= '0';
                tooth_cnt    <= (others => '0');
                z_count      <= (others => '0');
            else
                cam_prev     <= cam_clean;
                cam_edge_int <= '0';

                -- Edge detection
                if cam_edge_sel = '1' then
                    if cam_clean = '1' and cam_prev = '0' then
                        cam_edge_int <= '1';
                        tooth_cnt    <= tooth_cnt + 1;
                    end if;
                else
                    if cam_clean = '0' and cam_prev = '1' then
                        cam_edge_int <= '1';
                        tooth_cnt    <= tooth_cnt + 1;
                    end if;
                end if;

                -- Reset tooth count every 2nd z_edge (720 deg boundary)
                if z_edge = '1' then
                    z_count <= z_count + 1;
                    if z_count = "1" then
                        tooth_cnt <= (others => '0');
                        z_count   <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process p_cam;

    cam_edge        <= cam_edge_int;
    cam_tooth_count <= tooth_cnt;
end architecture rtl;
