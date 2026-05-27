library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- enc_input (stub)
--
-- Placeholder for encoder A/B/Z input path.
-- Outputs tied to safe defaults. Will be implemented when encoder
-- hardware is available.
--
-- Port names match ang_sel expectations:
--   ab_enc, z_enc, ab_period_enc, ppr_enc, ab_count_enc, signal_present
-- =============================================================================

entity enc_input is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        a_clean        : in  std_logic;
        b_clean        : in  std_logic;
        z_clean        : in  std_logic;
        ab_edge_sel    : in  std_logic;
        z_edge_sel     : in  std_logic;
        n_teeth        : in  unsigned(7 downto 0);
        n_pulses       : in  unsigned(7 downto 0);
        ab_enc         : out std_logic;
        z_enc          : out std_logic;
        ab_period_enc  : out unsigned(31 downto 0);
        ppr_enc        : out unsigned(7 downto 0);
        ab_count_enc   : out unsigned(7 downto 0);
        signal_present : out std_logic;
        enc_edge_pulse : out std_logic
    );
end entity enc_input;

architecture rtl of enc_input is
begin
    -- Stub: all outputs safe defaults
    ab_enc         <= '0';
    z_enc          <= '0';
    ab_period_enc  <= (others => '0');
    ppr_enc        <= n_teeth;  -- pass through so ang_sel has a valid ppr
    ab_count_enc   <= (others => '0');
    signal_present <= '0';
    enc_edge_pulse <= '0';
end architecture rtl;
