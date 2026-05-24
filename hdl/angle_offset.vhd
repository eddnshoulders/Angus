library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- angle_offset
--
-- Applies sync_offset and tdc_offset to raw_angle to produce final angles.
-- Purely combinational, no clock required.
--
-- crank_angle  = (raw_angle + 3600) mod 7200  when sync_offset = '1'
--              =  raw_angle                    when sync_offset = '0'
--
-- engine_angle = (crank_angle + tdc_offset) mod 7200
--
-- All angles in units of 0.1 degrees (0-7199 per 720 degree cycle)
-- =============================================================================

entity angle_offset is
    port (
        -- From angle_engine
        raw_angle    : in  unsigned(15 downto 0);  -- 0-7199

        -- From phase_detector via sync
        sync_offset  : in  std_logic;              -- '0' = no offset, '1' = add 3600

        -- From PS configuration
        tdc_offset   : in  unsigned(15 downto 0);  -- 0-7199, 0.1 deg units

        -- Outputs
        crank_angle  : out unsigned(15 downto 0);  -- 0-7199
        engine_angle : out unsigned(15 downto 0)   -- 0-7199
    );
end entity angle_offset;

architecture rtl of angle_offset is

    constant CYCLE_STEPS : unsigned(15 downto 0) := to_unsigned(7200, 16);
    constant HALF_CYCLE  : unsigned(15 downto 0) := to_unsigned(3600, 16);

    signal crank_angle_int  : unsigned(15 downto 0);
    signal engine_angle_int : unsigned(16 downto 0);  -- extra bit for overflow detection

begin

    -- -------------------------------------------------------------------------
    -- Apply sync_offset to get crank_angle
    -- sync_offset = '1': add 3600, wrap at 7200
    -- sync_offset = '0': pass through
    -- -------------------------------------------------------------------------
    p_crank : process(raw_angle, sync_offset)
        variable offset_angle : unsigned(16 downto 0);
    begin
        if sync_offset = '1' then
            offset_angle := resize(raw_angle, 17) + resize(HALF_CYCLE, 17);
            if offset_angle >= resize(CYCLE_STEPS, 17) then
                crank_angle_int <= resize(offset_angle - CYCLE_STEPS, 16);
            else
                crank_angle_int <= resize(offset_angle, 16);
            end if;
        else
            crank_angle_int <= raw_angle;
        end if;
    end process p_crank;

    -- -------------------------------------------------------------------------
    -- Apply tdc_offset to get engine_angle
    -- engine_angle = (crank_angle + tdc_offset) mod 7200
    -- -------------------------------------------------------------------------
    p_engine : process(crank_angle_int, tdc_offset)
        variable sum : unsigned(16 downto 0);
    begin
        sum := resize(crank_angle_int, 17) + resize(tdc_offset, 17);
        if sum >= resize(CYCLE_STEPS, 17) then
            engine_angle <= resize(sum - CYCLE_STEPS, 16);
        else
            engine_angle <= resize(sum, 16);
        end if;
    end process p_engine;

    crank_angle <= crank_angle_int;

end architecture rtl;