library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- axi_lite_regs
--
-- AXI4-Lite register bank for combustion analyser PS/PL interface.
--
-- Write registers (PS → PL):
--   0x00 CONTROL:    [2] correction_dir, [1] fault_clear (self-clearing), [0] edge_select
--   0x04 GAP_THRESH: [7:0] gap_threshold
--   0x08 PLL_KP:     [15:0] kp
--   0x0C PLL_KI:     [15:0] ki
--   0x10 PLL_MAXC:   [15:0] max_correction
--   0x14 PHASE_ANG:  [15:0] expected_phase_angle
--   0x18 PHASE_TOL:  [15:0] phase_tolerance
--   0x1C TDC_OFF:    [15:0] tdc_offset
--   0x20 DECIMATION: [7:0]  decimation
--   0x60 PULSE_WIDTH:[15:0] sample_pulse debug stretch (cycles, default 1000)
--
-- Read registers (PL → PS):
--   0x24 STATUS:     [5] synced, [4] signal_present, [3] phase_fault, [2:0] sync_state
--   0x28 SYNC_LOSS:  [15:0] sync_loss_count
--   0x2C PHASE_FLT:  [15:0] phase_fault_count
--   0x30 PKT_COUNT:  [31:0] packet_count
--   0x34 OVF_COUNT:  [15:0] overflow_count
--   0x38 RAW_ANGLE:  [15:0] raw_angle
--   0x3C CRANK_ANG:  [15:0] crank_angle
--   0x40 ENG_ANG:    [15:0] engine_angle
--   0x44 AB_COUNT:   [7:0]  ab_count (teeth counted this revolution)
--   0x48 TOOTH_PER:  [31:0] tooth_period (clock cycles)
--   0x4C GAP_PER:    [31:0] gap_period (clock cycles)
--   0x50 NCO_INC:    [31:0] NCO frequency word
--   0x54 PHASE_ERR:  [31:0] signed phase error
--   0x58 CORRECTION: [31:0] signed PI correction
--   0x5C CAM_ANGLE:  [15:0] detected cam edge angle
-- =============================================================================

