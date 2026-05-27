library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- top
--
-- Top-level module for combustion analyser PL design.
--
-- Signal chain:
--   crank_raw  -> signal_conditioner -> crank_input -+
--                                                    +- ang_sel -> angle_calc -> phase_detector
--   enc_input (stub) -----------------------------=--+           -> angle_engine -> sample_trigger
--
--   cam_raw    -> signal_conditioner -> cam_input -+
--                                                  +- ref_sel -> phase_detector
--   peak_detector (stub) -----------------------+-+
--
--   phase_detector -> sync -> angle_engine
--                  -> axi_lite_regs (status)
--
--   angle_engine -> sample_trigger -> sample_packer -> AXI Stream DMA
--
--   axi_lite_regs <-> PS (config/status)
--   config_valid gates rst: design held in reset until PS writes CONFIG_APPLY
-- =============================================================================

entity top is
    port (
        clk                : in  std_logic;
        rst_n              : in  std_logic;

        -- Crank sensor input
        crank_raw          : in  std_logic;

        -- Cam sensor input (phase reference)
        cam_raw            : in  std_logic;

        -- Digital inputs (spark flags, injector events etc)
        digital_inputs     : in  std_logic_vector(7 downto 0);

        -- xADC interface
        xadc_do            : in  std_logic_vector(15 downto 0);
        xadc_channel       : in  std_logic_vector(4 downto 0);
        xadc_eoc           : in  std_logic;
        xadc_eos           : in  std_logic;
        xadc_busy          : in  std_logic;
        xadc_convst        : out std_logic;
        xadc_dclk          : out std_logic;
        xadc_den           : out std_logic;
        xadc_dwe           : out std_logic;
        xadc_daddr         : out std_logic_vector(6 downto 0);
        xadc_di            : out std_logic_vector(15 downto 0);

        -- AXI-Lite slave interface
        s_axi_aclk         : in  std_logic;
        s_axi_aresetn      : in  std_logic;
        s_axi_awaddr       : in  std_logic_vector(6 downto 0);
        s_axi_awvalid      : in  std_logic;
        s_axi_awready      : out std_logic;
        s_axi_wdata        : in  std_logic_vector(31 downto 0);
        s_axi_wstrb        : in  std_logic_vector(3 downto 0);
        s_axi_wvalid       : in  std_logic;
        s_axi_wready       : out std_logic;
        s_axi_bresp        : out std_logic_vector(1 downto 0);
        s_axi_bvalid       : out std_logic;
        s_axi_bready       : in  std_logic;
        s_axi_araddr       : in  std_logic_vector(6 downto 0);
        s_axi_arvalid      : in  std_logic;
        s_axi_arready      : out std_logic;
        s_axi_rdata        : out std_logic_vector(31 downto 0);
        s_axi_rresp        : out std_logic_vector(1 downto 0);
        s_axi_rvalid       : out std_logic;
        s_axi_rready       : in  std_logic;

        -- AXI Stream master to DMA
        m_axis_tdata       : out std_logic_vector(31 downto 0);
        m_axis_tvalid      : out std_logic;
        m_axis_tready      : in  std_logic;
        m_axis_tlast       : out std_logic;

        -- Debug outputs to Pi header
        debug_out          : out std_logic_vector(11 downto 0)
    );
end entity top;

