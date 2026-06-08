"""
angus_regs.py -- AXI register map and raw access for Angus combustion analyser v3.

Matches axi_lite_regs.vhd v3 (v3_dev branch). Contains only the register
map and raw read/write primitives. Do not import this directly in notebooks --
use angus.py instead.

Register tuple format: (byte_address, msb, lsb, description)
"""

# =============================================================================
# Write register map
# =============================================================================
WRITE_REGS = {
    'CONTROL':              (0x000, 9,  0,
                             '[0]=crank_edge_sel [1]=cam_edge_sel [3:2]=enc_ab_edge_sel '
                             '[4]=enc_z_edge_sel [5]=src_sel [6]=ref_sel '
                             '[7]=config_apply(self-clr) [8]=ang_sel [9]=angle_interp_en'),
    'CONTROL_RT':           (0x004, 3,  0,
                             '[0]=fault_clear(self-clr) [1]=pll_corr_dir '
                             '[2]=phase_fault_drop [3]=phase_ref_phase'),
    'RST_CYCLES':           (0x008, 8,  0,  'Reset duration clocks (default 256)'),
    'PEAK_HYST':            (0x00C, 15, 0,  'Peak detector hysteresis counts (default 128)'),
    'CAM_DBC':              (0x010, 15, 0,  'Cam debounce cycles (default 5)'),
    'CRANK_DBC':            (0x014, 15, 0,  'Crank debounce cycles (default 5)'),
    'ENC_A_DBC':            (0x018, 15, 0,  'Encoder A debounce cycles (default 5)'),
    'ENC_B_DBC':            (0x01C, 15, 0,  'Encoder B debounce cycles (default 5)'),
    'ENC_Z_DBC':            (0x020, 15, 0,  'Encoder Z debounce cycles (default 5)'),
    'CRANK_GAP_THRESH':     (0x024, 7,  0,  'Gap threshold 1.7fp (0xC0 = 1.5x tooth period)'),
    'CRANK_N_TEETH':        (0x028, 7,  0,  'Total teeth including missing (default 60)'),
    'CRANK_N_MISSING':      (0x02C, 7,  0,  'Missing teeth (default 2)'),
    'CAM_N_TEETH':          (0x030, 7,  0,  'Cam teeth per 2 crank revs (default 1)'),
    'ENC_N_PPR':            (0x034, 15, 0,  'Encoder edges per revolution'),
    'PHASE_REF_MIN':        (0x038, 31, 0,  'Detection window lower bound (angfac)'),
    'PHASE_REF_MAX':        (0x03C, 31, 0,  'Detection window upper bound (angfac)'),
    'PLL_KP':               (0x040, 15, 0,  'PLL proportional gain (default 0)'),
    'PLL_KI':               (0x044, 15, 0,  'PLL integral gain (default 0)'),
    'PLL_CORR_MAX':         (0x048, 15, 0,  'PLL max correction NCO LSB (default 0xFFFF)'),
    'TRIG_DECIMATION':      (0x04C, 15, 0,  'Sample trigger decimation (1 = every 0.1 deg equiv)'),
    'MAX_RPM':              (0x050, 15, 0,  'Max RPM for speed fault check (default 6000)'),
    'PLL_PHASE_ERR_THRESH': (0x054, 31, 0,  'Max abs PLL phase error angfac before fault'),
    'TDC_OFFSET':           (0x058, 31, 0,  'TDC offset from Z edge (angfac)'),
    'DMA_BUFFER_SIZE':      (0x05C, 3,  0,  'Z-edge cycles per DMA buffer (default 2)'),
}

