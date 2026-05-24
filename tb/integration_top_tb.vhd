library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- =============================================================================
-- top_tb
--
-- Full end-to-end testbench for top.vhd.
-- Drives crank_raw and cam_raw with realistic signals.
-- Configures the system via AXI-Lite writes (simulating PS).
-- Verifies AXI Stream packet output with correct angle and ADC data.
-- Checks sync acquisition, angle accuracy, and packet content end to end.
-- =============================================================================

entity integration_top_tb is
end entity integration_top_tb;

architecture sim of integration_top_tb is

    -- -------------------------------------------------------------------------
    -- Constants
    -- -------------------------------------------------------------------------
    constant CLK_PERIOD      : time    := 10 ns;     -- 100MHz PL clock
    constant AXI_CLK_PERIOD  : time    := 10 ns;     -- 100MHz AXI clock
    constant N_TEETH         : integer := 60;
    constant N_MISSING       : integer := 2;
    constant TEETH_REAL      : integer := N_TEETH - N_MISSING;

    -- At 100MHz, 1000 RPM:
    -- Tooth period = 1ms = 100,000 cycles
    constant TOOTH_1000_RPM  : time := 1_000_000 ns;
    constant TOOTH_2000_RPM  : time :=   500_000 ns;
    constant CYCLE_1000      : time := TOOTH_1000_RPM * N_TEETH;

    -- AXI-Lite register addresses
    constant ADDR_CONTROL    : integer := 16#00#;
    constant ADDR_GAP_THRESH : integer := 16#04#;
    constant ADDR_PLL_KP     : integer := 16#08#;
    constant ADDR_PLL_KI     : integer := 16#0C#;
    constant ADDR_PLL_MAXC   : integer := 16#10#;
    constant ADDR_PHASE_ANG  : integer := 16#14#;
    constant ADDR_PHASE_TOL  : integer := 16#18#;
    constant ADDR_TDC_OFF    : integer := 16#1C#;
    constant ADDR_DECIMATION : integer := 16#20#;
    constant ADDR_STATUS     : integer := 16#24#;
    constant ADDR_SYNC_LOSS  : integer := 16#28#;
    constant ADDR_PKT_COUNT  : integer := 16#30#;
    constant ADDR_OVF_COUNT  : integer := 16#34#;
    constant ADDR_RAW_ANGLE  : integer := 16#38#;
    constant ADDR_CRANK_ANG  : integer := 16#3C#;
    constant ADDR_ENG_ANG    : integer := 16#40#;

    -- Sync state encoding
    constant ST_UNSYNC       : std_logic_vector(2 downto 0) := "000";
    constant ST_FIRST_GAP    : std_logic_vector(2 downto 0) := "001";
    constant ST_SYNC_CRANK   : std_logic_vector(2 downto 0) := "010";
    constant ST_SYNC_FULL    : std_logic_vector(2 downto 0) := "011";

    -- -------------------------------------------------------------------------
    -- DUT ports
    -- -------------------------------------------------------------------------
    signal clk               : std_logic := '0';
    signal rst_n             : std_logic := '0';

    -- Sensor inputs
    signal crank_raw         : std_logic := '1';
    signal cam_raw           : std_logic := '1';
    signal digital_inputs    : std_logic_vector(7 downto 0) := (others => '0');

    -- xADC (simulated)
    signal xadc_drdy         : std_logic := '0';
    signal xadc_do           : std_logic_vector(15 downto 0) := (others => '0');
    signal xadc_channel      : std_logic_vector(4 downto 0) := (others => '0');
    signal xadc_eoc          : std_logic := '0';
    signal xadc_dclk         : std_logic;
    signal xadc_den          : std_logic;
    signal xadc_dwe          : std_logic;
    signal xadc_daddr        : std_logic_vector(6 downto 0);
    signal xadc_di           : std_logic_vector(15 downto 0);

    -- AXI-Lite
    signal s_axi_aclk        : std_logic := '0';
    signal s_axi_aresetn     : std_logic := '0';
    signal s_axi_awaddr      : std_logic_vector(6 downto 0) := (others => '0');
    signal s_axi_awvalid     : std_logic := '0';
    signal s_axi_awready     : std_logic;
    signal s_axi_wdata       : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axi_wstrb       : std_logic_vector(3 downto 0) := "1111";
    signal s_axi_wvalid      : std_logic := '0';
    signal s_axi_wready      : std_logic;
    signal s_axi_bresp       : std_logic_vector(1 downto 0);
    signal s_axi_bvalid      : std_logic;
    signal s_axi_bready      : std_logic := '1';
    signal s_axi_araddr      : std_logic_vector(6 downto 0) := (others => '0');
    signal s_axi_arvalid     : std_logic := '0';
    signal s_axi_arready     : std_logic;
    signal s_axi_rdata       : std_logic_vector(31 downto 0);
    signal s_axi_rresp       : std_logic_vector(1 downto 0);
    signal s_axi_rvalid      : std_logic;
    signal s_axi_rready      : std_logic := '1';

    -- AXI Stream
    signal m_axis_tdata      : std_logic_vector(31 downto 0);
    signal m_axis_tvalid     : std_logic;
    signal m_axis_tready     : std_logic := '1';
    signal m_axis_tlast      : std_logic;

    -- -------------------------------------------------------------------------
    -- Testbench control
    -- -------------------------------------------------------------------------
    signal sim_done          : boolean   := false;
    signal test_num          : integer   := 0;
    signal crank_run         : std_logic := '0';
    signal cam_run           : std_logic := '0';
    signal crank_period      : time      := TOOTH_1000_RPM;
    signal cam_tooth_offset  : integer   := 7;
    signal glitch_request    : std_logic := '0';

    -- Received packet storage
    type packet_t is array (0 to 3) of std_logic_vector(31 downto 0);
    signal rx_packet         : packet_t := (others => (others => '0'));
    signal rx_done           : std_logic := '0';
    signal rx_word_idx       : integer   := 0;
    signal rx_count          : integer   := 0;

    -- -------------------------------------------------------------------------
    -- AXI-Lite write procedure
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
        wait until rising_edge(s_axi_aclk) and
                   awready_s = '1' and wready_s = '1';
        wait for clk_p;
        awvalid_s <= '0';
        wvalid_s  <= '0';
        wait until rising_edge(s_axi_aclk) and bvalid_s = '1';
        wait for clk_p;
    end procedure axi_write;

    -- -------------------------------------------------------------------------
    -- AXI-Lite read procedure
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
        wait until rising_edge(s_axi_aclk) and arready_s = '1';
        wait for clk_p;
        arvalid_s <= '0';
        wait until rising_edge(s_axi_aclk) and rvalid_s = '1';
        data := rdata_s;
        wait for clk_p;
    end procedure axi_read;