architecture rtl of top is

    -- Reset: hardware reset OR config not yet applied
    signal rst                  : std_logic;
    signal config_valid         : std_logic;

    -- signal_conditioner outputs
    signal crank_clean          : std_logic;
    signal crank_stable         : std_logic;
    signal cam_clean            : std_logic;
    signal cam_stable           : std_logic;

    -- crank_input outputs
    signal crank_ab             : std_logic;
    signal crank_z              : std_logic;
    signal crank_tooth_period   : unsigned(31 downto 0);
    signal crank_tooth_count    : unsigned(7 downto 0);
    signal crank_ppr            : unsigned(7 downto 0);
    signal crank_gap_detected   : std_logic;
    signal crank_signal_present : std_logic;
    signal crank_edge_pulse     : std_logic;
    signal crank_gap_period     : unsigned(31 downto 0);

    -- enc_input outputs (stub)
    signal enc_ab               : std_logic;
    signal enc_z                : std_logic;
    signal enc_ab_period        : unsigned(31 downto 0);
    signal enc_ppr              : unsigned(7 downto 0);
    signal enc_ab_count         : unsigned(7 downto 0);
    signal enc_signal_present   : std_logic;
    signal enc_edge_pulse       : std_logic;

    -- ang_sel outputs
    signal ab                   : std_logic;
    signal z                    : std_logic;
    signal ab_period            : unsigned(31 downto 0);
    signal ppr                  : unsigned(7 downto 0);
    signal ab_count_mux         : unsigned(7 downto 0);
    signal signal_present       : std_logic;

    -- cam_input output
    signal cam_pulse            : std_logic;

    -- peak_detector output (stub)
    signal peak_pulse           : std_logic;

    -- ref_sel output
    signal ref_pulse            : std_logic;

    -- angle_calc outputs
    signal angle_raw            : unsigned(15 downto 0);
    signal phase_calc           : std_logic;
    signal count_fault          : unsigned(15 downto 0);

    -- phase_detector outputs
    signal ref_detected         : std_logic;
    signal phase_offset         : std_logic;
    signal angle_corr           : unsigned(15 downto 0);
    signal ref_edge_pulse       : std_logic;
    signal ref_angle            : unsigned(15 downto 0);

    -- sync outputs
    signal sync_state           : std_logic_vector(2 downto 0);
    signal synced               : std_logic;
    signal phase_engine         : std_logic;
    signal sync_loss_count      : unsigned(15 downto 0);
    signal phase_fault          : std_logic;
    signal phase_fault_count    : unsigned(15 downto 0);
    signal ab_count             : unsigned(7 downto 0);
    signal z_count              : unsigned(15 downto 0);

    -- angle_engine outputs
    signal angle_hires          : unsigned(15 downto 0);
    signal ae_div_valid         : std_logic;
    signal nco_inc              : unsigned(31 downto 0);
    signal nco_accum            : unsigned(31 downto 0);
    signal phase_error          : signed(31 downto 0);
    signal correction           : signed(31 downto 0);

    -- sample_trigger outputs
    signal sample_pulse         : std_logic;
    signal sample_pulse_dbg     : std_logic;
    signal sample_angle         : unsigned(15 downto 0);

    -- xadc_buffer output
    signal adc_data             : std_logic_vector(127 downto 0);

    -- sample_packer outputs
    signal packet_count         : unsigned(31 downto 0);
    signal overflow_count       : unsigned(15 downto 0);

    -- axi_lite_regs config outputs
    signal crank_edge_sel       : std_logic;
    signal cam_edge_sel         : std_logic;
    signal correction_dir       : std_logic;
    signal phase_fault_drop     : std_logic;
    signal ang_sel_s            : std_logic;
    signal ref_sel_s            : std_logic;
    signal config_apply         : std_logic;
    signal gap_threshold        : unsigned(7 downto 0);
    signal kp                   : unsigned(15 downto 0);
    signal ki                   : unsigned(15 downto 0);
    signal max_correction_s     : unsigned(15 downto 0);
    signal expected_cam_ang     : unsigned(15 downto 0);
    signal window_tolerance     : unsigned(15 downto 0);
    signal tdc_offset           : unsigned(15 downto 0);
    signal decimation           : unsigned(7 downto 0);
    signal pulse_width          : unsigned(15 downto 0);
    signal fault_clear          : std_logic;
    signal n_teeth              : unsigned(7 downto 0);
    signal n_missing            : unsigned(7 downto 0);

