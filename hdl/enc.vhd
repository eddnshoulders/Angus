library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- enc.vhd
-- Quadrature encoder input processing.
-- Merges A and B channels with configurable edge selection (rising/falling/both).
-- Z channel for revolution reference.
-- Outputs edge strobes matching src_sel interface for routing through src_sel.
-- enc_ab_edge: strobe on every counted encoder edge
-- enc_z_edge:  strobe on z channel detected edge
-- enc_ppr_conf: pass-through of enc_n_ppr (lower 8 bits)
-- enc_ab_period: clocks between consecutive ab edges
-- enc_ab_count:  ab edge count per revolution (resets on z)
-- enc_a_count:   a channel edge count
-- enc_b_count:   b channel edge count
-- enc_signal_ok: signal present flag
-- enc_fault_count: placeholder for future use
-- =============================================================================
entity enc is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        a_clean          : in  std_logic;
        b_clean          : in  std_logic;
        z_clean          : in  std_logic;
        enc_ab_edge_sel  : in  unsigned(1 downto 0);  -- 0=rising, 1=falling, 2=both
        enc_z_edge_sel   : in  std_logic;              -- 0=rising, 1=falling
        enc_n_ppr        : in  unsigned(15 downto 0);
        enc_ab_edge      : out std_logic;
        enc_z_edge       : out std_logic;
        enc_ppr_conf     : out unsigned(7 downto 0);
        enc_ab_period    : out unsigned(31 downto 0);
        enc_ab_count     : out unsigned(7 downto 0);
        enc_a_count      : out unsigned(7 downto 0);
        enc_b_count      : out unsigned(7 downto 0);
        enc_signal_ok    : out std_logic;
        enc_fault_count  : out unsigned(7 downto 0)
    );
end entity enc;

architecture rtl of enc is
    signal a_prev        : std_logic := '0';
    signal b_prev        : std_logic := '0';
    signal z_prev        : std_logic := '0';
    signal ab_edge_int   : std_logic := '0';
    signal z_edge_int    : std_logic := '0';
    signal period_cnt    : unsigned(31 downto 0) := (others => '0');
    signal ab_period_int : unsigned(31 downto 0) := (others => '0');
    signal ab_count_int  : unsigned(7 downto 0)  := (others => '0');
    signal a_count_int   : unsigned(7 downto 0)  := (others => '0');
    signal b_count_int   : unsigned(7 downto 0)  := (others => '0');
    signal sig_timer     : unsigned(31 downto 0) := (others => '0');
    signal signal_ok_int : std_logic := '0';
begin
    p_enc : process(clk)
        variable a_edge_v : std_logic;
        variable b_edge_v : std_logic;
        variable z_edge_v : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                a_prev        <= '0';
                b_prev        <= '0';
                z_prev        <= '0';
                ab_edge_int   <= '0';
                z_edge_int    <= '0';
                period_cnt    <= (others => '0');
                ab_period_int <= (others => '0');
                ab_count_int  <= (others => '0');
                a_count_int   <= (others => '0');
                b_count_int   <= (others => '0');
                sig_timer     <= (others => '0');
                signal_ok_int <= '0';
            else
                a_prev      <= a_clean;
                b_prev      <= b_clean;
                z_prev      <= z_clean;
                ab_edge_int <= '0';
                z_edge_int  <= '0';
                a_edge_v    := '0';
                b_edge_v    := '0';
                z_edge_v    := '0';

                -- A channel edge detection
                case to_integer(enc_ab_edge_sel) is
                    when 0 =>  -- rising
                        if a_clean = '1' and a_prev = '0' then a_edge_v := '1'; end if;
                    when 1 =>  -- falling
                        if a_clean = '0' and a_prev = '1' then a_edge_v := '1'; end if;
                    when others =>  -- both
                        if a_clean /= a_prev then a_edge_v := '1'; end if;
                end case;

                -- B channel edge detection
                case to_integer(enc_ab_edge_sel) is
                    when 0 =>
                        if b_clean = '1' and b_prev = '0' then b_edge_v := '1'; end if;
                    when 1 =>
                        if b_clean = '0' and b_prev = '1' then b_edge_v := '1'; end if;
                    when others =>
                        if b_clean /= b_prev then b_edge_v := '1'; end if;
                end case;

                -- Z channel edge detection
                if enc_z_edge_sel = '0' then
                    if z_clean = '1' and z_prev = '0' then z_edge_v := '1'; end if;
                else
                    if z_clean = '0' and z_prev = '1' then z_edge_v := '1'; end if;
                end if;

                -- Period counter
                period_cnt <= period_cnt + 1;

                -- Signal watchdog
                sig_timer <= sig_timer + 1;
                if a_edge_v = '1' or b_edge_v = '1' then
                    sig_timer     <= (others => '0');
                    signal_ok_int <= '1';
                end if;
                if sig_timer > x"0FFFFFFF" then
                    signal_ok_int <= '0';
                end if;

                -- AB edge processing
                if a_edge_v = '1' then
                    ab_edge_int   <= '1';
                    ab_period_int <= period_cnt;
                    period_cnt    <= (others => '0');
                    ab_count_int  <= ab_count_int + 1;
                    a_count_int   <= a_count_int + 1;
                elsif b_edge_v = '1' then
                    ab_edge_int   <= '1';
                    ab_period_int <= period_cnt;
                    period_cnt    <= (others => '0');
                    ab_count_int  <= ab_count_int + 1;
                    b_count_int   <= b_count_int + 1;
                end if;

                -- Z edge processing
                if z_edge_v = '1' then
                    z_edge_int   <= '1';
                    ab_count_int <= (others => '0');
                    a_count_int  <= (others => '0');
                    b_count_int  <= (others => '0');
                end if;
            end if;
        end if;
    end process p_enc;

    enc_ab_edge   <= ab_edge_int;
    enc_z_edge    <= z_edge_int;
    enc_ppr_conf  <= enc_n_ppr(7 downto 0);
    enc_ab_period <= ab_period_int;
    enc_ab_count  <= ab_count_int;
    enc_a_count   <= a_count_int;
    enc_b_count   <= b_count_int;
    enc_signal_ok <= signal_ok_int;
    enc_fault_count <= (others => '0');
end architecture rtl;
