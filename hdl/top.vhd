library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- top
--
-- Top-level module for combustion analyser PL design.
-- Wires all sub-blocks together.
--
-- Signal chain:
--   crank_raw → signal_conditioner → crank_input → angle_engine → angle_offset
--   cam_raw   → signal_conditioner → phase_detector
--   angle_engine + sync → phase_detector → sync (ref_detected, sync_offset)
--   angle_offset → sample_trigger → sample_packer → AXI Stream DMA
--   sample_pulse → xadc_buffer.convst → xADC → xadc_buffer → sample_packer
--   axi_lite_regs ↔ PS (config/status)
--
-- xADC interface:
--   Event mode: sample_pulse drives convst to trigger conversion sequence
--   eos used as latch trigger (all channels complete after eos)
--   DRP interface held at safe defaults (no runtime reconfiguration)
--
-- Phase 1: xADC pressure input via VAUXP/N[0..5]
-- Phase 2: Replace xadc_buffer with AD7606 SPI interface
-- =============================================================================

entity top is
    port (
        -- PL clock and reset
        clk                : in  std_logic;
        rst_n              : in  std_logic;

        -- Crank sensor input
        crank_raw          : in  std_logic;

        -- Cam sensor input (phase reference)
        cam_raw            : in  std_logic;

        -- Digital inputs (spark flags, injector events etc)
        digital_inputs     : in  std_logic_vector(7 downto 0);

        -- xADC interface
        -- Inputs from xADC Wizard (s_drp expanded + status outputs)
        xadc_do            : in  std_logic_vector(15 downto 0);
        xadc_channel       : in  std_logic_vector(4 downto 0);
        xadc_eoc           : in  std_logic;
        xadc_eos           : in  std_logic;
        xadc_busy          : in  std_logic;
        -- Outputs to xADC Wizard
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

        -- Debug outputs routed to Pi header pins
        debug_out          : out std_logic_vector(11 downto 0)
    );
end entity top;

architecture rtl of top is

    signal rst                  : std_logic;

    -- signal_conditioner outputs
    signal crank_clean          : std_logic;
    signal crank_stable         : std_logic;
    signal cam_clean            : std_logic;
    signal cam_stable           : std_logic;

    -- crank_input outputs
    signal ab                   : std_logic;
    signal z                    : std_logic;
    signal tooth_period         : unsigned(31 downto 0);
    signal tooth_count          : unsigned(7 downto 0);
    signal gap_detected         : std_logic;
    signal signal_present       : std_logic;
    signal edge_pulse_out       : std_logic;
    signal gap_period           : unsigned(31 downto 0);

    -- angle_engine output
    signal raw_angle            : unsigned(15 downto 0);
    signal div_valid            : std_logic;
    signal synced               : std_logic;
    signal nco_inc              : unsigned(31 downto 0);
    signal phase_error          : signed(31 downto 0);
    signal correction           : signed(31 downto 0);

    -- sync outputs
    signal sync_state           : std_logic_vector(2 downto 0);
    signal sync_loss_count      : unsigned(15 downto 0);
    signal phase_fault          : std_logic;
    signal phase_fault_count    : unsigned(15 downto 0);
    signal ab_count             : unsigned(7 downto 0);

    -- phase_detector outputs
    signal ref_detected         : std_logic;
    signal sync_offset          : std_logic;
    signal cam_edge_pulse       : std_logic;
    signal cam_angle            : unsigned(15 downto 0);

    -- angle_offset outputs
    signal crank_angle          : unsigned(15 downto 0);
    signal engine_angle         : unsigned(15 downto 0);

    -- sample_trigger outputs
    signal sample_pulse         : std_logic;
    signal sample_angle         : unsigned(15 downto 0);

    -- xadc_buffer output
    signal adc_data             : std_logic_vector(127 downto 0);

    -- sample_packer outputs
    signal packet_count         : unsigned(31 downto 0);
    signal overflow_count       : unsigned(15 downto 0);

    -- axi_lite_regs outputs
    signal edge_select          : std_logic;
    signal correction_dir       : std_logic;
    signal gap_threshold        : unsigned(7 downto 0);
    signal kp                   : unsigned(15 downto 0);
    signal ki                   : unsigned(15 downto 0);
    signal max_correction       : unsigned(15 downto 0);
    signal expected_phase_angle : unsigned(15 downto 0);
    signal phase_tolerance      : unsigned(15 downto 0);
    signal tdc_offset           : unsigned(15 downto 0);
    signal decimation           : unsigned(7 downto 0);
    signal fault_clear          : std_logic;

