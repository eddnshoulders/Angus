library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.env.all;

-- Diagnostic stress TB for avg.vhd: exercises AXIS backpressure and bank
-- overrun, which the original avg_tb never does (tready is held at '1'
-- for whole frames there). Relies on p_dbg_monitor inside avg.vhd.
entity avg_stress_tb is
end entity;

architecture tb of avg_stress_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant BINS_C     : positive := 16;
    constant ADDR_W_C   : positive := 4;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';

    signal sample_valid : std_logic := '0';
    signal sample_ready : std_logic;
    signal tdc_deg      : unsigned(ADDR_W_C - 1 downto 0) := (others => '0');
    signal adc_ch0      : unsigned(11 downto 0) := (others => '0');
    signal di_in        : std_logic_vector(7 downto 0) := (others => '0');
    signal avg_n        : unsigned(1 downto 0) := (others => '0');

    signal m_axis_tdata  : std_logic_vector(31 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '0';
    signal m_axis_tlast  : std_logic;

    signal frames_out_count, bank_overrun_count, dropped_sample_count : unsigned(31 downto 0);

    -- 0 = random backpressure, 1 = hold low (DMA not armed), 2 = always high
    signal ready_mode : integer := 0;
    signal stalled_samples : natural := 0;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.avg
        generic map (BINS => BINS_C, ADDR_W => ADDR_W_C)
        port map (
            clk => clk, rst => rst, avg_resetn => '1', drain_disable => '0',
            sample_valid => sample_valid, sample_ready => sample_ready,
            tdc_deg => tdc_deg, adc_ch0 => adc_ch0, di_in => di_in, avg_n => avg_n,
            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast,
            frames_in_count => open, frames_out_count => frames_out_count,
            samples_in_count => open, missed_sample_count => open,
            out_of_order_count => open, bank_overrun_count => bank_overrun_count,
            dropped_sample_count => dropped_sample_count, out_stall_count => open,
            state_dbg => open, bank0_state_dbg => open, bank1_state_dbg => open,
            out_bin_dbg => open);

    -- Sink: LFSR-driven tready
    sink : process(clk)
        variable lfsr : std_logic_vector(15 downto 0) := x"ACE1";
    begin
        if rising_edge(clk) then
            lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
            case ready_mode is
                when 0      => m_axis_tready <= lfsr(0);
                when 1      => m_axis_tready <= '0';
                when others => m_axis_tready <= '1';
            end case;
        end if;
    end process;

    stim : process
        procedure send(deg, adc : natural) is
            variable n : natural := 0;
        begin
            tdc_deg <= to_unsigned(deg, ADDR_W_C);
            adc_ch0 <= to_unsigned(adc, 12);
            di_in   <= x"A5";
            sample_valid <= '1';
            loop
                wait until rising_edge(clk);
                wait for 1 ns;
                exit when sample_ready = '1';
                n := n + 1;
                if n > 2000 then   -- real source does not wait; count & drop
                    stalled_samples <= stalled_samples + 1;
                    exit;
                end if;
            end loop;
            sample_valid <= '0';
            -- spacing: ~20 clocks between samples (sample-rate-like gap)
            for i in 1 to 20 loop wait until rising_edge(clk); end loop;
        end procedure;
        procedure frame(base : natural) is
        begin
            for b in 0 to BINS_C - 1 loop send(b, base + b); end loop;
        end procedure;
    begin
        rst <= '1';
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        rst <= '0';

        report "STRESS PHASE 1: random tready backpressure, 6 frames";
        ready_mode <= 0;
        frame(0);                          -- dummy (wait_frame)
        for f in 1 to 6 loop frame(100 * f); end loop;

        report "STRESS PHASE 2: tready held low for 4 frames (forces overrun)";
        ready_mode <= 1;
        for f in 1 to 4 loop frame(1000 + f); end loop;

        report "STRESS PHASE 3: tready always high, 6 frames (should recover)";
        ready_mode <= 2;
        for f in 1 to 6 loop frame(2000 + 10 * f); end loop;

        report "SUMMARY: frames_out=" & integer'image(to_integer(frames_out_count))
             & " overruns=" & integer'image(to_integer(bank_overrun_count))
             & " dropped_cycles=" & integer'image(to_integer(dropped_sample_count))
             & " tb_samples_timed_out=" & integer'image(stalled_samples);
        std.env.stop;
    end process;
end architecture;
