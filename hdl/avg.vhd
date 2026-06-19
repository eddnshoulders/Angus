library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- avg.vhd
--
-- Theta-P averaging accumulator.
-- Consumes the raw AXI-Stream from pack.vhd and produces a second AXI-Stream
-- of averaged frames for the display DMA path.
--
-- ARCHITECTURE: independent bank ownership, single bank-manager process
-- -----------------------------------------------------------------------------
-- Each of the two pressure banks carries an explicit state:
--
--   BANK_EMPTY        -- cleared, available, owned by nobody
--   BANK_ACCUMULATING -- being written by the accumulator
--   BANK_FULL         -- accumulation target reached, awaiting collection
--   BANK_STREAMING    -- being read out over m_axis
--   BANK_CLEARING     -- being zeroed after streaming
--
-- All writes to bank0_state/bank1_state (and the per-bank avg_n latch,
-- and the bank-select signals below) happen in exactly one process,
-- p_bank_mgr. This satisfies VHDL's single-driver rule trivially, and also
-- makes the cross-bank priority rules easy to express as one ordered set
-- of checks in one place rather than reasoned about across two symmetric
-- processes. The accumulator (p_acc) and output (p_out) FSMs never assign
-- bank state directly -- they only emit single-cycle "done" pulses
-- (acc_frame_done_pulse, out_stream_done_pulse, out_clear_done_pulse) and
-- read the bank-select signals p_bank_mgr publishes:
--
--   acc_bank_sel : '0'/'1' -- which physical bank the accumulator should
--                             currently address (only meaningful while
--                             that bank's state is BANK_ACCUMULATING)
--   out_bank_sel : '0'/'1' -- which physical bank the output side should
--                             currently address (only meaningful while
--                             out_owner_valid = '1')
--
-- BRAM port muxing for each bank is derived combinationally from these
-- two select signals (see "Bank port routing" below), so the actual
-- read/write address presented to ram0/ram1 always reflects the bank
-- manager's current decision with no additional latency or handshake.
--
-- Priority rules (p_bank_mgr), in the order applied:
--   1. The accumulator always uses whichever bank is presently
--      BANK_ACCUMULATING and matches acc_bank_sel -- this is true by
--      construction, since acc_bank_sel is only ever pointed at a bank
--      the manager has put into BANK_ACCUMULATING.
--   2. When acc_frame_done_pulse arrives, the accumulator's current bank
--      (acc_bank_sel) transitions BANK_ACCUMULATING -> BANK_FULL.
--   3. At that same moment, if the OTHER bank is BANK_EMPTY, it
--      immediately transitions BANK_EMPTY -> BANK_ACCUMULATING and
--      acc_bank_sel flips to it -- the accumulator never has a gap cycle
--      with no bank to address.
--   4. If the other bank is NOT BANK_EMPTY at that moment, neither bank
--      is available for the accumulator to continue into. bank_overflow
--      is asserted (sticky until acknowledged by a bank becoming
--      available) -- a real, named error condition, not a silent stall.
--   5. Output claims a bank: whenever the output side is idle
--      (out_owner_valid = '0'), if bank0 is BANK_FULL, claim it
--      (out_bank_sel <= '0'); otherwise if bank1 is BANK_FULL, claim it.
--      This is the deterministic "bank 0 first" tie-break when both
--      banks are FULL simultaneously.
--   6. When out_stream_done_pulse arrives, the output's current bank
--      (out_bank_sel) transitions BANK_STREAMING -> BANK_CLEARING.
--   7. When out_clear_done_pulse arrives, that bank transitions
--      BANK_CLEARING -> BANK_EMPTY, and out_owner_valid drops so rule 5
--      can claim the next FULL bank.
--
-- SIMPLIFICATION FOR THIS PASS: DI handling removed entirely.
-- -----------------------------------------------------------------------------
-- DI is not read, stored, or output in this version. The output word 1
-- DI byte field is held at 0x00. DI support can be reintroduced once
-- pressure averaging under the new bank-ownership structure is verified.
--
-- Input stream (from pack.vhd, 2 words per sample):
--   Word 0: [31:0]  tdc_deg  (0-7199, used directly as bin address)
--   Word 1: [31:24] DI (ignored this pass) | [15:4] pressure | other: 0
--   tlast asserted on Word 1 of the last sample in each engine cycle
--
-- Output stream (to avg DMA, 2 words per bin, matching pack.vhd format):
--   Word 0: [31:0]  tdc_deg = bin index (0-7199)
--   Word 1: [31:24] 0x00 | [23:16] 0x00 | [15:4] pressure_avg | [3:0] 0x0
--   tlast asserted on Word 1 of bin 7199
--   Frame = 14400 words = 57600 bytes (identical layout to raw 1-rev frame)
--
-- Averaging:
--   N = 0: bypass mode. Raw stream passes directly to output, bank
--          machinery and the input FIFO are not used at all.
--   N > 0: accumulate 2^N engine cycles, output averaged frame.
--          pressure_avg = sum >> N (right shift, exact for power-of-2)
--
-- avg_n is latched per-bank at the moment that bank is claimed out of
-- BANK_EMPTY (bank0_avg_n / bank1_avg_n), not as a single shared latch,
-- since one bank may still be accumulating at the previous avg_n while
-- the other has just been claimed at a newly-changed avg_n.
--
-- INPUT RATE / TIMING BUDGET
-- -----------------------------------------------------------------------------
-- Design target: 20,000 rpm at 0.1 degree sampling = 7200 samples per
-- revolution at up to 20000/60 = 333.3 rev/s = 2.4 MS/s maximum input rate.
-- At a 100 MHz (or faster) PL clock that is roughly 41 clock cycles
-- available per sample. The accumulator's read-modify-write sequence
-- (5 explicit stages, see p_acc below) takes a handful of cycles -- far
-- under that budget -- so there is no need to accept a sample every
-- clock or to make s_axis_tready track the RMW pipeline's exact timing.
--
-- A small synchronous input FIFO (p_in_fifo) sits between s_axis and the
-- accumulator to absorb any short-term burstiness from pack.vhd, so
-- s_axis_tready is governed purely by FIFO occupancy. The accumulator
-- pops one complete, already-assembled sample (bin index + pressure +
-- tlast flag) per FIFO read, rather than tracking word_cnt itself.
--
-- BRAM timing assumed throughout: synchronous, single read+write port,
-- one-cycle registered read latency, no read-during-write forwarding.
--
-- OVERFLOW / THROUGHPUT RISK (conversation deliverable #3)
-- -----------------------------------------------------------------------------
-- bank_overflow (rule 4 above) is the accumulator-side risk: it fires if
-- the bank just vacated by the accumulator has not reached BANK_EMPTY
-- (still STREAMING or CLEARING) by the time the other bank's
-- accumulation target completes. This is a real-time budget: streaming
-- (14400 beats, rate-limited by m_axis_tready) plus clearing (7200 BRAM
-- writes, one per cycle) must finish inside one accumulation period of
-- the other bank. At low avg_n combined with a slow or stalled
-- downstream consumer, this budget can genuinely be exceeded -- that is
-- real backpressure exhaustion, not a logic fault, and is surfaced as a
-- named, sticky condition rather than a silent stall or dropped sample.
--
-- The input FIFO (p_in_fifo) has its own, much smaller and much less
-- likely overflow case: if pack.vhd bursts faster than the accumulator
-- can drain for long enough to fill the FIFO. At a 41-cycle-per-sample
-- budget and a FIFO depth of 32, this would require a sustained burst
-- many times the rated input rate; in_fifo_overflow_count is provided
-- to make this visible if it ever happens rather than silently dropping
-- samples.
-- =============================================================================

entity avg is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- Raw input stream (from pack.vhd)
        s_axis_tdata    : in  std_logic_vector(31 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;
        s_axis_tlast    : in  std_logic;

        -- Averaged output stream (to avg DMA)
        m_axis_tdata    : out std_logic_vector(31 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;

        -- Control inputs
        avg_n           : in  unsigned(3 downto 0);

        -- Status
        frame_count     : out unsigned(31 downto 0);

        -- Diagnostic counters (avg<->DMA1 handshake visibility)
        in_beat_count   : out unsigned(31 downto 0);  -- s_axis beats accepted
        out_beat_count  : out unsigned(31 downto 0);  -- m_axis beats accepted (tvalid & tready)
        out_tlast_count : out unsigned(31 downto 0);  -- m_axis tlast beats accepted
        out_stall_count : out unsigned(31 downto 0);  -- cycles tvalid=1, tready=0
        bad_tlast_count : out unsigned(31 downto 0);  -- tlast asserted on word 0 (framing bug)

        -- Bank overflow: rule 4 -- accumulator finished a frame but the
        -- other bank was not BANK_EMPTY. Sticky until a bank becomes
        -- available again. Real resource exhaustion, not a logic fault.
        bank_overflow      : out std_logic;
        bank_overflow_count: out unsigned(31 downto 0);

        -- Input FIFO overflow: pack.vhd produced samples faster than the
        -- accumulator could drain the FIFO for long enough to fill it.
        -- Should not happen given the 41-cycles-per-sample budget; see
        -- header note.
        in_fifo_overflow_count : out unsigned(31 downto 0);

        -- Output state, for ILA correlation against stall/tlast counters.
        -- Reports the state of whichever bank the output side currently
        -- owns, or "000" when it owns none (waiting for a FULL bank).
        -- 000=IDLE 001=FULL/claimed 010=STREAMING 011=CLEARING
        out_state_dbg   : out std_logic_vector(2 downto 0)
    );
end entity avg;

architecture rtl of avg is

    constant BINS : integer := 7200;

    type t_bram32 is array (0 to BINS - 1) of unsigned(31 downto 0);

    -- =========================================================================
    -- Pressure BRAMs: two independent 7200x32-bit banks, single registered
    -- read+write port each, one-cycle latency, no read-during-write
    -- forwarding.
    -- =========================================================================
    signal ram0     : t_bram32 := (others => (others => '0'));
    signal r0_addr  : unsigned(12 downto 0) := (others => '0');
    signal r0_wdata : unsigned(31 downto 0) := (others => '0');
    signal r0_rdata : unsigned(31 downto 0);
    signal r0_we    : std_logic := '0';

    signal ram1     : t_bram32 := (others => (others => '0'));
    signal r1_addr  : unsigned(12 downto 0) := (others => '0');
    signal r1_wdata : unsigned(31 downto 0) := (others => '0');
    signal r1_rdata : unsigned(31 downto 0);
    signal r1_we    : std_logic := '0';

    -- =========================================================================
    -- Bank ownership state -- written ONLY by p_bank_mgr.
    -- =========================================================================
    type bank_state_t is (
        BANK_EMPTY,
        BANK_ACCUMULATING,
        BANK_FULL,
        BANK_STREAMING,
        BANK_CLEARING
    );

    signal bank0_state : bank_state_t := BANK_EMPTY;
    signal bank1_state : bank_state_t := BANK_EMPTY;

    signal bank0_avg_n : unsigned(3 downto 0) := (others => '0');
    signal bank1_avg_n : unsigned(3 downto 0) := (others => '0');

    -- Bank-select signals -- written ONLY by p_bank_mgr, read by p_acc,
    -- p_out, and the BRAM port mux below.
    signal acc_bank_sel : std_logic := '0';
    signal out_bank_sel : std_logic := '0';
    signal out_owner_valid : std_logic := '0';  -- '1' once out_bank_sel
                                                 -- points at a real claim

    signal bank_overflow_i : std_logic := '0';

    -- =========================================================================
    -- Pulses from the accumulator and output FSMs into p_bank_mgr.
    -- Each is exactly one clock cycle wide. Neither FSM writes bank
    -- state directly -- this is the only interface between them and
    -- p_bank_mgr.
    -- =========================================================================
    signal acc_frame_done_pulse  : std_logic := '0';
    signal out_stream_done_pulse : std_logic := '0';
    signal out_clear_done_pulse  : std_logic := '0';

    -- avg_n actually in effect for whichever bank each side currently
    -- owns -- a simple combinational read of the per-bank latch, not a
    -- separate latch of its own.
    signal acc_active_avg_n : unsigned(3 downto 0);
    signal out_active_avg_n : unsigned(3 downto 0);
    signal frame_target     : unsigned(14 downto 0);

    -- =========================================================================
    -- Accumulator-side BRAM-facing signals (muxed into ram0/ram1 by
    -- acc_bank_sel below)
    -- =========================================================================
    signal acc_addr  : unsigned(12 downto 0) := (others => '0');
    signal acc_wdata : unsigned(31 downto 0) := (others => '0');
    signal acc_we    : std_logic := '0';
    signal acc_rdata : unsigned(31 downto 0);

    -- =========================================================================
    -- Output-side BRAM-facing signals (muxed into ram0/ram1 by
    -- out_bank_sel below)
    -- =========================================================================
    signal out_addr  : unsigned(12 downto 0) := (others => '0');
    signal out_wdata : unsigned(31 downto 0) := (others => '0');
    signal out_we    : std_logic := '0';
    signal out_rdata : unsigned(31 downto 0);

    -- =========================================================================
    -- Input FIFO: assembles each 2-word AXI-Stream sample (tdc_deg,
    -- pressure, tlast) into one packed entry and decouples s_axis timing
    -- from the accumulator's RMW pipeline. Synchronous, single clock
    -- domain (no CDC -- s_axis and the accumulator both run on clk).
    -- Packed entry layout: [25] tlast | [24:13] bin (13 bits) |
    --                       [11:0] pressure (12 bits)
    -- =========================================================================
    constant FIFO_DEPTH : integer := 32;
    constant FIFO_AWID   : integer := 5;  -- log2(32)
    constant ENTRY_WIDTH : integer := 26;

    type t_fifo is array (0 to FIFO_DEPTH - 1) of std_logic_vector(ENTRY_WIDTH - 1 downto 0);
    signal fifo_mem : t_fifo := (others => (others => '0'));

    signal fifo_wr_ptr : unsigned(FIFO_AWID downto 0) := (others => '0');
    signal fifo_rd_ptr : unsigned(FIFO_AWID downto 0) := (others => '0');
    signal fifo_count  : unsigned(FIFO_AWID downto 0) := (others => '0');
    signal fifo_full    : std_logic;
    signal fifo_empty   : std_logic;
    signal fifo_wr_en    : std_logic := '0';
    signal fifo_rd_en    : std_logic := '0';
    signal fifo_wr_data  : std_logic_vector(ENTRY_WIDTH - 1 downto 0) := (others => '0');
    signal fifo_rd_data  : std_logic_vector(ENTRY_WIDTH - 1 downto 0);

    signal in_fifo_overflow_cnt : unsigned(31 downto 0) := (others => '0');

    -- Assembler: latches word 0 (bin), then on word 1 (pressure) pushes
    -- one packed entry into the FIFO. Entirely separate from the
    -- accumulator's own pipeline -- this only runs while assembling a
    -- sample from s_axis, before anything reaches the FIFO.
    signal asm_word_cnt : std_logic := '0';
    signal asm_tdc      : unsigned(12 downto 0) := (others => '0');

    -- =========================================================================
    -- Accumulator FSM
    --
    -- Read-modify-write pipeline stages, explicit (synchronous BRAM,
    -- one-cycle registered read latency, no read-during-write
    -- forwarding). Given the ~41 cycles/sample budget at the rated
    -- 2.4 MS/s input rate, these stages are written for clarity, not
    -- single-cycle throughput:
    --   A0 (ACC_POP)      -- pop one assembled sample off the input FIFO;
    --                         latch its bin index, pressure value, and
    --                         tlast flag.
    --   A1 (ACC_RDADDR)   -- drive the BRAM read address for this bin
    --                         (registered into r0_addr/r1_addr this
    --                         cycle via acc_addr).
    --   A2 (ACC_RDCAP)    -- dead cycle while the BRAM's registered read
    --                         output catches up; acc_rdata becomes valid
    --                         for the first time at the end of this
    --                         cycle (visible at the start of A3).
    --   A3 (ACC_SUM)      -- acc_rdata now holds the old bin value;
    --                         compute the new sum (sum + value) into a
    --                         register, ready to write next cycle.
    --   A4 (ACC_WRITE)    -- issue the write of the computed sum to the
    --                         same address. acc_frame_done_pulse fires
    --                         here, for one cycle, if this sample was
    --                         the last one of the accumulation target.
    -- =========================================================================
    type t_acc_state is (ACC_POP, ACC_RDADDR, ACC_RDCAP, ACC_SUM, ACC_WRITE);
    signal acc_state : t_acc_state := ACC_POP;

    signal acc_tdc      : unsigned(12 downto 0) := (others => '0');
    signal acc_pressure : unsigned(11 downto 0) := (others => '0');
    signal acc_tlast    : std_logic := '0';
    signal acc_sum_next : unsigned(31 downto 0) := (others => '0');

    signal frame_cnt : unsigned(14 downto 0) := (others => '0');

    -- =========================================================================
    -- Output FSM (lookahead pipeline to hide BRAM read latency, unchanged
    -- in shape from the previous design -- this part is orthogonal to the
    -- bank-ownership coupling the refactor addresses)
    -- =========================================================================
    type t_out_state is (OUT_IDLE, OUT_RDWAIT, OUT_RDWAIT2, OUT_STREAM, OUT_CLR);
    signal out_state : t_out_state := OUT_IDLE;

    signal out_bin   : unsigned(12 downto 0) := (others => '0');
    signal out_pres  : unsigned(31 downto 0) := (others => '0');
    signal out_word  : std_logic := '0';  -- 0=tdc_deg word, 1=pressure word
    signal out_valid : std_logic := '0';
    signal tlast_int  : std_logic := '0';
    signal clr_bin    : unsigned(12 downto 0) := (others => '0');

    signal frame_out_cnt : unsigned(31 downto 0) := (others => '0');

    -- =========================================================================
    -- Diagnostic counters
    -- =========================================================================
    signal in_beat_cnt        : unsigned(31 downto 0) := (others => '0');
    signal out_beat_cnt       : unsigned(31 downto 0) := (others => '0');
    signal out_tlast_cnt      : unsigned(31 downto 0) := (others => '0');
    signal out_stall_cnt      : unsigned(31 downto 0) := (others => '0');
    signal bad_tlast_cnt      : unsigned(31 downto 0) := (others => '0');
    signal bank_overflow_cnt  : unsigned(31 downto 0) := (others => '0');

    signal s_axis_tready_i : std_logic;
    signal out_data_i      : std_logic_vector(31 downto 0);
    signal bypass_active   : std_logic;

begin

    -- =========================================================================
    -- BRAM processes
    -- =========================================================================
    p_ram0 : process(clk)
    begin
        if rising_edge(clk) then
            if r0_we = '1' then
                ram0(to_integer(r0_addr)) <= r0_wdata;
            end if;
            r0_rdata <= ram0(to_integer(r0_addr));
        end if;
    end process p_ram0;

    p_ram1 : process(clk)
    begin
        if rising_edge(clk) then
            if r1_we = '1' then
                ram1(to_integer(r1_addr)) <= r1_wdata;
            end if;
            r1_rdata <= ram1(to_integer(r1_addr));
        end if;
    end process p_ram1;

    -- =========================================================================
    -- Bank port routing: derived purely from acc_bank_sel / out_bank_sel
    -- (published by p_bank_mgr) and each bank's own state. Single driver
    -- each (concurrent signal assignment), no process owns these.
    -- =========================================================================
    r0_addr  <= acc_addr  when acc_bank_sel = '0' and bank0_state = BANK_ACCUMULATING
                else out_addr;
    r0_wdata <= acc_wdata when acc_bank_sel = '0' and bank0_state = BANK_ACCUMULATING
                else out_wdata;
    r0_we    <= acc_we when acc_bank_sel = '0' and bank0_state = BANK_ACCUMULATING
                else out_we when out_bank_sel = '0' and out_owner_valid = '1'
                else '0';

    r1_addr  <= acc_addr  when acc_bank_sel = '1' and bank1_state = BANK_ACCUMULATING
                else out_addr;
    r1_wdata <= acc_wdata when acc_bank_sel = '1' and bank1_state = BANK_ACCUMULATING
                else out_wdata;
    r1_we    <= acc_we when acc_bank_sel = '1' and bank1_state = BANK_ACCUMULATING
                else out_we when out_bank_sel = '1' and out_owner_valid = '1'
                else '0';

    acc_rdata <= r0_rdata when acc_bank_sel = '0' else r1_rdata;
    out_rdata <= r0_rdata when out_bank_sel = '0' else r1_rdata;

    acc_active_avg_n <= bank0_avg_n when acc_bank_sel = '0' else bank1_avg_n;
    out_active_avg_n <= bank0_avg_n when out_bank_sel = '0' else bank1_avg_n;

    frame_target  <= shift_left(to_unsigned(1, 15), to_integer(acc_active_avg_n));
    bypass_active <= '1' when avg_n = 0 else '0';

    bank_overflow       <= bank_overflow_i;
    bank_overflow_count <= bank_overflow_cnt;

    -- =========================================================================
    -- Bank manager -- the ONLY process that writes bank0_state, bank1_state,
    -- bank0_avg_n, bank1_avg_n, acc_bank_sel, out_bank_sel, out_owner_valid,
    -- and bank_overflow_i. Implements priority rules 1-7 from the header
    -- comment, in order, each cycle.
    -- =========================================================================
    p_bank_mgr : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bank0_state     <= BANK_EMPTY;
                bank1_state     <= BANK_EMPTY;
                bank0_avg_n     <= (others => '0');
                bank1_avg_n     <= (others => '0');
                acc_bank_sel    <= '0';
                out_bank_sel    <= '0';
                out_owner_valid <= '0';
                bank_overflow_i <= '0';
            else
                -- Rule 2 + 3 + 4: accumulator frame completion.
                if acc_frame_done_pulse = '1' then
                    if acc_bank_sel = '0' then
                        bank0_state <= BANK_FULL;
                        if bank1_state = BANK_EMPTY then
                            bank1_state  <= BANK_ACCUMULATING;
                            bank1_avg_n  <= avg_n;
                            acc_bank_sel <= '1';
                        else
                            bank_overflow_i <= '1';
                        end if;
                    else
                        bank1_state <= BANK_FULL;
                        if bank0_state = BANK_EMPTY then
                            bank0_state  <= BANK_ACCUMULATING;
                            bank0_avg_n  <= avg_n;
                            acc_bank_sel <= '0';
                        else
                            bank_overflow_i <= '1';
                        end if;
                    end if;
                end if;

                -- Initial claim out of power-on/reset: if the accumulator
                -- is not yet pointed at any ACCUMULATING bank at all (only
                -- true once, right after reset, since rule 2/3 always
                -- keeps a bank ACCUMULATING thereafter unless overflow is
                -- asserted), claim bank0 first.
                if bank0_state = BANK_EMPTY and bank1_state = BANK_EMPTY then
                    bank0_state  <= BANK_ACCUMULATING;
                    bank0_avg_n  <= avg_n;
                    acc_bank_sel <= '0';
                end if;

                -- Rule 5: output claims a FULL bank when idle. Bank 0
                -- first if both are FULL (deterministic tie-break).
                if out_owner_valid = '0' then
                    if bank0_state = BANK_FULL then
                        out_bank_sel    <= '0';
                        out_owner_valid <= '1';
                    elsif bank1_state = BANK_FULL then
                        out_bank_sel    <= '1';
                        out_owner_valid <= '1';
                    end if;
                end if;

                -- Rule 6: streaming finished -> clearing.
                if out_stream_done_pulse = '1' then
                    if out_bank_sel = '0' then
                        bank0_state <= BANK_CLEARING;
                    else
                        bank1_state <= BANK_CLEARING;
                    end if;
                end if;

                -- Rule 7: clearing finished -> empty, release ownership.
                -- Clears bank_overflow_i too -- a bank has become
                -- available again, so the error condition (rule 4) is no
                -- longer current. Counted once per occurrence below.
                if out_clear_done_pulse = '1' then
                    if out_bank_sel = '0' then
                        bank0_state <= BANK_EMPTY;
                    else
                        bank1_state <= BANK_EMPTY;
                    end if;
                    out_owner_valid <= '0';
                    if bank_overflow_i = '1' then
                        bank_overflow_i   <= '0';
                        bank_overflow_cnt <= bank_overflow_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_bank_mgr;

    -- =========================================================================
    -- Input FIFO assembler: latches word 0 (bin) then word 1 (pressure),
    -- pushes one packed entry. s_axis_tready is governed by fifo_full,
    -- not by anything accumulator-side -- this is the decoupling the
    -- 41-cycles-per-sample budget makes possible.
    -- =========================================================================
    fifo_full  <= '1' when fifo_count = FIFO_DEPTH else '0';
    fifo_empty <= '1' when fifo_count = 0 else '0';

    p_assemble : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                asm_word_cnt <= '0';
                fifo_wr_en   <= '0';
            else
                fifo_wr_en <= '0';
                if s_axis_tvalid = '1' and bypass_active = '0' and s_axis_tready_i = '1' then
                    if asm_word_cnt = '0' then
                        asm_tdc      <= unsigned(s_axis_tdata(12 downto 0));
                        asm_word_cnt <= '1';
                    else
                        asm_word_cnt <= '0';
                        fifo_wr_data <= s_axis_tlast
                                        & std_logic_vector(asm_tdc)
                                        & s_axis_tdata(15 downto 4);
                        fifo_wr_en   <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process p_assemble;

    -- s_axis_tready: governed by FIFO occupancy only (bypass mode passes
    -- straight through to m_axis_tready instead, as before).
    s_axis_tready_i <= m_axis_tready when bypass_active = '1'
                       else not fifo_full;
    s_axis_tready   <= s_axis_tready_i;

    p_fifo : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                fifo_wr_ptr <= (others => '0');
                fifo_rd_ptr <= (others => '0');
                fifo_count  <= (others => '0');
                in_fifo_overflow_cnt <= (others => '0');
            else
                if fifo_wr_en = '1' and fifo_full = '0' then
                    fifo_mem(to_integer(fifo_wr_ptr(FIFO_AWID - 1 downto 0))) <= fifo_wr_data;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                elsif fifo_wr_en = '1' and fifo_full = '1' then
                    in_fifo_overflow_cnt <= in_fifo_overflow_cnt + 1;
                end if;

                if fifo_rd_en = '1' and fifo_empty = '0' then
                    fifo_rd_ptr <= fifo_rd_ptr + 1;
                end if;

                if fifo_wr_en = '1' and fifo_full = '0'
                   and not (fifo_rd_en = '1' and fifo_empty = '0') then
                    fifo_count <= fifo_count + 1;
                elsif fifo_rd_en = '1' and fifo_empty = '0'
                      and not (fifo_wr_en = '1' and fifo_full = '0') then
                    fifo_count <= fifo_count - 1;
                end if;
            end if;
        end if;
    end process p_fifo;

    fifo_rd_data <= fifo_mem(to_integer(fifo_rd_ptr(FIFO_AWID - 1 downto 0)));

    in_fifo_overflow_count <= in_fifo_overflow_cnt;

    -- =========================================================================
    -- Accumulator FSM. Reads acc_bank_sel to know which bank it owns;
    -- never inspects bank0_state/bank1_state/out_state directly, and
    -- never assigns bank state -- only emits acc_frame_done_pulse.
    -- =========================================================================
    p_acc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                acc_state           <= ACC_POP;
                acc_we               <= '0';
                fifo_rd_en           <= '0';
                frame_cnt            <= (others => '0');
                acc_frame_done_pulse <= '0';
            else
                acc_we               <= '0';
                fifo_rd_en           <= '0';
                acc_frame_done_pulse <= '0';

                case acc_state is

                    when ACC_POP =>
                        -- A0: pop one assembled sample if available.
                        if fifo_empty = '0' then
                            fifo_rd_en <= '1';
                            acc_state  <= ACC_RDADDR;
                        end if;

                    when ACC_RDADDR =>
                        -- Latch the popped entry (fifo_rd_data is valid
                        -- this cycle, one cycle after fifo_rd_en was
                        -- asserted in ACC_POP -- mirrors the BRAM's own
                        -- registered-read convention used throughout).
                        acc_tlast    <= fifo_rd_data(25);
                        acc_tdc      <= unsigned(fifo_rd_data(24 downto 12));
                        acc_pressure <= unsigned(fifo_rd_data(11 downto 0));
                        -- A1: drive the BRAM read address for this bin.
                        acc_addr  <= unsigned(fifo_rd_data(24 downto 12));
                        acc_state <= ACC_RDCAP;

                    when ACC_RDCAP =>
                        -- A2: dead cycle, BRAM registered read output
                        -- catches up to the address driven in A1.
                        acc_state <= ACC_SUM;

                    when ACC_SUM =>
                        -- A3: acc_rdata now holds the old bin value;
                        -- compute the new sum, ready to write next cycle.
                        acc_sum_next <= acc_rdata + resize(acc_pressure, 32);
                        acc_state    <= ACC_WRITE;

                    when ACC_WRITE =>
                        -- A4: issue the write of the computed sum.
                        acc_wdata <= acc_sum_next;
                        acc_we    <= '1';
                        acc_addr  <= acc_tdc;

                        if acc_tlast = '1' then
                            if frame_cnt + 1 >= frame_target then
                                frame_cnt            <= (others => '0');
                                acc_frame_done_pulse <= '1';
                            else
                                frame_cnt <= frame_cnt + 1;
                            end if;
                        end if;

                        acc_state <= ACC_POP;

                end case;
            end if;
        end if;
    end process p_acc;

    -- =========================================================================
    -- Output generator FSM
    -- Streams 2 words per bin: word0=tdc_deg, word1=pressure (DI byte
    -- held at 0x00 for this pass). tlast on word 1 of bin 7199.
    -- =========================================================================
    p_out : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_state            <= OUT_IDLE;
                out_valid            <= '0';
                tlast_int            <= '0';
                out_bin              <= (others => '0');
                out_word             <= '0';
                clr_bin              <= (others => '0');
                out_we               <= '0';
                frame_out_cnt        <= (others => '0');
                out_stream_done_pulse <= '0';
                out_clear_done_pulse  <= '0';
            else
                out_we                 <= '0';
                out_stream_done_pulse  <= '0';
                out_clear_done_pulse   <= '0';

                case out_state is

                    when OUT_IDLE =>
                        out_valid <= '0';
                        tlast_int <= '0';
                        out_word  <= '0';
                        if out_owner_valid = '1' then
                            out_bin   <= (others => '0');
                            out_addr  <= (others => '0');
                            out_state <= OUT_RDWAIT;
                        end if;

                    when OUT_RDWAIT =>
                        -- bin 0 address issued in OUT_IDLE (cycle N).
                        -- BRAM registering the read this cycle. Issue
                        -- lookahead read for bin 1.
                        out_addr  <= to_unsigned(1, 13);
                        out_state <= OUT_RDWAIT2;

                    when OUT_RDWAIT2 =>
                        -- out_rdata now holds bin 0 data (registered from
                        -- RDWAIT read). Capture into stable output
                        -- register, scaled by this bank's own latched
                        -- avg_n.
                        out_pres  <= shift_right(out_rdata, to_integer(out_active_avg_n));
                        out_valid <= '1';
                        out_state <= OUT_STREAM;

                    when OUT_STREAM =>
                        out_valid <= '1';

                        if m_axis_tready = '1' then
                            if out_word = '0' then
                                out_word <= '1';
                            else
                                out_word <= '0';
                                if out_bin = BINS - 1 then
                                    out_valid              <= '0';
                                    tlast_int               <= '0';
                                    frame_out_cnt           <= frame_out_cnt + 1;
                                    clr_bin                 <= (others => '0');
                                    out_state                <= OUT_CLR;
                                    out_stream_done_pulse    <= '1';
                                else
                                    out_pres <= shift_right(out_rdata,
                                                            to_integer(out_active_avg_n));
                                    out_bin  <= out_bin + 1;
                                    if to_integer(out_bin) + 2 < BINS then
                                        out_addr <= out_bin + 2;
                                    else
                                        out_addr <= to_unsigned(BINS-1, 13);
                                    end if;
                                end if;
                            end if;

                            if out_bin = BINS - 1 and out_word = '0' then
                                tlast_int <= '1';
                            end if;
                        end if;

                    when OUT_CLR =>
                        out_addr  <= clr_bin;
                        out_wdata <= (others => '0');
                        out_we    <= '1';
                        if clr_bin = BINS - 1 then
                            out_we                <= '0';
                            out_state              <= OUT_IDLE;
                            out_clear_done_pulse   <= '1';
                        else
                            clr_bin <= clr_bin + 1;
                        end if;

                    when others =>
                        out_state <= OUT_IDLE;

                end case;
            end if;
        end if;
    end process p_out;

    -- =========================================================================
    -- Diagnostic counters
    -- =========================================================================
    p_diag : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                in_beat_cnt   <= (others => '0');
                out_beat_cnt  <= (others => '0');
                out_tlast_cnt <= (others => '0');
                out_stall_cnt <= (others => '0');
                bad_tlast_cnt <= (others => '0');
            else
                if s_axis_tvalid = '1' and s_axis_tready_i = '1' then
                    in_beat_cnt <= in_beat_cnt + 1;
                end if;

                if bypass_active = '0' then
                    if out_valid = '1' and m_axis_tready = '1' then
                        out_beat_cnt <= out_beat_cnt + 1;
                        if tlast_int = '1' then
                            out_tlast_cnt <= out_tlast_cnt + 1;
                        end if;
                    elsif out_valid = '1' and m_axis_tready = '0' then
                        out_stall_cnt <= out_stall_cnt + 1;
                    end if;

                    if tlast_int = '1' and out_word = '0' then
                        bad_tlast_cnt <= bad_tlast_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_diag;

    -- =========================================================================
    -- Output data mux
    -- =========================================================================
    process(out_word, out_bin, out_pres)
        variable w1 : std_logic_vector(31 downto 0);
    begin
        if out_word = '0' then
            out_data_i <= std_logic_vector(resize(out_bin, 32));
        else
            w1(31 downto 24) := x"00";
            w1(23 downto 16) := x"00";
            w1(15 downto 4)  := std_logic_vector(out_pres(11 downto 0));
            w1(3 downto 0)   := "0000";
            out_data_i <= w1;
        end if;
    end process;

    -- =========================================================================
    -- Bypass mux and output assignments
    -- =========================================================================
    m_axis_tdata  <= s_axis_tdata when bypass_active = '1' else out_data_i;
    m_axis_tvalid <= s_axis_tvalid when bypass_active = '1' else out_valid;
    m_axis_tlast  <= s_axis_tlast  when bypass_active = '1' else tlast_int;

    frame_count   <= frame_out_cnt;

    in_beat_count   <= in_beat_cnt;
    out_beat_count  <= out_beat_cnt;
    out_tlast_count <= out_tlast_cnt;
    out_stall_count <= out_stall_cnt;
    bad_tlast_count <= bad_tlast_cnt;

    with out_state select out_state_dbg <=
        "000" when OUT_IDLE,
        "010" when OUT_RDWAIT,
        "010" when OUT_RDWAIT2,
        "010" when OUT_STREAM,
        "011" when OUT_CLR,
        "111" when others;

end architecture rtl;
