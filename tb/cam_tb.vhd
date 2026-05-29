library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity cam_tb is end entity;
architecture sim of cam_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal done      : boolean := false;
    signal rst       : std_logic := '1';
    signal cam_clean : std_logic := '0';
    signal z_edge    : std_logic := '0';
    signal edge_sel  : std_logic := '1';
    signal cam_edge  : std_logic;
    signal cam_cnt   : unsigned(7 downto 0);

    procedure fire_z(signal z : out std_logic; signal clk : in std_logic) is
    begin
        z <= '1'; wait until rising_edge(clk); z <= '0'; wait until rising_edge(clk);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.cam port map(clk=>clk, rst=>rst, cam_clean=>cam_clean,
        z_edge=>z_edge, cam_edge_sel=>edge_sel, cam_edge=>cam_edge, cam_tooth_count=>cam_cnt);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0';

        -- T1: rising edge detected
        cam_clean <= '0'; wait for CLK_PERIOD;
        cam_clean <= '1'; wait for CLK_PERIOD;
        assert cam_edge = '1' report "FAIL T1: rising edge not detected" severity failure;
        wait for CLK_PERIOD;
        assert cam_edge = '0' report "FAIL T1: cam_edge not 1-clock pulse" severity failure;
        report "T1: PASS";

        -- T2: falling edge sel=0
        edge_sel <= '0';
        cam_clean <= '0'; wait for CLK_PERIOD;
        assert cam_edge = '1' report "FAIL T2: falling edge not detected" severity failure;
        wait for CLK_PERIOD;
        assert cam_edge = '0' report "FAIL T2: cam_edge not 1-clock pulse" severity failure;
        report "T2: PASS";

        -- T3: tooth count increments
        edge_sel <= '1';
        assert to_integer(cam_cnt) = 2 report "FAIL T3: tooth count wrong" severity failure;
        cam_clean <= '1'; wait for CLK_PERIOD; cam_clean <= '0'; wait for CLK_PERIOD;
        assert to_integer(cam_cnt) = 3 report "FAIL T3: tooth count not incrementing" severity failure;
        report "T3: PASS";

        -- T4: tooth count resets on every 2nd z_edge
        fire_z(z_edge, clk);
        assert to_integer(cam_cnt) = 3 report "FAIL T4: count reset on 1st z" severity failure;
        fire_z(z_edge, clk);
        assert to_integer(cam_cnt) = 0 report "FAIL T4: count not reset on 2nd z" severity failure;
        report "T4: PASS";

        report "All cam tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
