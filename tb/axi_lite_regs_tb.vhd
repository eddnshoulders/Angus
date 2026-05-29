File is new
TB is 22308 chars
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std; use std.env.all;

-- =============================================================================
-- axi_lite_regs_tb
--
-- T1: AXI write/read -- write each runtime register, read back, verify
-- T2: config_apply -- write startup config, pulse CONTROL[3], verify latches
--                     and CONTROL[3] self-clears
-- T3: rst_out -- verify rst_out high during RST_CYCLES after config_apply
-- T4: pll_nco_ab_inc -- verify 0xFFFFFFFF/60 = 71582788 (src_sel=0)
-- T5: src_sel divisor -- verify enc_n_ppr used when src_sel=1
-- T6: fault_clear -- verify CONTROL_RT[0] self-clears after one cycle
-- T7: runtime config -- verify direct outputs update without config_apply
-- T8: status readback -- drive status inputs, verify AXI read
-- =============================================================================

entity axi_lite_regs_tb is end entity;

architecture sim of axi_lite_regs_tb is

    constant CLK_PERIOD : time := 10 ns;
    signal clk          : std_logic := '0';
    signal sim_done     : boolean   := false;
    signal test_num     : integer   := 0;

    -- AXI-Lite
    signal aresetn      : std_logic := '0';
    signal awaddr       : std_logic_vector(8 downto 0) := (others => '0');
    signal awvalid      : std_logic := '0';
    signal awready      : std_logic;
    signal wdata        : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb        : std_logic_vector(3 downto 0)  := "1111";
    signal wvalid       : std_logic := '0';
    signal wready       : std_logic;
    signal bresp        : std_logic_vector(1 downto 0);
    signal bvalid       : std_logic;
    signal bready       : std_logic := '1';
    signal araddr       : std_logic_vector(8 downto 0) := (others => '0');
    signal arvalid      : std_logic := '0';
    signal arready      : std_logic;
    signal rdata        : std_logic_vector(31 downto 0);
    signal rresp        : std_logic_vector(1 downto 0);
    signal rvalid       : std_logic;
    signal rready       : std_logic := '1';

    -- DUT outputs
    signal rst_out          : std_logic;
    signal crank_edge_sel   : std_logic;
    signal src_sel          : std_logic;
    signal ref_sel          : std_logic;
    signal cam_edge_sel     : std_logic;
    signal ang_sel          : std_logic;
    signal crank_gap_thresh : unsigned(7 downto 0);
    signal crank_n_teeth    : unsigned(7 downto 0);
    signal crank_n_missing  : unsigned(7 downto 0);
    signal cam_n_teeth      : unsigned(7 downto 0);
    signal enc_n_ppr        : unsigned(15 downto 0);
    signal enc_ab_edge_sel  : unsigned(1 downto 0);
    signal enc_z_edge_sel   : std_logic;
    signal dma_buffer_size  : unsigned(3 downto 0);
    signal pll_nco_ab_inc   : unsigned(31 downto 0);
    signal fault_clear      : std_logic;
    signal pll_corr_dir     : std_logic;
    signal phase_fault_drop : std_logic;
    signal cam_debounce     : unsigned(15 downto 0);
    signal crank_debounce   : unsigned(15 downto 0);
    signal enc_a_debounce   : unsigned(15 downto 0);
    signal enc_b_debounce   : unsigned(15 downto 0);
    signal enc_z_debounce   : unsigned(15 downto 0);
    signal phase_ref_ang    : unsigned(15 downto 0);
    signal phase_ref_tol    : unsigned(15 downto 0);
    signal tdc_offset       : unsigned(15 downto 0);
    signal pll_phase_err_thresh : unsigned(31 downto 0);
    signal pll_kp           : unsigned(15 downto 0);
    signal pll_ki           : unsigned(15 downto 0);
    signal pll_corr_max     : unsigned(15 downto 0);
    signal trig_decimation  : unsigned(15 downto 0);
    signal trig_pulse_width : unsigned(15 downto 0);

    -- Status inputs (driven by TB)
    signal sync_state_in      : unsigned(1 downto 0)  := (others => '0');
    signal sync_fault_cnt_in  : unsigned(15 downto 0) := (others => '0');
    signal speed_slow_in      : unsigned(15 downto 0) := (others => '0');
    signal speed_fast_in      : unsigned(15 downto 0) := (others => '0');
    signal angle_deg_in       : unsigned(15 downto 0) := (others => '0');
    signal phase_raw_in       : std_logic := '0';
    signal phase_ref_det_in   : std_logic := '0';
    signal phase_ref_ok_in    : std_logic := '0';
    signal phase_ref_found_in : std_logic := '0';
    signal phase_inv_in       : std_logic := '0';
    signal phase_inv_latch_in : std_logic := '0';
    signal phase_ang_corr_in  : unsigned(15 downto 0) := (others => '0');
    signal phase_eng_in       : std_logic := '0';
    signal phase_ang_eng_in   : unsigned(15 downto 0) := (others => '0');
    signal phase_ref_det_cnt_in: unsigned(15 downto 0) := (others => '0');
    signal pll_ang_hires_in   : unsigned(15 downto 0) := (others => '0');
    signal pll_div_valid_in   : std_logic := '0';
    signal pll_nco_inc_in     : unsigned(31 downto 0) := (others => '0');
    signal pll_nco_accum_in   : unsigned(31 downto 0) := (others => '0');
    signal pll_phase_err_in   : signed(31 downto 0)   := (others => '0');
    signal pll_p_term_in      : signed(31 downto 0)   := (others => '0');
    signal pll_i_term_in      : signed(31 downto 0)   := (others => '0');
    signal pll_pi_corr_in     : signed(31 downto 0)   := (others => '0');
    signal pll_cycle_ab_cnt_in: unsigned(7 downto 0)  := (others => '0');
    signal trig_pulse_cnt_in  : unsigned(31 downto 0) := (others => '0');
    signal crank_tooth_per_in : unsigned(31 downto 0) := (others => '0');
    signal crank_gap_per_in   : unsigned(31 downto 0) := (others => '0');
    signal crank_tooth_cnt_in : unsigned(7 downto 0)  := (others => '0');
    signal crank_ab_cnt_in    : unsigned(7 downto 0)  := (others => '0');
    signal crank_gap_det_in   : std_logic := '0';
    signal cam_tooth_cnt_in   : unsigned(7 downto 0)  := (others => '0');
    signal ref_angle_in       : unsigned(15 downto 0) := (others => '0');
    signal enc_ab_cnt_in      : unsigned(7 downto 0)  := (others => '0');
    signal enc_a_cnt_in       : unsigned(7 downto 0)  := (others => '0');
    signal enc_b_cnt_in       : unsigned(7 downto 0)  := (others => '0');
    signal enc_ab_per_in      : unsigned(31 downto 0) := (others => '0');
    signal fault_flags_in     : std_logic_vector(31 downto 0) := (others => '0');
    signal cam_fault_cnt_in   : unsigned(15 downto 0) := (others => '0');
    signal crank_fault_cnt_in : unsigned(15 downto 0) := (others => '0');
    signal phase_fault_cnt_in : unsigned(15 downto 0) := (others => '0');
    signal ab_fault_cnt_in    : unsigned(15 downto 0) := (others => '0');
    signal speed_fault_cnt_in : unsigned(15 downto 0) := (others => '0');
    signal pll_err_cnt_in     : unsigned(15 downto 0) := (others => '0');
    signal pkt_cnt_in         : unsigned(31 downto 0) := (others => '0');
    signal ovf_cnt_in         : unsigned(15 downto 0) := (others => '0');

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    dut : entity work.axi_lite_regs
        port map (
            s_axi_aclk      => clk,
            s_axi_aresetn   => aresetn,
            s_axi_awaddr    => awaddr,
            s_axi_awvalid   => awvalid,
            s_axi_awready   => awready,
            s_axi_wdata     => wdata,
            s_axi_wstrb     => wstrb,
            s_axi_wvalid    => wvalid,
            s_axi_wready    => wready,
            s_axi_bresp     => bresp,
            s_axi_bvalid    => bvalid,
            s_axi_bready    => bready,
            s_axi_araddr    => araddr,
            s_axi_arvalid   => arvalid,
            s_axi_arready   => arready,
            s_axi_rdata     => rdata,
            s_axi_rresp     => rresp,
            s_axi_rvalid    => rvalid,
            s_axi_rready    => rready,
            rst_out         => rst_out,
            crank_edge_sel  => crank_edge_sel,
            src_sel         => src_sel,
            ref_sel         => ref_sel,
            cam_edge_sel    => cam_edge_sel,
            ang_sel         => ang_sel,
            crank_gap_thresh => crank_gap_thresh,
            crank_n_teeth   => crank_n_teeth,
            crank_n_missing => crank_n_missing,
            cam_n_teeth     => cam_n_teeth,
            enc_n_ppr       => enc_n_ppr,
            enc_ab_edge_sel => enc_ab_edge_sel,
            enc_z_edge_sel  => enc_z_edge_sel,
            dma_buffer_size => dma_buffer_size,
            pll_nco_ab_inc  => pll_nco_ab_inc,
            fault_clear     => fault_clear,
            pll_corr_dir    => pll_corr_dir,
            phase_fault_drop => phase_fault_drop,
            cam_debounce    => cam_debounce,
            crank_debounce  => crank_debounce,
            enc_a_debounce  => enc_a_debounce,
            enc_b_debounce  => enc_b_debounce,
            enc_z_debounce  => enc_z_debounce,
            phase_ref_ang   => phase_ref_ang,
            phase_ref_tol   => phase_ref_tol,
            tdc_offset      => tdc_offset,
            pll_phase_err_thresh => pll_phase_err_thresh,
            pll_kp          => pll_kp,
            pll_ki          => pll_ki,
            pll_corr_max    => pll_corr_max,
            trig_decimation => trig_decimation,
            trig_pulse_width => trig_pulse_width,
            sync_state      => sync_state_in,
            sync_fault_count => sync_fault_cnt_in,
            speed_rpm_slow  => speed_slow_in,
            speed_rpm_fast  => speed_fast_in,
            angle_deg       => angle_deg_in,
            phase_raw       => phase_raw_in,
            phase_ref_det   => phase_ref_det_in,
            phase_ref_ok    => phase_ref_ok_in,
            phase_ref_found => phase_ref_found_in,
            phase_inv       => phase_inv_in,
            phase_inv_latch => phase_inv_latch_in,
            phase_ang_corr  => phase_ang_corr_in,
            phase_eng       => phase_eng_in,
            phase_ang_eng   => phase_ang_eng_in,
            phase_ref_det_cnt => phase_ref_det_cnt_in,
            pll_ang_hires   => pll_ang_hires_in,
            pll_div_valid   => pll_div_valid_in,
            pll_nco_inc     => pll_nco_inc_in,
            pll_nco_accum   => pll_nco_accum_in,
            pll_phase_err   => pll_phase_err_in,
            pll_p_term      => pll_p_term_in,
            pll_i_term      => pll_i_term_in,
            pll_pi_corr     => pll_pi_corr_in,
            pll_cycle_ab_count => pll_cycle_ab_cnt_in,
            trig_pulse_count => trig_pulse_cnt_in,
            crank_tooth_period => crank_tooth_per_in,
            crank_gap_period => crank_gap_per_in,
            crank_tooth_count => crank_tooth_cnt_in,
            crank_ab_count  => crank_ab_cnt_in,
            crank_gap_det   => crank_gap_det_in,
            cam_tooth_count => cam_tooth_cnt_in,
            ref_angle       => ref_angle_in,
            enc_ab_count    => enc_ab_cnt_in,
            enc_a_count     => enc_a_cnt_in,
            enc_b_count     => enc_b_cnt_in,
            enc_ab_period   => enc_ab_per_in,
            fault_flags     => fault_flags_in,
            cam_fault_count => cam_fault_cnt_in,
            crank_fault_count => crank_fault_cnt_in,
            phase_fault_count => phase_fault_cnt_in,
            ab_fault_count  => ab_fault_cnt_in,
            speed_fault_count => speed_fault_cnt_in,
            pll_phase_err_count => pll_err_cnt_in,
            pkt_count       => pkt_cnt_in,
            ovf_count       => ovf_cnt_in
        );

    p_stim : process

        -- AXI write helper
        procedure axi_write(addr : in integer; data : in std_logic_vector(31 downto 0)) is
        begin
            awaddr  <= std_logic_vector(to_unsigned(addr, 9));
            awvalid <= '1';
            wdata   <= data;
            wvalid  <= '1';
            wait until rising_edge(clk) and awready = '1' and wready = '1';
            awvalid <= '0';
            wvalid  <= '0';
            wait until rising_edge(clk) and bvalid = '1';
            wait for CLK_PERIOD;
        end procedure;

        -- AXI read helper, returns rdata
        procedure axi_read(addr : in integer; data : out std_logic_vector(31 downto 0)) is
        begin
            araddr  <= std_logic_vector(to_unsigned(addr, 9));
            arvalid <= '1';
            wait until rising_edge(clk) and arready = '1';
            arvalid <= '0';
            wait until rising_edge(clk) and rvalid = '1';
            data := rdata;
            wait for CLK_PERIOD;
        end procedure;

        -- Pulse config_apply (CONTROL[3])
        procedure do_config_apply is
        begin
            axi_write(16#000#, x"00000008");  -- CONTROL[3]=1
            wait for CLK_PERIOD;
        end procedure;

        variable rd : std_logic_vector(31 downto 0);

    begin
        -- Release AXI reset
        aresetn <= '0';
        wait for 10 * CLK_PERIOD;
        aresetn <= '1';
        wait for 5 * CLK_PERIOD;

        -- ----------------------------------------------------------------
        -- T1: AXI write/read of runtime registers
        -- ----------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: AXI write/read runtime registers";

        axi_write(16#00C#, x"0000001E");  -- CAM_DBC = 30
        axi_read (16#00C#, rd);
        assert rd = x"0000001E"
            report "FAIL T1: CAM_DBC readback" severity failure;

        axi_write(16#04C#, x"00000100");  -- PLL_KP = 256
        axi_read (16#04C#, rd);
        assert rd = x"00000100"
            report "FAIL T1: PLL_KP readback" severity failure;

        axi_write(16#058#, x"0000000A");  -- TRIG_DECIMATION = 10
        axi_read (16#058#, rd);
        assert rd = x"0000000A"
            report "FAIL T1: TRIG_DECIMATION readback" severity failure;

        axi_write(16#048#, x"DEADBEEF");  -- PLL_PHASE_ERR_THRESH
        axi_read (16#048#, rd);
        assert rd = x"DEADBEEF"
            report "FAIL T1: PLL_PHASE_ERR_THRESH readback" severity failure;

        report "TEST 1: PASS";

        -- ----------------------------------------------------------------
        -- T2: config_apply latches startup config
        -- ----------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: config_apply latches startup config";

        -- Write startup registers
        axi_write(16#024#, x"00000028");  -- CRANK_N_TEETH = 40
        axi_write(16#028#, x"00000001");  -- CRANK_N_MISSING = 1
        axi_write(16#02C#, x"00000002");  -- CAM_N_TEETH = 2
        axi_write(16#008#, x"00000010");  -- RST_CYCLES = 16 (short for sim)

        -- Write CONTROL: crank_edge_sel=1, src_sel=0, ref_sel=1, cam_edge_sel=0, ang_sel=1
        -- bits: [0]=1 [1]=0 [2]=1 [3]=1(apply) [4]=0 [5]=1 = 0x2B
        axi_write(16#000#, x"0000002B");

        -- Wait for CONTROL[3] to self-clear
        wait for 5 * CLK_PERIOD;
        axi_read(16#000#, rd);
        assert rd(3) = '0'
            report "FAIL T2: config_apply did not self-clear" severity failure;

        -- Wait for rst to release (RST_CYCLES=16 clocks)
        wait for 20 * CLK_PERIOD;

        -- Check latched values
        assert crank_edge_sel = '1'
            report "FAIL T2: crank_edge_sel not latched" severity failure;
        assert ref_sel = '1'
            report "FAIL T2: ref_sel not latched" severity failure;
        assert ang_sel = '1'
            report "FAIL T2: ang_sel not latched" severity failure;
        assert to_integer(crank_n_teeth) = 40
            report "FAIL T2: crank_n_teeth not latched" severity failure;
        assert to_integer(crank_n_missing) = 1
            report "FAIL T2: crank_n_missing not latched" severity failure;
        assert to_integer(cam_n_teeth) = 2
            report "FAIL T2: cam_n_teeth not latched" severity failure;

        report "TEST 2: PASS";

        -- ----------------------------------------------------------------
        -- T3: rst_out high for RST_CYCLES after config_apply
        -- ----------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: rst_out duration";

        axi_write(16#008#, x"00000020");  -- RST_CYCLES = 32
        axi_write(16#000#, x"00000008");  -- config_apply

        -- rst_out should be high immediately
        wait for CLK_PERIOD;
        assert rst_out = '1'
            report "FAIL T3: rst_out not high after config_apply" severity failure;

        -- Wait 31 cycles - still high
        wait for 31 * CLK_PERIOD;
        assert rst_out = '1'
            report "FAIL T3: rst_out went low too early" severity failure;

        -- Wait a few more - should release
        wait for 5 * CLK_PERIOD;
        assert rst_out = '0'
            report "FAIL T3: rst_out did not release after RST_CYCLES" severity failure;

        report "TEST 3: PASS";

        -- ----------------------------------------------------------------
        -- T4: pll_nco_ab_inc = 0xFFFFFFFF / 60 = 71582788 (0x4444444)
        -- ----------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: pll_nco_ab_inc calc for crank (ppr=60)";

        axi_write(16#024#, x"0000003C");  -- CRANK_N_TEETH = 60
        axi_write(16#000#, x"00000008");  -- config_apply, src_sel=0

        -- Wait for rst + divider (32 cycles divider, RST_CYCLES=32)
        wait for 80 * CLK_PERIOD;

        -- 0xFFFFFFFF / 60 = 71582788 = 0x4444444
        assert to_integer(pll_nco_ab_inc) = 71582788
            report "FAIL T4: pll_nco_ab_inc wrong for ppr=60, got " &
                   integer'image(to_integer(pll_nco_ab_inc)) severity failure;

        -- Check AXI readback at 0xCC
        axi_read(16#0CC#, rd);
        assert to_integer(unsigned(rd)) = 71582788
            report "FAIL T4: AXI readback of PLL_NCO_AB_INC wrong" severity failure;

        report "TEST 4: PASS";

        -- ----------------------------------------------------------------
        -- T5: src_sel=1 uses enc_n_ppr for divisor
        -- 0xFFFFFFFF / 36 = 119304647 (0x71C71C7)
        -- ----------------------------------------------------------------
        test_num <= 5;
        report "TEST 5: pll_nco_ab_inc uses enc_n_ppr when src_sel=1";

        axi_write(16#030#, x"00000024");  -- ENC_N_PPR = 36
        -- CONTROL: src_sel=1 (bit[1]), config_apply (bit[3]) = 0x0A
        axi_write(16#000#, x"0000000A");

        wait for 80 * CLK_PERIOD;

        -- 0xFFFFFFFF / 36 = 119304647
        assert to_integer(pll_nco_ab_inc) = 119304647
            report "FAIL T5: pll_nco_ab_inc wrong for enc ppr=36, got " &
                   integer'image(to_integer(pll_nco_ab_inc)) severity failure;

        report "TEST 5: PASS";

        -- ----------------------------------------------------------------
        -- T6: fault_clear self-clears after one cycle
        -- ----------------------------------------------------------------
        test_num <= 6;
        report "TEST 6: fault_clear self-clears";

        axi_write(16#004#, x"00000001");  -- CONTROL_RT[0] = fault_clear

        wait for CLK_PERIOD;
        assert fault_clear = '1'
            report "FAIL T6: fault_clear not high" severity failure;

        wait for CLK_PERIOD;
        assert fault_clear = '0'
            report "FAIL T6: fault_clear did not self-clear" severity failure;

        -- Verify register also cleared
        axi_read(16#004#, rd);
        assert rd(0) = '0'
            report "FAIL T6: fault_clear not cleared in register" severity failure;

        report "TEST 6: PASS";

        -- ----------------------------------------------------------------
        -- T7: Runtime config outputs update immediately
        -- ----------------------------------------------------------------
        test_num <= 7;
        report "TEST 7: Runtime config direct outputs";

        axi_write(16#00C#, x"000001F4");  -- CAM_DBC = 500
        assert to_integer(cam_debounce) = 500
            report "FAIL T7: cam_debounce not updated" severity failure;

        axi_write(16#04C#, x"00000200");  -- PLL_KP = 512
        assert to_integer(pll_kp) = 512
            report "FAIL T7: pll_kp not updated" severity failure;

        axi_write(16#004#, x"00000002");  -- pll_corr_dir=1
        assert pll_corr_dir = '1'
            report "FAIL T7: pll_corr_dir not updated" severity failure;

        report "TEST 7: PASS";

        -- ----------------------------------------------------------------
        -- T8: Status register readback
        -- ----------------------------------------------------------------
        test_num <= 8;
        report "TEST 8: Status register readback";

        sync_state_in    <= "11";       -- FULL_SYNC
        speed_slow_in    <= to_unsigned(3000, 16);
        angle_deg_in     <= to_unsigned(1800, 16);
        phase_ref_ok_in  <= '1';
        pll_nco_inc_in   <= x"AABBCCDD";
        fault_flags_in   <= x"00000015"; -- bits 0,2,4
        pkt_cnt_in       <= to_unsigned(12345, 32);
        wait for CLK_PERIOD;

        axi_read(16#070#, rd);
        assert rd(1 downto 0) = "11"
            report "FAIL T8: SYNC_STATE readback" severity failure;

        axi_read(16#078#, rd);
        assert to_integer(unsigned(rd(15 downto 0))) = 3000
            report "FAIL T8: SPEED_RPM_SLOW readback" severity failure;

        axi_read(16#080#, rd);
        assert to_integer(unsigned(rd(15 downto 0))) = 1800
            report "FAIL T8: ANGLE_DEG readback" severity failure;

        axi_read(16#08C#, rd);
        assert rd(0) = '1'
            report "FAIL T8: PHASE_REF_OK readback" severity failure;

        axi_read(16#0B4#, rd);
        assert rd = x"AABBCCDD"
            report "FAIL T8: PLL_NCO_INC readback" severity failure;

        axi_read(16#104#, rd);
        assert rd = x"00000015"
            report "FAIL T8: FAULT_FLAGS readback" severity failure;

        axi_read(16#120#, rd);
        assert to_integer(unsigned(rd)) = 12345
            report "FAIL T8: PKT_COUNT readback" severity failure;

        report "TEST 8: PASS";

        wait for 20 * CLK_PERIOD;
        report "========================================";
        report "All axi_lite_regs tests PASS";
        report "========================================";
        sim_done <= true;
        std.env.stop;
        wait;
    end process p_stim;

end architecture sim;

