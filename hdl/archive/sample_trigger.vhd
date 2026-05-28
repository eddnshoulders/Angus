library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sample_trigger
--
-- Fires a one-cycle sample_pulse each time engine_angle changes, when in
-- SYNC_FULL state. Also latches the current engine_angle to sample_angle.
--
-- Decimation: only fire every N angle steps (1 = every step, 2 = every other, etc.)
-- At 0.1 degree resolution with decimation = 1, fires up to 7200 times per cycle.
-- At 3000 RPM (25 cycles/sec): 7200 * 25 = 180,000 samples/sec max.
--
-- sample_pulse is the master trigger for:
--   - AD7606 CONVST (latches all ADC channels)
--   - Digital input sampling
--   - sample_packer write strobe
-- =============================================================================

entity sample_trigger is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- From angle_offset
        engine_angle   : in  unsigned(15 downto 0);

        -- From sync
        sync_state     : in  std_logic_vector(2 downto 0);

        -- Configuration from PS
        -- Fire every N angle steps (1 = every step)
        decimation     : in  unsigned(7 downto 0);
        -- Debug pulse stretch width in clock cycles (0 = one cycle, 1000 = 10us)
        pulse_width    : in  unsigned(15 downto 0);

        -- Outputs
        sample_pulse   : out std_logic;      -- one-cycle pulse (functional)
        sample_pulse_dbg : out std_logic;    -- stretched pulse for scope debug
        sample_angle   : out unsigned(15 downto 0)
    );
end entity sample_trigger;

architecture rtl of sample_trigger is

    -- Sync state constant (must match sync.vhd)
    constant ST_SYNC_FULL  : std_logic_vector(2 downto 0) := "011";

    -- Pulse stretcher uses runtime-configurable pulse_width
    signal engine_angle_reg  : unsigned(15 downto 0) := (others => '0');  -- input register
    signal engine_angle_prev : unsigned(15 downto 0) := (others => '0');
    signal angle_changed     : std_logic := '0';
    signal decim_cnt         : unsigned(7 downto 0) := (others => '0');
    signal sample_pulse_int  : std_logic := '0';
    signal sample_angle_int  : unsigned(15 downto 0) := (others => '0');
    signal stretch_cnt       : unsigned(15 downto 0) := (others => '0');
    signal sample_pulse_out  : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- Detect engine_angle changes and fire sample_pulse with decimation
    -- -------------------------------------------------------------------------
    p_trigger : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                engine_angle_reg  <= (others => '0');
                engine_angle_prev <= (others => '0');
                decim_cnt         <= (others => '0');
                sample_pulse_int  <= '0';
                sample_angle_int  <= (others => '0');
            else
                -- Input register: breaks long net from angle_engine
                engine_angle_reg  <= engine_angle;
                engine_angle_prev <= engine_angle_reg;
                sample_pulse_int  <= '0';

                -- Only sample in SYNC_FULL
                if sync_state = ST_SYNC_FULL then

                    -- Detect angle change
                    if engine_angle_reg /= engine_angle_prev then

                        if decim_cnt = decimation - 1 then
                            -- Fire sample pulse
                            sample_pulse_int <= '1';
                            sample_angle_int <= engine_angle_reg;
                            decim_cnt        <= (others => '0');
                        else
                            decim_cnt <= decim_cnt + 1;
                        end if;

                    end if;

                else
                    -- Not in SYNC_FULL: reset decimation counter
                    decim_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process p_trigger;

    -- -------------------------------------------------------------------------
    -- Pulse stretcher for scope visibility
    -- sample_pulse_int is the functional one-cycle trigger
    -- sample_pulse output is stretched to STRETCH_CYCLES for debug
    -- sample_packer and xadc_buffer use sample_pulse_int internally
    -- -------------------------------------------------------------------------
    p_stretch : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                stretch_cnt      <= (others => '0');
                sample_pulse_out <= '0';
            else
                if sample_pulse_int = '1' then
                    sample_pulse_out <= '1';
                    stretch_cnt      <= pulse_width;
                elsif stretch_cnt > 0 then
                    stretch_cnt <= stretch_cnt - 1;
                else
                    sample_pulse_out <= '0';
                end if;
            end if;
        end if;
    end process p_stretch;

    sample_pulse     <= sample_pulse_int;  -- one-cycle pulse for functional use
    sample_pulse_dbg <= sample_pulse_out;  -- stretched pulse for scope debug
    sample_angle     <= sample_angle_int;

end architecture rtl;