library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- enc_input (stub)
--
-- Placeholder for encoder A/B/Z input path.
-- Outputs tied to safe defaults. Will be implemented when encoder
-- hardware is available.
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
        ab             : out std_logic;
        z              : out std_logic;
        tooth_period   : out unsigned(31 downto 0);
        tooth_count    : out unsigned(7 downto 0);
        signal_present : out std_logic;
        enc_edge_pulse : out std_logic
    );
end entity enc_input;

architecture rtl of enc_input is
begin
    -- Stub: all outputs safe defaults
    ab             <= '0';
    z              <= '0';
    tooth_period   <= (others => '0');
    tooth_count    <= (others => '0');
    signal_present <= '0';
    enc_edge_pulse <= '0';
end architecture rtl;
