library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- angle_tb
-- T1: startup divider -- angle_nco_ab_inc = 0xFFFFFFFF / (ppr*2)
--     For ppr=60: 0xFFFFFFFF / 120 = 35791394 (0x2222222)
-- T2: ab_edge snaps accumulator to edge_count * nco_ab_inc
-- T3: angle_deg correct after several edges (no interpolation)
-- T4: 2nd z_edge resets edge_count and accumulator
-- T5: interpolation -- nco_accum advances between edges when enabled
-- T6: angle_nco_clk_inc = angle_nco_ab_inc / ab_period
-- =============================================================================
entity angle_tb is end entity;
architecture sim of angle_tb is
    constant CLK_PERIOD   : time    := 10 ns;
    constant PPR          : integer := 60;
    constant AB_PERIOD_C  : integer := 10000;
    -- angle_nco_ab_inc = 0xFFFFFFFF / 120 = 35791394
    constant NCO_AB_INC   : integer := 35791394;

    signal clk        : std_logic := '0';
    signal done       : boolean   := false;
    signal rst        : std_logic := '1';
    signal ab_edge    : std_logic := '0';
    signal z_edge     : std_logic := '0';
    signal ab_per     : unsigned(31 downto 0) := to_unsigned(AB_PERIOD_C, 32);
    signal ppr_s      : unsigned(7 downto 0)  := to_unsigned(PPR, 8);
    signal interp_en  : std_logic := '0';
    signal angle_deg  : unsigned(15 downto 0);
    signal nco_ab_inc_s : unsigned(31 downto 0);
    signal nco_clk_inc: unsigned(31 downto 0);

    procedure fire_ab(signal s : out std_logic; signal c : in std_logic) is
    begin
        s <= '1'; wait until rising_edge(c); wait for 1 ns; s <= '0';
        wait until rising_edge(c);
    end procedure;

    procedure fire_z(signal s : out std_logic; signal c : in std_logic) is
    begin
        s <= '1'; wait until rising_edge(c); wait for 1 ns; s <= '0';
        wait until rising_edge(c);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not done else '0';

    dut : entity work.angle
        port map (clk=>clk, rst=>rst, ab_edge=>ab_edge, z_edge=>z_edge,
                  ab_period=>ab_per, ppr_conf=>ppr_s,
                  angle_interp_en=>interp_en,
                  angle_deg=>angle_deg,
                  angle_nco_ab_inc=>nco_ab_inc_s,
                  angle_nco_clk_inc=>nco_clk_inc);

    p_stim : process
    begin
        wait for 5 * CLK_PERIOD;
        rst <= '0';
        -- Wait for startup divider to complete (~70 cycles for ppr=60)
        wait for 100 * CLK_PERIOD;

        -- T1: verify angle_nco_ab_inc = 0xFFFFFFFF / 120
        assert nco_ab_inc_s = to_unsigned(NCO_AB_INC, 32)
            report "FAIL T1: nco_ab_inc wrong: " &
                   integer'image(to_integer(nco_ab_inc_s)) &
                   " expected " & integer'image(NCO_AB_INC)
            severity failure;
        report "T1: PASS";

        -- T2: ab_edge snaps nco_accum to edge_count * nco_ab_inc
        -- Before first ab_edge: angle_deg should be 0
        assert angle_deg = to_unsigned(0, 16)
            report "FAIL T2: angle_deg not 0 before first edge" severity failure;
        fire_ab(ab_edge, clk);
        -- edge_count was 0, snap to 0 * nco_ab_inc = 0, then edge_count becomes 1
        assert angle_deg = to_unsigned(0, 16)
            report "FAIL T2: angle_deg wrong after edge 0" severity failure;
        report "T2: PASS";

        -- T3: angle_deg advances correctly over several edges
        -- After edge 1 (second fire_ab): snap to 1 * nco_ab_inc
        -- angle_deg = (1 * 35791394 * 7200) >> 32 = (35791394 * 7200) >> 32
        -- = 257697956800 >> 32 = 59.99... ~ 60
        fire_ab(ab_edge, clk);
        assert to_integer(angle_deg) >= 59 and to_integer(angle_deg) <= 61
            report "FAIL T3: angle_deg after edge 1 wrong: " &
                   integer'image(to_integer(angle_deg)) severity failure;

        -- After 5 more edges (total edge_count=6):
        -- snap to 6 * 35791394 = 214748364
        -- angle_deg = (214748364 * 7200) >> 32 = 360
        fire_ab(ab_edge, clk); fire_ab(ab_edge, clk);
        fire_ab(ab_edge, clk); fire_ab(ab_edge, clk); fire_ab(ab_edge, clk);
        assert to_integer(angle_deg) >= 359 and to_integer(angle_deg) <= 361
            report "FAIL T3: angle_deg at edge 6 wrong: " &
                   integer'image(to_integer(angle_deg)) severity failure;
        report "T3: PASS";

        -- T4: 2nd z_edge resets edge_count and accumulator
        fire_z(z_edge, clk);
        assert to_integer(angle_deg) >= 359  -- first z doesn't reset
            report "FAIL T4: first z_edge reset accumulator (should not)" severity failure;
        fire_z(z_edge, clk);
        assert angle_deg = to_unsigned(0, 16)
            report "FAIL T4: second z_edge did not reset accumulator" severity failure;
        -- Verify edge_count reset by firing one ab_edge -- should snap to 0
        fire_ab(ab_edge, clk);
        assert angle_deg = to_unsigned(0, 16)
            report "FAIL T4: edge_count not reset after 2nd z (snap to non-zero)" severity failure;
        report "T4: PASS";

        -- T5: interpolation -- accumulator advances between edges
        interp_en <= '1';
        -- Fire ab_edge to trigger tooth divider
        fire_ab(ab_edge, clk);
        -- Wait for tooth divider to complete and supply clk_inc
        wait for 100 * CLK_PERIOD;
        -- After tooth divider: nco_clk_inc_int = nco_ab_inc / ab_period
        -- = 35791394 / 10000 = 3579
        -- After 10 more clocks accumulator should have advanced ~35790
        -- vs snap position + 10 * 3579 = snap + 35790
        -- angle_deg should be slightly above snap value
        assert to_integer(angle_deg) > 0
            report "FAIL T5: interpolation not advancing accumulator" severity failure;
        -- angle_deg at this point should be > edge 2 snap (60 deg)
        assert to_integer(angle_deg) >= 60
            report "FAIL T5: angle_deg below expected with interpolation" severity failure;
        report "T5: PASS";

        -- T6: angle_nco_clk_inc = nco_ab_inc / ab_period = 35791394 / 10000 = 3579
        assert to_integer(nco_clk_inc) >= 3570 and to_integer(nco_clk_inc) <= 3590
            report "FAIL T6: nco_clk_inc wrong: " &
                   integer'image(to_integer(nco_clk_inc)) severity failure;
        report "T6: PASS";

        report "All angle tests PASS";
        done <= true; std.env.stop; wait;
    end process;
end architecture sim;
