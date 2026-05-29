library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

entity angle_tb is end entity;
architecture sim of angle_tb is
    constant CLK_PERIOD  : time    := 10 ns;
    constant PPR         : integer := 60;
    constant AB_PERIOD   : integer := 1000;
    constant DEG_PER_EDGE: integer := 60; -- 7200/(60*2)

    signal clk       : std_logic := '0';
    signal done      : boolean   := false;
    signal rst       : std_logic := '1';
    signal ab_edge   : std_logic := '0';
    signal z_edge    : std_logic := '0';
    signal ab_per    : unsigned(31 downto 0) := to_unsigned(AB_PERIOD, 32);
    signal ppr_s     : unsigned(7 downto 0)  := to_unsigned(PPR, 8);
    signal angle_deg : unsigned(15 downto 0);
    signal angle_ph  : std_logic;

    procedure fire_ab(signal ab : out std_logic; signal clk : in std_logic) is
    begin
        ab <= '1'; wait until rising_edge(clk); ab <= '0'; wait until rising_edge(clk);
    end procedure;
    procedure fire_z(signal z : out std_logic; signal clk : in std_logic) is
    begin
        z <= '1'; wait until rising_edge(clk); z <= '0'; wait until rising_edge(clk);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';
    dut : entity work.angle port map(clk=>clk, rst=>rst, ab_edge=>ab_edge,
        z_edge=>z_edge, ab_period=>ab_per, ppr_conf=>ppr_s,
        angle_deg=>angle_deg, angle_phase=>angle_ph);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD; rst <= '0';

        -- T1: before first Z, ab edges don't count
        fire_ab(ab_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(angle_deg) = 0 report "FAIL T1: angle non-zero before first Z" severity failure;
        report "T1: PASS";

        -- T2: first Z sets origin
        fire_z(z_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(angle_deg) = 0 report "FAIL T2: angle not 0 after first Z" severity failure;
        assert angle_ph = '0' report "FAIL T2: phase not 0" severity failure;
        report "T2: PASS";

        -- T3: ab edges advance angle by deg_per_edge
        fire_ab(ab_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(angle_deg) = 0 report "FAIL T3: edge 0 should be 0" severity failure;
        fire_ab(ab_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(angle_deg) = DEG_PER_EDGE
            report "FAIL T3: edge 1 wrong: " & integer'image(to_integer(angle_deg)) severity failure;
        fire_ab(ab_edge, clk); fire_ab(ab_edge, clk); fire_ab(ab_edge, clk);
        wait for CLK_PERIOD;
        assert to_integer(angle_deg) = 4 * DEG_PER_EDGE
            report "FAIL T3: edge 4 wrong" severity failure;
        report "T3: PASS";

        -- T4: interpolation between edges
        fire_ab(ab_edge, clk);  -- snap to edge 5
        wait for CLK_PERIOD;
        -- Wait half ab_period
        wait for (AB_PERIOD/2) * CLK_PERIOD;
        -- base=5*60=300, interp at half period ~= 30, total ~= 330
        assert to_integer(angle_deg) >= 320 and to_integer(angle_deg) <= 340
            report "FAIL T4: interpolation wrong: " & integer'image(to_integer(angle_deg)) severity failure;
        report "T4: PASS";

        -- T5: second Z toggles phase, third Z resets angle
        fire_z(z_edge, clk);
        wait for CLK_PERIOD;
        assert angle_ph = '1' report "FAIL T5: phase not 1 after 2nd Z" severity failure;
        fire_z(z_edge, clk);
        wait for CLK_PERIOD;
        assert angle_ph = '0' report "FAIL T5: phase not 0 after 3rd Z" severity failure;
        assert to_integer(angle_deg) = 0 report "FAIL T5: angle not reset after 3rd Z" severity failure;
        report "T5: PASS";

        report "All angle tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
