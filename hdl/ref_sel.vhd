library ieee;
use ieee.std_logic_1164.all;

-- =============================================================================
-- ref_sel.vhd
-- Selects between cam_edge and peak_edge as phase reference.
-- sel=0: cam_edge, sel=1: peak_edge
-- =============================================================================
entity ref_sel is
    port (
        sel       : in  std_logic;
        cam_edge  : in  std_logic;
        peak_edge : in  std_logic;
        ref_edge  : out std_logic
    );
end entity ref_sel;

architecture rtl of ref_sel is
begin
    ref_edge <= cam_edge when sel = '0' else peak_edge;
end architecture rtl;
