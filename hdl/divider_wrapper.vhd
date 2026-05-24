-- divider_wrapper.vhd
-- VHDL wrapper around Yigit Suoglu's Verilog divider

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity divider is
    generic (
        WIDTH    : integer := 32;
        CACHING  : integer := 0;
        INIT_VLD : integer := 0
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        start     : in  std_logic;
        dividend  : in  unsigned(WIDTH - 1 downto 0);
        divisor   : in  unsigned(WIDTH - 1 downto 0);
        quotient  : out unsigned(WIDTH - 1 downto 0);
        remainder : out unsigned(WIDTH - 1 downto 0);
        zero_err  : out std_logic;
        valid     : out std_logic
    );
end entity divider;

architecture rtl of divider is

    component divider_v
        generic (
            WIDTH    : integer;
            CACHING  : integer;
            INIT_VLD : integer
        );
        port (
            clk      : in  std_logic;
            rst      : in  std_logic;
            start    : in  std_logic;
            dividend : in  std_logic_vector(WIDTH - 1 downto 0);
            divisor  : in  std_logic_vector(WIDTH - 1 downto 0);
            quotient : out std_logic_vector(WIDTH - 1 downto 0);
            remainder: out std_logic_vector(WIDTH - 1 downto 0);
            zeroErr  : out std_logic;
            valid    : out std_logic
        );
    end component;

    signal quotient_slv  : std_logic_vector(WIDTH - 1 downto 0);
    signal remainder_slv : std_logic_vector(WIDTH - 1 downto 0);

begin

    u_divider : divider_v
        generic map (
            WIDTH    => WIDTH,
            CACHING  => CACHING,
            INIT_VLD => INIT_VLD
        )
        port map (
            clk       => clk,
            rst       => rst,
            start     => start,
            dividend  => std_logic_vector(dividend),
            divisor   => std_logic_vector(divisor),
            quotient  => quotient_slv,
            remainder => remainder_slv,
            zeroErr   => zero_err,
            valid     => valid
        );

    quotient  <= unsigned(quotient_slv);
    remainder <= unsigned(remainder_slv);

end architecture rtl;
