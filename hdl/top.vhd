library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- top.vhd  (v3)
--
-- Angus combustion analyser top-level.
-- Internal angle domain: _angfac (unsigned 32-bit, full scale = 360 crank deg).
-- All degree conversion lives in angus_regs.py on the PS side.
--
-- Block status:
--   COMPLETE: axi_lite_regs, filter(x5), peak_detector, cam, crank, enc,
--             src_sel, ref_sel, angle, phase, sync, speed, pll, ang_sel,
--             tdc, trig, pack, fault
--
-- Debug outputs (16 bits, Pi header):
--   [0]  crank_clean
--   [1]  crank_gap_det
--   [2]  crank_ab          (raw toggle)
--   [3]  crank_z
--   [4]  ab_edge           (widened 10us)
--   [5]  z_edge            (widened 10us)
--   [6]  cam_clean
--   [7]  cam_edge          (widened 10us)
--   [8]  ref_edge          (widened 10us)
--   [9]  phase_ref_det
--   [10] phase_ref_found
--   [11] phase_eng
--   [12] sync_full
--   [13] trig_pulse        (widened 10us)
--   [14] pll_div_valid
--   [15] crank_signal_ok
-- =============================================================================

entity top is
    port (
        clk                : in  std_logic;
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
        m_axis_tdata       : out std_logic_vector(31 downto 0);
        m_axis_tvalid      : out std_logic;
        m_axis_tready      : in  std_logic;
        m_axis_tlast       : out std_logic;
        -- Averaged stream output (to 2nd FIFO/DMA)
        m_avg_axis_tdata   : out std_logic_vector(31 downto 0);
        m_avg_axis_tvalid  : out std_logic;
        m_avg_axis_tready  : in  std_logic;
        m_avg_axis_tlast   : out std_logic;
        cam_raw            : in  std_logic;
        crank_raw          : in  std_logic;
        a_raw              : in  std_logic;
        b_raw              : in  std_logic;
        z_raw              : in  std_logic;
        -- XADC analog inputs (direct pin, VAUX1 = Arduino A0, E17/D18)
        vauxp1             : in  std_logic;
        vauxn1             : in  std_logic;

        -- XADC ILA debug outputs
        xadc_drp_state     : out std_logic_vector(1 downto 0);
        xadc_eoc_out       : out std_logic;
        xadc_eos_out       : out std_logic;
        xadc_busy_out      : out std_logic;
        xadc_channel_out   : out std_logic_vector(4 downto 0);
        xadc_drdy_out      : out std_logic;
        xadc_do_out        : out std_logic_vector(15 downto 0);
        xadc_den_out       : out std_logic;
        xadc_convst_out    : out std_logic;
        di_ch              : in  std_logic_vector(7 downto 0);
        debug_out          : out std_logic_vector(15 downto 0);
        -- =====================================================================
        -- ILA debug outputs -- connect each directly to an ILA probe
        -- (w) = 10us widened pulse via p_debug
        -- =====================================================================
        -- src_sel
        ila_ab_edge                  : out std_logic;
        ila_z_edge                   : out std_logic;
        ila_ab_count                 : out std_logic_vector(7 downto 0);
        ila_ppr_conf                 : out std_logic_vector(7 downto 0);
        ila_ab_period                : out std_logic_vector(31 downto 0);
        -- angle
        ila_angle_angfac             : out std_logic_vector(31 downto 0);
        ila_angle_nco_ab_inc         : out std_logic_vector(31 downto 0);
        ila_angle_nco_clk_inc        : out std_logic_vector(31 downto 0);
        ila_angle_nco_clk_inc_valid  : out std_logic;
        -- ref_sel
        ila_ref_edge                 : out std_logic;
        -- phase
        ila_phase_ref_det            : out std_logic;
        ila_phase_ref_found          : out std_logic;
        ila_phase_eng                : out std_logic;
        ila_phase_ref_angfac         : out std_logic_vector(31 downto 0);
        ila_phase_ref_det_cnt        : out std_logic_vector(15 downto 0);
        -- sync
        ila_sync_state               : out std_logic_vector(1 downto 0);
        ila_sync_full                : out std_logic;
        -- pll
        ila_pll_angfac               : out std_logic_vector(31 downto 0);
        ila_pll_nco_accum            : out std_logic_vector(31 downto 0);
        ila_pll_err_angfac           : out std_logic_vector(31 downto 0);
        ila_pll_p_term               : out std_logic_vector(31 downto 0);
        ila_pll_i_term               : out std_logic_vector(31 downto 0);
        ila_pll_pi_corr              : out std_logic_vector(31 downto 0);
        ila_pll_div_valid            : out std_logic;
        -- ang_sel / tdc / trig
        ila_ang_angfac               : out std_logic_vector(31 downto 0);
        ila_tdc_deg                  : out std_logic_vector(15 downto 0);
        ila_trig_pulse               : out std_logic;
        ila_trig_count               : out std_logic_vector(31 downto 0);
        -- fault
        ila_fault_cam_tooth          : out std_logic;
        ila_fault_crank_tooth        : out std_logic;
        ila_fault_crank_ab           : out std_logic;
        ila_fault_pll_phase          : out std_logic;
        ila_fault_speed_calc         : out std_logic;
        -- avg stream debug
        ila_pack_tvalid              : out std_logic;
        ila_pack_tready              : out std_logic;
        ila_pack_tlast               : out std_logic;
        ila_avg_tvalid               : out std_logic;
        ila_avg_tready               : out std_logic;
        ila_avg_tlast                : out std_logic;
        ila_avg_frame_count          : out std_logic_vector(7 downto 0);
        ila_avg_out_state            : out std_logic_vector(2 downto 0)
    );
