library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- ang_sel
--
-- Selects between crank_input and enc_input as the angle source.
-- sel='0': crank_input (default)
-- sel='1': enc_input (stub, future)
--
-- Routes 5 signals:
--   ab            <- crank_input.ab          / enc_input.ab
--   z             <- crank_input.z           / enc_input.z
--   ab_period     <- crank_input.tooth_period / enc_input.ab_period
--   ppr           <- crank_input.ppr_crank   / enc_input.ppr_enc
--   ab_count      <- crank_input.tooth_count / enc_input.ab_count_enc
-- =============================================================================

entity ang_sel is
    port (
        -- Select (latched on config_apply)
        sel                  : in  std_logic;  -- '0'=crank, '1'=encoder

        -- From crank_input
        crank_ab             : in  std_logic;
        crank_z              : in  std_logic;
        crank_ab_period      : in  unsigned(31 downto 0);  -- tooth_period from crank_input
        crank_ppr            : in  unsigned(7 downto 0);   -- ppr_crank from crank_input
        crank_ab_count       : in  unsigned(7 downto 0);   -- tooth_count from crank_input
        crank_signal_present : in  std_logic;

        -- From enc_input (stub)
        enc_ab               : in  std_logic;
        enc_z                : in  std_logic;
        enc_ab_period        : in  unsigned(31 downto 0);
        enc_ppr              : in  unsigned(7 downto 0);
        enc_ab_count         : in  unsigned(7 downto 0);
        enc_signal_present   : in  std_logic;

        -- Outputs
        ab                   : out std_logic;
        z                    : out std_logic;
        ab_period            : out unsigned(31 downto 0);
        ppr                  : out unsigned(7 downto 0);
        ab_count             : out unsigned(7 downto 0);
        signal_present       : out std_logic
    );
end entity ang_sel;

architecture rtl of ang_sel is
begin

    ab             <= crank_ab          when sel = '0' else enc_ab;
    z              <= crank_z           when sel = '0' else enc_z;
    ab_period      <= crank_ab_period   when sel = '0' else enc_ab_period;
    ppr            <= crank_ppr         when sel = '0' else enc_ppr;
    ab_count       <= crank_ab_count    when sel = '0' else enc_ab_count;
    signal_present <= crank_signal_present when sel = '0' else enc_signal_present;

end architecture rtl;
