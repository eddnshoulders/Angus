library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- axi_lite_regs.vhd  (v3)
-- AXI-Lite slave register file for Angus combustion analyser.
-- 9-bit byte address bus (512 bytes), 4-byte aligned word access.
--
-- All angle values on the AXI interface are in degrees (via angus_regs.py).
-- Conversion to/from angfac units for internal use is done in angus_regs.py.
-- The angle domain note in each register description refers to the PS view.
--
-- Write register map:
--   0x00  CONTROL           startup config bits (see below)
--   0x04  CONTROL_RT        runtime control bits (see below)
--   0x08  RST_CYCLES [8:0]  clock cycles after reset before release (def 256)
--   0x0C  PEAK_HYST  [15:0] peak detector hysteresis (runtime)
--   0x10  CAM_DBC    [15:0] cam debounce cycles (runtime, default 5)
--   0x14  CRANK_DBC  [15:0] crank debounce cycles (runtime, default 5)
--   0x18  ENC_A_DBC  [15:0] encoder A debounce cycles (runtime, default 5)
--   0x1C  ENC_B_DBC  [15:0] encoder B debounce cycles (runtime, default 5)
--   0x20  ENC_Z_DBC  [15:0] encoder Z debounce cycles (runtime, default 5)
--   0x24  CRANK_GAP_THRESH [7:0] gap threshold 1.7fp (startup, default 0xC0)
--   0x28  CRANK_N_TEETH    [7:0] total teeth including missing (startup, def 60)
--   0x2C  CRANK_N_MISSING  [7:0] missing teeth (startup, default 2)
--   0x30  CAM_N_TEETH      [7:0] cam teeth per 2 crank revs (startup, def 1)
--   0x34  ENC_N_PPR        [15:0] encoder pulses per rev (startup)
--   0x38  PHASE_REF_MIN    [31:0] detection window min (angfac, startup)
--   0x3C  PHASE_REF_MAX    [31:0] detection window max (angfac, startup)
--   0x40  PLL_KP           [15:0] PLL proportional gain (runtime, default 0)
--   0x44  PLL_KI           [15:0] PLL integral gain (runtime, default 0)
--   0x48  PLL_CORR_MAX     [15:0] PLL max correction NCO LSB (runtime)
--   0x4C  TRIG_DECIMATION  [15:0] decimation count (runtime, default 1)
--   0x50  MAX_RPM          [15:0] speed fault threshold RPM (runtime, def 6000)
--   0x54  PLL_PHASE_ERR_THRESH [31:0] max PLL phase error NCO units (runtime)
--   0x58  TDC_OFFSET       [31:0] TDC offset from crank Z (angfac, runtime)
--   0x5C  DMA_BUFFER_SIZE  [3:0] engine cycles per DMA buffer (startup, def 2)
--
-- CONTROL [0x00] bits (all startup, latched on config_apply):
--   [0]  crank_edge_sel    0=falling 1=rising
--   [1]  cam_edge_sel      0=falling 1=rising
--   [3:2] enc_ab_edge_sel  0=rising 1=falling 2=both
--   [4]  enc_z_edge_sel    0=rising 1=falling
--   [5]  src_sel           0=crank 1=encoder
--   [6]  ref_sel           0=cam 1=peak_detector
--   [7]  config_apply      self-clearing, latches startup config
--   [8]  ang_sel           0=angle_angfac (tooth-based) 1=pll_angfac
--   [9]  angle_interp_en   0=tooth-snap only 1=Bresenham interpolation
--
-- CONTROL_RT [0x04] bits (all runtime):
--   [0]  fault_clear       self-clearing pulse
--   [1]  pll_corr_dir      0=subtract 1=add correction
--   [2]  phase_fault_drop  0=count only 1=drop to CRANK_SYNC on fault
--   [3]  phase_ref_phase   expected phase_eng value at cam detection
--
-- Read register map:
--   0x70  CAM_TOOTH_COUNT  [7:0]  cam edges per 2 crank revs
--   0x74  CRANK_TOOTH_PERIOD [31:0] last tooth period (clocks)
--   0x78  CRANK_TOOTH_COUNT  [7:0]  real tooth count per revolution
--   0x7C  CRANK_AB_COUNT     [7:0]  all ab edges per rev inc interpolated
--   0x80  ENC_AB_PERIOD      [31:0] encoder ab period (clocks)
--   0x84  ENC_AB_COUNT       [7:0]  encoder ab edge count
--   0x88  ENC_A_COUNT        [7:0]  encoder A channel count
--   0x8C  ENC_B_COUNT        [7:0]  encoder B channel count
--   0x90  ANGLE_ANGFAC       [31:0] tooth-based angle (angfac, 0=360deg)
--   0x94  ANGLE_NCO_CLK_INC  [31:0] interpolation increment per clock
--   0x98  ANGLE_NCO_AB_INC   [31:0] per-tooth increment
--   0x9C  PHASE_REF_ANGFAC   [31:0] angfac at last cam detection
--   0xA0  PHASE_REF_DET      [0]    cam detection strobe
--   0xA4  PHASE_REF_FOUND    [0]    latched 1 after first detection
--   0xA8  PHASE_ENG          [0]    engine phase (0 or 1)
--   0xAC  PHASE_REF_OK       [0]    cam detection healthy
--   0xB0  PHASE_REF_DET_CNT  [15:0] cumulative detection count
--   0xB4  SYNC_STATE         [1:0]  0=STOPPED 1=MOVING 2=CRANK_SYNC 3=FULL
--   0xB8  SPEED_RPM_SLOW     [15:0] RPM from z_period
--   0xBC  SPEED_RPM_FAST     [15:0] RPM from ab_period
--   0xC0  PLL_ANGFAC         [31:0] PLL NCO angle (angfac)
--   0xC4  PLL_DIV_VALID      [0]    PLL active flag
--   0xC8  PLL_NCO_ACCUM      [31:0] raw NCO accumulator (= PLL_ANGFAC)
--   0xCC  PLL_ERR_ANGFAC     [31:0] signed phase error (angfac)
--   0xD0  PLL_P_TERM         [31:0] signed proportional term
--   0xD4  PLL_I_TERM         [31:0] signed integral term
--   0xD8  PLL_PI_CORR        [31:0] signed PI correction
--   0xDC  PLL_NCO_INC        [31:0] current NCO increment per clock
--   0xE0  TRIG_COUNT         [31:0] trigger pulses since last z_edge
--   0xE4  FAULT_FLAGS        [31:0] instantaneous fault flags
--   0xE8  FAULT_CAM_COUNT    [15:0] cam fault event count
--   0xEC  FAULT_CRANK_COUNT  [15:0] crank fault event count
--   0xF0  FAULT_PLL_COUNT    [15:0] phase_ref_ok fault count
--   0xF4  FAULT_AB_COUNT     [15:0] ab count mismatch count
--   0xF8  FAULT_SPEED_COUNT  [15:0] speed fault event count
--   0xFC  FAULT_ENC_COUNT    [15:0] encoder fault event count
--   0x100 TDC_DEG            [15:0] TDC-referenced engine angle (0-7199)
--   0x104 PKT_COUNT          [31:0] DMA packet count
--   0x108 OVF_COUNT          [15:0] DMA overflow count
--   0x10C AVG_N              [3:0]  averaging exponent (0=bypass, N=2^N cycles)
--   0x110 AVG_FRAME_COUNT    [31:0] avg output frames completed
--   0x114 AVG_IN_BEAT_COUNT  [31:0] avg s_axis beats accepted
--   0x118 AVG_OUT_BEAT_COUNT [31:0] avg m_axis beats accepted (tvalid & tready)
--   0x11C AVG_OUT_TLAST_COUNT[31:0] avg m_axis tlast beats accepted
--   0x120 AVG_OUT_STALL_COUNT[31:0] cycles avg m_axis tvalid=1, tready=0
--   0x124 AVG_BAD_TLAST_COUNT[31:0] avg tlast asserted on wrong word (framing bug)
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

        -- Reset output to PL fabric
        rst_out         : out std_logic;

        -- =====================================================================
        -- Startup config outputs (latched on config_apply)
        -- =====================================================================
        crank_edge_sel  : out std_logic;
        cam_edge_sel    : out std_logic;
        enc_ab_edge_sel : out unsigned(1 downto 0);
        enc_z_edge_sel  : out std_logic;
        src_sel         : out std_logic;
        ref_sel         : out std_logic;
        ang_sel         : out std_logic;
        angle_interp_en : out std_logic;
        crank_gap_thresh: out unsigned(7 downto 0);
        crank_n_teeth   : out unsigned(7 downto 0);
        crank_n_missing : out unsigned(7 downto 0);
        cam_n_teeth     : out unsigned(7 downto 0);
        enc_n_ppr       : out unsigned(15 downto 0);
        phase_ref_min   : out unsigned(31 downto 0);  -- detection window min (angfac)
        phase_ref_max   : out unsigned(31 downto 0);  -- detection window max (angfac)
        dma_buffer_size : out unsigned(3 downto 0);

        -- =====================================================================
        -- Runtime config outputs
        -- =====================================================================
        fault_clear     : out std_logic;
        pll_corr_dir    : out std_logic;
        phase_fault_drop: out std_logic;
        phase_ref_phase : out std_logic;              -- expected phase_eng at detection
        peak_hyst       : out unsigned(15 downto 0);
        cam_debounce    : out unsigned(15 downto 0);
        crank_debounce  : out unsigned(15 downto 0);
        enc_a_debounce  : out unsigned(15 downto 0);
        enc_b_debounce  : out unsigned(15 downto 0);
        enc_z_debounce  : out unsigned(15 downto 0);
        tdc_offset      : out unsigned(31 downto 0);  -- TDC offset (angfac)
        pll_phase_err_thresh : out unsigned(31 downto 0);
        pll_kp          : out unsigned(15 downto 0);
        pll_ki          : out unsigned(15 downto 0);
        pll_corr_max    : out unsigned(15 downto 0);
        trig_decimation : out unsigned(15 downto 0);
        max_rpm         : out unsigned(15 downto 0);

        -- =====================================================================
        -- Status inputs
        -- =====================================================================
        -- Crank
        crank_tooth_period : in unsigned(31 downto 0);
        crank_tooth_count  : in unsigned(7 downto 0);
        crank_ab_count     : in unsigned(7 downto 0);
        -- Cam
        cam_tooth_count    : in unsigned(7 downto 0);
        -- Encoder
        enc_ab_period      : in unsigned(31 downto 0);
        enc_ab_count       : in unsigned(7 downto 0);
        enc_a_count        : in unsigned(7 downto 0);
        enc_b_count        : in unsigned(7 downto 0);
        -- Angle
        angle_angfac       : in unsigned(31 downto 0);
        angle_nco_clk_inc  : in unsigned(31 downto 0);
        angle_nco_ab_inc   : in unsigned(31 downto 0);
        -- Phase
        phase_ref_det      : in std_logic;
        phase_ref_found    : in std_logic;
        phase_eng          : in std_logic;
        phase_ref_ok       : in std_logic;
        phase_ref_angfac   : in unsigned(31 downto 0);
        phase_ref_det_cnt  : in unsigned(15 downto 0);
        -- Sync
        sync_state         : in unsigned(1 downto 0);
        -- Speed
        speed_rpm_slow     : in unsigned(15 downto 0);
        speed_rpm_fast     : in unsigned(15 downto 0);
        -- PLL
        pll_angfac         : in unsigned(31 downto 0);
        pll_div_valid      : in std_logic;
        pll_nco_accum      : in unsigned(31 downto 0);
        pll_err_angfac     : in signed(31 downto 0);
        pll_p_term         : in signed(31 downto 0);
        pll_i_term         : in signed(31 downto 0);
        pll_pi_corr        : in signed(31 downto 0);
        pll_nco_inc        : in unsigned(31 downto 0);
        -- Trig
        trig_count         : in unsigned(31 downto 0);
        -- TDC
        tdc_deg            : in unsigned(15 downto 0);
        -- Fault
        fault_flags        : in std_logic_vector(31 downto 0);
        cam_fault_count    : in unsigned(15 downto 0);
        crank_fault_count  : in unsigned(15 downto 0);
        phase_fault_count  : in unsigned(15 downto 0);
        ab_fault_count     : in unsigned(15 downto 0);
        speed_fault_count  : in unsigned(15 downto 0);
        pll_phase_err_count: in unsigned(15 downto 0);
        -- Pack
        pkt_count          : in unsigned(31 downto 0);
        ovf_count          : in unsigned(15 downto 0);
        avg_n              : out unsigned(3 downto 0);

        -- Raw DMA0 path control and diagnostics
        raw_stream_resetn     : out std_logic;
        raw_dropped_pkt_count : in  unsigned(31 downto 0);

        -- Avg diagnostics (direct-sample design, see avg_summary.md)
        avg_frames_in_count     : in unsigned(31 downto 0);
        avg_frames_out_count    : in unsigned(31 downto 0);
        avg_samples_in_count    : in unsigned(31 downto 0);
        avg_missed_sample_count : in unsigned(31 downto 0);
        avg_out_of_order_count  : in unsigned(31 downto 0);
        avg_bank_overrun_count  : in unsigned(31 downto 0);
        avg_dropped_sample_count: in unsigned(31 downto 0);
        avg_out_stall_count     : in unsigned(31 downto 0);
        avg_state_dbg           : in std_logic_vector(7 downto 0)
    );