entity axi_lite_regs is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 7
    );
    port (
        -- AXI4-Lite slave interface
        s_axi_aclk      : in  std_logic;
        s_axi_aresetn   : in  std_logic;
        s_axi_awaddr    : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_wstrb     : in  std_logic_vector(C_S_AXI_DATA_WIDTH/8-1 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;

        -- Configuration outputs to PL
        edge_select          : out std_logic;
        correction_dir       : out std_logic;
        gap_threshold        : out unsigned(7 downto 0);
        kp                   : out unsigned(15 downto 0);
        ki                   : out unsigned(15 downto 0);
        max_correction       : out unsigned(15 downto 0);
        expected_phase_angle : out unsigned(15 downto 0);
        phase_tolerance      : out unsigned(15 downto 0);
        tdc_offset           : out unsigned(15 downto 0);
        decimation           : out unsigned(7 downto 0);
        fault_clear          : out std_logic;
        pulse_width          : out unsigned(15 downto 0);

        -- Status inputs from PL
        sync_state           : in  std_logic_vector(2 downto 0);
        signal_present       : in  std_logic;
        phase_fault          : in  std_logic;
        sync_loss_count      : in  unsigned(15 downto 0);
        phase_fault_count    : in  unsigned(15 downto 0);
        packet_count         : in  unsigned(31 downto 0);
        overflow_count       : in  unsigned(15 downto 0);
        raw_angle            : in  unsigned(15 downto 0);
        crank_angle          : in  unsigned(15 downto 0);
        engine_angle         : in  unsigned(15 downto 0);

        -- Debug inputs from PL
        synced               : in  std_logic;
        ab_count             : in  unsigned(7 downto 0);
        tooth_period         : in  unsigned(31 downto 0);
        gap_period           : in  unsigned(31 downto 0);
        nco_inc              : in  unsigned(31 downto 0);
        phase_error          : in  signed(31 downto 0);
        correction           : in  signed(31 downto 0);
        cam_angle            : in  unsigned(15 downto 0)
    );
end entity axi_lite_regs;

architecture rtl of axi_lite_regs is

    -- Register addresses (word addressed, byte offset / 4)
    constant ADDR_CONTROL   : integer := 16#00# / 4;
    constant ADDR_GAP_THRESH: integer := 16#04# / 4;
    constant ADDR_PLL_KP    : integer := 16#08# / 4;
    constant ADDR_PLL_KI    : integer := 16#0C# / 4;
    constant ADDR_PLL_MAXC  : integer := 16#10# / 4;
    constant ADDR_PHASE_ANG : integer := 16#14# / 4;
    constant ADDR_PHASE_TOL : integer := 16#18# / 4;
    constant ADDR_TDC_OFF   : integer := 16#1C# / 4;
    constant ADDR_DECIMATION : integer := 16#20# / 4;
    constant ADDR_PULSE_WIDTH: integer := 16#60# / 4;
    constant ADDR_STATUS    : integer := 16#24# / 4;
    constant ADDR_SYNC_LOSS : integer := 16#28# / 4;
    constant ADDR_PHASE_FLT : integer := 16#2C# / 4;
    constant ADDR_PKT_COUNT : integer := 16#30# / 4;
    constant ADDR_OVF_COUNT : integer := 16#34# / 4;
    constant ADDR_RAW_ANGLE : integer := 16#38# / 4;
    constant ADDR_CRANK_ANG : integer := 16#3C# / 4;
    constant ADDR_ENG_ANG   : integer := 16#40# / 4;
    constant ADDR_AB_COUNT  : integer := 16#44# / 4;
    constant ADDR_TOOTH_PER : integer := 16#48# / 4;
    constant ADDR_GAP_PER   : integer := 16#4C# / 4;
    constant ADDR_NCO_INC   : integer := 16#50# / 4;
    constant ADDR_PHASE_ERR : integer := 16#54# / 4;
    constant ADDR_CORR      : integer := 16#58# / 4;
    constant ADDR_CAM_ANGLE : integer := 16#5C# / 4;

    -- Write registers
    signal reg_control      : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_gap_thresh   : std_logic_vector(31 downto 0) := x"000000C0";
    signal reg_kp           : std_logic_vector(31 downto 0) := x"00000100";
    signal reg_ki           : std_logic_vector(31 downto 0) := x"00000010";
    signal reg_max_corr     : std_logic_vector(31 downto 0) := x"00000400";
    signal reg_phase_ang    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_phase_tol    : std_logic_vector(31 downto 0) := x"000000B4";  -- 180
    signal reg_tdc_off      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_decimation   : std_logic_vector(31 downto 0) := x"00000001";
    signal reg_pulse_width  : std_logic_vector(31 downto 0) := x"000003E8"; -- 1000 cycles

    -- AXI write state
    signal aw_en            : std_logic := '0';
    signal axi_awready      : std_logic := '0';
    signal axi_wready       : std_logic := '0';
    signal axi_bvalid       : std_logic := '0';
    signal axi_bresp        : std_logic_vector(1 downto 0) := "00";
    signal write_addr       : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);

    -- AXI read state
    signal axi_arready      : std_logic := '0';
    signal axi_rvalid       : std_logic := '0';
    signal axi_rdata        : std_logic_vector(31 downto 0) := (others => '0');
    signal axi_rresp        : std_logic_vector(1 downto 0) := "00";
    signal read_addr        : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);

    -- fault_clear is self-clearing
    signal fault_clear_int  : std_logic := '0';