begin

    rst <= not rst_n;

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
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            N_TEETH     => 60,
            N_MISSING   => 2
        )
        port map (
            clk            => clk,
            rst            => rst,
            clean_signal   => crank_clean,
            signal_stable  => crank_stable,
            edge_select    => edge_select,
            gap_threshold  => gap_threshold,
            ab             => ab,
            z              => z,
            tooth_period   => tooth_period,
            tooth_count    => tooth_count,
            gap_detected   => gap_detected,
            signal_present => signal_present,
            edge_pulse_out => edge_pulse_out,
            gap_period     => gap_period
        );

    -- =========================================================================
    -- angle_engine
    -- =========================================================================
    u_angle_engine : entity work.angle_engine
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            N_TEETH     => 60
        )
        port map (
            clk            => clk,
            rst            => rst,
            ab             => ab,
            z              => z,
            tooth_period   => tooth_period,
            sync_state     => sync_state,
            kp             => kp,
            ki             => ki,
            max_correction  => max_correction,
            correction_dir  => correction_dir,
            raw_angle       => raw_angle,
            div_valid_out   => div_valid,
            synced_out      => synced,
            nco_inc_out     => nco_inc,
            phase_error_out => phase_error,
            correction_out  => correction
        );

    -- =========================================================================
    -- sync
    -- =========================================================================
    u_sync : entity work.sync
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            N_TEETH     => 60
        )
        port map (
            clk               => clk,
            rst               => rst,
            ab                => ab,
            z                 => z,
            signal_present    => signal_present,
            ref_detected      => ref_detected,
            sync_offset       => sync_offset,
            fault_clear       => fault_clear,
            sync_state        => sync_state,
            sync_loss_count   => sync_loss_count,
            phase_fault_count => phase_fault_count,
            phase_fault       => phase_fault,
            ab_count_out      => ab_count
        );

    -- =========================================================================
    -- phase_detector
    -- Phase 1: cam signal only
    -- Future: add pressure peak detector and mux
    -- =========================================================================
    u_phase_detector : entity work.phase_detector
        port map (
            clk                  => clk,
            rst                  => rst,
            raw_angle            => raw_angle,
            phase_ref            => cam_clean,
            expected_phase_angle => expected_phase_angle,
            phase_tolerance      => phase_tolerance,
            ref_detected         => ref_detected,
            sync_offset          => sync_offset,
            cam_edge_pulse       => cam_edge_pulse,
            cam_angle            => cam_angle
        );

    -- =========================================================================
    -- angle_offset
    -- =========================================================================
    u_angle_offset : entity work.angle_offset
        port map (
            raw_angle    => raw_angle,
            sync_offset  => sync_offset,
            tdc_offset   => tdc_offset,
            crank_angle  => crank_angle,
            engine_angle => engine_angle
        );

    -- =========================================================================
    -- sample_trigger
    -- =========================================================================
    u_sample_trigger : entity work.sample_trigger
        port map (
            clk            => clk,
            rst            => rst,
            engine_angle   => engine_angle,
            sync_state     => sync_state,
            decimation     => decimation,
            sample_pulse   => sample_pulse,
            sample_angle   => sample_angle
        );

    -- =========================================================================
    -- xadc_buffer
    -- convst driven by sample_pulse (event mode trigger)
    -- eos used as latch trigger (all channels complete)
    -- DRP held at safe defaults
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
            edge_select          => edge_select,
            correction_dir       => correction_dir,
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
            engine_angle         => engine_angle,
            synced               => synced,
            ab_count             => ab_count,
            tooth_period         => tooth_period,
            gap_period           => gap_period,
            nco_inc              => nco_inc,
            phase_error          => phase_error,
            correction           => correction,
            cam_angle            => cam_angle
        );

    -- =========================================================================
    -- Debug outputs → Pi header
    -- debug_out[0]  crank_clean     Pi pin 3   W18
    -- debug_out[1]  cam_clean       Pi pin 5   W19
    -- debug_out[2]  edge_pulse_out  Pi pin 7   Y18
    -- debug_out[3]  cam_edge_pulse  Pi pin 29  Y19
    -- debug_out[4]  ab              Pi pin 31  U18
    -- debug_out[5]  z               Pi pin 26  U19
    -- debug_out[6]  gap_detected    Pi pin 32  B20
    -- debug_out[7]  ref_detected    Pi pin 33  B19
    -- debug_out[8]  sample_pulse    Pi pin 22  W10
    -- debug_out[9]  div_valid       Pi pin 36  V6
    -- debug_out[10] signal_present  Pi pin 11  Y6
    -- debug_out[11] synced          Pi pin 12  C20
    -- =========================================================================
    debug_out(0)  <= crank_clean;
    debug_out(1)  <= cam_clean;
    debug_out(2)  <= edge_pulse_out;
    debug_out(3)  <= cam_edge_pulse;
    debug_out(4)  <= ab;
    debug_out(5)  <= z;
    debug_out(6)  <= gap_detected;
    debug_out(7)  <= ref_detected;
    debug_out(8)  <= sample_pulse;
    debug_out(9)  <= div_valid;
    debug_out(10) <= signal_present;
    debug_out(11) <= synced;

end architecture rtl;