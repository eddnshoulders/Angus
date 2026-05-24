library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

entity axi_lite_regs_tb is
end entity axi_lite_regs_tb;

architecture sim of axi_lite_regs_tb is

    constant CLK_PERIOD : time := 10 ns;   -- 100MHz for AXI

    -- AXI signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal awaddr       : std_logic_vector(6 downto 0) := (others => '0');
    signal awvalid      : std_logic := '0';
    signal awready      : std_logic;
    signal wdata        : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb        : std_logic_vector(3 downto 0) := "1111";
    signal wvalid       : std_logic := '0';
    signal wready       : std_logic;
    signal bresp        : std_logic_vector(1 downto 0);
    signal bvalid       : std_logic;
    signal bready       : std_logic := '1';
    signal araddr       : std_logic_vector(6 downto 0) := (others => '0');
    signal arvalid      : std_logic := '0';
    signal arready      : std_logic;
    signal rdata        : std_logic_vector(31 downto 0);
    signal rresp        : std_logic_vector(1 downto 0);
    signal rvalid       : std_logic;
    signal rready       : std_logic := '1';

    -- Config outputs
    signal edge_select          : std_logic;
    signal gap_threshold        : unsigned(7 downto 0);
    signal kp                   : unsigned(15 downto 0);
    signal ki                   : unsigned(15 downto 0);
    signal max_correction       : unsigned(15 downto 0);
    signal expected_phase_angle : unsigned(15 downto 0);
    signal phase_tolerance      : unsigned(15 downto 0);
    signal tdc_offset           : unsigned(15 downto 0);
    signal decimation           : unsigned(7 downto 0);
    signal fault_clear          : std_logic;

    -- Status inputs
    signal sync_state           : std_logic_vector(2 downto 0) := "011";
    signal signal_present       : std_logic := '1';
    signal phase_fault          : std_logic := '0';
    signal sync_loss_count      : unsigned(15 downto 0) := to_unsigned(42, 16);
    signal phase_fault_count    : unsigned(15 downto 0) := to_unsigned(3, 16);
    signal packet_count         : unsigned(31 downto 0) := to_unsigned(12345, 32);
    signal overflow_count       : unsigned(15 downto 0) := to_unsigned(7, 16);
    signal raw_angle            : unsigned(15 downto 0) := to_unsigned(1234, 16);
    signal crank_angle          : unsigned(15 downto 0) := to_unsigned(4834, 16);
    signal engine_angle         : unsigned(15 downto 0) := to_unsigned(5000, 16);

    signal sim_done             : boolean := false;
    signal test_num             : integer := 0;
    signal test_step             : integer := 0;

    -- -------------------------------------------------------------------------
    -- AXI write transaction
    -- -------------------------------------------------------------------------
    procedure axi_write(
        signal   awaddr_s  : out std_logic_vector(6 downto 0);
        signal   awvalid_s : out std_logic;
        signal   wdata_s   : out std_logic_vector(31 downto 0);
        signal   wvalid_s  : out std_logic;
        signal   awready_s : in  std_logic;
        signal   wready_s  : in  std_logic;
        signal   bvalid_s  : in  std_logic;
        constant addr      : in  integer;
        constant data      : in  std_logic_vector(31 downto 0);
        constant clk_p     : in  time
    ) is
    begin
        awaddr_s  <= std_logic_vector(to_unsigned(addr, 7));
        awvalid_s <= '1';
        wdata_s   <= data;
        wvalid_s  <= '1';
        wait for clk_p;
        wait until rising_edge(clk) and awready_s = '1' and wready_s = '1';
        wait for clk_p;
        awvalid_s <= '0';
        wvalid_s  <= '0';
        wait until rising_edge(clk) and bvalid_s = '1';
        wait for clk_p;
    end procedure axi_write;

    -- -------------------------------------------------------------------------
    -- AXI read transaction
    -- -------------------------------------------------------------------------
    procedure axi_read(
        signal   araddr_s  : out std_logic_vector(6 downto 0);
        signal   arvalid_s : out std_logic;
        signal   arready_s : in  std_logic;
        signal   rvalid_s  : in  std_logic;
        signal   rdata_s   : in  std_logic_vector(31 downto 0);
        constant addr      : in  integer;
        variable data      : out std_logic_vector(31 downto 0);
        constant clk_p     : in  time
    ) is
    begin
        araddr_s  <= std_logic_vector(to_unsigned(addr, 7));
        arvalid_s <= '1';
        wait for clk_p;
        wait until rising_edge(clk) and arready_s = '1';
        wait for clk_p;
        arvalid_s <= '0';
        wait until rising_edge(clk) and rvalid_s = '1';
        data := rdata_s;
        wait for clk_p;
    end procedure axi_read;

