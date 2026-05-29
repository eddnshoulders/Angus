library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- top.vhd  (v2 skeleton)
--
-- Angus combustion analyser top-level.
-- Wires all functional blocks together.
-- Synthesises cleanly as a framework; blocks marked TODO will need
-- updating as the architecture refactor progresses.
--
-- Skeleton status:
--   CURRENT:  filter, crank, enc, cam, src_sel, ref_sel, ang_sel
--             phase, sync, speed, pll, trig, pack, fault, peak_detector
--   TODO:     axi_lite_regs  -- register map update required (new addresses,
--                               PEAK_HYST, PEAK_PULSE_CYCLES, MAX_RPM,
--                               angle_interp_en; divider to be removed)
--   TODO:     angle          -- major rewrite (2^32 domain, divider instances,
--                               angle_nco_ab_inc, angle_interp_en)
--   TODO:     pll            -- take angle_nco_ab_inc from angle.vhd
--
-- Debug outputs (22-bit std_logic_vector, Pi header):
--   [0]  crank_clean
--   [1]  cam_clean
--   [2]  crank_ab_edge (widened to 1us)
--   [3]  ref_edge      (widened to 1us)
--   [4]  ab_edge       (widened to 1us)
--   [5]  z_edge        (widened to 1us)
--   [6]  crank_gap_det
--   [7]  phase_ref_det
--   [8]  trig_pulse
--   [9]  pll_div_valid
--   [10] crank_signal_ok
--   [11] sync_full
--   [12] phase_inv_latch
--   [13] phase_ref_found
--   [14:21] unassigned ('0')
-- =============================================================================

entity top is
    port (
        -- Fabric clock (from PS FCLK_CLK0, 100 MHz)
        clk                : in  std_logic;

        -- AXI-Lite slave interface (from PS, same clock domain)
        s_axi_aclk         : in  std_logic;
        s_axi_aresetn      : in  std_logic;
        s_axi_awaddr       : in  std_logic_vector(8 downto 0);
        s_axi_awvalid      : in  std_logic;
        s_axi_awready      : out std_logic;
        s_axi_wdata        : in  std_logic_vector(31 downto 0);
        s_axi_wstrb        : in  std_logic_vector(3 downto 0);
        s_axi_wvalid       : in  std_logic;
        s_axi_wready       : out std_logic;
        s_axi_bresp        : out std_logic_vector(1 downto 0);
        s_axi_bvalid       : out std_logic;
        s_axi_bready       : in  std_logic;
        s_axi_araddr       : in  std_logic_vector(8 downto 0);
        s_axi_arvalid      : in  std_logic;
        s_axi_arready      : out std_logic;
        s_axi_rdata        : out std_logic_vector(31 downto 0);
        s_axi_rresp        : out std_logic_vector(1 downto 0);
        s_axi_rvalid       : out std_logic;
        s_axi_rready       : in  std_logic;

        -- AXI-Stream master (to DMA)
        m_axis_tdata       : out std_logic_vector(31 downto 0);
        m_axis_tvalid      : out std_logic;
        m_axis_tready      : in  std_logic;
        m_axis_tlast       : out std_logic;

        -- Sensor inputs (raw, before filter)
        cam_raw            : in  std_logic;
        crank_raw          : in  std_logic;
        a_raw              : in  std_logic;   -- encoder A
        b_raw              : in  std_logic;   -- encoder B
        z_raw              : in  std_logic;   -- encoder Z

        -- ADC inputs (from XADC or external ADC)
        adc_ch0            : in  unsigned(11 downto 0);  -- peak detector input
        adc_ch1            : in  unsigned(11 downto 0);
        adc_ch2            : in  unsigned(11 downto 0);
        adc_ch3            : in  unsigned(11 downto 0);
        adc_ch4            : in  unsigned(11 downto 0);
        adc_ch5            : in  unsigned(11 downto 0);
        adc_ch6            : in  unsigned(11 downto 0);

        -- Digital inputs
        di_ch              : in  std_logic_vector(7 downto 0);

        -- Debug outputs (Pi header, 22 bits)
        debug_out          : out std_logic_vector(21 downto 0)
    );
