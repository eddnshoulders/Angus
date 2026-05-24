library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sync
--
-- Synchronisation state machine for engine angle measurement.
-- Source-agnostic: works with AB/Z interface from crank_input or encoder_input.
--
-- States:
--   UNSYNC:      Power-up state. No signal or no valid pattern seen.
--   FIRST_GAP:   First Z pulse seen with signal_present. Counting AB edges.
--   SYNC_CRANK:  N_TEETH AB edges confirmed between consecutive Z pulses.
--   SYNC_FULL:   Cycle phase confirmed via phase_detector ref_detected.
--
-- All edge detection and AB counting is handled within p_fsm using registered
-- previous values. No intermediate pulse signals are used, avoiding pipeline
-- delay and signal alignment issues.
--
-- signal_present = '0' returns immediately to UNSYNC from any state.
-- Sync losses and phase faults are counted rather than held as states.
-- =============================================================================

entity sync is
    generic (
        CLK_FREQ_HZ       : integer := 100_000_000;
        N_TEETH           : integer := 60;
        N_AB_PULSES       : integer := 30
    );
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- From crank_input or encoder_input
        ab                : in  std_logic;
        z                 : in  std_logic;
        signal_present    : in  std_logic;

        -- From phase_detector
        ref_detected      : in  std_logic;
        sync_offset       : in  std_logic;

        -- Configuration from PS
        fault_clear       : in  std_logic;

        -- Outputs
        sync_state        : out std_logic_vector(2 downto 0);
        sync_loss_count   : out unsigned(15 downto 0);
        phase_fault_count : out unsigned(15 downto 0);
        phase_fault       : out std_logic;

        -- Debug output
        ab_count_out      : out unsigned(7 downto 0)   -- teeth counted this revolution
    );
end entity sync;

architecture rtl of sync is

    -- -------------------------------------------------------------------------
    -- State type
    -- -------------------------------------------------------------------------
    type sync_state_t is (
        UNSYNC,       -- power-up / no signal / pattern lost
        FIRST_GAP,    -- first Z seen, counting AB edges
        SYNC_CRANK,   -- crank pattern confirmed
        SYNC_FULL     -- cycle phase confirmed
    );

    function state_to_slv(s : sync_state_t) return std_logic_vector is
    begin
        case s is
            when UNSYNC      => return "000";
            when FIRST_GAP   => return "001";
            when SYNC_CRANK  => return "010";
            when SYNC_FULL   => return "011";
            when others      => return "000";
        end case;
    end function;

    -- State register
    signal state          : sync_state_t := UNSYNC;

    -- Previous values for edge detection within p_fsm
    signal ab_prev        : std_logic := '0';
    signal z_prev         : std_logic := '0';
    signal ref_prev       : std_logic := '0';
    signal ref_prev_f : std_logic := '0';

    -- AB counter between Z pulses
    signal ab_count       : unsigned(7 downto 0) := (others => '0');

    -- Phase tracking
    signal locked_offset  : std_logic := '0';
    signal offset_locked  : std_logic := '0';

    -- Counters
    signal sync_loss_cnt  : unsigned(15 downto 0) := (others => '0');
    signal phase_flt_cnt  : unsigned(15 downto 0) := (others => '0');
    signal phase_flt      : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- Combined FSM, edge detection and AB counting
    -- All in one process to avoid signal alignment issues
    -- -------------------------------------------------------------------------
    p_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ab_prev       <= '0';
                z_prev        <= '0';
                ref_prev      <= '0';
                ab_count      <= (others => '0');
                state         <= UNSYNC;
                locked_offset <= '0';
                offset_locked <= '0';
                sync_loss_cnt <= (others => '0');
            else
                -- Register previous values for next cycle
                ab_prev  <= ab;
                z_prev   <= z;
                ref_prev <= ref_detected;

                -- AB edge: increment counter
                if ab /= ab_prev then
                    ab_count <= ab_count + 1;
                end if;

                -- Z rising edge: evaluate state transition
                if z = '1' and z_prev = '0' then

                    -- Reset AB counter for next cycle
                    -- If AB also transitions on this clock, count it in next cycle
                    if ab /= ab_prev then
                        ab_count <= to_unsigned(1, 8);
                    else
                        ab_count <= (others => '0');
                    end if;

                    case state is

                        when UNSYNC =>
                            if signal_present = '1' then
                                state <= FIRST_GAP;
                            end if;

                        when FIRST_GAP =>
                            if signal_present = '0' then
                                state <= UNSYNC;
                            elsif ab_count = to_unsigned(N_TEETH, 8) then
                                state <= SYNC_CRANK;
                            else
                                -- Wrong count, stay in FIRST_GAP and try again
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                            end if;

                        when SYNC_CRANK =>
                            if signal_present = '0' then
                                state <= UNSYNC;
                            elsif ab_count /= to_unsigned(N_TEETH, 8) then
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                                state <= UNSYNC;
                            end if;

                        when SYNC_FULL =>
                            if signal_present = '0' then
                                state         <= UNSYNC;
                                offset_locked <= '0';
                            elsif ab_count /= to_unsigned(N_TEETH, 8) then
                                if sync_loss_cnt /= (sync_loss_cnt'range => '1') then
                                    sync_loss_cnt <= sync_loss_cnt + 1;
                                end if;
                                state         <= UNSYNC;
                                offset_locked <= '0';
                            end if;

                    end case;

                -- Between Z edges: handle signal loss and ref_detected
                else
                    if signal_present = '0' then
                        state         <= UNSYNC;
                        offset_locked <= '0';
                        ab_count      <= (others => '0');

                    elsif state = SYNC_CRANK and
                          ref_detected = '1' and ref_prev = '0' then
                        locked_offset <= sync_offset;
                        offset_locked <= '1';
                        state         <= SYNC_FULL;
                    end if;
                end if;

            end if;
        end if;
    end process p_fsm;

    -- -------------------------------------------------------------------------
    -- Phase fault detection
    -- In SYNC_FULL, ref pulse arriving with different offset = fault
    -- Latching, cleared by fault_clear or rst
    -- -------------------------------------------------------------------------
    p_fault : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                phase_flt     <= '0';
                phase_flt_cnt <= (others => '0');
                ref_prev_f    <= '0';
            else
                ref_prev_f <= ref_detected;

                if fault_clear = '1' then
                    phase_flt <= '0';
                elsif state = SYNC_FULL and
                      ref_detected = '1' and ref_prev_f = '0' and
                      offset_locked = '1' and
                      sync_offset /= locked_offset then
                    phase_flt <= '1';
                    if phase_flt_cnt /= (phase_flt_cnt'range => '1') then
                        phase_flt_cnt <= phase_flt_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_fault;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    sync_state        <= state_to_slv(state);
    sync_loss_count   <= sync_loss_cnt;
    phase_fault_count <= phase_flt_cnt;
    phase_fault       <= phase_flt;
    ab_count_out      <= ab_count;

end architecture rtl;