begin

    -- -------------------------------------------------------------------------
    -- AXI write address channel
    -- -------------------------------------------------------------------------
    p_aw : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_awready <= '0';
                aw_en       <= '1';
            else
                if aw_en = '1' and s_axi_awvalid = '1' and
                   s_axi_wvalid = '1' then
                    axi_awready <= '1';
                    aw_en       <= '0';
                    write_addr  <= s_axi_awaddr;
                elsif s_axi_bready = '1' and axi_bvalid = '1' then
                    aw_en       <= '1';
                    axi_awready <= '0';
                else
                    axi_awready <= '0';
                end if;
            end if;
        end if;
    end process p_aw;

    -- -------------------------------------------------------------------------
    -- AXI write data channel
    -- -------------------------------------------------------------------------
    p_w : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_wready <= '0';
            else
                if aw_en = '1' and s_axi_awvalid = '1' and
                   s_axi_wvalid = '1' then
                    axi_wready <= '1';
                else
                    axi_wready <= '0';
                end if;
            end if;
        end if;
    end process p_w;

    -- -------------------------------------------------------------------------
    -- Register write logic
    -- -------------------------------------------------------------------------
    p_reg_write : process(s_axi_aclk)
        variable word_addr : integer;
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                reg_control    <= x"00000000";
                reg_gap_thresh <= x"000000C0";
                reg_kp         <= x"00000100";
                reg_ki         <= x"00000010";
                reg_max_corr   <= x"00000400";
                reg_phase_ang  <= (others => '0');
                reg_phase_tol  <= x"000000B4";
                reg_tdc_off    <= (others => '0');
                reg_decimation <= x"00000001";
                reg_pulse_width <= x"000003E8";
                fault_clear_int <= '0';
            else
                -- Self-clear fault_clear
                fault_clear_int <= '0';

                if axi_wready = '1' and s_axi_wvalid = '1' and
                   axi_awready = '1' and s_axi_awvalid = '1' then

                    word_addr := to_integer(unsigned(write_addr(6 downto 2)));

                    case word_addr is
                        when ADDR_CONTROL =>
                            reg_control    <= s_axi_wdata;
                            fault_clear_int <= s_axi_wdata(1);
                        when ADDR_GAP_THRESH =>
                            reg_gap_thresh <= s_axi_wdata;
                        when ADDR_PLL_KP =>
                            reg_kp         <= s_axi_wdata;
                        when ADDR_PLL_KI =>
                            reg_ki         <= s_axi_wdata;
                        when ADDR_PLL_MAXC =>
                            reg_max_corr   <= s_axi_wdata;
                        when ADDR_PHASE_ANG =>
                            reg_phase_ang  <= s_axi_wdata;
                        when ADDR_PHASE_TOL =>
                            reg_phase_tol  <= s_axi_wdata;
                        when ADDR_TDC_OFF =>
                            reg_tdc_off    <= s_axi_wdata;
                        when ADDR_DECIMATION =>
                            reg_decimation <= s_axi_wdata;
                        when ADDR_PULSE_WIDTH =>
                            reg_pulse_width <= s_axi_wdata;
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process p_reg_write;

    -- -------------------------------------------------------------------------
    -- AXI write response channel
    -- -------------------------------------------------------------------------
    p_b : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_bvalid <= '0';
                axi_bresp  <= "00";
            else
                if axi_awready = '1' and s_axi_awvalid = '1' and
                   axi_wready = '1' and s_axi_wvalid = '1' and
                   axi_bvalid = '0' then
                    axi_bvalid <= '1';
                    axi_bresp  <= "00";
                elsif s_axi_bready = '1' and axi_bvalid = '1' then
                    axi_bvalid <= '0';
                end if;
            end if;
        end if;
    end process p_b;

    -- -------------------------------------------------------------------------
    -- AXI read address channel
    -- -------------------------------------------------------------------------
    p_ar : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_arready <= '0';
            else
                if s_axi_arvalid = '1' and axi_arready = '0' then
                    axi_arready <= '1';
                    read_addr   <= s_axi_araddr;
                else
                    axi_arready <= '0';
                end if;
            end if;
        end if;
    end process p_ar;

    -- -------------------------------------------------------------------------
    -- AXI read data channel
    -- -------------------------------------------------------------------------
    p_r : process(s_axi_aclk)
        variable word_addr : integer;
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_rvalid <= '0';
                axi_rresp  <= "00";
                axi_rdata  <= (others => '0');
            else
                if axi_arready = '1' and s_axi_arvalid = '1' and
                   axi_rvalid = '0' then
                    axi_rvalid <= '1';
                    axi_rresp  <= "00";

                    word_addr := to_integer(unsigned(read_addr(6 downto 2)));

                    case word_addr is
                        -- Write registers are readable
                        when ADDR_CONTROL    => axi_rdata <= reg_control;
                        when ADDR_GAP_THRESH => axi_rdata <= reg_gap_thresh;
                        when ADDR_PLL_KP     => axi_rdata <= reg_kp;
                        when ADDR_PLL_KI     => axi_rdata <= reg_ki;
                        when ADDR_PLL_MAXC   => axi_rdata <= reg_max_corr;
                        when ADDR_PHASE_ANG  => axi_rdata <= reg_phase_ang;
                        when ADDR_PHASE_TOL  => axi_rdata <= reg_phase_tol;
                        when ADDR_TDC_OFF    => axi_rdata <= reg_tdc_off;
                        when ADDR_DECIMATION => axi_rdata <= reg_decimation;
                        when ADDR_PULSE_WIDTH=> axi_rdata <= reg_pulse_width;

                        -- Status registers
                        when ADDR_STATUS =>
                            axi_rdata <= (others => '0');
                            axi_rdata(5) <= synced;
                            axi_rdata(4) <= signal_present;
                            axi_rdata(3) <= phase_fault;
                            axi_rdata(2 downto 0) <= sync_state;

                        when ADDR_SYNC_LOSS =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(sync_loss_count);

                        when ADDR_PHASE_FLT =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(phase_fault_count);

                        when ADDR_PKT_COUNT =>
                            axi_rdata <= std_logic_vector(packet_count);

                        when ADDR_OVF_COUNT =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(overflow_count);

                        when ADDR_RAW_ANGLE =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(raw_angle);

                        when ADDR_CRANK_ANG =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(crank_angle);

                        when ADDR_ENG_ANG =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(engine_angle);

                        when ADDR_AB_COUNT =>
                            axi_rdata <= x"000000" &
                                         std_logic_vector(ab_count);

                        when ADDR_TOOTH_PER =>
                            axi_rdata <= std_logic_vector(tooth_period);

                        when ADDR_GAP_PER =>
                            axi_rdata <= std_logic_vector(gap_period);

                        when ADDR_NCO_INC =>
                            axi_rdata <= std_logic_vector(nco_inc);

                        when ADDR_PHASE_ERR =>
                            axi_rdata <= std_logic_vector(phase_error);

                        when ADDR_CORR =>
                            axi_rdata <= std_logic_vector(correction);

                        when ADDR_CAM_ANGLE =>
                            axi_rdata <= x"0000" &
                                         std_logic_vector(cam_angle);

                        when others =>
                            axi_rdata <= (others => '0');
                    end case;

                elsif axi_rvalid = '1' and s_axi_rready = '1' then
                    axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process p_r;

    -- -------------------------------------------------------------------------
    -- Output assignments
    -- -------------------------------------------------------------------------
    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bresp   <= axi_bresp;
    s_axi_bvalid  <= axi_bvalid;
    s_axi_arready <= axi_arready;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= axi_rresp;
    s_axi_rvalid  <= axi_rvalid;

    -- Configuration outputs
    edge_select          <= reg_control(0);
    correction_dir       <= reg_control(2);
    fault_clear          <= fault_clear_int;
    gap_threshold        <= unsigned(reg_gap_thresh(7 downto 0));
    kp                   <= unsigned(reg_kp(15 downto 0));
    ki                   <= unsigned(reg_ki(15 downto 0));
    max_correction       <= unsigned(reg_max_corr(15 downto 0));
    expected_phase_angle <= unsigned(reg_phase_ang(15 downto 0));
    phase_tolerance      <= unsigned(reg_phase_tol(15 downto 0));
    tdc_offset           <= unsigned(reg_tdc_off(15 downto 0));
    decimation           <= unsigned(reg_decimation(7 downto 0));
    pulse_width          <= unsigned(reg_pulse_width(15 downto 0));

end architecture rtl;