end entity top;

architecture rtl of top is

    -- =========================================================================
    -- Reset
    -- =========================================================================
    signal rst             : std_logic;

    -- =========================================================================
    -- AXI-lite config outputs (startup, latched on config_apply)
    -- =========================================================================
    signal crank_edge_sel  : std_logic;
    signal src_sel_cfg     : std_logic;
    signal ref_sel_cfg     : std_logic;
    signal cam_edge_sel    : std_logic;
    signal ang_sel_cfg     : std_logic;
    signal crank_gap_thresh: unsigned(7 downto 0);
    signal crank_n_teeth   : unsigned(7 downto 0);
    signal crank_n_missing : unsigned(7 downto 0);
    signal cam_n_teeth     : unsigned(7 downto 0);
    signal enc_n_ppr       : unsigned(15 downto 0);
    signal enc_ab_edge_sel : unsigned(1 downto 0);
    signal enc_z_edge_sel  : std_logic;
    signal dma_buffer_size : unsigned(3 downto 0);

    -- AXI-lite config outputs (runtime)
    signal fault_clear     : std_logic;
    signal pll_corr_dir    : std_logic;
    signal phase_fault_drop: std_logic;
    signal cam_debounce    : unsigned(15 downto 0);
    signal crank_debounce  : unsigned(15 downto 0);
    signal enc_a_debounce  : unsigned(15 downto 0);
    signal enc_b_debounce  : unsigned(15 downto 0);
    signal enc_z_debounce  : unsigned(15 downto 0);
    signal phase_ref_ang   : unsigned(15 downto 0);
    signal phase_ref_tol   : unsigned(15 downto 0);
    signal tdc_offset      : unsigned(15 downto 0);
    signal pll_phase_err_thresh: unsigned(31 downto 0);
    signal pll_kp          : unsigned(15 downto 0);
    signal pll_ki          : unsigned(15 downto 0);
    signal pll_corr_max    : unsigned(15 downto 0);
    signal trig_decimation : unsigned(15 downto 0);
    signal trig_pulse_width: unsigned(15 downto 0);

    -- From axi_lite_regs (new ports)
    signal peak_hyst        : unsigned(15 downto 0);
    signal peak_pulse_cycles: unsigned(15 downto 0);
    signal max_rpm          : unsigned(15 downto 0);
    signal angle_interp_en  : std_logic;

    -- =========================================================================
    -- Filter outputs
    -- =========================================================================
    signal cam_clean       : std_logic;
    signal crank_clean     : std_logic;
    signal a_clean         : std_logic;
    signal b_clean         : std_logic;
    signal z_clean         : std_logic;

    -- =========================================================================
    -- Peak detector
    -- =========================================================================
    signal peak_edge       : std_logic;

    -- =========================================================================
    -- Cam block
    -- =========================================================================
    signal cam_edge        : std_logic;
    signal cam_tooth_count : unsigned(7 downto 0);

    -- =========================================================================
    -- Crank block
    -- =========================================================================
    signal crank_ab_edge    : std_logic;
    signal crank_z_edge     : std_logic;
    signal crank_ppr_conf   : unsigned(7 downto 0);
    signal crank_tooth_period: unsigned(31 downto 0);
    signal crank_tooth_count : unsigned(7 downto 0);
    signal crank_ab_count   : unsigned(7 downto 0);
    signal crank_gap_det    : std_logic;
    signal crank_gap_period : unsigned(31 downto 0);
    signal crank_signal_ok  : std_logic;
    signal crank_ab         : std_logic;
    signal crank_z          : std_logic;

    -- =========================================================================
    -- Encoder block
    -- =========================================================================
    signal enc_ab_edge     : std_logic;
    signal enc_z_edge      : std_logic;
    signal enc_ppr_conf    : unsigned(7 downto 0);
    signal enc_ab_period   : unsigned(31 downto 0);
    signal enc_ab_count    : unsigned(7 downto 0);
    signal enc_a_count     : unsigned(7 downto 0);
    signal enc_b_count     : unsigned(7 downto 0);
    signal enc_signal_ok   : std_logic;
    signal enc_fault_count : unsigned(7 downto 0);

    -- =========================================================================
    -- src_sel outputs (routed angle source)
    -- =========================================================================
    signal ab_edge         : std_logic;
    signal z_edge          : std_logic;
    signal ppr_conf        : unsigned(7 downto 0);
    signal ab_period       : unsigned(31 downto 0);
    signal ab_count        : unsigned(7 downto 0);

    -- =========================================================================
    -- ref_sel output
    -- =========================================================================
    signal ref_edge        : std_logic;

    -- =========================================================================
    -- Angle block
    -- =========================================================================
    signal angle_deg          : unsigned(15 downto 0);
    signal angle_nco_ab_inc   : unsigned(31 downto 0);  -- from angle, to pll + axi
    signal angle_nco_clk_inc  : unsigned(31 downto 0);  -- from angle, to pll

    -- =========================================================================
    -- Phase block
    -- =========================================================================
    signal phase_raw       : std_logic;
    signal phase_ref_det   : std_logic;
    signal phase_ref_ok    : std_logic;
    signal phase_ref_found : std_logic;
    signal phase_inv       : std_logic;
    signal phase_inv_latch : std_logic;
    signal phase_ang_corr  : unsigned(15 downto 0);
    signal phase_eng       : std_logic;
    signal phase_eng_ang   : unsigned(15 downto 0);  -- was phase_ang_eng
    signal phase_ref_det_cnt: unsigned(15 downto 0);

    -- =========================================================================
    -- Sync block
    -- =========================================================================
    signal sync_state      : unsigned(1 downto 0);
    signal sync_full       : std_logic;
    signal sync_fault_count: unsigned(15 downto 0);

    -- =========================================================================
    -- Speed block
    -- =========================================================================
    signal speed_rpm_slow  : unsigned(15 downto 0);
    signal speed_rpm_fast  : unsigned(15 downto 0);

    -- =========================================================================
    -- PLL block
    -- =========================================================================
    signal pll_ang_hires   : unsigned(15 downto 0);
    signal pll_div_valid   : std_logic;
    signal pll_nco_inc     : unsigned(31 downto 0);
    signal pll_nco_accum   : unsigned(31 downto 0);
    signal pll_phase_err   : signed(31 downto 0);
    signal pll_p_term      : signed(31 downto 0);
    signal pll_i_term      : signed(31 downto 0);
    signal pll_pi_corr     : signed(31 downto 0);
    signal pll_cycle_ab_count: unsigned(7 downto 0);

    -- =========================================================================
    -- ang_sel output
    -- =========================================================================
    signal ang_deg         : unsigned(15 downto 0);

    -- =========================================================================
    -- Trig block
    -- =========================================================================
    signal trig_pulse      : std_logic;
    signal trig_pulse_count: unsigned(31 downto 0);

    -- =========================================================================
    -- Pack block
    -- =========================================================================
    signal pkt_count       : unsigned(31 downto 0);
    signal ovf_count       : unsigned(15 downto 0);

    -- =========================================================================
    -- Fault block
    -- =========================================================================
    signal fault_flags     : std_logic_vector(31 downto 0);
    signal cam_fault_count : unsigned(15 downto 0);
    signal crank_fault_count: unsigned(15 downto 0);
    signal phase_fault_count: unsigned(15 downto 0);
    signal ab_fault_count  : unsigned(15 downto 0);
    signal speed_fault_count: unsigned(15 downto 0);
    signal pll_err_count   : unsigned(15 downto 0);

    -- =========================================================================
    -- Debug pulse wideners (1us = 100 clocks @ 100MHz)
    -- =========================================================================
    constant PULSE_WIDTH   : integer := 100;
    signal dbg_crank_ab    : unsigned(6 downto 0) := (others => '0');
    signal dbg_ref_edge    : unsigned(6 downto 0) := (others => '0');
    signal dbg_ab_edge     : unsigned(6 downto 0) := (others => '0');
    signal dbg_z_edge      : unsigned(6 downto 0) := (others => '0');

