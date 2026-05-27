library ieee;
use ieee.std_logic_1164.all;

-- =============================================================================
-- cam_input
--
-- Edge detector for cam sensor signal.
-- cam_edge_sel: '0'=falling edge, '1'=rising edge (startup config from AXI)
-- =============================================================================

entity cam_input is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        cam_clean  : in  std_logic;
        cam_edge_sel : in  std_logic;  -- '0'=falling, '1'=rising
        cam_pulse  : out std_logic
    );
end entity cam_input;

architecture rtl of cam_input is
    signal cam_prev : std_logic := '0';
begin
    p_edge : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cam_prev  <= '0';
                cam_pulse <= '0';
            else
                cam_prev  <= cam_clean;
                cam_pulse <= '0';
                if cam_edge_sel = '1' then
                    if cam_clean = '1' and cam_prev = '0' then
                        cam_pulse <= '1';
                    end if;
                else
                    if cam_clean = '0' and cam_prev = '1' then
                        cam_pulse <= '1';
                    end if;
                end if;
            end if;
        end if;    end process p_edge;
end architecture rtl;