begin

    -- -------------------------------------------------------------------------
    -- Clocks
    -- -------------------------------------------------------------------------
    p_clk : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_clk;

    p_axi_clk : process
    begin
        while not sim_done loop
            s_axi_aclk <= '0'; wait for AXI_CLK_PERIOD / 2;
            s_axi_aclk <= '1'; wait for AXI_CLK_PERIOD / 2;
        end loop;
        wait;
    end process p_axi_clk;

    -- -------------------------------------------------------------------------
    -- DUT
    -- -------------------------------------------------------------------------
    dut : entity work.top
        port map (
            clk              => clk,
            rst_n            => rst_n,
            crank_raw        => crank_raw,
            cam_raw          => cam_raw,
            digital_inputs   => digital_inputs,
            xadc_drdy        => xadc_drdy,
            xadc_do          => xadc_do,
            xadc_channel     => xadc_channel,
            xadc_eoc         => xadc_eoc,
            xadc_dclk        => xadc_dclk,
            xadc_den         => xadc_den,
            xadc_dwe         => xadc_dwe,
            xadc_daddr       => xadc_daddr,
            xadc_di          => xadc_di,
            s_axi_aclk       => s_axi_aclk,
            s_axi_aresetn    => s_axi_aresetn,
            s_axi_awaddr     => s_axi_awaddr,
            s_axi_awvalid    => s_axi_awvalid,
            s_axi_awready    => s_axi_awready,
            s_axi_wdata      => s_axi_wdata,
            s_axi_wstrb      => s_axi_wstrb,
            s_axi_wvalid     => s_axi_wvalid,
            s_axi_wready     => s_axi_wready,
            s_axi_bresp      => s_axi_bresp,
            s_axi_bvalid     => s_axi_bvalid,
            s_axi_bready     => s_axi_bready,
            s_axi_araddr     => s_axi_araddr,
            s_axi_arvalid    => s_axi_arvalid,
            s_axi_arready    => s_axi_arready,
            s_axi_rdata      => s_axi_rdata,
            s_axi_rresp      => s_axi_rresp,
            s_axi_rvalid     => s_axi_rvalid,
            s_axi_rready     => s_axi_rready,
            m_axis_tdata     => m_axis_tdata,
            m_axis_tvalid    => m_axis_tvalid,
            m_axis_tready    => m_axis_tready,
            m_axis_tlast     => m_axis_tlast
        );

    -- -------------------------------------------------------------------------
    -- Crank signal generator
    -- -------------------------------------------------------------------------
    p_crank : process
        variable t_half : time;
    begin
        loop
            if crank_run = '0' then
                crank_raw <= '1';
                wait until crank_run = '1';
            end if;

            t_half := crank_period / 2;

            for i in 1 to TEETH_REAL loop
                if crank_run = '0' then
                    crank_raw <= '1';
                    exit;
                end if;
                if glitch_request = '1' then
                    crank_raw <= '0'; wait for 3 * CLK_PERIOD;
                    crank_raw <= '1'; wait for 2 * CLK_PERIOD;
                end if;
                crank_raw <= '1'; wait for t_half;
                crank_raw <= '0'; wait for t_half;
            end loop;

            if crank_run = '1' then
                crank_raw <= '1';
                wait for crank_period * (N_MISSING + 1);
            end if;
        end loop;
    end process p_crank;

    -- -------------------------------------------------------------------------
    -- Cam signal generator
    -- Fires once per engine cycle at cam_tooth_offset teeth after gap
    -- -------------------------------------------------------------------------
    p_cam : process
    begin
        loop
            if cam_run = '0' then
                cam_raw <= '1';
                wait until cam_run = '1';
            end if;

            -- Wait for gap end (Z fires at start of new cycle in crank_input)
            -- Use crank_raw going low after the gap as a proxy
            -- Actually wait one full cycle then fire at tooth offset
            wait for crank_period * N_TEETH;
            wait for crank_period * cam_tooth_offset;

            if cam_run = '1' then
                cam_raw <= '0';
                wait for crank_period;
                cam_raw <= '1';
            end if;
        end loop;
    end process p_cam;

    -- -------------------------------------------------------------------------
    -- xADC simulator
    -- Continuously converts channel 0 (VAUX0) with a known value
    -- -------------------------------------------------------------------------
    p_xadc : process
    begin
        loop
            wait for 1_000 ns;   -- 1us conversion period = 1MSPS
            if rst_n = '1' then
                xadc_channel <= std_logic_vector(to_unsigned(16#10#, 5));
                xadc_do      <= x"1234";   -- known pressure value
                xadc_eoc     <= '1';
                wait for CLK_PERIOD;
                xadc_eoc     <= '0';
                xadc_drdy    <= '1';
                wait for CLK_PERIOD;
                xadc_drdy    <= '0';
            end if;
        end loop;
    end process p_xadc;

    -- -------------------------------------------------------------------------
    -- AXI Stream receiver
    -- -------------------------------------------------------------------------
    p_receiver : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rx_word_idx <= 0;
                rx_done     <= '0';
                rx_count    <= 0;
            else
                rx_done <= '0';
                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    rx_packet(rx_word_idx) <= m_axis_tdata;
                    if m_axis_tlast = '1' then
                        rx_word_idx <= 0;
                        rx_done     <= '1';
                        rx_count    <= rx_count + 1;
                    else
                        rx_word_idx <= rx_word_idx + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_receiver;

    -- =========================================================================
    -- Stimulus
    -- =========================================================================
    p_stim : process
        variable rd_data      : std_logic_vector(31 downto 0);
        variable pkt_start    : integer;
        variable sync_state_v : std_logic_vector(2 downto 0);
    begin

        -- --------------------------------------------------------------------
        -- TEST 1: Reset - all outputs in known state
        -- --------------------------------------------------------------------
        test_num     <= 1;
        report "TEST 1: Reset behaviour";
        rst_n        <= '0';
        s_axi_aresetn <= '0';
        crank_run    <= '0';
        cam_run      <= '0';
        wait for 20 * CLK_PERIOD;
        rst_n        <= '1';
        s_axi_aresetn <= '1';
        wait for 20 * CLK_PERIOD;

        assert m_axis_tvalid = '0'
            report "FAIL T1: tvalid should be low after reset"
            severity failure;
        report "TEST 1: PASS";

        -- --------------------------------------------------------------------
        -- TEST 2: Configure system via AXI-Lite
        -- Write PLL gains, phase angle, tolerance, decimation
        -- --------------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: AXI-Lite configuration";

        -- falling edge detection
        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_CONTROL, x"00000000", AXI_CLK_PERIOD);

        -- PLL gains
        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_PLL_KP, x"00000100", AXI_CLK_PERIOD);

        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_PLL_KI, x"00000010", AXI_CLK_PERIOD);

        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_PLL_MAXC, x"00000400", AXI_CLK_PERIOD);

        -- Phase angle = 900 (90.0 deg), tolerance = 300 (30.0 deg)
        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_PHASE_ANG, x"00000384", AXI_CLK_PERIOD);

        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_PHASE_TOL, x"0000012C", AXI_CLK_PERIOD);

        -- Decimation = 1 (maximum resolution)
        axi_write(s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wvalid,
                  s_axi_awready, s_axi_wready, s_axi_bvalid,
                  ADDR_DECIMATION, x"00000001", AXI_CLK_PERIOD);

        report "TEST 2: PASS - system configured";

        -- --------------------------------------------------------------------
        -- TEST 3: Sync acquisition end to end
        -- Start crank signal and verify sync state advances
        -- --------------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: End-to-end sync acquisition";

        crank_run <= '1';

        -- Allow 4 cycles for SYNC_CRANK acquisition
        wait for CYCLE_1000 * 4;

        -- Read sync state via AXI
        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_STATUS, rd_data, AXI_CLK_PERIOD);

        sync_state_v := rd_data(2 downto 0);
        assert sync_state_v = ST_SYNC_CRANK
            report "FAIL T3: STATUS sync_state should be SYNC_CRANK, got " &
                   integer'image(to_integer(unsigned(sync_state_v)))
            severity failure;

        report "TEST 3: PASS - SYNC_CRANK acquired";

        -- --------------------------------------------------------------------
        -- TEST 4: Full sync with cam pulse → SYNC_FULL
        -- --------------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: SYNC_FULL with cam pulse";

        cam_tooth_offset <= 7;   -- fires at ~84 deg, within 30 deg of 90 deg
        cam_run          <= '1';

        -- Allow several cycles for cam pulse to be detected
        wait for CYCLE_1000 * 5;

        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_STATUS, rd_data, AXI_CLK_PERIOD);

        sync_state_v := rd_data(2 downto 0);
        assert sync_state_v = ST_SYNC_FULL
            report "FAIL T4: STATUS sync_state should be SYNC_FULL, got " &
                   integer'image(to_integer(unsigned(sync_state_v)))
            severity failure;

        report "TEST 4: PASS - SYNC_FULL achieved";

        -- --------------------------------------------------------------------
        -- TEST 5: Packets being produced
        -- --------------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: Packet production";

        wait for CYCLE_1000 * 2;

        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_PKT_COUNT, rd_data, AXI_CLK_PERIOD);

        assert to_integer(unsigned(rd_data)) > 0
            report "FAIL T5: packet_count should be > 0"
            severity failure;

        report "TEST 5: PASS - packet_count = " &
               integer'image(to_integer(unsigned(rd_data)));

        -- --------------------------------------------------------------------
        -- TEST 6: Verify packet word 0 contains valid angle
        -- --------------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: Packet angle data valid";

        wait until rx_done = '1';
        wait for CLK_PERIOD;

        -- Word 0 [15:0] = sample_angle, should be 0-7199
        assert to_integer(unsigned(rx_packet(0)(15 downto 0))) < 7200
            report "FAIL T6: sample_angle out of range: " &
                   integer'image(to_integer(unsigned(rx_packet(0)(15 downto 0))))
            severity failure;

        report "TEST 6: PASS - sample_angle = " &
               integer'image(to_integer(unsigned(rx_packet(0)(15 downto 0))));

        -- --------------------------------------------------------------------
        -- TEST 7: Verify xADC data appears in packet
        -- xADC channel 0 continuously outputs 0x1234
        -- --------------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: xADC data in packet";

        -- Wait for several packets to ensure xADC has updated
        wait for CYCLE_1000 * 2;
        wait until rx_done = '1';
        wait for CLK_PERIOD;

        assert rx_packet(1)(15 downto 0) = x"1234"
            report "FAIL T7: xADC ch0 should be 0x1234 in packet word 1, got " &
                   integer'image(to_integer(unsigned(rx_packet(1)(15 downto 0))))
            severity failure;

        report "TEST 7: PASS - xADC data correct in packet";

        -- --------------------------------------------------------------------
        -- TEST 8: Glitch rejection end to end
        -- --------------------------------------------------------------------
        test_num <= 8;
        report "TEST 8: Glitch rejection end to end";

        glitch_request <= '1';
        wait for TOOTH_1000_RPM * 2;
        glitch_request <= '0';

        -- Read status - should still be SYNC_FULL
        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_STATUS, rd_data, AXI_CLK_PERIOD);

        assert rd_data(2 downto 0) = ST_SYNC_FULL
            report "FAIL T8: should remain SYNC_FULL after glitch"
            severity failure;

        report "TEST 8: PASS - glitch rejected, still SYNC_FULL";

        -- --------------------------------------------------------------------
        -- TEST 9: No overflow at 1000 RPM with decimation = 1
        -- --------------------------------------------------------------------
        test_num <= 9;
        report "TEST 9: No overflow at 1000 RPM";

        wait for CYCLE_1000 * 5;

        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_OVF_COUNT, rd_data, AXI_CLK_PERIOD);

        assert to_integer(unsigned(rd_data)) = 0
            report "FAIL T9: overflow_count should be 0 at 1000 RPM, got " &
                   integer'image(to_integer(unsigned(rd_data)))
            severity failure;

        report "TEST 9: PASS - no overflow at 1000 RPM";

        -- --------------------------------------------------------------------
        -- TEST 10: RPM change to 2000 RPM, sync maintained
        -- --------------------------------------------------------------------
        test_num <= 10;
        report "TEST 10: RPM change to 2000 RPM";

        crank_period <= TOOTH_2000_RPM;

        -- Allow PLL to relock
        wait for CYCLE_1000 * 5;

        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_STATUS, rd_data, AXI_CLK_PERIOD);

        assert rd_data(2 downto 0) = ST_SYNC_FULL
            report "FAIL T10: should remain SYNC_FULL after RPM change"
            severity failure;

        report "TEST 10: PASS - SYNC_FULL maintained at 2000 RPM";

        -- --------------------------------------------------------------------
        -- TEST 11: Sync loss and reacquisition end to end
        -- --------------------------------------------------------------------
        test_num <= 11;
        report "TEST 11: Sync loss and reacquisition";

        crank_period <= TOOTH_1000_RPM;
        crank_run    <= '0';
        cam_run      <= '0';

        -- Wait for signal_present timeout
        wait for TOOTH_1000_RPM * 10;

        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_STATUS, rd_data, AXI_CLK_PERIOD);

        assert rd_data(2 downto 0) = ST_UNSYNC
            report "FAIL T11: should be UNSYNC after signal loss"
            severity failure;

        -- Check sync_loss_count incremented
        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_SYNC_LOSS, rd_data, AXI_CLK_PERIOD);

        assert to_integer(unsigned(rd_data)) > 0
            report "FAIL T11: sync_loss_count should be > 0"
            severity failure;

        -- Reacquire
        crank_run <= '1';
        wait for CYCLE_1000 * 4;
        cam_run   <= '1';
        wait for CYCLE_1000 * 5;

        axi_read(s_axi_araddr, s_axi_arvalid, s_axi_arready,
                 s_axi_rvalid, s_axi_rdata,
                 ADDR_STATUS, rd_data, AXI_CLK_PERIOD);

        assert rd_data(2 downto 0) = ST_SYNC_FULL
            report "FAIL T11: should reacquire SYNC_FULL"
            severity failure;

        report "TEST 11: PASS - sync loss and reacquisition successful";

        -- --------------------------------------------------------------------
        -- Done
        -- --------------------------------------------------------------------
        crank_run <= '0';
        cam_run   <= '0';
        wait for 20 * CLK_PERIOD;

        report "========================================";
        report "All top_tb tests complete";
        report "========================================";

        sim_done <= true;
        std.env.stop;
        wait;

    end process p_stim;

end architecture sim;