begin

    -- Reset: hardware OR config not applied yet
    rst <= (not rst_n) or (not config_valid);

    -- =========================================================================
    -- signal_conditioner: crank
    -- =========================================================================
    u_sig_cond_crank : entity work.signal_conditioner
        generic map (DEBOUNCE_CYCLES => 5)
        port map (
            clk            => clk,
            rst            => rst,
            raw_signal     => crank_raw,
            clean_signal   => crank_clean,
            signal_stable  => crank_stable
        );

    -- =========================================================================
    -- signal_conditioner: cam
    -- =========================================================================
    u_sig_cond_cam : entity work.signal_conditioner
        generic map (DEBOUNCE_CYCLES => 5)
        port map (
            clk            => clk,
            rst            => rst,
            raw_signal     => cam_raw,
            clean_signal   => cam_clean,
            signal_stable  => cam_stable
        );

    -- =========================================================================
    -- crank_input
    -- =========================================================================
    u_crank_input : entity work.crank_input
        generic map (CLK_FREQ_HZ => 100_000_000)
        port map (
            clk              => clk,
            rst              => rst,
            clean_signal     => crank_clean,
            signal_stable    => crank_stable,
            crank_edge_sel   => crank_edge_sel,
            gap_threshold    => gap_threshold,
            n_teeth          => n_teeth,
            n_missing        => n_missing,
            ab               => crank_ab,
            z                => crank_z,
            tooth_period     => crank_tooth_period,
            tooth_count      => crank_tooth_count,
            ppr_crank        => crank_ppr,
            gap_detected     => crank_gap_detected,
            signal_present   => crank_signal_present,
            edge_pulse_out   => crank_edge_pulse,
            gap_period       => crank_gap_period
        );

    -- =========================================================================
    -- enc_input (stub)
    -- =========================================================================
    u_enc_input : entity work.enc_input
        port map (
            clk            => clk,
            rst            => rst,
            a_clean        => '0',
            b_clean        => '0',
            z_clean        => '0',
            ab_edge_sel    => '0',
            z_edge_sel     => '0',
            n_teeth        => n_teeth,
            n_pulses       => (others => '0'),
            ab             => enc_ab,
            z              => enc_z,
            tooth_period   => enc_ab_period,
            tooth_count    => enc_ab_count,
            signal_present => enc_signal_present,
            enc_edge_pulse => enc_edge_pulse
        );
    enc_ppr <= n_teeth;  -- stub: use n_teeth as ppr

    -- =========================================================================
    -- ang_sel: select crank or encoder source
    -- =========================================================================
    u_ang_sel : entity work.ang_sel
        port map (
            sel                  => ang_sel_s,
            crank_ab             => crank_ab,
            crank_z              => crank_z,
            crank_ab_period      => crank_tooth_period,
            crank_ppr            => crank_ppr,
            crank_ab_count       => crank_tooth_count,
            crank_signal_present => crank_signal_present,
            enc_ab               => enc_ab,
            enc_z                => enc_z,
            enc_ab_period        => enc_ab_period,
            enc_ppr              => enc_ppr,
            enc_ab_count         => enc_ab_count,
            enc_signal_present   => enc_signal_present,
            ab                   => ab,
            z                    => z,
            ab_period            => ab_period,
            ppr                  => ppr,
            ab_count             => ab_count_mux,
            signal_present       => signal_present
        );

    -- =========================================================================
    -- cam_input: edge detector for cam signal
    -- =========================================================================
    u_cam_input : entity work.cam_input
        port map (
            clk          => clk,
            rst          => rst,
            cam_clean    => cam_clean,
            cam_edge_sel => cam_edge_sel,
            cam_pulse    => cam_pulse
        );

    -- =========================================================================
    -- peak_detector (stub)
    -- =========================================================================
    u_peak_detector : entity work.peak_detector
        port map (
            clk        => clk,
            rst        => rst,
            adc_data   => (others => '0'),
            adc_valid  => '0',
            peak_pulse => peak_pulse
        );

    -- =========================================================================
    -- ref_sel: select cam or peak_detector
    -- =========================================================================
    u_ref_sel : entity work.ref_sel
        port map (
            sel        => ref_sel_s,
            cam_pulse  => cam_pulse,
            peak_pulse => peak_pulse,
            ref_pulse  => ref_pulse
        );

    -- =========================================================================
    -- angle_calc: tooth-based crank angle interpolation
    -- =========================================================================
    u_angle_calc : entity work.angle_calc
        port map (
            clk            => clk,
            rst            => rst,
            ab             => ab,
            z              => z,
            ab_period      => ab_period,
            ppr            => ppr,
            ab_count       => ab_count_mux,
            signal_present => signal_present,
            angle_raw      => angle_raw,
            phase          => phase_calc,
            count_fault    => count_fault
        );

    -- =========================================================================
    -- phase_detector: cam window check, angle_corr calculation
    -- =========================================================================
    u_phase_detector : entity work.phase_detector
        port map (
            clk              => clk,
            rst              => rst,
            angle_raw        => angle_raw,
            phase            => phase_calc,
            ref_pulse        => ref_pulse,
            expected_cam_ang => expected_cam_ang,
            window_tolerance => window_tolerance,
            tdc_offset       => tdc_offset,
            ref_detected     => ref_detected,
            phase_offset     => phase_offset,
            angle_corr       => angle_corr,
            ref_edge_pulse   => ref_edge_pulse,
            ref_angle        => ref_angle
        );

    -- =========================================================================
    -- sync: state machine
    -- =========================================================================
    u_sync : entity work.sync
        port map (
            clk               => clk,
            rst               => rst,
            ab                => ab,
            z                 => z,
            signal_present    => signal_present,
            ref_detected      => ref_detected,
            phase_offset      => phase_offset,
            n_teeth           => n_teeth,
            fault_clear       => fault_clear,
            phase_fault_drop  => phase_fault_drop,
            sync_state        => sync_state,
            synced            => synced,
            phase_engine      => phase_engine,
            sync_loss_count   => sync_loss_count,
            phase_fault_count => phase_fault_count,
            phase_fault       => phase_fault,
            ab_count_out      => ab_count,
            z_count_out       => z_count
        );

    -- =========================================================================
    -- angle_engine: NCO + PI loop
    -- =========================================================================
    u_angle_engine : entity work.angle_engine
        port map (
            clk             => clk,
            rst             => rst,
            ab              => ab,
            z               => z,
            synced          => synced,
            phase_engine    => phase_engine,
            n_teeth         => n_teeth,
            config_apply    => config_apply,
            kp              => kp,
            ki              => ki,
            max_correction  => max_correction_s,
            correction_dir  => correction_dir,
            angle_hires     => angle_hires,
            div_valid_out   => ae_div_valid,
            nco_inc_out     => nco_inc,
            nco_accum_out   => nco_accum,
            phase_error_out => phase_error,
            correction_out  => correction
        );

    -- =========================================================================
    -- sample_trigger
    -- =========================================================================
    u_sample_trigger : entity work.sample_trigger
        port map (
            clk              => clk,
            rst              => rst,
            engine_angle     => angle_hires,
            sync_state       => sync_state,
            decimation       => decimation,
            pulse_width      => pulse_width,
            sample_pulse     => sample_pulse,
            sample_pulse_dbg => sample_pulse_dbg,
            sample_angle     => sample_angle
        );

    -- =========================================================================
    -- xadc_buffer
    -- =========================================================================
    u_xadc_buffer : entity work.xadc_buffer
        generic map (
            NUM_CHANNELS => 8,
            CLK_FREQ_HZ  => 100_000_000
        )
        port map (
            clk              => clk,
            rst              => rst,
            xadc_do          => xadc_do,
            xadc_channel     => xadc_channel,
            xadc_eoc         => xadc_eoc,
            xadc_eos         => xadc_eos,
            xadc_busy        => xadc_busy,
            xadc_convst      => xadc_convst,
            xadc_dclk        => xadc_dclk,
            xadc_den         => xadc_den,
            xadc_dwe         => xadc_dwe,
            xadc_daddr       => xadc_daddr,
            xadc_di          => xadc_di,
            sample_pulse     => sample_pulse,
            adc_data         => adc_data,
            conversion_count => open
        );

    -- =========================================================================
    -- sample_packer
    -- =========================================================================
    u_sample_packer : entity work.sample_packer
        generic map (ADC_CHANNELS => 8)
        port map (
            clk            => clk,
            rst            => rst,
            sample_pulse   => sample_pulse,
            sample_angle   => sample_angle,
            adc_data       => adc_data,
            digital_inputs => digital_inputs,
            m_axis_tdata   => m_axis_tdata,
            m_axis_tvalid  => m_axis_tvalid,
            m_axis_tready  => m_axis_tready,
            m_axis_tlast   => m_axis_tlast,
            packet_count   => packet_count,
            overflow_count => overflow_count
        );

    -- =========================================================================
    -- axi_lite_regs
    -- =========================================================================
    u_axi_lite_regs : entity work.axi_lite_regs
        port map (
            s_axi_aclk           => s_axi_aclk,
            s_axi_aresetn        => s_axi_aresetn,
            s_axi_awaddr         => s_axi_awaddr,
            s_axi_awvalid        => s_axi_awvalid,
            s_axi_awready        => s_axi_awready,
            s_axi_wdata          => s_axi_wdata,
            s_axi_wstrb          => s_axi_wstrb,
            s_axi_wvalid         => s_axi_wvalid,
            s_axi_wready         => s_axi_wready,
            s_axi_bresp          => s_axi_bresp,
            s_axi_bvalid         => s_axi_bvalid,
            s_axi_bready         => s_axi_bready,
            s_axi_araddr         => s_axi_araddr,
            s_axi_arvalid        => s_axi_arvalid,
            s_axi_arready        => s_axi_arready,
            s_axi_rdata          => s_axi_rdata,
            s_axi_rresp          => s_axi_rresp,
            s_axi_rvalid         => s_axi_rvalid,
            s_axi_rready         => s_axi_rready,
            -- Startup config outputs (latched on config_apply)
            crank_edge_sel       => crank_edge_sel,
            cam_edge_sel         => cam_edge_sel,
            ang_sel              => ang_sel_s,
            ref_sel              => ref_sel_s,
            config_valid         => config_valid,
            config_apply_out     => config_apply,
            gap_threshold        => gap_threshold,
            n_teeth              => n_teeth,
            n_missing            => n_missing,
            -- Runtime config outputs
            correction_dir       => correction_dir,
            phase_fault_drop     => phase_fault_drop,
            kp                   => kp,
            ki                   => ki,
            max_correction       => max_correction_s,
            expected_phase_angle => expected_cam_ang,
            phase_tolerance      => window_tolerance,
            tdc_offset           => tdc_offset,
            decimation           => decimation,
            pulse_width          => pulse_width,
            fault_clear          => fault_clear,
            -- Status inputs
            sync_state           => sync_state,
            signal_present       => signal_present,
            phase_fault          => phase_fault,
            sync_loss_count      => sync_loss_count,
            phase_fault_count    => phase_fault_count,
            packet_count         => packet_count,
            overflow_count       => overflow_count,
            -- Debug inputs
            synced               => synced,
            ab_count             => ab_count,
            tooth_period         => crank_tooth_period,
            gap_period           => crank_gap_period,
            nco_inc              => nco_inc,
            phase_error          => phase_error,
            correction           => correction,
            raw_angle            => angle_raw,
            angle_corr           => angle_corr,
            angle_hires          => angle_hires,
            cam_angle            => ref_angle
        );

    -- =========================================================================
    -- Debug outputs -> Pi header
    -- debug_out[0]  crank_clean      Pi pin 3   W18
    -- debug_out[1]  cam_clean        Pi pin 5   W19
    -- debug_out[2]  crank_edge_pulse Pi pin 7   Y18
    -- debug_out[3]  ref_edge_pulse   Pi pin 29  Y19
    -- debug_out[4]  ab               Pi pin 15  U8
    -- debug_out[5]  z                Pi pin 16  W6
    -- debug_out[6]  crank_gap_det    Pi pin 32  B20
    -- debug_out[7]  ref_detected     Pi pin 33  W8
    -- debug_out[8]  sample_pulse_dbg Pi pin 22  W10
    -- debug_out[9]  ae_div_valid     Pi pin 36  B19
    -- debug_out[10] signal_present   Pi pin 19  V8
    -- debug_out[11] synced           Pi pin 12  C20
    -- =========================================================================
    debug_out(0)  <= crank_clean;
    debug_out(1)  <= cam_clean;
    debug_out(2)  <= crank_edge_pulse;
    debug_out(3)  <= ref_edge_pulse;
    debug_out(4)  <= ab;
    debug_out(5)  <= z;
    debug_out(6)  <= crank_gap_detected;
    debug_out(7)  <= ref_detected;
    debug_out(8)  <= sample_pulse_dbg;
    debug_out(9)  <= ae_div_valid;
    debug_out(10) <= signal_present;
    debug_out(11) <= synced;

end architecture rtl;
