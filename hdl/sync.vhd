library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sync.vhd
-- FSM tracking sync state.
-- States: 0=STOPPED, 1=MOVING, 2=CRANK_SYNC, 3=FULL_SYNC
-- STOPPED:    no ab edges, no z received
-- MOVING:     ab edges arriving, < 2 z_edges received
-- CRANK_SYNC: 2 z_edges received and ab_count = ppr_conf at 2nd z_edge
-- FULL_SYNC:  CRANK_SYNC + phase_ref_found
-- sync_fault_count increments when ab_count != ppr_conf at expected z
-- =============================================================================
entity sync is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        ab_edge         : in  std_logic;
        z_edge          : in  std_logic;
        ppr_conf        : in  unsigned(7 downto 0);
        ab_count        : in  unsigned(7 downto 0);
        phase_ref_found : in  std_logic;
        sync_state      : out unsigned(1 downto 0);
        sync_full       : out std_logic;
        sync_fault_count: out unsigned(15 downto 0)
    );
end entity sync;

architecture rtl of sync is
    signal state_int     : unsigned(1 downto 0) := (others => '0');
    signal z_count       : unsigned(1 downto 0) := (others => '0');
    signal fault_cnt     : unsigned(15 downto 0) := (others => '0');
begin
    p_sync : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state_int <= (others => '0');
                z_count   <= (others => '0');
                fault_cnt <= (others => '0');
            else
                case to_integer(state_int) is

                    when 0 =>  -- STOPPED
                        if ab_edge = '1' then
                            state_int <= to_unsigned(1, 2);  -- MOVING
                        end if;

                    when 1 =>  -- MOVING
                        if z_edge = '1' then
                            z_count <= z_count + 1;
                            if z_count = "01" then
                                -- 2nd z_edge: check ab_count
                                if ab_count = ppr_conf then
                                    state_int <= to_unsigned(2, 2);  -- CRANK_SYNC
                                else
                                    -- Wrong count, stay MOVING, reset z_count
                                    z_count <= (others => '0');
                                    if fault_cnt /= (fault_cnt'range => '1') then
                                        fault_cnt <= fault_cnt + 1;
                                    end if;
                                end if;
                            end if;
                        end if;

                    when 2 =>  -- CRANK_SYNC
                        if phase_ref_found = '1' then
                            state_int <= to_unsigned(3, 2);  -- FULL_SYNC
                        end if;
                        -- Check ab_count at each z_edge
                        if z_edge = '1' and ab_count /= ppr_conf then
                            if fault_cnt /= (fault_cnt'range => '1') then
                                fault_cnt <= fault_cnt + 1;
                            end if;
                        end if;

                    when 3 =>  -- FULL_SYNC
                        -- Check ab_count at each z_edge
                        if z_edge = '1' and ab_count /= ppr_conf then
                            if fault_cnt /= (fault_cnt'range => '1') then
                                fault_cnt <= fault_cnt + 1;
                            end if;
                        end if;

                    when others => null;
                end case;
            end if;
        end if;
    end process p_sync;

    sync_state       <= state_int;
    sync_full        <= '1' when state_int = 3 else '0';
    sync_fault_count <= fault_cnt;
end architecture rtl;
