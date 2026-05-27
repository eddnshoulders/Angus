library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sync
--
-- Synchronisation state machine for engine angle measurement.
-- Source-agnostic: works with AB/Z from crank_input or enc_input via ang_sel.
--
-- States:
--   UNSYNC:      Power-up / no signal / pattern lost
--   FIRST_GAP:   First Z seen with signal_present, counting AB edges
--   SYNC_CRANK:  n_teeth AB edges confirmed between consecutive Z pulses
--   SYNC_FULL:   Cycle phase confirmed via phase_detector ref_detected
--
-- n_teeth is runtime configurable (from AXI, latched on config_apply).
--
-- phase_engine output:
--   Latched from phase_offset at moment SYNC_FULL is acquired.
--   0 = ref detected on first crank rotation (cam in Band A)
--   1 = ref detected on second crank rotation (cam in Band B)
--   Feeds angle_engine so NCO knows which half of 720 deg cycle it is on.
--   Toggles on each subsequent Z pulse after SYNC_FULL.
--
-- signal_present='0' returns immediately to UNSYNC from any state.
-- =============================================================================

entity sync is
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- From ang_sel (crank_input or enc_input)
        ab                : in  std_logic;
        z                 : in  std_logic;
        signal_present    : in  std_logic;

        -- From phase_detector
        ref_detected      : in  std_logic;
        phase_offset      : in  std_logic;  -- 0=Band A, 1=Band B

        -- Configuration from AXI (latched on config_apply)
        n_teeth           : in  unsigned(7 downto 0);
        fault_clear       : in  std_logic;
        phase_fault_drop  : in  std_logic;

        -- Outputs
        sync_state        : out std_logic_vector(2 downto 0);
        synced            : out std_logic;
        phase_engine      : out std_logic;  -- 4-stroke phase for angle_engine
        sync_loss_count   : out unsigned(15 downto 0);
        phase_fault_count : out unsigned(15 downto 0);
        phase_fault       : out std_logic;

        -- Debug outputs
        ab_count_out      : out unsigned(7 downto 0);
        z_count_out       : out unsigned(15 downto 0)
    );
end entity sync;

architecture rtl of sync is

    type sync_state_t is (UNSYNC, FIRST_GAP, SYNC_CRANK, SYNC_FULL);

    function state_to_slv(s : sync_state_t) return std_logic_vector is
    begin
        case s is
            when UNSYNC     => return "000";
            when FIRST_GAP  => return "001";
            when SYNC_CRANK => return "010";
            when SYNC_FULL  => return "011";
            when others     => return "000";
        end case;
    end function;

    signal state              : sync_state_t := UNSYNC;
    signal ab_prev            : std_logic := '0';
    signal z_prev             : std_logic := '0';
    signal ref_prev           : std_logic := '0';
    signal ref_prev_f         : std_logic := '0';
    signal ab_count           : unsigned(7 downto 0)  := (others => '0');
    signal z_count            : unsigned(15 downto 0) := (others => '0');

    -- 4-stroke phase tracking
    signal phase_engine_int   : std_logic := '0';
    signal locked_phase       : std_logic := '0';  -- phase_offset at SYNC_FULL
    signal phase_locked       : std_logic := '0';  -- SYNC_FULL acquired

    -- Counters and fault signals
    signal sync_loss_cnt      : unsigned(15 downto 0) := (others => '0');
    signal phase_flt_cnt      : unsigned(15 downto 0) := (others => '0');
    signal phase_flt          : std_logic := '0';
    signal fault_drop_req     : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- FSM, edge detection and AB/Z counting
    -- -------------------------------------------------------------------------
    p_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_prev         <= '0';
                z_prev          <= '0';
                ref_prev        <= '0';
                ab_count        <= (others => '0');
                z_count         <= (others => '0');
                state           <= UNSYNC;
                locked_phase    <= '0';
                phase_locked    <= '0';
                phase_engine_int <= '0';
                sync_loss_cnt   <= (others => '0');
            else
                ab_prev  <= ab;
                z_prev   <= z;
                ref_prev <= ref_detected;

                -- AB edge: increment counter
                if ab /= ab_prev then
                    ab_count <= ab_count + 1;
                end if;

                -- Z rising edge: evaluate state
                if z = '1' and z_prev = '0' then

                    z_count <= z_count + 1;

                    -- Reset AB counter (if AB also edges this cycle, count it next)
                    if ab /= ab_prev then
                        ab_count <= to_unsigned(1, 8);
                    else
                        ab_count <= (others => '0');
                    end if;

                    -- Toggle phase_engine on Z after SYNC_FULL established
                    if phase_locked = '1' then
                        phase_engine_int <= not phase_engine_int;
                    end if;

                    case state is

                        when UNSYNC =>
                            if signal_present = '1' then
                                state <= FIRST_GAP;
                            end if;

                        when FIRST_GAP =>
                            if signal_present = '0' then
                                state <= UNSYNC;
                            elsif ab_count = n_teeth then
                                state <= SYNC_CRANK;
                            else
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                            end if;

                        when SYNC_CRANK =>
                            if signal_present = '0' then
                                state <= UNSYNC;
                            elsif ab_count /= n_teeth then
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                                state <= UNSYNC;
                            end if;

                        when SYNC_FULL =>
                            if signal_present = '0' then
                                state         <= UNSYNC;
                                phase_locked  <= '0';
                            elsif fault_drop_req = '1' then
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                                state        <= SYNC_CRANK;
                                phase_locked <= '0';
                            elsif ab_count /= n_teeth then
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                                state        <= UNSYNC;
                                phase_locked <= '0';
                            end if;

                    end case;

                else
                    -- Between Z edges
                    if signal_present = '0' then
                        state        <= UNSYNC;
                        phase_locked <= '0';
                        ab_count     <= (others => '0');

                    elsif state = SYNC_CRANK and
                          ref_detected = '1' and ref_prev = '0' then
                        -- First valid ref pulse: latch phase and go to SYNC_FULL
                        locked_phase    <= phase_offset;
                        phase_engine_int <= phase_offset;
                        phase_locked    <= '1';
                        state           <= SYNC_FULL;
                    end if;
                end if;

            end if;
        end if;
    end process p_fsm;

    -- -------------------------------------------------------------------------
    -- Phase fault detection
    -- In SYNC_FULL, ref_detected with different phase_offset = fault
    -- -------------------------------------------------------------------------
    p_fault : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_flt      <= '0';
                phase_flt_cnt  <= (others => '0');
                ref_prev_f     <= '0';
                fault_drop_req <= '0';
            else
                ref_prev_f     <= ref_detected;
                fault_drop_req <= '0';

                if fault_clear = '1' then
                    phase_flt <= '0';
                elsif state = SYNC_FULL and
                      ref_detected = '1' and ref_prev_f = '0' and
                      phase_locked = '1' and
                      phase_offset /= locked_phase then
                    phase_flt <= '1';
                    if phase_flt_cnt /= (phase_flt_cnt'range => '1') then
                        phase_flt_cnt <= phase_flt_cnt + 1;
                    end if;
                    if phase_fault_drop = '1' then
                        fault_drop_req <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process p_fault;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    sync_state        <= state_to_slv(state);
    synced            <= '1' when state = SYNC_FULL else '0';
    phase_engine      <= phase_engine_int;
    sync_loss_count   <= sync_loss_cnt;
    phase_fault_count <= phase_flt_cnt;
    phase_fault       <= phase_flt;
    ab_count_out      <= ab_count;
    z_count_out       <= z_count;

end architecture rtl;