end entity top;

architecture rtl of top is

    signal rst             : std_logic;

    -- =========================================================================
    -- AXI config -- startup (latched on config_apply)
    -- =========================================================================
    signal crank_edge_sel  : std_logic;
    signal cam_edge_sel    : std_logic;
    signal enc_ab_edge_sel : unsigned(1 downto 0);
    signal enc_z_edge_sel  : std_logic;
    signal src_sel_cfg     : std_logic;
    signal ref_sel_cfg     : std_logic;
    signal ang_sel_cfg     : std_logic;
    signal angle_interp_en : std_logic;
    signal crank_gap_thresh: unsigned(7 downto 0);
    signal crank_n_teeth   : unsigned(7 downto 0);
    signal crank_n_missing : unsigned(7 downto 0);
    signal cam_n_teeth     : unsigned(7 downto 0);
    signal enc_n_ppr       : unsigned(15 downto 0);
    signal phase_ref_min   : unsigned(31 downto 0);
    signal phase_ref_max   : unsigned(31 downto 0);
    signal dma_buffer_size : unsigned(3 downto 0);

    -- AXI config -- runtime
    signal fault_clear     : std_logic;
    signal pll_corr_dir    : std_logic;
    signal phase_fault_drop: std_logic;
    signal phase_ref_phase : std_logic;
    signal cam_debounce    : unsigned(15 downto 0);
    signal crank_debounce  : unsigned(15 downto 0);
    signal enc_a_debounce  : unsigned(15 downto 0);
    signal enc_b_debounce  : unsigned(15 downto 0);
    signal enc_z_debounce  : unsigned(15 downto 0);
    signal tdc_offset      : unsigned(31 downto 0);
    signal pll_phase_err_thresh: unsigned(31 downto 0);
    signal pll_kp          : unsigned(15 downto 0);
    signal pll_ki          : unsigned(15 downto 0);
    signal pll_corr_max    : unsigned(15 downto 0);
    signal trig_decimation : unsigned(15 downto 0);
    signal peak_hyst       : unsigned(15 downto 0);
    signal max_rpm         : unsigned(15 downto 0);

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
    -- Cam
    -- =========================================================================
    signal cam_edge        : std_logic;
    signal cam_tooth_count : unsigned(7 downto 0);

    -- =========================================================================
    -- Crank
    -- =========================================================================
    signal crank_ab_edge    : std_logic;
    signal crank_z_edge     : std_logic;
    signal crank_ppr_conf   : unsigned(7 downto 0);
    signal crank_tooth_period: unsigned(31 downto 0);
    signal crank_tooth_count : unsigned(7 downto 0);
    signal crank_ab_count   : unsigned(7 downto 0);
    signal crank_gap_det    : std_logic;
    signal crank_signal_ok  : std_logic;
    signal crank_ab         : std_logic;
    signal crank_z          : std_logic;

    -- =========================================================================
    -- Encoder
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
    -- src_sel outputs
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
    signal angle_angfac      : unsigned(31 downto 0);
    signal angle_nco_ab_inc  : unsigned(31 downto 0);
    signal angle_nco_clk_inc : unsigned(31 downto 0);
    signal angle_nco_clk_inc_valid : std_logic;

    -- =========================================================================
    -- Phase block
    -- =========================================================================
    signal phase_ref_det   : std_logic;
    signal phase_ref_ok    : std_logic;
    signal phase_ref_found : std_logic;
    signal phase_eng       : std_logic;
    signal phase_ref_angfac: unsigned(31 downto 0);
    signal phase_ref_det_cnt: unsigned(15 downto 0);

    -- =========================================================================
    -- Sync block
    -- =========================================================================
    signal sync_state      : unsigned(1 downto 0);
    signal sync_full       : std_logic;

    -- =========================================================================
    -- Speed block
    -- =========================================================================
    signal speed_rpm_slow  : unsigned(15 downto 0);
    signal speed_rpm_fast  : unsigned(15 downto 0);

    -- =========================================================================
    -- PLL block
    -- =========================================================================
    signal pll_angfac      : unsigned(31 downto 0);
    signal pll_div_valid   : std_logic;
    signal pll_nco_inc     : unsigned(31 downto 0);
    signal pll_nco_accum   : unsigned(31 downto 0);
    signal pll_err_angfac  : signed(31 downto 0);
    signal pll_p_term      : signed(31 downto 0);
    signal pll_i_term      : signed(31 downto 0);
    signal pll_pi_corr     : signed(31 downto 0);

    -- =========================================================================
    -- ang_sel output
    -- =========================================================================
    signal ang_angfac      : unsigned(31 downto 0);

    -- =========================================================================
    -- TDC block
    -- =========================================================================
    signal tdc_deg         : unsigned(15 downto 0);

    -- =========================================================================
    -- Trig block
    -- =========================================================================
    signal trig_pulse      : std_logic;
    signal trig_count      : unsigned(31 downto 0);

    -- =========================================================================
    -- Pack block
    -- =========================================================================
    signal pkt_count       : unsigned(31 downto 0);
    signal ovf_count       : unsigned(15 downto 0);
    -- avg block signals
    signal avg_n           : unsigned(3 downto 0);
    signal avg_frame_count : unsigned(31 downto 0);

    signal avg_in_beat_count   : unsigned(31 downto 0);
    signal avg_out_beat_count  : unsigned(31 downto 0);
    signal avg_out_tlast_count : unsigned(31 downto 0);
    signal avg_out_stall_count : unsigned(31 downto 0);
    signal avg_bad_tlast_count : unsigned(31 downto 0);
    signal avg_out_state_dbg   : std_logic_vector(2 downto 0);
    -- pack→avg internal stream
    signal pack_tdata      : std_logic_vector(31 downto 0);
    signal pack_tvalid     : std_logic;
    signal pack_tready     : std_logic;
    signal pack_tlast      : std_logic;
    -- avg output stream internals (cannot read 'out' ports directly)
    signal avg_tdata_i     : std_logic_vector(31 downto 0);
    signal avg_tvalid_i    : std_logic;
    signal avg_tlast_i     : std_logic;

    -- =========================================================================
    -- Fault block
    -- =========================================================================
    signal fault_cam_tooth   : std_logic;
    signal fault_crank_tooth : std_logic;
    signal fault_crank_ab    : std_logic;
    signal fault_pll_phase   : std_logic;
    signal fault_speed_calc  : std_logic;
    signal fault_flags     : std_logic_vector(31 downto 0);
    signal cam_fault_count : unsigned(15 downto 0);
    signal crank_fault_count: unsigned(15 downto 0);
    signal phase_fault_count: unsigned(15 downto 0);
    signal ab_fault_count  : unsigned(15 downto 0);
    signal speed_fault_count: unsigned(15 downto 0);
    signal pll_err_count   : unsigned(15 downto 0);

    -- =========================================================================
    -- Debug pulse wideners (10us = 1000 clocks @ 100MHz)
    -- =========================================================================
    constant DBG_WIDTH     : integer := 1000;
    signal dbg_ab_edge     : unsigned(15 downto 0) := (others => '0');
    signal dbg_z_edge      : unsigned(15 downto 0) := (others => '0');
    signal dbg_cam_edge    : unsigned(15 downto 0) := (others => '0');
    signal dbg_ref_edge    : unsigned(15 downto 0) := (others => '0');
    signal dbg_trig_pulse  : unsigned(15 downto 0) := (others => '0');

    -- =========================================================================
    -- XADC buffer: direct XADC primitive, single channel (VAUX1)
    -- adc_ch0 drives peak_detector; adc_ch1-6 unused (single cylinder)
    -- =========================================================================
    signal adc_data  : std_logic_vector(15 downto 0);
    signal adc_ch0   : unsigned(11 downto 0);  -- XADC VAUX1 = pressure sensor


