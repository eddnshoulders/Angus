library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- ang_sel
--
-- Selects between crank_input and enc_input as the angle source.
-- sel='0': crank_input (default)
-- sel='1': enc_input (future)
--
-- Also muxes tooth_period for angle_calc and angle_engine.
-- =============================================================================

entity ang_sel is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- Select (from AXI config_apply)
        sel            : in  std_logic;  -- '0'=crank, '1'=encoder

        -- From crank_input
        crank_ab       : in  std_logic;
        crank_z        : in  std_logic;
        crank_tooth_period : in unsigned(31 downto 0);
        crank_tooth_count  : in unsigned(7 downto 0);
        crank_signal_present : in std_logic;

        -- From enc_input (stub - not yet implemented)
        enc_ab         : in  std_logic;
        enc_z          : in  std_logic;
        enc_tooth_period : in unsigned(31 downto 0);
        enc_tooth_count  : in unsigned(7 downto 0);
        enc_signal_present : in std_logic;

        -- Outputs to angle_calc and angle_engine
        ab             : out std_logic;
        z              : out std_logic;
        tooth_period   : out unsigned(31 downto 0);
        tooth_count    : out unsigned(7 downto 0);
        signal_present : out std_logic
    );
end entity ang_sel;

architecture rtl of ang_sel is
begin

    ab             <= crank_ab           when sel = '0' else enc_ab;
    z              <= crank_z            when sel = '0' else enc_z;
    tooth_period   <= crank_tooth_period when sel = '0' else enc_tooth_period;
    tooth_count    <= crank_tooth_count  when sel = '0' else enc_tooth_count;
    signal_present <= crank_signal_present when sel = '0' else enc_signal_present;

end architecture rtl;