begin

    -- =========================================================================
    -- axi_lite_regs
    -- Register map v2: updated addresses, PEAK_HYST, PEAK_PULSE_CYCLES,
    --                  MAX_RPM, angle_interp_en now present
    -- =========================================================================
    u_axi_regs : entity work.axi_lite_regs
        port map (
            s_axi_aclk          => s_axi_aclk,
            s_axi_aresetn       => s_axi_aresetn,
            s_axi_awaddr        => s_axi_awaddr,
            s_axi_awvalid       => s_axi_awvalid,
            s_axi_awready       => s_axi_awready,
            s_axi_wdata         => s_axi_wdata,
            s_axi_wstrb         => s_axi_wstrb,
            s_axi_wvalid        => s_axi_wvalid,
            s_axi_wready        => s_axi_wready,
            s_axi_bresp         => s_axi_bresp,
            s_axi_bvalid        => s_axi_bvalid,
            s_axi_bready        => s_axi_bready,
            s_axi_araddr        => s_axi_araddr,
            s_axi_arvalid       => s_axi_arvalid,
            s_axi_arready       => s_axi_arready,
            s_axi_rdata         => s_axi_rdata,
            s_axi_rresp         => s_axi_rresp,
            s_axi_rvalid        => s_axi_rvalid,
            s_axi_rready        => s_axi_rready,
            rst_out             => rst,
            -- Startup config
            crank_edge_sel      => crank_edge_sel,
            src_sel             => src_sel_cfg,
            ref_sel             => ref_sel_cfg,
            cam_edge_sel        => cam_edge_sel,
            ang_sel             => ang_sel_cfg,
            angle_interp_en     => angle_interp_en,
            crank_gap_thresh    => crank_gap_thresh,
            crank_n_teeth       => crank_n_teeth,
            crank_n_missing     => crank_n_missing,
            cam_n_teeth         => cam_n_teeth,
            enc_n_ppr           => enc_n_ppr,
            enc_ab_edge_sel     => enc_ab_edge_sel,
            enc_z_edge_sel      => enc_z_edge_sel,
            dma_buffer_size     => dma_buffer_size,
            pll_nco_ab_inc      => angle_nco_ab_inc,  -- from angle.vhd
            -- Runtime config
            fault_clear         => fault_clear,
            pll_corr_dir        => pll_corr_dir,
            phase_fault_drop    => phase_fault_drop,
            cam_debounce        => cam_debounce,
            crank_debounce      => crank_debounce,
            enc_a_debounce      => enc_a_debounce,
            enc_b_debounce      => enc_b_debounce,
            enc_z_debounce      => enc_z_debounce,
            phase_ref_ang       => phase_ref_ang,
            phase_ref_tol       => phase_ref_tol,
            tdc_offset          => tdc_offset,
            pll_phase_err_thresh => pll_phase_err_thresh,
            pll_kp              => pll_kp,
            pll_ki              => pll_ki,
            pll_corr_max        => pll_corr_max,
            trig_decimation     => trig_decimation,
            trig_pulse_width    => trig_pulse_width,
            max_rpm             => max_rpm,
            peak_hyst           => peak_hyst,
            peak_pulse_cycles   => peak_pulse_cycles,
            -- Status inputs
            sync_state          => sync_state,
            sync_fault_count    => sync_fault_count,
            speed_rpm_slow      => speed_rpm_slow,
            speed_rpm_fast      => speed_rpm_fast,
            angle_deg           => angle_deg,
            phase_raw           => phase_raw,
            phase_ref_det       => phase_ref_det,
            phase_ref_ok        => phase_ref_ok,
            phase_ref_found     => phase_ref_found,
            phase_inv           => phase_inv,
            phase_inv_latch     => phase_inv_latch,
            phase_ang_corr      => phase_ang_corr,
            phase_eng           => phase_eng,
            phase_ang_eng       => phase_eng_ang,
            phase_ref_det_cnt   => phase_ref_det_cnt,
            pll_ang_hires       => pll_ang_hires,
            pll_div_valid       => pll_div_valid,
            pll_nco_inc         => pll_nco_inc,
            pll_nco_accum       => pll_nco_accum,
            pll_phase_err       => pll_phase_err,
            pll_p_term          => pll_p_term,
            pll_i_term          => pll_i_term,
            pll_pi_corr         => pll_pi_corr,
            pll_cycle_ab_count  => pll_cycle_ab_count,
            trig_pulse_count    => trig_pulse_count,
            crank_tooth_period  => crank_tooth_period,
            crank_gap_period    => crank_gap_period,
            crank_tooth_count   => crank_tooth_count,
            crank_ab_count      => crank_ab_count,
            crank_gap_det       => crank_gap_det,
            cam_tooth_count     => cam_tooth_count,
            ref_angle           => phase_ang_corr,  -- ref_angle = angle at last ref detection
            enc_ab_count        => enc_ab_count,
            enc_a_count         => enc_a_count,
            enc_b_count         => enc_b_count,
            enc_ab_period       => enc_ab_period,
            fault_flags         => fault_flags,
            cam_fault_count     => cam_fault_count,
            crank_fault_count   => crank_fault_count,
            phase_fault_count   => phase_fault_count,
            ab_fault_count      => ab_fault_count,
            speed_fault_count   => speed_fault_count,
            pll_phase_err_count => pll_err_count,
            pkt_count           => pkt_count,
            ovf_count           => ovf_count
        );

    -- =========================================================================
    -- Filters (5 instances)
    -- =========================================================================
    u_filter_cam : entity work.filter
        port map (clk=>clk, rst=>rst, raw=>cam_raw,
                  debounce_cycles=>cam_debounce, clean=>cam_clean);

    u_filter_crank : entity work.filter
        port map (clk=>clk, rst=>rst, raw=>crank_raw,
                  debounce_cycles=>crank_debounce, clean=>crank_clean);

    u_filter_enc_a : entity work.filter
        port map (clk=>clk, rst=>rst, raw=>a_raw,
                  debounce_cycles=>enc_a_debounce, clean=>a_clean);

    u_filter_enc_b : entity work.filter
        port map (clk=>clk, rst=>rst, raw=>b_raw,
                  debounce_cycles=>enc_b_debounce, clean=>b_clean);

    u_filter_enc_z : entity work.filter
        port map (clk=>clk, rst=>rst, raw=>z_raw,
                  debounce_cycles=>enc_z_debounce, clean=>z_clean);

    -- =========================================================================
    -- Peak detector
    -- Telltale/hysteresis peak detector
    -- =========================================================================
    u_peak : entity work.peak_detector
        port map (clk=>clk, rst=>rst,
                  adc_val=>adc_ch0,
                  z_edge=>z_edge,
                  peak_hyst=>peak_hyst,
                  peak_pulse_cycles=>peak_pulse_cycles,
                  peak_edge=>peak_edge);

    -- =========================================================================
    -- Cam
    -- =========================================================================
    u_cam : entity work.cam
        port map (clk=>clk, rst=>rst, cam_clean=>cam_clean,
                  z_edge=>z_edge, cam_edge_sel=>cam_edge_sel,
                  cam_edge=>cam_edge, cam_tooth_count=>cam_tooth_count);

    -- =========================================================================
    -- Crank
    -- =========================================================================
    u_crank : entity work.crank
        port map (clk=>clk, rst=>rst, crank_clean=>crank_clean,
                  crank_edge_sel=>crank_edge_sel,
                  crank_gap_thresh=>crank_gap_thresh,
                  crank_n_teeth=>crank_n_teeth,
                  crank_n_missing=>crank_n_missing,
                  crank_ab_edge=>crank_ab_edge,
                  crank_z_edge=>crank_z_edge,
                  crank_ppr_conf=>crank_ppr_conf,
                  crank_tooth_period=>crank_tooth_period,
                  crank_tooth_count=>crank_tooth_count,
                  crank_ab_count=>crank_ab_count,
                  crank_gap_det=>crank_gap_det,
                  crank_gap_period=>crank_gap_period,
                  crank_signal_ok=>crank_signal_ok,
                  crank_ab=>crank_ab,
                  crank_z=>crank_z);

    -- =========================================================================
    -- Encoder
    -- =========================================================================
    u_enc : entity work.enc
        port map (clk=>clk, rst=>rst,
                  a_clean=>a_clean, b_clean=>b_clean, z_clean=>z_clean,
                  enc_ab_edge_sel=>enc_ab_edge_sel,
                  enc_z_edge_sel=>enc_z_edge_sel,
                  enc_n_ppr=>enc_n_ppr,
                  enc_ab_edge=>enc_ab_edge,
                  enc_z_edge=>enc_z_edge,
                  enc_ppr_conf=>enc_ppr_conf,
                  enc_ab_period=>enc_ab_period,
                  enc_ab_count=>enc_ab_count,
                  enc_a_count=>enc_a_count,
                  enc_b_count=>enc_b_count,
                  enc_signal_ok=>enc_signal_ok,
                  enc_fault_count=>enc_fault_count);

    -- =========================================================================
    -- src_sel
    -- =========================================================================
    u_src_sel : entity work.src_sel
        port map (sel=>src_sel_cfg,
                  crank_ab_edge=>crank_ab_edge,
                  crank_z_edge=>crank_z_edge,
                  crank_ppr_conf=>crank_ppr_conf,
                  crank_tooth_period=>crank_tooth_period,
                  crank_ab_count=>crank_ab_count,
                  enc_ab_edge=>enc_ab_edge,
                  enc_z_edge=>enc_z_edge,
                  enc_ppr_conf=>enc_ppr_conf,
                  enc_ab_period=>enc_ab_period,
                  enc_ab_count=>enc_ab_count,
                  ab_edge=>ab_edge,
                  z_edge=>z_edge,
                  ppr_conf=>ppr_conf,
                  ab_period=>ab_period,
                  ab_count=>ab_count);

    -- =========================================================================
    -- ref_sel
    -- =========================================================================
    u_ref_sel : entity work.ref_sel
        port map (sel=>ref_sel_cfg,
                  cam_edge=>cam_edge,
                  peak_edge=>peak_edge,
                  ref_edge=>ref_edge);

    -- =========================================================================
    -- Angle
    -- TODO: major rewrite -- 2^32 domain, divider instances,
    --       angle_nco_ab_inc, angle_nco_clk_inc, angle_interp_en
    --       Current version used as stub.
    -- =========================================================================
    u_angle : entity work.angle
        port map (clk=>clk, rst=>rst,
                  ab_edge=>ab_edge,
                  z_edge=>z_edge,
                  ab_period=>ab_period,
                  ppr_conf=>ppr_conf,
                  angle_interp_en=>angle_interp_en,
                  angle_deg=>angle_deg,
                  angle_nco_ab_inc=>angle_nco_ab_inc,
                  angle_nco_clk_inc=>angle_nco_clk_inc);

    -- =========================================================================
    -- Phase
    -- TODO: rename phase_ang_eng port to phase_eng_ang in phase.vhd
    -- =========================================================================
    u_phase : entity work.phase
        port map (clk=>clk, rst=>rst,
                  ref_edge=>ref_edge,
                  angle_deg=>angle_deg,
                  z_edge=>z_edge,
                  phase_ref_ang=>phase_ref_ang,
                  phase_ref_tol=>phase_ref_tol,
                  tdc_offset=>tdc_offset,
                  phase_raw=>phase_raw,
                  phase_ref_det=>phase_ref_det,
                  phase_ref_ok=>phase_ref_ok,
                  phase_ref_found=>phase_ref_found,
                  phase_inv=>phase_inv,
                  phase_inv_latch=>phase_inv_latch,
                  phase_ang_corr=>phase_ang_corr,
                  phase_eng=>phase_eng,
                  phase_ang_eng=>phase_eng_ang,
                  phase_ref_det_cnt=>phase_ref_det_cnt);

    -- =========================================================================
    -- Sync
    -- =========================================================================
    u_sync : entity work.sync
        port map (clk=>clk, rst=>rst,
                  ab_edge=>ab_edge,
                  z_edge=>z_edge,
                  ppr_conf=>ppr_conf,
                  ab_count=>ab_count,
                  phase_ref_found=>phase_ref_found,
                  sync_state=>sync_state,
                  sync_full=>sync_full,
                  sync_fault_count=>sync_fault_count);

    -- =========================================================================
    -- Speed
    -- =========================================================================
    u_speed : entity work.speed
        port map (clk=>clk, rst=>rst,
                  ab_edge=>ab_edge,
                  z_edge=>z_edge,
                  ab_period=>ab_period,
                  ppr_conf=>ppr_conf,
                  speed_rpm_slow=>speed_rpm_slow,
                  speed_rpm_fast=>speed_rpm_fast);

    -- =========================================================================
    -- PLL
    -- TODO: take angle_nco_ab_inc from angle.vhd when angle is refactored
    -- =========================================================================
    u_pll : entity work.pll
        port map (clk=>clk, rst=>rst,
                  sync_full=>sync_full,
                  phase_eng=>phase_eng,
                  ab_edge=>ab_edge,
                  ab_period=>ab_period,
                  z_edge=>z_edge,
                  pll_nco_ab_inc=>angle_nco_ab_inc,
                  pll_kp=>pll_kp,
                  pll_ki=>pll_ki,
                  pll_corr_dir=>pll_corr_dir,
                  pll_corr_max=>pll_corr_max,
                  pll_ang_hires=>pll_ang_hires,
                  pll_div_valid=>pll_div_valid,
                  pll_nco_inc=>pll_nco_inc,
                  pll_nco_accum=>pll_nco_accum,
                  pll_phase_err=>pll_phase_err,
                  pll_p_term=>pll_p_term,
                  pll_i_term=>pll_i_term,
                  pll_pi_corr=>pll_pi_corr,
                  pll_cycle_ab_count=>pll_cycle_ab_count);

    -- =========================================================================
    -- ang_sel
    -- =========================================================================
    u_ang_sel : entity work.ang_sel
        port map (sel=>ang_sel_cfg,
                  angle_deg_in=>phase_eng_ang,
                  pll_ang_hires=>pll_ang_hires,
                  ang_deg=>ang_deg);

    -- =========================================================================
    -- Trig
    -- =========================================================================
    u_trig : entity work.trig
        port map (clk=>clk, rst=>rst,
                  ang_deg=>ang_deg,
                  z_edge=>z_edge,
                  trig_decimation=>trig_decimation,
                  trig_pulse_width=>trig_pulse_width,
                  trig_pulse=>trig_pulse,
                  trig_pulse_count=>trig_pulse_count);

    -- =========================================================================
    -- Pack
    -- TODO: fix tlast logic per DMA_BUFFER_SIZE cycles
    -- =========================================================================
    u_pack : entity work.pack
        port map (clk=>clk, rst=>rst,
                  trig_pulse=>trig_pulse,
                  ang_deg=>ang_deg,
                  speed_rpm_fast=>speed_rpm_fast,
                  di_ch=>di_ch,
                  adc_ch1=>adc_ch1,
                  adc_ch2=>adc_ch2,
                  adc_ch3=>adc_ch3,
                  adc_ch4=>adc_ch4,
                  adc_ch5=>adc_ch5,
                  adc_ch6=>adc_ch6,
                  z_edge=>z_edge,
                  dma_buffer_size=>dma_buffer_size,
                  m_axis_tdata=>m_axis_tdata,
                  m_axis_tvalid=>m_axis_tvalid,
                  m_axis_tready=>m_axis_tready,
                  m_axis_tlast=>m_axis_tlast,
                  pkt_count=>pkt_count,
                  ovf_count=>ovf_count);

    -- =========================================================================
    -- Fault
    -- TODO: add fault gating (src_sel/ref_sel), enc faults, MAX_RPM
    -- =========================================================================
    u_fault : entity work.fault
        port map (clk=>clk, rst=>rst,
                  fault_clear=>fault_clear,
                  cam_tooth_count=>cam_tooth_count,
                  cam_n_teeth=>cam_n_teeth,
                  z_edge=>z_edge,
                  crank_tooth_count=>crank_tooth_count,
                  crank_ab_count=>crank_ab_count,
                  crank_n_teeth=>crank_n_teeth,
                  crank_n_missing=>crank_n_missing,
                  crank_z_edge=>crank_z_edge,
                  speed_rpm_slow=>speed_rpm_slow,
                  pll_phase_err=>pll_phase_err,
                  pll_phase_err_thresh=>pll_phase_err_thresh,
                  sync_full=>sync_full,
                  phase_fault_drop=>phase_fault_drop,
                  phase_ref_ok=>phase_ref_ok,
                  fault_flags=>fault_flags,
                  cam_fault_count=>cam_fault_count,
                  crank_fault_count=>crank_fault_count,
                  phase_fault_count=>phase_fault_count,
                  ab_fault_count=>ab_fault_count,
                  speed_fault_count=>speed_fault_count,
                  pll_err_count=>pll_err_count);

    -- =========================================================================
    -- Debug output pulse wideners (1us = 100 clocks)
    -- =========================================================================
    p_debug_pulse : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                dbg_crank_ab <= (others => '0');
                dbg_ref_edge <= (others => '0');
                dbg_ab_edge  <= (others => '0');
                dbg_z_edge   <= (others => '0');
            else
                if crank_ab_edge = '1' then
                    dbg_crank_ab <= to_unsigned(PULSE_WIDTH - 1, 7);
                elsif dbg_crank_ab > 0 then
                    dbg_crank_ab <= dbg_crank_ab - 1;
                end if;

                if ref_edge = '1' then
                    dbg_ref_edge <= to_unsigned(PULSE_WIDTH - 1, 7);
                elsif dbg_ref_edge > 0 then
                    dbg_ref_edge <= dbg_ref_edge - 1;
                end if;

                if ab_edge = '1' then
                    dbg_ab_edge <= to_unsigned(PULSE_WIDTH - 1, 7);
                elsif dbg_ab_edge > 0 then
                    dbg_ab_edge <= dbg_ab_edge - 1;
                end if;

                if z_edge = '1' then
                    dbg_z_edge <= to_unsigned(PULSE_WIDTH - 1, 7);
                elsif dbg_z_edge > 0 then
                    dbg_z_edge <= dbg_z_edge - 1;
                end if;
            end if;
        end if;
    end process p_debug_pulse;

    -- =========================================================================
    -- Debug output assignments
    -- =========================================================================
    debug_out(0)  <= crank_clean;
    debug_out(1)  <= cam_clean;
    debug_out(2)  <= '1' when dbg_crank_ab > 0 else '0';
    debug_out(3)  <= '1' when dbg_ref_edge > 0 else '0';
    debug_out(4)  <= '1' when dbg_ab_edge  > 0 else '0';
    debug_out(5)  <= '1' when dbg_z_edge   > 0 else '0';
    debug_out(6)  <= crank_gap_det;
    debug_out(7)  <= phase_ref_det;
    debug_out(8)  <= trig_pulse;
    debug_out(9)  <= pll_div_valid;
    debug_out(10) <= crank_signal_ok;
    debug_out(11) <= sync_full;
    debug_out(12) <= phase_inv_latch;
    debug_out(13) <= phase_ref_found;
    debug_out(21 downto 14) <= (others => '0');

end architecture rtl;