begin

    -- =========================================================================
    -- AXI register file
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
            cam_edge_sel        => cam_edge_sel,
            enc_ab_edge_sel     => enc_ab_edge_sel,
            enc_z_edge_sel      => enc_z_edge_sel,
            src_sel             => src_sel_cfg,
            ref_sel             => ref_sel_cfg,
            ang_sel             => ang_sel_cfg,
            angle_interp_en     => angle_interp_en,
            crank_gap_thresh    => crank_gap_thresh,
            crank_n_teeth       => crank_n_teeth,
            crank_n_missing     => crank_n_missing,
            cam_n_teeth         => cam_n_teeth,
            enc_n_ppr           => enc_n_ppr,
            phase_ref_min       => phase_ref_min,
            phase_ref_max       => phase_ref_max,
            dma_buffer_size     => dma_buffer_size,
            -- Runtime config
            fault_clear         => fault_clear,
            pll_corr_dir        => pll_corr_dir,
            phase_fault_drop    => phase_fault_drop,
            phase_ref_phase     => phase_ref_phase,
            peak_hyst           => peak_hyst,
            cam_debounce        => cam_debounce,
            crank_debounce      => crank_debounce,
            enc_a_debounce      => enc_a_debounce,
            enc_b_debounce      => enc_b_debounce,
            enc_z_debounce      => enc_z_debounce,
            tdc_offset          => tdc_offset,
            pll_phase_err_thresh => pll_phase_err_thresh,
            pll_kp              => pll_kp,
            pll_ki              => pll_ki,
            pll_corr_max        => pll_corr_max,
            trig_decimation     => trig_decimation,
            max_rpm             => max_rpm,
            -- Status inputs
            crank_tooth_period  => crank_tooth_period,
            crank_tooth_count   => crank_tooth_count,
            crank_ab_count      => crank_ab_count,
            cam_tooth_count     => cam_tooth_count,
            enc_ab_period       => enc_ab_period,
            enc_ab_count        => enc_ab_count,
            enc_a_count         => enc_a_count,
            enc_b_count         => enc_b_count,
            angle_angfac        => angle_angfac,
            angle_nco_clk_inc   => angle_nco_clk_inc,
            angle_nco_ab_inc    => angle_nco_ab_inc,
            phase_ref_det       => phase_ref_det,
            phase_ref_found     => phase_ref_found,
            phase_eng           => phase_eng,
            phase_ref_ok        => phase_ref_ok,
            phase_ref_angfac    => phase_ref_angfac,
            phase_ref_det_cnt   => phase_ref_det_cnt,
            sync_state          => sync_state,
            speed_rpm_slow      => speed_rpm_slow,
            speed_rpm_fast      => speed_rpm_fast,
            pll_angfac          => pll_angfac,
            pll_div_valid       => pll_div_valid,
            pll_nco_accum       => pll_nco_accum,
            pll_err_angfac      => pll_err_angfac,
            pll_p_term          => pll_p_term,
            pll_i_term          => pll_i_term,
            pll_pi_corr         => pll_pi_corr,
            pll_nco_inc         => pll_nco_inc,
            trig_count          => trig_count,
            tdc_deg             => tdc_deg,
            fault_flags         => fault_flags,
            cam_fault_count     => cam_fault_count,
            crank_fault_count   => crank_fault_count,
            phase_fault_count   => phase_fault_count,
            ab_fault_count      => ab_fault_count,
            speed_fault_count   => speed_fault_count,
            pll_phase_err_count => pll_err_count,
            pkt_count           => pkt_count,
            ovf_count           => ovf_count,
            avg_n               => avg_n,
            avg_frame_count     => avg_frame_count,

            avg_in_beat_count   => avg_in_beat_count,
            avg_out_beat_count  => avg_out_beat_count,
            avg_out_tlast_count => avg_out_tlast_count,
            avg_out_stall_count => avg_out_stall_count,
            avg_bad_tlast_count => avg_bad_tlast_count
        );

    -- =========================================================================
    -- Filters
    -- =========================================================================
    u_filter_cam   : entity work.filter port map (clk=>clk, rst=>rst, raw=>cam_raw,
                         debounce_cycles=>cam_debounce, clean=>cam_clean);
    u_filter_crank : entity work.filter port map (clk=>clk, rst=>rst, raw=>crank_raw,
                         debounce_cycles=>crank_debounce, clean=>crank_clean);
    u_filter_enc_a : entity work.filter port map (clk=>clk, rst=>rst, raw=>a_raw,
                         debounce_cycles=>enc_a_debounce, clean=>a_clean);
    u_filter_enc_b : entity work.filter port map (clk=>clk, rst=>rst, raw=>b_raw,
                         debounce_cycles=>enc_b_debounce, clean=>b_clean);
    u_filter_enc_z : entity work.filter port map (clk=>clk, rst=>rst, raw=>z_raw,
                         debounce_cycles=>enc_z_debounce, clean=>z_clean);

    -- =========================================================================
    -- Peak detector
    -- =========================================================================
    u_peak : entity work.peak_detector
        port map (clk=>clk, rst=>rst, adc_val=>adc_ch0, z_edge=>z_edge,
                  peak_hyst=>peak_hyst, peak_pulse_cycles=>to_unsigned(1000,16),
                  peak_edge=>peak_edge);

    -- =========================================================================
    -- Cam
    -- =========================================================================
    u_cam : entity work.cam
        port map (clk=>clk, rst=>rst, cam_clean=>cam_clean, z_edge=>z_edge,
                  cam_edge_sel=>cam_edge_sel, cam_edge=>cam_edge,
                  cam_tooth_count=>cam_tooth_count);

    -- =========================================================================
    -- Crank
    -- =========================================================================
    u_crank : entity work.crank
        port map (clk=>clk, rst=>rst, crank_clean=>crank_clean,
                  crank_edge_sel=>crank_edge_sel, crank_gap_thresh=>crank_gap_thresh,
                  crank_n_teeth=>crank_n_teeth, crank_n_missing=>crank_n_missing,
                  crank_ab_edge=>crank_ab_edge, crank_z_edge=>crank_z_edge,
                  crank_ppr_conf=>crank_ppr_conf, crank_tooth_period=>crank_tooth_period,
                  crank_gap_period=>open, crank_tooth_count=>crank_tooth_count,
                  crank_ab_count=>crank_ab_count, crank_gap_det=>crank_gap_det,
                  crank_signal_ok=>crank_signal_ok, crank_ab=>crank_ab, crank_z=>crank_z);

    -- =========================================================================
    -- Encoder
    -- =========================================================================
    u_enc : entity work.enc
        port map (clk=>clk, rst=>rst, a_clean=>a_clean, b_clean=>b_clean, z_clean=>z_clean,
                  enc_ab_edge_sel=>enc_ab_edge_sel, enc_z_edge_sel=>enc_z_edge_sel,
                  enc_n_ppr=>enc_n_ppr, enc_ab_edge=>enc_ab_edge, enc_z_edge=>enc_z_edge,
                  enc_ppr_conf=>enc_ppr_conf, enc_ab_period=>enc_ab_period,
                  enc_ab_count=>enc_ab_count, enc_a_count=>enc_a_count,
                  enc_b_count=>enc_b_count, enc_signal_ok=>enc_signal_ok,
                  enc_fault_count=>enc_fault_count);

    -- =========================================================================
    -- src_sel
    -- =========================================================================
    u_src_sel : entity work.src_sel
        port map (sel=>src_sel_cfg,
                  crank_ab_edge=>crank_ab_edge, crank_z_edge=>crank_z_edge,
                  crank_ppr_conf=>crank_ppr_conf, crank_tooth_period=>crank_tooth_period,
                  crank_ab_count=>crank_ab_count, enc_ab_edge=>enc_ab_edge,
                  enc_z_edge=>enc_z_edge, enc_ppr_conf=>enc_ppr_conf,
                  enc_ab_period=>enc_ab_period, enc_ab_count=>enc_ab_count,
                  ab_edge=>ab_edge, z_edge=>z_edge, ppr_conf=>ppr_conf,
                  ab_period=>ab_period, ab_count=>ab_count);

    -- =========================================================================
    -- ref_sel
    -- =========================================================================
    u_ref_sel : entity work.ref_sel
        port map (sel=>ref_sel_cfg, cam_edge=>cam_edge, peak_edge=>peak_edge,
                  ref_edge=>ref_edge);

    -- =========================================================================
    -- Angle
    -- =========================================================================
    u_angle : entity work.angle
        port map (clk=>clk, rst=>rst, ab_edge=>ab_edge, z_edge=>z_edge,
                  ab_period=>ab_period, ppr_conf=>ppr_conf,
                  angle_interp_en=>angle_interp_en, angle_angfac=>angle_angfac,
                  angle_nco_ab_inc=>angle_nco_ab_inc,
                  angle_nco_clk_inc=>angle_nco_clk_inc,
                  angle_nco_clk_inc_valid=>angle_nco_clk_inc_valid);

    -- =========================================================================
    -- Phase
    -- =========================================================================
    u_phase : entity work.phase
        port map (clk=>clk, rst=>rst, ref_edge=>ref_edge, angle_angfac=>angle_angfac,
                  z_edge=>z_edge, phase_ref_min=>phase_ref_min, phase_ref_max=>phase_ref_max,
                  phase_ref_phase=>phase_ref_phase, phase_ref_det=>phase_ref_det,
                  phase_ref_ok=>phase_ref_ok, phase_ref_found=>phase_ref_found,
                  phase_eng=>phase_eng, phase_ref_angfac=>phase_ref_angfac,
                  phase_ref_det_cnt=>phase_ref_det_cnt);

    -- =========================================================================
    -- Sync
    -- =========================================================================
    u_sync : entity work.sync
        port map (clk=>clk, rst=>rst, ab_edge=>ab_edge, z_edge=>z_edge,
                  ppr_conf=>ppr_conf, ab_count=>ab_count, phase_ref_found=>phase_ref_found,
                  sync_state=>sync_state, sync_full=>sync_full,
                  sync_fault_count=>open);

    -- =========================================================================
    -- Speed
    -- =========================================================================
    u_speed : entity work.speed
        port map (clk=>clk, rst=>rst, ab_edge=>ab_edge, z_edge=>z_edge,
                  ab_period=>ab_period, ppr_conf=>ppr_conf,
                  speed_rpm_slow=>speed_rpm_slow, speed_rpm_fast=>speed_rpm_fast);

    -- =========================================================================
    -- PLL
    -- =========================================================================
    u_pll : entity work.pll
        port map (clk=>clk, rst=>rst, sync_full=>sync_full,
                  ab_edge=>ab_edge, ab_period=>ab_period,
                  z_edge=>z_edge, angle_angfac=>angle_angfac,
                  angle_nco_clk_inc=>angle_nco_clk_inc, pll_kp=>pll_kp,
                  pll_ki=>pll_ki, pll_corr_dir=>pll_corr_dir, pll_corr_max=>pll_corr_max,
                  pll_angfac=>pll_angfac, pll_div_valid=>pll_div_valid,
                  pll_nco_inc=>pll_nco_inc, pll_nco_accum=>pll_nco_accum,
                  pll_err_angfac=>pll_err_angfac, pll_p_term=>pll_p_term,
                  pll_i_term=>pll_i_term, pll_pi_corr=>pll_pi_corr);

    -- =========================================================================
    -- ang_sel
    -- =========================================================================
    u_ang_sel : entity work.ang_sel
        port map (sel=>ang_sel_cfg, angle_angfac=>angle_angfac,
                  pll_angfac=>pll_angfac, ang_angfac=>ang_angfac);

    -- =========================================================================
    -- TDC
    -- =========================================================================
    u_tdc : entity work.tdc
        port map (clk=>clk, rst=>rst, ang_angfac=>ang_angfac,
                  phase_eng=>phase_eng, tdc_offset=>tdc_offset, tdc_deg=>tdc_deg);

    -- =========================================================================
    -- Trig
    -- =========================================================================
    u_trig : entity work.trig
        port map (clk=>clk, rst=>rst, ang_angfac=>ang_angfac, z_edge=>z_edge,
                  trig_decimation=>trig_decimation, trig_pulse=>trig_pulse,
                  trig_count=>trig_count);

    -- =========================================================================
    -- XADC buffer: direct XADC primitive, single channel (VAUX1)
    -- Triggered by trig_pulse (crank-angle-synchronised sampling).
    -- =========================================================================
    u_xadc_buffer : entity work.xadc_buffer
        generic map (NUM_CHANNELS => 1)
        port map (
            clk              => clk,
            rst              => rst,
            vauxp1           => vauxp1,
            vauxn1           => vauxn1,
            sample_pulse     => trig_pulse,
            adc_data         => adc_data,
            conversion_count => open,
            drp_state_out    => xadc_drp_state,
            xadc_eoc_out     => xadc_eoc_out,
            xadc_eos_out     => xadc_eos_out,
            xadc_busy_out    => xadc_busy_out,
            xadc_channel_out => xadc_channel_out,
            xadc_drdy_out    => xadc_drdy_out,
            xadc_do_out      => xadc_do_out,
            xadc_den_out     => xadc_den_out,
            xadc_convst_out  => xadc_convst_out);

    -- Extract 12-bit result: DO format [15:4] = result, [3:0] = 0
    adc_ch0 <= unsigned(adc_data(15 downto 4));

    -- Raw stream: pack output tapped directly to m_axis_* (raw DMA path).
    -- pack_tready driven by raw FIFO tready (m_axis_tready from BD).
    -- avg taps the same stream independently, never stalling pack.
    m_axis_tdata  <= pack_tdata;
    m_axis_tvalid <= pack_tvalid;
    m_axis_tlast  <= pack_tlast;

    -- =========================================================================
    -- Pack
    -- =========================================================================
    u_pack : entity work.pack
        port map (clk=>clk, rst=>rst, trig_pulse=>trig_pulse, tdc_deg=>tdc_deg,
                  di_ch=>di_ch, adc_ch0=>adc_ch0, z_edge=>z_edge,
                  dma_buffer_size=>dma_buffer_size, m_axis_tdata=>pack_tdata,
                  m_axis_tvalid=>pack_tvalid, m_axis_tready=>pack_tready,
                  m_axis_tlast=>pack_tlast, pkt_count=>pkt_count, ovf_count=>ovf_count);

    -- =========================================================================
    -- Avg -- theta-P averaging accumulator
    -- Consumes raw stream from pack, produces:
    --   m_axis_*     : raw stream passthrough (to raw DMA FIFO)
    --   m_avg_axis_* : averaged frames (to avg DMA FIFO)
    -- =========================================================================
    -- Raw stream tready: pack is driven directly by raw FIFO tready.
    -- avg also taps the stream but must never stall pack -- its m_axis_tready
    -- is tied high so the bypass path doesn't gate pack.
    -- avg FIFO overflow is acceptable during heavy averaging (counted separately).
    pack_tready <= m_axis_tready;

    u_avg : entity work.avg
        port map (
            clk              => clk,
            rst              => rst,
            s_axis_tdata     => pack_tdata,
            s_axis_tvalid    => pack_tvalid,
            s_axis_tready    => open,          -- avg must not stall pack
            s_axis_tlast     => pack_tlast,
            m_axis_tdata     => avg_tdata_i,
            m_axis_tvalid    => avg_tvalid_i,
            m_axis_tready    => m_avg_axis_tready,
            m_axis_tlast     => avg_tlast_i,
            avg_n            => avg_n,
            frame_count      => avg_frame_count,

            in_beat_count    => avg_in_beat_count,
            out_beat_count   => avg_out_beat_count,
            out_tlast_count  => avg_out_tlast_count,
            out_stall_count  => avg_out_stall_count,
            bad_tlast_count  => avg_bad_tlast_count,
            out_state_dbg    => avg_out_state_dbg,

            -- New in the bank-ownership refactor; not yet wired to
            -- axi_lite_regs or the ILA pending review -- left open.
            bank_overflow          => open,
            bank_overflow_count    => open,
            in_fifo_overflow_count => open
        );

    -- =========================================================================
    -- Fault
    -- =========================================================================
    u_fault : entity work.fault
        port map (clk=>clk, rst=>rst, fault_clear=>fault_clear, src_sel=>src_sel_cfg,
                  ref_sel=>ref_sel_cfg, cam_tooth_count=>cam_tooth_count,
                  cam_n_teeth=>cam_n_teeth, z_edge=>z_edge, crank_tooth_count=>crank_tooth_count,
                  crank_ab_count=>crank_ab_count, crank_n_teeth=>crank_n_teeth,
                  crank_n_missing=>crank_n_missing, crank_z_edge=>crank_z_edge,
                  ab_count=>ab_count, ppr_conf=>ppr_conf, speed_rpm_slow=>speed_rpm_slow,
                  max_rpm=>max_rpm, pll_phase_err=>pll_err_angfac,
                  pll_phase_err_thresh=>pll_phase_err_thresh, sync_full=>sync_full,
                  phase_fault_drop=>phase_fault_drop, phase_ref_ok=>phase_ref_ok,
                  fault_cam_tooth=>fault_cam_tooth, fault_crank_tooth=>fault_crank_tooth,
                  fault_crank_ab=>fault_crank_ab, fault_pll_phase=>fault_pll_phase,
                  fault_speed_calc=>fault_speed_calc,
                  fault_flags=>fault_flags, cam_fault_count=>cam_fault_count,
                  crank_fault_count=>crank_fault_count, phase_fault_count=>phase_fault_count,
                  ab_fault_count=>ab_fault_count, speed_fault_count=>speed_fault_count,
                  pll_err_count=>pll_err_count);

    -- =========================================================================
    -- Debug pulse wideners
    -- =========================================================================
    p_debug : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                dbg_ab_edge    <= (others => '0');
                dbg_z_edge     <= (others => '0');
                dbg_cam_edge   <= (others => '0');
                dbg_ref_edge   <= (others => '0');
                dbg_trig_pulse <= (others => '0');
            else
                if ab_edge = '1' then
                    dbg_ab_edge <= to_unsigned(DBG_WIDTH - 1, 16);
                elsif dbg_ab_edge > 0 then
                    dbg_ab_edge <= dbg_ab_edge - 1;
                end if;
                if z_edge = '1' then
                    dbg_z_edge <= to_unsigned(DBG_WIDTH - 1, 16);
                elsif dbg_z_edge > 0 then
                    dbg_z_edge <= dbg_z_edge - 1;
                end if;
                if cam_edge = '1' then
                    dbg_cam_edge <= to_unsigned(DBG_WIDTH - 1, 16);
                elsif dbg_cam_edge > 0 then
                    dbg_cam_edge <= dbg_cam_edge - 1;
                end if;
                if ref_edge = '1' then
                    dbg_ref_edge <= to_unsigned(DBG_WIDTH - 1, 16);
                elsif dbg_ref_edge > 0 then
                    dbg_ref_edge <= dbg_ref_edge - 1;
                end if;
                if trig_pulse = '1' then
                    dbg_trig_pulse <= to_unsigned(DBG_WIDTH - 1, 16);
                elsif dbg_trig_pulse > 0 then
                    dbg_trig_pulse <= dbg_trig_pulse - 1;
                end if;
            end if;
        end if;
    end process p_debug;

    -- =========================================================================
    -- Debug output assignments
    -- =========================================================================
    debug_out(0)  <= crank_clean;
    debug_out(1)  <= crank_gap_det;
    debug_out(2)  <= crank_ab;
    debug_out(3)  <= crank_z;
    debug_out(4)  <= '1' when dbg_ab_edge    > 0 else '0';
    debug_out(5)  <= '1' when dbg_z_edge     > 0 else '0';
    debug_out(6)  <= cam_clean;
    debug_out(7)  <= '1' when dbg_cam_edge   > 0 else '0';
    debug_out(8)  <= '1' when dbg_ref_edge   > 0 else '0';
    debug_out(9)  <= phase_ref_det;
    debug_out(10) <= phase_ref_found;
    debug_out(11) <= phase_eng;
    debug_out(12) <= sync_full;
    debug_out(13) <= '1' when dbg_trig_pulse > 0 else '0';
    debug_out(14) <= pll_div_valid;
    debug_out(15) <= crank_signal_ok;

    -- =========================================================================
    -- ILA debug output assignments
    -- (w) signals use p_debug widened versions for scope visibility
    -- =========================================================================
    -- src_sel
    ila_ab_edge                 <= '1' when dbg_ab_edge    > 0 else '0';
    ila_z_edge                  <= '1' when dbg_z_edge     > 0 else '0';
    ila_ab_count                <= std_logic_vector(ab_count);
    ila_ppr_conf                <= std_logic_vector(ppr_conf);
    ila_ab_period               <= std_logic_vector(ab_period);
    -- angle
    ila_angle_angfac            <= std_logic_vector(angle_angfac);
    ila_angle_nco_ab_inc        <= std_logic_vector(angle_nco_ab_inc);
    ila_angle_nco_clk_inc       <= std_logic_vector(angle_nco_clk_inc);
    ila_angle_nco_clk_inc_valid <= angle_nco_clk_inc_valid;
    -- ref_sel
    ila_ref_edge                <= '1' when dbg_ref_edge   > 0 else '0';
    -- phase
    ila_phase_ref_det           <= phase_ref_det;
    ila_phase_ref_found         <= phase_ref_found;
    ila_phase_eng               <= phase_eng;
    ila_phase_ref_angfac        <= std_logic_vector(phase_ref_angfac);
    ila_phase_ref_det_cnt       <= std_logic_vector(phase_ref_det_cnt);
    -- sync
    ila_sync_state              <= std_logic_vector(sync_state);
    ila_sync_full               <= sync_full;
    -- pll
    ila_pll_angfac              <= std_logic_vector(pll_angfac);
    ila_pll_nco_accum           <= std_logic_vector(pll_nco_accum);
    ila_pll_err_angfac          <= std_logic_vector(pll_err_angfac);
    ila_pll_p_term              <= std_logic_vector(pll_p_term);
    ila_pll_i_term              <= std_logic_vector(pll_i_term);
    ila_pll_pi_corr             <= std_logic_vector(pll_pi_corr);
    ila_pll_div_valid           <= pll_div_valid;
    -- ang_sel / tdc / trig
    ila_ang_angfac              <= std_logic_vector(ang_angfac);
    ila_tdc_deg                 <= std_logic_vector(tdc_deg);
    ila_trig_pulse              <= '1' when dbg_trig_pulse > 0 else '0';
    ila_trig_count              <= std_logic_vector(trig_count);
    -- fault
    ila_fault_cam_tooth         <= fault_cam_tooth;
    ila_fault_crank_tooth       <= fault_crank_tooth;
    ila_fault_crank_ab          <= fault_crank_ab;
    ila_fault_pll_phase         <= fault_pll_phase;
    ila_fault_speed_calc        <= fault_speed_calc;

    -- avg stream port assignments
    m_avg_axis_tdata            <= avg_tdata_i;
    m_avg_axis_tvalid           <= avg_tvalid_i;
    m_avg_axis_tlast            <= avg_tlast_i;

    -- avg stream debug
    ila_pack_tvalid             <= pack_tvalid;
    ila_pack_tready             <= pack_tready;
    ila_pack_tlast              <= pack_tlast;
    ila_avg_tvalid              <= avg_tvalid_i;
    ila_avg_tready              <= m_avg_axis_tready;
    ila_avg_tlast               <= avg_tlast_i;
    ila_avg_frame_count         <= std_logic_vector(avg_frame_count(7 downto 0));
    ila_avg_out_state           <= avg_out_state_dbg;

end architecture rtl;
