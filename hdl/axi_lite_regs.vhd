library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- axi_lite_regs.vhd  (v2)
-- AXI-Lite slave register file for Angus combustion analyser.
-- 9-bit byte address bus, 4-byte aligned, 128 word-addressed registers.
--
-- config_apply (CONTROL[3]) self-clears in p_write on the same cycle it is
-- written, and pulses config_apply_int for one clock to p_config.
-- p_config latches startup registers and starts the rst counter + divider.
-- rst_out is high until rst_counter reaches zero.
-- =============================================================================

entity axi_lite_regs is
    port (
        s_axi_aclk      : in  std_logic;
        s_axi_aresetn   : in  std_logic;
        s_axi_awaddr    : in  std_logic_vector(8 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(31 downto 0);
        s_axi_wstrb     : in  std_logic_vector(3 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(8 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(31 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;
        -- Reset output
        rst_out         : out std_logic;
        -- Startup config outputs (latched on config_apply)
        crank_edge_sel  : out std_logic;
        src_sel         : out std_logic;
        ref_sel         : out std_logic;
        cam_edge_sel    : out std_logic;
        ang_sel         : out std_logic;
        crank_gap_thresh: out unsigned(7 downto 0);
        crank_n_teeth   : out unsigned(7 downto 0);
        crank_n_missing : out unsigned(7 downto 0);
        cam_n_teeth     : out unsigned(7 downto 0);
        enc_n_ppr       : out unsigned(15 downto 0);
        enc_ab_edge_sel : out unsigned(1 downto 0);
        enc_z_edge_sel  : out std_logic;
        dma_buffer_size : out unsigned(3 downto 0);
        pll_nco_ab_inc  : out unsigned(31 downto 0);
        -- Runtime config outputs
        fault_clear     : out std_logic;
        pll_corr_dir    : out std_logic;
        phase_fault_drop: out std_logic;
        cam_debounce    : out unsigned(15 downto 0);
        crank_debounce  : out unsigned(15 downto 0);
        enc_a_debounce  : out unsigned(15 downto 0);
        enc_b_debounce  : out unsigned(15 downto 0);
        enc_z_debounce  : out unsigned(15 downto 0);
        phase_ref_ang   : out unsigned(15 downto 0);
        phase_ref_tol   : out unsigned(15 downto 0);
        tdc_offset      : out unsigned(15 downto 0);
        pll_phase_err_thresh : out unsigned(31 downto 0);
        pll_kp          : out unsigned(15 downto 0);
        pll_ki          : out unsigned(15 downto 0);
        pll_corr_max    : out unsigned(15 downto 0);
        trig_decimation : out unsigned(15 downto 0);
        trig_pulse_width: out unsigned(15 downto 0);
        -- Status inputs
        sync_state      : in  unsigned(1 downto 0);
        sync_fault_count: in  unsigned(15 downto 0);
        speed_rpm_slow  : in  unsigned(15 downto 0);
        speed_rpm_fast  : in  unsigned(15 downto 0);
        angle_deg       : in  unsigned(15 downto 0);
        phase_raw       : in  std_logic;
        phase_ref_det   : in  std_logic;
        phase_ref_ok    : in  std_logic;
        phase_ref_found : in  std_logic;
        phase_inv       : in  std_logic;
        phase_inv_latch : in  std_logic;
        phase_ang_corr  : in  unsigned(15 downto 0);
        phase_eng       : in  std_logic;
        phase_ang_eng   : in  unsigned(15 downto 0);
        phase_ref_det_cnt: in unsigned(15 downto 0);
        pll_ang_hires   : in  unsigned(15 downto 0);
        pll_div_valid   : in  std_logic;
        pll_nco_inc     : in  unsigned(31 downto 0);
        pll_nco_accum   : in  unsigned(31 downto 0);
        pll_phase_err   : in  signed(31 downto 0);
        pll_p_term      : in  signed(31 downto 0);
        pll_i_term      : in  signed(31 downto 0);
        pll_pi_corr     : in  signed(31 downto 0);
        pll_cycle_ab_count: in unsigned(7 downto 0);
        trig_pulse_count: in  unsigned(31 downto 0);
        crank_tooth_period: in unsigned(31 downto 0);
        crank_gap_period  : in unsigned(31 downto 0);
        crank_tooth_count : in unsigned(7 downto 0);
        crank_ab_count    : in unsigned(7 downto 0);
        crank_gap_det     : in std_logic;
        cam_tooth_count : in  unsigned(7 downto 0);
        ref_angle       : in  unsigned(15 downto 0);
        enc_ab_count    : in  unsigned(7 downto 0);
        enc_a_count     : in  unsigned(7 downto 0);
        enc_b_count     : in  unsigned(7 downto 0);
        enc_ab_period   : in  unsigned(31 downto 0);
        fault_flags     : in  std_logic_vector(31 downto 0);
        cam_fault_count : in  unsigned(15 downto 0);
        crank_fault_count: in unsigned(15 downto 0);
        phase_fault_count: in unsigned(15 downto 0);
        ab_fault_count  : in  unsigned(15 downto 0);
        speed_fault_count: in unsigned(15 downto 0);
        pll_phase_err_count: in unsigned(15 downto 0);
        pkt_count       : in  unsigned(31 downto 0);
        ovf_count       : in  unsigned(15 downto 0)
    );
end entity axi_lite_regs;

architecture rtl of axi_lite_regs is

    -- Address constants (byte addr / 4)
    constant A_CONTROL          : integer := 16#000# / 4;
    constant A_CONTROL_RT       : integer := 16#004# / 4;
    constant A_RST_CYCLES       : integer := 16#008# / 4;
    constant A_CAM_DBC          : integer := 16#00C# / 4;
    constant A_CRANK_DBC        : integer := 16#010# / 4;
    constant A_ENC_A_DBC        : integer := 16#014# / 4;
    constant A_ENC_B_DBC        : integer := 16#018# / 4;
    constant A_ENC_Z_DBC        : integer := 16#01C# / 4;
    constant A_CRANK_GAP_THRESH : integer := 16#020# / 4;
    constant A_CRANK_N_TEETH    : integer := 16#024# / 4;
    constant A_CRANK_N_MISSING  : integer := 16#028# / 4;
    constant A_CAM_N_TEETH      : integer := 16#02C# / 4;
    constant A_ENC_N_PPR        : integer := 16#030# / 4;
    constant A_ENC_AB_EDGE_SEL  : integer := 16#034# / 4;
    constant A_ENC_Z_EDGE_SEL   : integer := 16#038# / 4;
    constant A_PHASE_REF_ANG    : integer := 16#03C# / 4;
    constant A_PHASE_REF_TOL    : integer := 16#040# / 4;
    constant A_TDC_OFFSET       : integer := 16#044# / 4;
    constant A_PLL_PHASE_THRESH : integer := 16#048# / 4;
    constant A_PLL_KP           : integer := 16#04C# / 4;
    constant A_PLL_KI           : integer := 16#050# / 4;
    constant A_PLL_CORR_MAX     : integer := 16#054# / 4;
    constant A_TRIG_DECIMATION  : integer := 16#058# / 4;
    constant A_TRIG_PULSE_WIDTH : integer := 16#05C# / 4;
    constant A_DMA_BUFFER_SIZE  : integer := 16#060# / 4;
    constant A_SYNC_STATE       : integer := 16#070# / 4;
    constant A_SYNC_FAULT_COUNT : integer := 16#074# / 4;
    constant A_SPEED_RPM_SLOW   : integer := 16#078# / 4;
    constant A_SPEED_RPM_FAST   : integer := 16#07C# / 4;
    constant A_ANGLE_DEG        : integer := 16#080# / 4;
    constant A_PHASE_RAW        : integer := 16#084# / 4;
    constant A_PHASE_REF_DET    : integer := 16#088# / 4;
    constant A_PHASE_REF_OK     : integer := 16#08C# / 4;
    constant A_PHASE_REF_FOUND  : integer := 16#090# / 4;
    constant A_PHASE_INV        : integer := 16#094# / 4;
    constant A_PHASE_INV_LATCH  : integer := 16#098# / 4;
    constant A_PHASE_ANG_CORR   : integer := 16#09C# / 4;
    constant A_PHASE_ENG        : integer := 16#0A0# / 4;
    constant A_PHASE_ANG_ENG    : integer := 16#0A4# / 4;
    constant A_PHASE_REF_DET_CNT: integer := 16#0A8# / 4;
    constant A_PLL_ANG_HIRES    : integer := 16#0AC# / 4;
    constant A_PLL_DIV_VALID    : integer := 16#0B0# / 4;
    constant A_PLL_NCO_INC      : integer := 16#0B4# / 4;
    constant A_PLL_NCO_ACCUM    : integer := 16#0B8# / 4;
    constant A_PLL_PHASE_ERR    : integer := 16#0BC# / 4;
    constant A_PLL_P_TERM       : integer := 16#0C0# / 4;
    constant A_PLL_I_TERM       : integer := 16#0C4# / 4;
    constant A_PLL_PI_CORR      : integer := 16#0C8# / 4;
    constant A_PLL_NCO_AB_INC   : integer := 16#0CC# / 4;
    constant A_PLL_CYCLE_AB_CNT : integer := 16#0D0# / 4;
    constant A_TRIG_PULSE_COUNT : integer := 16#0D4# / 4;
    constant A_CRANK_TOOTH_PER  : integer := 16#0D8# / 4;
    constant A_CRANK_GAP_PER    : integer := 16#0DC# / 4;
    constant A_CRANK_TOOTH_CNT  : integer := 16#0E0# / 4;
    constant A_CRANK_AB_COUNT   : integer := 16#0E4# / 4;
    constant A_CRANK_GAP_DET    : integer := 16#0E8# / 4;
    constant A_CAM_TOOTH_COUNT  : integer := 16#0EC# / 4;
    constant A_REF_ANGLE        : integer := 16#0F0# / 4;
    constant A_ENC_AB_COUNT     : integer := 16#0F4# / 4;
    constant A_ENC_A_COUNT      : integer := 16#0F8# / 4;
    constant A_ENC_B_COUNT      : integer := 16#0FC# / 4;
    constant A_ENC_AB_PERIOD    : integer := 16#100# / 4;
    constant A_FAULT_FLAGS      : integer := 16#104# / 4;
    constant A_CAM_FAULT_COUNT  : integer := 16#108# / 4;
    constant A_CRANK_FAULT_CNT  : integer := 16#10C# / 4;
    constant A_PHASE_FAULT_CNT  : integer := 16#110# / 4;
    constant A_AB_FAULT_COUNT   : integer := 16#114# / 4;
    constant A_SPEED_FAULT_CNT  : integer := 16#118# / 4;
    constant A_PLL_ERR_COUNT    : integer := 16#11C# / 4;
    constant A_PKT_COUNT        : integer := 16#120# / 4;
    constant A_OVF_COUNT        : integer := 16#124# / 4;

    -- AXI internal
    signal axi_awready  : std_logic := '0';
    signal axi_wready   : std_logic := '0';
    signal axi_bvalid   : std_logic := '0';
    signal axi_arready  : std_logic := '0';
    signal axi_rvalid   : std_logic := '0';
    signal axi_rdata    : std_logic_vector(31 downto 0) := (others => '0');
    signal aw_addr      : std_logic_vector(8 downto 0)  := (others => '0');
    signal ar_addr      : std_logic_vector(8 downto 0)  := (others => '0');

    -- Write registers (single process manages each)
    signal reg_control          : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_control_rt       : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_rst_cycles       : std_logic_vector(31 downto 0) := x"00000100";
    signal reg_cam_dbc          : std_logic_vector(31 downto 0) := x"00000005";
    signal reg_crank_dbc        : std_logic_vector(31 downto 0) := x"00000005";
    signal reg_enc_a_dbc        : std_logic_vector(31 downto 0) := x"00000005";
    signal reg_enc_b_dbc        : std_logic_vector(31 downto 0) := x"00000005";
    signal reg_enc_z_dbc        : std_logic_vector(31 downto 0) := x"00000005";
    signal reg_crank_gap_thresh : std_logic_vector(31 downto 0) := x"000000C0";
    signal reg_crank_n_teeth    : std_logic_vector(31 downto 0) := x"0000003C";
    signal reg_crank_n_missing  : std_logic_vector(31 downto 0) := x"00000002";
    signal reg_cam_n_teeth      : std_logic_vector(31 downto 0) := x"00000001";
    signal reg_enc_n_ppr        : std_logic_vector(31 downto 0) := x"00000060";
    signal reg_enc_ab_edge_sel  : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_enc_z_edge_sel   : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_phase_ref_ang    : std_logic_vector(31 downto 0) := x"00000708";
    signal reg_phase_ref_tol    : std_logic_vector(31 downto 0) := x"00000258";
    signal reg_tdc_offset       : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_pll_phase_thresh : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_pll_kp           : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_pll_ki           : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_pll_corr_max     : std_logic_vector(31 downto 0) := x"0000FFFF";
    signal reg_trig_decimation  : std_logic_vector(31 downto 0) := x"00000001";
    signal reg_trig_pulse_width : std_logic_vector(31 downto 0) := x"00000001";
    signal reg_dma_buffer_size  : std_logic_vector(31 downto 0) := x"00000002";

    -- config_apply pulse (set in p_write, cleared next cycle)
    signal config_apply_int     : std_logic := '0';
    signal fault_clear_int      : std_logic := '0';

    -- Startup config latches
    signal latch_crank_edge_sel : std_logic := '1';
    signal latch_src_sel        : std_logic := '0';
    signal latch_ref_sel        : std_logic := '0';
    signal latch_cam_edge_sel   : std_logic := '1';
    signal latch_ang_sel        : std_logic := '0';
    signal latch_gap_thresh     : unsigned(7 downto 0)  := x"C0";
    signal latch_crank_n_teeth  : unsigned(7 downto 0)  := to_unsigned(60, 8);
    signal latch_crank_n_missing: unsigned(7 downto 0)  := to_unsigned(2, 8);
    signal latch_cam_n_teeth    : unsigned(7 downto 0)  := to_unsigned(1, 8);
    signal latch_enc_n_ppr      : unsigned(15 downto 0) := to_unsigned(96, 16);
    signal latch_enc_ab_edge_sel: unsigned(1 downto 0)  := (others => '0');
    signal latch_enc_z_edge_sel : std_logic := '0';
    signal latch_dma_buffer_size: unsigned(3 downto 0)  := to_unsigned(2, 4);

    -- Reset
    signal config_valid         : std_logic := '0';
    signal rst_counter          : unsigned(8 downto 0) := (others => '0');

    -- Divider for pll_nco_ab_inc
    signal div_start        : std_logic := '0';
    signal div_busy         : std_logic := '0';
    signal div_divisor      : unsigned(7 downto 0)  := to_unsigned(60, 8);
    signal div_remainder    : unsigned(31 downto 0) := (others => '0');
    signal div_q            : unsigned(31 downto 0) := (others => '0');
    signal div_shift        : integer range 0 to 31 := 0;
    signal nco_ab_inc_int   : unsigned(31 downto 0) := (others => '0');

begin

    s_axi_awready <= axi_awready;
    s_axi_wready  <= axi_wready;
    s_axi_bresp   <= "00";
    s_axi_bvalid  <= axi_bvalid;
    s_axi_arready <= axi_arready;
    s_axi_rdata   <= axi_rdata;
    s_axi_rresp   <= "00";
    s_axi_rvalid  <= axi_rvalid;

    -- =========================================================================
    -- AXI write channel -- single process owns all reg_ signals
    -- =========================================================================
    p_write : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_awready      <= '0';
                axi_wready       <= '0';
                axi_bvalid       <= '0';
                aw_addr          <= (others => '0');
                config_apply_int <= '0';
                fault_clear_int  <= '0';
            else
                config_apply_int <= '0';
                fault_clear_int  <= '0';

                if axi_awready = '0' and s_axi_awvalid = '1' then
                    axi_awready <= '1';
                    aw_addr     <= s_axi_awaddr;
                else
                    axi_awready <= '0';
                end if;

                if axi_wready = '0' and s_axi_wvalid = '1' then
                    axi_wready <= '1';
                else
                    axi_wready <= '0';
                end if;

                if axi_awready = '1' and axi_wready = '1' then
                    case to_integer(unsigned(aw_addr)) / 4 is
                        when A_CONTROL =>
                            -- Store without bit 3; detect config_apply from wdata
                            reg_control <= s_axi_wdata and x"FFFFFFF7";
                            if s_axi_wdata(3) = '1' then
                                config_apply_int <= '1';
                            end if;
                        when A_CONTROL_RT =>
                            reg_control_rt <= s_axi_wdata and x"FFFFFFFE";
                            if s_axi_wdata(0) = '1' then
                                fault_clear_int <= '1';
                            end if;
                        when A_RST_CYCLES       => reg_rst_cycles       <= s_axi_wdata;
                        when A_CAM_DBC          => reg_cam_dbc          <= s_axi_wdata;
                        when A_CRANK_DBC        => reg_crank_dbc        <= s_axi_wdata;
                        when A_ENC_A_DBC        => reg_enc_a_dbc        <= s_axi_wdata;
                        when A_ENC_B_DBC        => reg_enc_b_dbc        <= s_axi_wdata;
                        when A_ENC_Z_DBC        => reg_enc_z_dbc        <= s_axi_wdata;
                        when A_CRANK_GAP_THRESH => reg_crank_gap_thresh <= s_axi_wdata;
                        when A_CRANK_N_TEETH    => reg_crank_n_teeth    <= s_axi_wdata;
                        when A_CRANK_N_MISSING  => reg_crank_n_missing  <= s_axi_wdata;
                        when A_CAM_N_TEETH      => reg_cam_n_teeth      <= s_axi_wdata;
                        when A_ENC_N_PPR        => reg_enc_n_ppr        <= s_axi_wdata;
                        when A_ENC_AB_EDGE_SEL  => reg_enc_ab_edge_sel  <= s_axi_wdata;
                        when A_ENC_Z_EDGE_SEL   => reg_enc_z_edge_sel   <= s_axi_wdata;
                        when A_PHASE_REF_ANG    => reg_phase_ref_ang    <= s_axi_wdata;
                        when A_PHASE_REF_TOL    => reg_phase_ref_tol    <= s_axi_wdata;
                        when A_TDC_OFFSET       => reg_tdc_offset       <= s_axi_wdata;
                        when A_PLL_PHASE_THRESH => reg_pll_phase_thresh <= s_axi_wdata;
                        when A_PLL_KP           => reg_pll_kp           <= s_axi_wdata;
                        when A_PLL_KI           => reg_pll_ki           <= s_axi_wdata;
                        when A_PLL_CORR_MAX     => reg_pll_corr_max     <= s_axi_wdata;
                        when A_TRIG_DECIMATION  => reg_trig_decimation  <= s_axi_wdata;
                        when A_TRIG_PULSE_WIDTH => reg_trig_pulse_width <= s_axi_wdata;
                        when A_DMA_BUFFER_SIZE  => reg_dma_buffer_size  <= s_axi_wdata;
                        when others => null;
                    end case;
                end if;

                if axi_awready = '1' and axi_wready = '1' then
                    axi_bvalid <= '1';
                elsif axi_bvalid = '1' and s_axi_bready = '1' then
                    axi_bvalid <= '0';
                end if;
            end if;
        end if;
    end process p_write;

    -- =========================================================================
    -- AXI read channel
    -- =========================================================================
    p_read : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_arready <= '0';
                axi_rvalid  <= '0';
                axi_rdata   <= (others => '0');
                ar_addr     <= (others => '0');
            else
                if axi_arready = '0' and s_axi_arvalid = '1' then
                    axi_arready <= '1';
                    ar_addr     <= s_axi_araddr;
                else
                    axi_arready <= '0';
                end if;

                if axi_arready = '1' and axi_rvalid = '0' then
                    axi_rvalid <= '1';
                    case to_integer(unsigned(ar_addr)) / 4 is
                        when A_CONTROL          => axi_rdata <= reg_control;
                        when A_CONTROL_RT       => axi_rdata <= reg_control_rt;
                        when A_RST_CYCLES       => axi_rdata <= reg_rst_cycles;
                        when A_CAM_DBC          => axi_rdata <= reg_cam_dbc;
                        when A_CRANK_DBC        => axi_rdata <= reg_crank_dbc;
                        when A_ENC_A_DBC        => axi_rdata <= reg_enc_a_dbc;
                        when A_ENC_B_DBC        => axi_rdata <= reg_enc_b_dbc;
                        when A_ENC_Z_DBC        => axi_rdata <= reg_enc_z_dbc;
                        when A_CRANK_GAP_THRESH => axi_rdata <= reg_crank_gap_thresh;
                        when A_CRANK_N_TEETH    => axi_rdata <= reg_crank_n_teeth;
                        when A_CRANK_N_MISSING  => axi_rdata <= reg_crank_n_missing;
                        when A_CAM_N_TEETH      => axi_rdata <= reg_cam_n_teeth;
                        when A_ENC_N_PPR        => axi_rdata <= reg_enc_n_ppr;
                        when A_ENC_AB_EDGE_SEL  => axi_rdata <= reg_enc_ab_edge_sel;
                        when A_ENC_Z_EDGE_SEL   => axi_rdata <= reg_enc_z_edge_sel;
                        when A_PHASE_REF_ANG    => axi_rdata <= reg_phase_ref_ang;
                        when A_PHASE_REF_TOL    => axi_rdata <= reg_phase_ref_tol;
                        when A_TDC_OFFSET       => axi_rdata <= reg_tdc_offset;
                        when A_PLL_PHASE_THRESH => axi_rdata <= reg_pll_phase_thresh;
                        when A_PLL_KP           => axi_rdata <= reg_pll_kp;
                        when A_PLL_KI           => axi_rdata <= reg_pll_ki;
                        when A_PLL_CORR_MAX     => axi_rdata <= reg_pll_corr_max;
                        when A_TRIG_DECIMATION  => axi_rdata <= reg_trig_decimation;
                        when A_TRIG_PULSE_WIDTH => axi_rdata <= reg_trig_pulse_width;
                        when A_DMA_BUFFER_SIZE  => axi_rdata <= reg_dma_buffer_size;
                        when A_SYNC_STATE       => axi_rdata <= x"0000000" & "00" & std_logic_vector(sync_state);
                        when A_SYNC_FAULT_COUNT => axi_rdata <= x"0000" & std_logic_vector(sync_fault_count);
                        when A_SPEED_RPM_SLOW   => axi_rdata <= x"0000" & std_logic_vector(speed_rpm_slow);
                        when A_SPEED_RPM_FAST   => axi_rdata <= x"0000" & std_logic_vector(speed_rpm_fast);
                        when A_ANGLE_DEG        => axi_rdata <= x"0000" & std_logic_vector(angle_deg);
                        when A_PHASE_RAW        => axi_rdata <= x"0000000" & "000" & phase_raw;
                        when A_PHASE_REF_DET    => axi_rdata <= x"0000000" & "000" & phase_ref_det;
                        when A_PHASE_REF_OK     => axi_rdata <= x"0000000" & "000" & phase_ref_ok;
                        when A_PHASE_REF_FOUND  => axi_rdata <= x"0000000" & "000" & phase_ref_found;
                        when A_PHASE_INV        => axi_rdata <= x"0000000" & "000" & phase_inv;
                        when A_PHASE_INV_LATCH  => axi_rdata <= x"0000000" & "000" & phase_inv_latch;
                        when A_PHASE_ANG_CORR   => axi_rdata <= x"0000" & std_logic_vector(phase_ang_corr);
                        when A_PHASE_ENG        => axi_rdata <= x"0000000" & "000" & phase_eng;
                        when A_PHASE_ANG_ENG    => axi_rdata <= x"0000" & std_logic_vector(phase_ang_eng);
                        when A_PHASE_REF_DET_CNT=> axi_rdata <= x"0000" & std_logic_vector(phase_ref_det_cnt);
                        when A_PLL_ANG_HIRES    => axi_rdata <= x"0000" & std_logic_vector(pll_ang_hires);
                        when A_PLL_DIV_VALID    => axi_rdata <= x"0000000" & "000" & pll_div_valid;
                        when A_PLL_NCO_INC      => axi_rdata <= std_logic_vector(pll_nco_inc);
                        when A_PLL_NCO_ACCUM    => axi_rdata <= std_logic_vector(pll_nco_accum);
                        when A_PLL_PHASE_ERR    => axi_rdata <= std_logic_vector(pll_phase_err);
                        when A_PLL_P_TERM       => axi_rdata <= std_logic_vector(pll_p_term);
                        when A_PLL_I_TERM       => axi_rdata <= std_logic_vector(pll_i_term);
                        when A_PLL_PI_CORR      => axi_rdata <= std_logic_vector(pll_pi_corr);
                        when A_PLL_NCO_AB_INC   => axi_rdata <= std_logic_vector(nco_ab_inc_int);
                        when A_PLL_CYCLE_AB_CNT => axi_rdata <= x"000000" & std_logic_vector(pll_cycle_ab_count);
                        when A_TRIG_PULSE_COUNT => axi_rdata <= std_logic_vector(trig_pulse_count);
                        when A_CRANK_TOOTH_PER  => axi_rdata <= std_logic_vector(crank_tooth_period);
                        when A_CRANK_GAP_PER    => axi_rdata <= std_logic_vector(crank_gap_period);
                        when A_CRANK_TOOTH_CNT  => axi_rdata <= x"000000" & std_logic_vector(crank_tooth_count);
                        when A_CRANK_AB_COUNT   => axi_rdata <= x"000000" & std_logic_vector(crank_ab_count);
                        when A_CRANK_GAP_DET    => axi_rdata <= x"0000000" & "000" & crank_gap_det;
                        when A_CAM_TOOTH_COUNT  => axi_rdata <= x"000000" & std_logic_vector(cam_tooth_count);
                        when A_REF_ANGLE        => axi_rdata <= x"0000" & std_logic_vector(ref_angle);
                        when A_ENC_AB_COUNT     => axi_rdata <= x"000000" & std_logic_vector(enc_ab_count);
                        when A_ENC_A_COUNT      => axi_rdata <= x"000000" & std_logic_vector(enc_a_count);
                        when A_ENC_B_COUNT      => axi_rdata <= x"000000" & std_logic_vector(enc_b_count);
                        when A_ENC_AB_PERIOD    => axi_rdata <= std_logic_vector(enc_ab_period);
                        when A_FAULT_FLAGS      => axi_rdata <= fault_flags;
                        when A_CAM_FAULT_COUNT  => axi_rdata <= x"0000" & std_logic_vector(cam_fault_count);
                        when A_CRANK_FAULT_CNT  => axi_rdata <= x"0000" & std_logic_vector(crank_fault_count);
                        when A_PHASE_FAULT_CNT  => axi_rdata <= x"0000" & std_logic_vector(phase_fault_count);
                        when A_AB_FAULT_COUNT   => axi_rdata <= x"0000" & std_logic_vector(ab_fault_count);
                        when A_SPEED_FAULT_CNT  => axi_rdata <= x"0000" & std_logic_vector(speed_fault_count);
                        when A_PLL_ERR_COUNT    => axi_rdata <= x"0000" & std_logic_vector(pll_phase_err_count);
                        when A_PKT_COUNT        => axi_rdata <= std_logic_vector(pkt_count);
                        when A_OVF_COUNT        => axi_rdata <= x"0000" & std_logic_vector(ovf_count);
                        when others             => axi_rdata <= (others => '0');
                    end case;
                elsif axi_rvalid = '1' and s_axi_rready = '1' then
                    axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process p_read;

    -- =========================================================================
    -- Config latch and reset counter
    -- =========================================================================
    p_config : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                config_valid          <= '0';
                rst_counter           <= (others => '0');
                div_start             <= '0';
                latch_crank_edge_sel  <= '1';
                latch_src_sel         <= '0';
                latch_ref_sel         <= '0';
                latch_cam_edge_sel    <= '1';
                latch_ang_sel         <= '0';
                latch_gap_thresh      <= x"C0";
                latch_crank_n_teeth   <= to_unsigned(60, 8);
                latch_crank_n_missing <= to_unsigned(2, 8);
                latch_cam_n_teeth     <= to_unsigned(1, 8);
                latch_enc_n_ppr       <= to_unsigned(96, 16);
                latch_enc_ab_edge_sel <= (others => '0');
                latch_enc_z_edge_sel  <= '0';
                latch_dma_buffer_size <= to_unsigned(2, 4);
            else
                div_start <= '0';

                if config_apply_int = '1' then
                    latch_crank_edge_sel  <= reg_control(0);
                    latch_src_sel         <= reg_control(1);
                    latch_ref_sel         <= reg_control(2);
                    latch_cam_edge_sel    <= reg_control(4);
                    latch_ang_sel         <= reg_control(5);
                    latch_gap_thresh      <= unsigned(reg_crank_gap_thresh(7 downto 0));
                    latch_crank_n_teeth   <= unsigned(reg_crank_n_teeth(7 downto 0));
                    latch_crank_n_missing <= unsigned(reg_crank_n_missing(7 downto 0));
                    latch_cam_n_teeth     <= unsigned(reg_cam_n_teeth(7 downto 0));
                    latch_enc_n_ppr       <= unsigned(reg_enc_n_ppr(15 downto 0));
                    latch_enc_ab_edge_sel <= unsigned(reg_enc_ab_edge_sel(1 downto 0));
                    latch_enc_z_edge_sel  <= reg_enc_z_edge_sel(0);
                    latch_dma_buffer_size <= unsigned(reg_dma_buffer_size(3 downto 0));
                    config_valid          <= '1';
                    rst_counter           <= unsigned(reg_rst_cycles(8 downto 0));
                    div_start             <= '1';
                end if;

                if rst_counter > 0 then
                    rst_counter <= rst_counter - 1;
                end if;
            end if;
        end if;
    end process p_config;

    rst_out <= '1' when (config_valid = '0' or rst_counter > 0) else '0';

    -- =========================================================================
    -- Startup divider: pll_nco_ab_inc = 0xFFFFFFFF / ppr
    -- Sequential restoring, 32-bit / 8-bit, max 32 cycles
    -- =========================================================================
    p_divider : process(s_axi_aclk)
        variable step_div : unsigned(63 downto 0);
        variable new_q    : unsigned(31 downto 0);
        variable new_rem  : unsigned(31 downto 0);
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                div_busy       <= '0';
                nco_ab_inc_int <= (others => '0');
            else
                if div_start = '1' and div_busy = '0' then
                    if reg_control(1) = '0' then
                        div_divisor <= unsigned(reg_crank_n_teeth(7 downto 0));
                    else
                        div_divisor <= unsigned(reg_enc_n_ppr(7 downto 0));
                    end if;
                    div_remainder <= (others => '1');
                    div_q         <= (others => '0');
                    div_shift     <= 31;
                    div_busy      <= '1';
                elsif div_busy = '1' then
                    step_div := resize(div_divisor, 64) sll div_shift;
                    new_q    := div_q;
                    new_rem  := div_remainder;
                    if resize(div_remainder, 64) >= step_div then
                        new_rem  := div_remainder - step_div(31 downto 0);
                        new_q(div_shift) := '1';
                    end if;
                    div_q         <= new_q;
                    div_remainder <= new_rem;
                    if div_shift = 0 then
                        div_busy       <= '0';
                        nco_ab_inc_int <= new_q;
                    else
                        div_shift <= div_shift - 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_divider;

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    crank_edge_sel       <= latch_crank_edge_sel;
    src_sel              <= latch_src_sel;
    ref_sel              <= latch_ref_sel;
    cam_edge_sel         <= latch_cam_edge_sel;
    ang_sel              <= latch_ang_sel;
    crank_gap_thresh     <= latch_gap_thresh;
    crank_n_teeth        <= latch_crank_n_teeth;
    crank_n_missing      <= latch_crank_n_missing;
    cam_n_teeth          <= latch_cam_n_teeth;
    enc_n_ppr            <= latch_enc_n_ppr;
    enc_ab_edge_sel      <= latch_enc_ab_edge_sel;
    enc_z_edge_sel       <= latch_enc_z_edge_sel;
    dma_buffer_size      <= latch_dma_buffer_size;
    pll_nco_ab_inc       <= nco_ab_inc_int;
    fault_clear          <= fault_clear_int;
    pll_corr_dir         <= reg_control_rt(1);
    phase_fault_drop     <= reg_control_rt(2);
    cam_debounce         <= unsigned(reg_cam_dbc(15 downto 0));
    crank_debounce       <= unsigned(reg_crank_dbc(15 downto 0));
    enc_a_debounce       <= unsigned(reg_enc_a_dbc(15 downto 0));
    enc_b_debounce       <= unsigned(reg_enc_b_dbc(15 downto 0));
    enc_z_debounce       <= unsigned(reg_enc_z_dbc(15 downto 0));
    phase_ref_ang        <= unsigned(reg_phase_ref_ang(15 downto 0));
    phase_ref_tol        <= unsigned(reg_phase_ref_tol(15 downto 0));
    tdc_offset           <= unsigned(reg_tdc_offset(15 downto 0));
    pll_phase_err_thresh <= unsigned(reg_pll_phase_thresh);
    pll_kp               <= unsigned(reg_pll_kp(15 downto 0));
    pll_ki               <= unsigned(reg_pll_ki(15 downto 0));
    pll_corr_max         <= unsigned(reg_pll_corr_max(15 downto 0));
    trig_decimation      <= unsigned(reg_trig_decimation(15 downto 0));
    trig_pulse_width     <= unsigned(reg_trig_pulse_width(15 downto 0));

end architecture rtl;