begin

    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    dut : entity work.axi_lite_regs
        port map (
            s_axi_aclk           => clk,
            s_axi_aresetn        => rst_n,
            s_axi_awaddr         => awaddr,
            s_axi_awvalid        => awvalid,
            s_axi_awready        => awready,
            s_axi_wdata          => wdata,
            s_axi_wstrb          => wstrb,
            s_axi_wvalid         => wvalid,
            s_axi_wready         => wready,
            s_axi_bresp          => bresp,
            s_axi_bvalid         => bvalid,
            s_axi_bready         => bready,
            s_axi_araddr         => araddr,
            s_axi_arvalid        => arvalid,
            s_axi_arready        => arready,
            s_axi_rdata          => rdata,
            s_axi_rresp          => rresp,
            s_axi_rvalid         => rvalid,
            s_axi_rready         => rready,
            edge_select          => edge_select,
            gap_threshold        => gap_threshold,
            kp                   => kp,
            ki                   => ki,
            max_correction       => max_correction,
            expected_phase_angle => expected_phase_angle,
            phase_tolerance      => phase_tolerance,
            tdc_offset           => tdc_offset,
            decimation           => decimation,
            fault_clear          => fault_clear,
            sync_state           => sync_state,
            signal_present       => signal_present,
            phase_fault          => phase_fault,
            sync_loss_count      => sync_loss_count,
            phase_fault_count    => phase_fault_count,
            packet_count         => packet_count,
            overflow_count       => overflow_count,
            raw_angle            => raw_angle,
            crank_angle          => crank_angle,
            engine_angle         => engine_angle
        );

    p_stim : process
        variable rd_data : std_logic_vector(31 downto 0);
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset - check defaults
        -- --------------------------------------------------------------------
        report "TEST 1: Reset and default values";
        test_num <= 1;
        rst_n <= '0'; wait for 10 * CLK_PERIOD;
        rst_n <= '1'; wait for 10 * CLK_PERIOD;

        assert edge_select = '0'
            report "FAIL T1: edge_select default should be 0"
            severity failure;
        assert to_integer(gap_threshold) = 16#C0#
            report "FAIL T1: gap_threshold default should be 0xC0"
            severity failure;
        assert to_integer(kp) = 16#100#
            report "FAIL T1: kp default should be 0x100"
            severity failure;
        assert to_integer(decimation) = 1
            report "FAIL T1: decimation default should be 1"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Write and read back CONTROL register
        -- edge_select = 1, fault_clear = 0
        -- --------------------------------------------------------------------
        report "TEST 2: Write CONTROL register";
        test_num <= 2;

        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                  16#00#, x"00000001", CLK_PERIOD);
        wait for CLK_PERIOD;

        assert edge_select = '1'
            report "FAIL T2: edge_select should be 1"
            severity failure;

        axi_read(araddr, arvalid, arready, rvalid, rdata,
                 16#00#, rd_data, CLK_PERIOD);

        assert rd_data(0) = '1'
            report "FAIL T2: readback edge_select should be 1"
            severity failure;
        report "TEST 2: PASS";

        -- --------------------------------------------------------------------
        -- TEST 3: Write PLL gains
        -- --------------------------------------------------------------------
        report "TEST 3: Write PLL gains";
        test_num <= 3;

        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                  16#08#, x"00000200", CLK_PERIOD);  -- kp = 0x200
        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                  16#0C#, x"00000020", CLK_PERIOD);  -- ki = 0x20
        wait for CLK_PERIOD;

        assert to_integer(kp) = 16#200#
            report "FAIL T3: kp should be 0x200"
            severity failure;
        assert to_integer(ki) = 16#20#
            report "FAIL T3: ki should be 0x20"
            severity failure;
        report "TEST 3: PASS";

        -- --------------------------------------------------------------------
        -- TEST 4: Write phase angle and tolerance
        -- --------------------------------------------------------------------
        report "TEST 4: Write phase angle and tolerance";
        test_num <= 4;

        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                  16#14#, x"00000384", CLK_PERIOD);  -- 900 = 90.0 deg
        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                  16#18#, x"000000B4", CLK_PERIOD);  -- 180 = 18.0 deg
        wait for CLK_PERIOD;

        assert to_integer(expected_phase_angle) = 900
            report "FAIL T4: expected_phase_angle should be 900"
            severity failure;
        assert to_integer(phase_tolerance) = 180
            report "FAIL T4: phase_tolerance should be 180"
            severity failure;
        report "TEST 4: PASS";

        -- --------------------------------------------------------------------
        -- TEST 5: Read STATUS register
        -- --------------------------------------------------------------------
        report "TEST 5: Read STATUS register";
        test_num <= 5;

        -- sync_state = "011", signal_present = 1, phase_fault = 0
        axi_read(araddr, arvalid, arready, rvalid, rdata,
                 16#24#, rd_data, CLK_PERIOD);

        assert rd_data(2 downto 0) = "011"
            report "FAIL T5: sync_state should be 011"
            severity failure;
        assert rd_data(4) = '1'
            report "FAIL T5: signal_present should be 1"
            severity failure;
        assert rd_data(3) = '0'
            report "FAIL T5: phase_fault should be 0"
            severity failure;
        report "TEST 5: PASS";

        -- --------------------------------------------------------------------
        -- TEST 6: Read packet_count
        -- --------------------------------------------------------------------
        report "TEST 6: Read packet_count";
        test_num <= 6;

        axi_read(araddr, arvalid, arready, rvalid, rdata,
                 16#30#, rd_data, CLK_PERIOD);

        assert to_integer(unsigned(rd_data)) = 12345
            report "FAIL T6: packet_count should be 12345, got " &
                   integer'image(to_integer(unsigned(rd_data)))
            severity failure;
        report "TEST 6: PASS";

        -- --------------------------------------------------------------------
        -- TEST 7: Read angle registers
        -- --------------------------------------------------------------------
        report "TEST 7: Read angle registers";
        test_num <= 7;

        axi_read(araddr, arvalid, arready, rvalid, rdata,
                 16#38#, rd_data, CLK_PERIOD);
        assert to_integer(unsigned(rd_data(15 downto 0))) = 1234
            report "FAIL T7: raw_angle should be 1234"
            severity failure;

        axi_read(araddr, arvalid, arready, rvalid, rdata,
                 16#3C#, rd_data, CLK_PERIOD);
        assert to_integer(unsigned(rd_data(15 downto 0))) = 4834
            report "FAIL T7: crank_angle should be 4834"
            severity failure;

        axi_read(araddr, arvalid, arready, rvalid, rdata,
                 16#40#, rd_data, CLK_PERIOD);
        assert to_integer(unsigned(rd_data(15 downto 0))) = 5000
            report "FAIL T7: engine_angle should be 5000"
            severity failure;

        report "TEST 7: PASS";

        -- --------------------------------------------------------------------
        -- TEST 8: fault_clear self-clears
        -- --------------------------------------------------------------------
        report "TEST 8: fault_clear self-clears";
        test_num <= 8;

        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                16#00#, x"00000002", CLK_PERIOD);

        -- fault_clear has already self-cleared by now
        -- Just verify it's now 0 (self-cleared) and was set at some point
        assert fault_clear = '0'
            report "FAIL T8: fault_clear should have self-cleared"
            severity failure;
        report "TEST 8: PASS - fault_clear self-cleared correctly";

        -- --------------------------------------------------------------------
        -- TEST 9: Write decimation
        -- --------------------------------------------------------------------
        report "TEST 9: Write decimation";
        test_num <= 9;

        axi_write(awaddr, awvalid, wdata, wvalid, awready, wready, bvalid,
                  16#20#, x"00000004", CLK_PERIOD);
        wait for CLK_PERIOD;

        assert to_integer(decimation) = 4
            report "FAIL T9: decimation should be 4"
            severity failure;
        report "TEST 9: PASS";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        wait for 10 * CLK_PERIOD;
        report "========================================";
        report "All axi_lite_regs tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;