end entity axi_lite_regs;

architecture rtl of axi_lite_regs is

    -- =========================================================================
    -- Address constants (byte addr / 4 = word index)
    -- =========================================================================
    -- Write
    constant A_CONTROL          : integer := 16#000# / 4;
    constant A_CONTROL_RT       : integer := 16#004# / 4;
    constant A_RST_CYCLES       : integer := 16#008# / 4;
    constant A_PEAK_HYST        : integer := 16#00C# / 4;
    constant A_CAM_DBC          : integer := 16#010# / 4;
    constant A_CRANK_DBC        : integer := 16#014# / 4;
    constant A_ENC_A_DBC        : integer := 16#018# / 4;
    constant A_ENC_B_DBC        : integer := 16#01C# / 4;
    constant A_ENC_Z_DBC        : integer := 16#020# / 4;
    constant A_CRANK_GAP_THRESH : integer := 16#024# / 4;
    constant A_CRANK_N_TEETH    : integer := 16#028# / 4;
    constant A_CRANK_N_MISSING  : integer := 16#02C# / 4;
    constant A_CAM_N_TEETH      : integer := 16#030# / 4;
    constant A_ENC_N_PPR        : integer := 16#034# / 4;
    constant A_PHASE_REF_MIN    : integer := 16#038# / 4;
    constant A_PHASE_REF_MAX    : integer := 16#03C# / 4;
    constant A_PLL_KP           : integer := 16#040# / 4;
    constant A_PLL_KI           : integer := 16#044# / 4;
    constant A_PLL_CORR_MAX     : integer := 16#048# / 4;
    constant A_TRIG_DECIMATION  : integer := 16#04C# / 4;
    constant A_MAX_RPM          : integer := 16#050# / 4;
    constant A_PLL_PHASE_THRESH : integer := 16#054# / 4;
    constant A_TDC_OFFSET       : integer := 16#058# / 4;
    constant A_DMA_BUFFER_SIZE  : integer := 16#05C# / 4;
    constant A_RAW_STREAM_RESET : integer := 16#060# / 4;  -- [0] self-clearing pulse
    -- Read
    constant A_CAM_TOOTH_COUNT  : integer := 16#070# / 4;
    constant A_CRANK_TOOTH_PER  : integer := 16#074# / 4;
    constant A_CRANK_TOOTH_CNT  : integer := 16#078# / 4;
    constant A_CRANK_AB_COUNT   : integer := 16#07C# / 4;
    constant A_ENC_AB_PERIOD    : integer := 16#080# / 4;
    constant A_ENC_AB_COUNT     : integer := 16#084# / 4;
    constant A_ENC_A_COUNT      : integer := 16#088# / 4;
    constant A_ENC_B_COUNT      : integer := 16#08C# / 4;
    constant A_ANGLE_ANGFAC     : integer := 16#090# / 4;
    constant A_ANGLE_NCO_CLK    : integer := 16#094# / 4;
    constant A_ANGLE_NCO_AB     : integer := 16#098# / 4;
    constant A_PHASE_REF_ANGFAC : integer := 16#09C# / 4;
    constant A_PHASE_REF_DET    : integer := 16#0A0# / 4;
    constant A_PHASE_REF_FOUND  : integer := 16#0A4# / 4;
    constant A_PHASE_ENG        : integer := 16#0A8# / 4;
    constant A_PHASE_REF_OK     : integer := 16#0AC# / 4;
    constant A_PHASE_DET_CNT    : integer := 16#0B0# / 4;
    constant A_SYNC_STATE       : integer := 16#0B4# / 4;
    constant A_SPEED_RPM_SLOW   : integer := 16#0B8# / 4;
    constant A_SPEED_RPM_FAST   : integer := 16#0BC# / 4;
    constant A_PLL_ANGFAC       : integer := 16#0C0# / 4;
    constant A_PLL_DIV_VALID    : integer := 16#0C4# / 4;
    constant A_PLL_NCO_ACCUM    : integer := 16#0C8# / 4;
    constant A_PLL_ERR_ANGFAC   : integer := 16#0CC# / 4;
    constant A_PLL_P_TERM       : integer := 16#0D0# / 4;
    constant A_PLL_I_TERM       : integer := 16#0D4# / 4;
    constant A_PLL_PI_CORR      : integer := 16#0D8# / 4;
    constant A_PLL_NCO_INC      : integer := 16#0DC# / 4;
    constant A_TRIG_COUNT       : integer := 16#0E0# / 4;
    constant A_FAULT_FLAGS      : integer := 16#0E4# / 4;
    constant A_FAULT_CAM        : integer := 16#0E8# / 4;
    constant A_FAULT_CRANK      : integer := 16#0EC# / 4;
    constant A_FAULT_PLL        : integer := 16#0F0# / 4;
    constant A_FAULT_AB         : integer := 16#0F4# / 4;
    constant A_FAULT_SPEED      : integer := 16#0F8# / 4;
    constant A_FAULT_ENC        : integer := 16#0FC# / 4;
    constant A_TDC_DEG          : integer := 16#100# / 4;
    constant A_PKT_COUNT        : integer := 16#104# / 4;
    constant A_OVF_COUNT        : integer := 16#108# / 4;
    constant A_AVG_N            : integer := 16#10C# / 4;
    -- avg.vhd status/diagnostic counters. Replaces the old AXI-stream-tap
    -- design's beat/tlast/stall counters (in_beat_count, out_beat_count,
    -- out_tlast_count, out_stall_count, bad_tlast_count) with the direct-
    -- sample design's counter set -- see avg_summary.md.
    constant A_AVG_FRAMES_IN    : integer := 16#110# / 4;
    constant A_AVG_FRAMES_OUT   : integer := 16#114# / 4;
    constant A_AVG_SAMPLES_IN   : integer := 16#118# / 4;
    constant A_AVG_MISSED       : integer := 16#11C# / 4;
    constant A_AVG_OUT_OF_ORDER : integer := 16#120# / 4;
    constant A_AVG_BANK_OVERRUN : integer := 16#124# / 4;
    constant A_AVG_DROPPED      : integer := 16#128# / 4;
    constant A_AVG_OUT_STALL    : integer := 16#12C# / 4;
    constant A_AVG_STATE_DBG    : integer := 16#130# / 4;
    constant A_RAW_DROPPED_PKT  : integer := 16#134# / 4;

    -- =========================================================================
    -- AXI internal
    -- =========================================================================
    signal axi_awready  : std_logic := '0';
    signal axi_wready   : std_logic := '0';
    signal axi_bvalid   : std_logic := '0';
    signal axi_arready  : std_logic := '0';
    signal axi_rvalid   : std_logic := '0';
    signal axi_rdata    : std_logic_vector(31 downto 0) := (others => '0');
    signal aw_addr      : std_logic_vector(8 downto 0)  := (others => '0');
    signal ar_addr      : std_logic_vector(8 downto 0)  := (others => '0');

    -- =========================================================================
    -- Write registers
    -- =========================================================================
    signal reg_control          : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_control_rt       : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_rst_cycles       : std_logic_vector(31 downto 0) := x"00000100";
    signal reg_peak_hyst        : std_logic_vector(31 downto 0) := x"00000080";
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
    signal reg_phase_ref_min    : std_logic_vector(31 downto 0) := x"10000000";
    signal reg_phase_ref_max    : std_logic_vector(31 downto 0) := x"20000000";
    signal reg_pll_kp           : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_pll_ki           : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_pll_corr_max     : std_logic_vector(31 downto 0) := x"0000FFFF";
    signal reg_trig_decimation  : std_logic_vector(31 downto 0) := x"00000001";
    signal reg_max_rpm          : std_logic_vector(31 downto 0) := x"00001770";
    signal reg_pll_phase_thresh : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_tdc_offset       : std_logic_vector(31 downto 0) := x"00000000";
    signal reg_dma_buffer_size  : std_logic_vector(31 downto 0) := x"00000001";
    signal reg_avg_n            : std_logic_vector(31 downto 0) := x"00000000";

    -- =========================================================================
    -- Self-clearing pulses
    -- =========================================================================
    signal config_apply_int : std_logic := '0';
    signal fault_clear_int  : std_logic := '0';
    signal raw_stream_resetn_int : std_logic := '1';

    -- =========================================================================
    -- Startup config latches
    -- =========================================================================
    signal latch_crank_edge_sel : std_logic             := '1';
    signal latch_cam_edge_sel   : std_logic             := '1';
    signal latch_enc_ab_edge_sel: unsigned(1 downto 0)  := (others => '0');
    signal latch_enc_z_edge_sel : std_logic             := '0';
    signal latch_src_sel        : std_logic             := '0';
    signal latch_ref_sel        : std_logic             := '0';
    signal latch_ang_sel        : std_logic             := '0';
    signal latch_angle_interp_en: std_logic             := '0';
    signal latch_gap_thresh     : unsigned(7 downto 0)  := x"C0";
    signal latch_crank_n_teeth  : unsigned(7 downto 0)  := to_unsigned(60, 8);
    signal latch_crank_n_missing: unsigned(7 downto 0)  := to_unsigned(2, 8);
    signal latch_cam_n_teeth    : unsigned(7 downto 0)  := to_unsigned(1, 8);
    signal latch_enc_n_ppr      : unsigned(15 downto 0) := to_unsigned(96, 16);
    signal latch_phase_ref_min  : unsigned(31 downto 0) := x"10000000";
    signal latch_phase_ref_max  : unsigned(31 downto 0) := x"20000000";
    signal latch_dma_buffer_size: unsigned(3 downto 0)  := to_unsigned(1, 4);

    -- =========================================================================
    -- Reset counter
    -- =========================================================================
    signal config_valid : std_logic := '0';
    signal rst_counter  : unsigned(8 downto 0) := (others => '0');

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
    -- AXI write channel
    -- =========================================================================
    p_write : process(s_axi_aclk)
    begin
        if rising_edge(s_axi_aclk) then
            if s_axi_aresetn = '0' then
                axi_awready          <= '0';
                axi_wready           <= '0';
                axi_bvalid           <= '0';
                aw_addr              <= (others => '0');
                config_apply_int     <= '0';
                fault_clear_int      <= '0';
                raw_stream_resetn_int <= '1';
            else
                config_apply_int     <= '0';
                fault_clear_int      <= '0';
                raw_stream_resetn_int <= '1';

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
                            -- Mask out config_apply bit (bit 7) -- self-clears
                            reg_control <= s_axi_wdata and x"FFFFFF7F";
                            if s_axi_wdata(7) = '1' then
                                config_apply_int <= '1';
                            end if;
                        when A_CONTROL_RT =>
                            -- Mask out fault_clear bit (bit 0) -- self-clears
                            reg_control_rt <= s_axi_wdata and x"FFFFFFFE";
                            if s_axi_wdata(0) = '1' then
                                fault_clear_int <= '1';
                            end if;
                        when A_RST_CYCLES       => reg_rst_cycles       <= s_axi_wdata;
                        when A_PEAK_HYST        => reg_peak_hyst        <= s_axi_wdata;
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
                        when A_PHASE_REF_MIN    => reg_phase_ref_min    <= s_axi_wdata;
                        when A_PHASE_REF_MAX    => reg_phase_ref_max    <= s_axi_wdata;
                        when A_PLL_KP           => reg_pll_kp           <= s_axi_wdata;
                        when A_PLL_KI           => reg_pll_ki           <= s_axi_wdata;
                        when A_PLL_CORR_MAX     => reg_pll_corr_max     <= s_axi_wdata;
                        when A_TRIG_DECIMATION  => reg_trig_decimation  <= s_axi_wdata;
                        when A_MAX_RPM          => reg_max_rpm          <= s_axi_wdata;
                        when A_PLL_PHASE_THRESH => reg_pll_phase_thresh <= s_axi_wdata;
                        when A_TDC_OFFSET       => reg_tdc_offset       <= s_axi_wdata;
                        when A_DMA_BUFFER_SIZE  => reg_dma_buffer_size  <= s_axi_wdata;
                        when A_AVG_N            => reg_avg_n            <= s_axi_wdata;
                        when A_RAW_STREAM_RESET =>
                            -- Self-clearing: bit 0 fires a one-cycle pulse,
                            -- not stored in a register.
                            if s_axi_wdata(0) = '1' then
                                raw_stream_resetn_int <= '0';
                            end if;
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
                        -- Write register readback
                        when A_CONTROL          => axi_rdata <= reg_control;
                        when A_CONTROL_RT       => axi_rdata <= reg_control_rt;
                        when A_RST_CYCLES       => axi_rdata <= reg_rst_cycles;
                        when A_PEAK_HYST        => axi_rdata <= reg_peak_hyst;
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
                        when A_PHASE_REF_MIN    => axi_rdata <= reg_phase_ref_min;
                        when A_PHASE_REF_MAX    => axi_rdata <= reg_phase_ref_max;
                        when A_PLL_KP           => axi_rdata <= reg_pll_kp;
                        when A_PLL_KI           => axi_rdata <= reg_pll_ki;
                        when A_PLL_CORR_MAX     => axi_rdata <= reg_pll_corr_max;
                        when A_TRIG_DECIMATION  => axi_rdata <= reg_trig_decimation;
                        when A_MAX_RPM          => axi_rdata <= reg_max_rpm;
                        when A_PLL_PHASE_THRESH => axi_rdata <= reg_pll_phase_thresh;
                        when A_TDC_OFFSET       => axi_rdata <= reg_tdc_offset;
                        when A_DMA_BUFFER_SIZE  => axi_rdata <= reg_dma_buffer_size;
                        -- Read-only status
                        when A_CAM_TOOTH_COUNT  => axi_rdata <= x"000000" & std_logic_vector(cam_tooth_count);
                        when A_CRANK_TOOTH_PER  => axi_rdata <= std_logic_vector(crank_tooth_period);
                        when A_CRANK_TOOTH_CNT  => axi_rdata <= x"000000" & std_logic_vector(crank_tooth_count);
                        when A_CRANK_AB_COUNT   => axi_rdata <= x"000000" & std_logic_vector(crank_ab_count);
                        when A_ENC_AB_PERIOD    => axi_rdata <= std_logic_vector(enc_ab_period);
                        when A_ENC_AB_COUNT     => axi_rdata <= x"000000" & std_logic_vector(enc_ab_count);
                        when A_ENC_A_COUNT      => axi_rdata <= x"000000" & std_logic_vector(enc_a_count);
                        when A_ENC_B_COUNT      => axi_rdata <= x"000000" & std_logic_vector(enc_b_count);
                        when A_ANGLE_ANGFAC     => axi_rdata <= std_logic_vector(angle_angfac);
                        when A_ANGLE_NCO_CLK    => axi_rdata <= std_logic_vector(angle_nco_clk_inc);
                        when A_ANGLE_NCO_AB     => axi_rdata <= std_logic_vector(angle_nco_ab_inc);
                        when A_PHASE_REF_ANGFAC => axi_rdata <= std_logic_vector(phase_ref_angfac);
                        when A_PHASE_REF_DET    => axi_rdata <= x"0000000" & "000" & phase_ref_det;
                        when A_PHASE_REF_FOUND  => axi_rdata <= x"0000000" & "000" & phase_ref_found;
                        when A_PHASE_ENG        => axi_rdata <= x"0000000" & "000" & phase_eng;
                        when A_PHASE_REF_OK     => axi_rdata <= x"0000000" & "000" & phase_ref_ok;
                        when A_PHASE_DET_CNT    => axi_rdata <= x"0000" & std_logic_vector(phase_ref_det_cnt);
                        when A_SYNC_STATE       => axi_rdata <= x"0000000" & "00" & std_logic_vector(sync_state);
                        when A_SPEED_RPM_SLOW   => axi_rdata <= x"0000" & std_logic_vector(speed_rpm_slow);
                        when A_SPEED_RPM_FAST   => axi_rdata <= x"0000" & std_logic_vector(speed_rpm_fast);
                        when A_PLL_ANGFAC       => axi_rdata <= std_logic_vector(pll_angfac);
                        when A_PLL_DIV_VALID    => axi_rdata <= x"0000000" & "000" & pll_div_valid;
                        when A_PLL_NCO_ACCUM    => axi_rdata <= std_logic_vector(pll_nco_accum);
                        when A_PLL_ERR_ANGFAC   => axi_rdata <= std_logic_vector(pll_err_angfac);
                        when A_PLL_P_TERM       => axi_rdata <= std_logic_vector(pll_p_term);
                        when A_PLL_I_TERM       => axi_rdata <= std_logic_vector(pll_i_term);
                        when A_PLL_PI_CORR      => axi_rdata <= std_logic_vector(pll_pi_corr);
                        when A_PLL_NCO_INC      => axi_rdata <= std_logic_vector(pll_nco_inc);
                        when A_TRIG_COUNT       => axi_rdata <= std_logic_vector(trig_count);
                        when A_FAULT_FLAGS      => axi_rdata <= fault_flags;
                        when A_FAULT_CAM        => axi_rdata <= x"0000" & std_logic_vector(cam_fault_count);
                        when A_FAULT_CRANK      => axi_rdata <= x"0000" & std_logic_vector(crank_fault_count);
                        when A_FAULT_PLL        => axi_rdata <= x"0000" & std_logic_vector(phase_fault_count);
                        when A_FAULT_AB         => axi_rdata <= x"0000" & std_logic_vector(ab_fault_count);
                        when A_FAULT_SPEED      => axi_rdata <= x"0000" & std_logic_vector(speed_fault_count);
                        when A_FAULT_ENC        => axi_rdata <= x"0000" & std_logic_vector(pll_phase_err_count);
                        when A_TDC_DEG          => axi_rdata <= x"0000" & std_logic_vector(tdc_deg);
                        when A_PKT_COUNT        => axi_rdata <= std_logic_vector(pkt_count);
                        when A_OVF_COUNT        => axi_rdata <= x"0000" & std_logic_vector(ovf_count);
                        when A_AVG_N            => axi_rdata <= reg_avg_n;
                        when A_AVG_FRAMES_IN     => axi_rdata <= std_logic_vector(avg_frames_in_count);
                        when A_AVG_FRAMES_OUT    => axi_rdata <= std_logic_vector(avg_frames_out_count);
                        when A_AVG_SAMPLES_IN    => axi_rdata <= std_logic_vector(avg_samples_in_count);
                        when A_AVG_MISSED        => axi_rdata <= std_logic_vector(avg_missed_sample_count);
                        when A_AVG_OUT_OF_ORDER  => axi_rdata <= std_logic_vector(avg_out_of_order_count);
                        when A_AVG_BANK_OVERRUN  => axi_rdata <= std_logic_vector(avg_bank_overrun_count);
                        when A_AVG_DROPPED       => axi_rdata <= std_logic_vector(avg_dropped_sample_count);
                        when A_AVG_OUT_STALL     => axi_rdata <= std_logic_vector(avg_out_stall_count);
                        when A_AVG_STATE_DBG     => axi_rdata <= x"000000" & avg_state_dbg;
                        when A_RAW_DROPPED_PKT   => axi_rdata <= std_logic_vector(raw_dropped_pkt_count);
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
                latch_crank_edge_sel  <= '1';
                latch_cam_edge_sel    <= '1';
                latch_enc_ab_edge_sel <= (others => '0');
                latch_enc_z_edge_sel  <= '0';
                latch_src_sel         <= '0';
                latch_ref_sel         <= '0';
                latch_ang_sel         <= '0';
                latch_angle_interp_en <= '0';
                latch_gap_thresh      <= x"C0";
                latch_crank_n_teeth   <= to_unsigned(60, 8);
                latch_crank_n_missing <= to_unsigned(2, 8);
                latch_cam_n_teeth     <= to_unsigned(1, 8);
                latch_enc_n_ppr       <= to_unsigned(96, 16);
                latch_phase_ref_min   <= x"10000000";
                latch_phase_ref_max   <= x"20000000";
                latch_dma_buffer_size <= to_unsigned(1, 4);
            else
                if config_apply_int = '1' then
                    latch_crank_edge_sel  <= reg_control(0);
                    latch_cam_edge_sel    <= reg_control(1);
                    latch_enc_ab_edge_sel <= unsigned(reg_control(3 downto 2));
                    latch_enc_z_edge_sel  <= reg_control(4);
                    latch_src_sel         <= reg_control(5);
                    latch_ref_sel         <= reg_control(6);
                    latch_ang_sel         <= reg_control(8);
                    latch_angle_interp_en <= reg_control(9);
                    latch_gap_thresh      <= unsigned(reg_crank_gap_thresh(7 downto 0));
                    latch_crank_n_teeth   <= unsigned(reg_crank_n_teeth(7 downto 0));
                    latch_crank_n_missing <= unsigned(reg_crank_n_missing(7 downto 0));
                    latch_cam_n_teeth     <= unsigned(reg_cam_n_teeth(7 downto 0));
                    latch_enc_n_ppr       <= unsigned(reg_enc_n_ppr(15 downto 0));
                    latch_phase_ref_min   <= unsigned(reg_phase_ref_min);
                    latch_phase_ref_max   <= unsigned(reg_phase_ref_max);
                    latch_dma_buffer_size <= unsigned(reg_dma_buffer_size(3 downto 0));
                    config_valid          <= '1';
                    rst_counter           <= unsigned(reg_rst_cycles(8 downto 0));
                end if;

                if rst_counter > 0 then
                    rst_counter <= rst_counter - 1;
                end if;
            end if;
        end if;
    end process p_config;

    rst_out <= '1' when (config_valid = '0' or rst_counter > 0) else '0';

    -- =========================================================================
    -- Output assignments
    -- =========================================================================
    -- Startup config (from latches)
    crank_edge_sel   <= latch_crank_edge_sel;
    cam_edge_sel     <= latch_cam_edge_sel;
    enc_ab_edge_sel  <= latch_enc_ab_edge_sel;
    enc_z_edge_sel   <= latch_enc_z_edge_sel;
    src_sel          <= latch_src_sel;
    ref_sel          <= latch_ref_sel;
    ang_sel          <= latch_ang_sel;
    angle_interp_en  <= latch_angle_interp_en;
    crank_gap_thresh <= latch_gap_thresh;
    crank_n_teeth    <= latch_crank_n_teeth;
    crank_n_missing  <= latch_crank_n_missing;
    cam_n_teeth      <= latch_cam_n_teeth;
    enc_n_ppr        <= latch_enc_n_ppr;
    phase_ref_min    <= latch_phase_ref_min;
    phase_ref_max    <= latch_phase_ref_max;
    dma_buffer_size  <= latch_dma_buffer_size;
    avg_n            <= unsigned(reg_avg_n(3 downto 0));
    -- Runtime config (direct from registers)
    fault_clear          <= fault_clear_int;
    raw_stream_resetn    <= raw_stream_resetn_int;
    pll_corr_dir         <= reg_control_rt(1);
    phase_fault_drop     <= reg_control_rt(2);
    phase_ref_phase      <= reg_control_rt(3);
    peak_hyst            <= unsigned(reg_peak_hyst(15 downto 0));
    cam_debounce         <= unsigned(reg_cam_dbc(15 downto 0));
    crank_debounce       <= unsigned(reg_crank_dbc(15 downto 0));
    enc_a_debounce       <= unsigned(reg_enc_a_dbc(15 downto 0));
    enc_b_debounce       <= unsigned(reg_enc_b_dbc(15 downto 0));
    enc_z_debounce       <= unsigned(reg_enc_z_dbc(15 downto 0));
    tdc_offset           <= unsigned(reg_tdc_offset);
    pll_phase_err_thresh <= unsigned(reg_pll_phase_thresh);
    pll_kp               <= unsigned(reg_pll_kp(15 downto 0));
    pll_ki               <= unsigned(reg_pll_ki(15 downto 0));
    pll_corr_max         <= unsigned(reg_pll_corr_max(15 downto 0));
    trig_decimation      <= unsigned(reg_trig_decimation(15 downto 0));
    max_rpm              <= unsigned(reg_max_rpm(15 downto 0));

end architecture rtl;