# =============================================================================
# Read register map
# =============================================================================
READ_REGS = {
    'CAM_TOOTH_COUNT':      (0x070, 7,  0,  'Cam edge count per 2 crank revs'),
    'CRANK_TOOTH_PERIOD':   (0x074, 31, 0,  'Last tooth period (clocks @ 100MHz)'),
    'CRANK_TOOTH_COUNT':    (0x078, 7,  0,  'Real tooth count per revolution'),
    'CRANK_AB_COUNT':       (0x07C, 7,  0,  'All ab edges per rev including interpolated'),
    'ENC_AB_PERIOD':        (0x080, 31, 0,  'Encoder ab period (clocks)'),
    'ENC_AB_COUNT':         (0x084, 7,  0,  'Encoder ab edge count'),
    'ENC_A_COUNT':          (0x088, 7,  0,  'Encoder A channel count'),
    'ENC_B_COUNT':          (0x08C, 7,  0,  'Encoder B channel count'),
    'ANGLE_ANGFAC':         (0x090, 31, 0,  'Tooth-based crank angle (angfac)'),
    'ANGLE_NCO_CLK_INC':    (0x094, 31, 0,  'Per-clock angfac increment (interpolation)'),
    'ANGLE_NCO_AB_INC':     (0x098, 31, 0,  '2^32/ppr -- per-tooth angfac increment'),
    'PHASE_REF_ANGFAC':     (0x09C, 31, 0,  'Angfac at last cam detection'),
    'PHASE_REF_DET':        (0x0A0, 0,  0,  'Cam detection strobe (1-clock)'),
    'PHASE_REF_FOUND':      (0x0A4, 0,  0,  '1 after first valid cam detection'),
    'PHASE_ENG':            (0x0A8, 0,  0,  'Engine phase: 0 or 1'),
    'PHASE_REF_OK':         (0x0AC, 0,  0,  'Cam detection healthy'),
    'PHASE_REF_DET_CNT':    (0x0B0, 15, 0,  'Cumulative cam detection count'),
    'SYNC_STATE':           (0x0B4, 1,  0,  '0=STOPPED 1=MOVING 2=CRANK_SYNC 3=FULL_SYNC'),
    'SPEED_RPM_SLOW':       (0x0B8, 15, 0,  'RPM from z_period (updated each z_edge)'),
    'SPEED_RPM_FAST':       (0x0BC, 15, 0,  'RPM from ab_period (updated each ab_edge)'),
    'PLL_ANGFAC':           (0x0C0, 31, 0,  'PLL NCO angle (angfac)'),
    'PLL_DIV_VALID':        (0x0C4, 0,  0,  'PLL active (sync_full)'),
    'PLL_NCO_ACCUM':        (0x0C8, 31, 0,  'Raw NCO accumulator (= PLL_ANGFAC)'),
    'PLL_ERR_ANGFAC':       (0x0CC, 31, 0,  'Signed phase error (angfac, two\'s complement)'),
    'PLL_P_TERM':           (0x0D0, 31, 0,  'Signed proportional term'),
    'PLL_I_TERM':           (0x0D4, 31, 0,  'Signed integral term (upper 32 of 64)'),
    'PLL_PI_CORR':          (0x0D8, 31, 0,  'Signed PI correction applied to NCO'),
    'PLL_NCO_INC':          (0x0DC, 31, 0,  'Current NCO increment per clock'),
    'TRIG_COUNT':           (0x0E0, 31, 0,  'Trigger pulse count since last z_edge'),
    'FAULT_FLAGS':          (0x0E4, 31, 0,  '[0]=cam [1]=crank_tooth [2]=crank_ab '
                                             '[3]=speed [4]=pll_phase_err'),
    'FAULT_CAM_COUNT':      (0x0E8, 15, 0,  'Cam fault event count'),
    'FAULT_CRANK_COUNT':    (0x0EC, 15, 0,  'Crank fault event count'),
    'FAULT_PLL_COUNT':      (0x0F0, 15, 0,  'Phase_ref_ok fault count'),
    'FAULT_AB_COUNT':       (0x0F4, 15, 0,  'AB count mismatch fault count'),
    'FAULT_SPEED_COUNT':    (0x0F8, 15, 0,  'Speed fault event count'),
    'FAULT_ENC_COUNT':      (0x0FC, 15, 0,  'Encoder fault event count'),
    'TDC_DEG':              (0x100, 15, 0,  'TDC-referenced engine angle (0-7199, 0.1 deg/LSB)'),
    'PKT_COUNT':            (0x104, 31, 0,  'DMA packet count'),
    'OVF_COUNT':            (0x108, 15, 0,  'DMA overflow count'),
}

ALL_REGS = {**WRITE_REGS, **READ_REGS}

# =============================================================================
# DMA packet format (3 x 32-bit words per sample, packed by pack.vhd)
#
#   Word 0: [31:16] speed_rpm_slow   [15:0]  speed_rpm_fast
#   Word 1: [31:0]  tdc_deg          (0-7199, 0.1 deg/LSB, 0.0-719.9 deg)
#   Word 2: [31:24] DI[7:0]          [23:16] 0x00
#            [15:4] pressure[11:0]   [3:0]   0x0
#
# Python unpacking:
#   rpm_slow  = (buf[0] >> 16) & 0xFFFF
#   rpm_fast  =  buf[0]        & 0xFFFF
#   tdc_deg   =  buf[1]        * 0.1        # degrees
#   di        = (buf[2] >> 24) & 0xFF
#   pressure  = (buf[2] >>  4) & 0xFFF     # 12-bit XADC VAUX1
# =============================================================================
DMA_WORDS_PER_SAMPLE = 3


class AngusRegs:
    """
    Raw AXI register access for Angus. Named-register read/write only.
    Use angus.Angus for the full application API.
    """

    def __init__(self, ip_core):
        self._ip = ip_core

    def read(self, name):
        """Read a named register. Returns unsigned field value."""
        addr, msb, lsb, _ = ALL_REGS[name]
        raw  = self._ip.read(addr) & 0xFFFF_FFFF
        mask = (1 << (msb - lsb + 1)) - 1
        return (raw >> lsb) & mask

    def read_signed(self, name):
        """Read a named register as signed 32-bit integer."""
        val = self.read(name)
        return val - 0x1_0000_0000 if val >= 0x8000_0000 else val

    def write(self, name, value):
        """Write a named register (field-masked, lsb-aligned)."""
        addr, msb, lsb, _ = WRITE_REGS[name]
        mask = (1 << (msb - lsb + 1)) - 1
        self._ip.write(addr, (int(value) & mask) << lsb)

    def read_raw(self, addr):
        """Read a 32-bit register by byte address."""
        return self._ip.read(addr) & 0xFFFF_FFFF

    def write_raw(self, addr, value):
        """Write a 32-bit register by byte address."""
        self._ip.write(addr, int(value) & 0xFFFF_FFFF)
