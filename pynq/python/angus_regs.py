"""
angus_regs.py
=============
Named AXI register access for the Angus combustion analyser overlay.

Usage:
    from angus_regs import AngusRegs
    regs = AngusRegs(ol.top_0)

    # Write configuration
    regs.write('KP', 256)
    regs.write('GAP_THRESH', 192)

    # Read status
    print(regs.read('SYNC_STATE'))     # 0-3
    print(regs.read('PHASE_ERR_DEG'))  # phase error in degrees (float)

    # Pretty-print all registers
    regs.print_status()
    regs.print_config()
    regs.print_debug()
"""

# =============================================================================
# Register map
# =============================================================================

# Write registers (PS → PL)
WRITE_REGS = {
    # Name            addr   bits     description
    'CONTROL':       (0x00, 31,  0, 'Control register'),
    'EDGE_SELECT':   (0x00,  0,  0, '0=falling edge, 1=rising edge'),
    'FAULT_CLEAR':   (0x00,  1,  1, 'Self-clearing fault clear pulse'),
    'CORRECTION_DIR':(0x00,  2,  2, '0=subtract correction, 1=add correction'),
    'PHASE_FAULT_DROP':(0x00, 3, 3, '0=count only, 1=drop to SYNC_CRANK on phase fault'),
    'GAP_THRESH':    (0x04,  7,  0, 'Gap threshold (192=1.5x tooth period)'),
    'KP':            (0x08, 15,  0, 'PI proportional gain'),
    'KI':            (0x0C, 15,  0, 'PI integral gain'),
    'MAX_CORR':      (0x10, 15,  0, 'PI maximum correction (NCO LSB)'),
    'PHASE_ANG':     (0x14, 15,  0, 'Expected cam phase angle (0-7199, 0.1deg steps)'),
    'PHASE_TOL':     (0x18, 15,  0, 'Cam phase window tolerance (0-7199)'),
    'TDC_OFFSET':    (0x1C, 15,  0, 'TDC offset applied to engine angle'),
    'DECIMATION':    (0x20,  7,  0, 'Sample trigger decimation (1=every step)'),
    'PULSE_WIDTH':   (0x60, 15,  0, 'Debug pulse stretch width (clock cycles, 1000=10us)'),
}

# Read registers (PL → PS)
READ_REGS = {
    # Status
    'STATUS':        (0x24, 31,  0, 'Full status word'),
    'SYNC_STATE':    (0x24,  2,  0, '0=UNSYNC 1=FIRST_GAP 2=SYNC_CRANK 3=SYNC_FULL'),
    'PHASE_FAULT':   (0x24,  3,  3, 'Phase fault flag'),
    'SIGNAL_PRESENT':(0x24,  4,  4, 'Crank signal present'),
    'SYNCED':        (0x24,  5,  5, 'NCO PLL locked'),
    'SYNC_LOSS':     (0x28, 15,  0, 'Sync loss event count'),
    'PHASE_FLT_CNT': (0x2C, 15,  0, 'Phase fault event count'),
    'PKT_COUNT':     (0x30, 31,  0, 'DMA packet count'),
    'OVF_COUNT':     (0x34, 15,  0, 'DMA overflow count'),

    # Angles
    'RAW_ANGLE':     (0x38, 15,  0, 'Raw NCO angle (0-7199, 0.1deg steps)'),
    'CRANK_ANGLE':   (0x3C, 15,  0, 'Crank angle with TDC offset'),
    'ENGINE_ANGLE':  (0x40, 15,  0, 'Engine angle (4-stroke, 0-7199)'),

    # Debug
    'AB_COUNT':      (0x44,  7,  0, 'Teeth counted this revolution'),
    'TOOTH_PERIOD':  (0x48, 31,  0, 'Current tooth period (clock cycles @ 100MHz)'),
    'GAP_PERIOD':    (0x4C, 31,  0, 'Last gap period (clock cycles @ 100MHz)'),
    'NCO_INC':       (0x50, 31,  0, 'NCO frequency word (from divider)'),
    'PHASE_ERR':     (0x54, 31,  0, 'Signed PI phase error (NCO units)'),
    'CORRECTION':    (0x58, 31,  0, 'Signed PI correction (NCO LSB)'),
    'CAM_ANGLE':     (0x5C, 15,  0, 'Cam edge angle at detection (0-7199)'),
}

SYNC_STATES = {0: 'UNSYNC', 1: 'FIRST_GAP', 2: 'SYNC_CRANK', 3: 'SYNC_FULL'}
CLK_FREQ    = 100_000_000
NCO_FULL    = 4_294_967_296  # 2^32


class AngusRegs:
    def __init__(self, mmio):
        """
        mmio: the pynq MMIO object e.g. ol.top_0
        """
        self._m = mmio

    # -------------------------------------------------------------------------
    # Raw register access
    # -------------------------------------------------------------------------
    def _raw_read(self, addr):
        return self._m.read(addr)

    def _raw_write(self, addr, value):
        self._m.write(addr, value)

    def _extract_bits(self, word, hi, lo):
        mask = (1 << (hi - lo + 1)) - 1
        return (word >> lo) & mask

    # -------------------------------------------------------------------------
    # Named register read
    # -------------------------------------------------------------------------
    def read(self, name):
        """Read a named register field. Returns integer."""
        if name in READ_REGS:
            addr, hi, lo, _ = READ_REGS[name]
        elif name in WRITE_REGS:
            addr, hi, lo, _ = WRITE_REGS[name]
        else:
            raise KeyError(f"Unknown register: '{name}'")
        word = self._raw_read(addr)
        return self._extract_bits(word, hi, lo)

    def read_signed(self, name):
        """Read a named register field as signed 32-bit integer."""
        v = self.read(name)
        if v > 0x7FFFFFFF:
            v -= 0x100000000
        return v

    # -------------------------------------------------------------------------
    # Named register write
    # -------------------------------------------------------------------------
    def write(self, name, value):
        """Write a named register field."""
        if name not in WRITE_REGS:
            raise KeyError(f"'{name}' is not a writable register")
        addr, hi, lo, _ = WRITE_REGS[name]
        if hi == lo and hi < 31:
            # Single bit or sub-field - read-modify-write
            word = self._raw_read(addr)
            mask = ((1 << (hi - lo + 1)) - 1) << lo
            word = (word & ~mask) | ((value << lo) & mask)
            self._raw_write(addr, word)
        else:
            self._raw_write(addr, value)

    # -------------------------------------------------------------------------
    # Convenience computed values
    # -------------------------------------------------------------------------
    def rpm(self):
        """Current engine speed in RPM."""
        tp = self.read('TOOTH_PERIOD')
        if tp == 0:
            return 0
        return round(CLK_FREQ / tp * 60 / 60)

    def phase_err_deg(self):
        """Phase error in degrees (float)."""
        pe = self.read_signed('PHASE_ERR')
        return pe / NCO_FULL * 360.0

    def raw_angle_deg(self):
        """Raw angle in degrees (float)."""
        return self.read('RAW_ANGLE') / 10.0

    def cam_angle_deg(self):
        """Cam detection angle in degrees (float)."""
        return self.read('CAM_ANGLE') / 10.0

    def gap_period_ms(self):
        """Gap period in milliseconds."""
        return self.read('GAP_PERIOD') / CLK_FREQ * 1000.0

    def tooth_period_ms(self):
        """Tooth period in milliseconds."""
        return self.read('TOOTH_PERIOD') / CLK_FREQ * 1000.0

    def sync_state_name(self):
        """Sync state as string."""
        return SYNC_STATES.get(self.read('SYNC_STATE'), '?')

    # -------------------------------------------------------------------------
    # Configuration helpers
    # -------------------------------------------------------------------------
    def configure(self, gap_thresh=192, kp=256, ki=16, max_corr=1024,
                  phase_ang=0, phase_tol=300, tdc_offset=0, decimation=1,
                  edge_select=1, correction_dir=0, pulse_width=1000,
                  phase_fault_drop=0):
        """Write all configuration registers in one call."""
        self.write('GAP_THRESH',    gap_thresh)
        self.write('KP',            kp)
        self.write('KI',            ki)
        self.write('MAX_CORR',      max_corr)
        self.write('PHASE_ANG',     phase_ang)
        self.write('PHASE_TOL',     phase_tol)
        self.write('TDC_OFFSET',    tdc_offset)
        self.write('DECIMATION',    decimation)
        self.write('PULSE_WIDTH',   pulse_width)
        # Build CONTROL word
        ctrl = ((edge_select      & 0x1)      |
                ((correction_dir  & 0x1) << 2) |
                ((phase_fault_drop & 0x1) << 3) | 0x01)
        self._raw_write(0x00, ctrl)

    def fault_clear(self):
        """Pulse fault_clear bit."""
        ctrl = self._raw_read(0x00)
        self._raw_write(0x00, ctrl | 0x02)

    # -------------------------------------------------------------------------
    # Pretty-print helpers
    # -------------------------------------------------------------------------
    def print_config(self):
        """Print all write (configuration) registers."""
        print("=== Configuration ===")
        print(f"  EDGE_SELECT    = {self.read('EDGE_SELECT')}"
              f"  ({'rising' if self.read('EDGE_SELECT') else 'falling'})")
        print(f"  CORRECTION_DIR = {self.read('CORRECTION_DIR')}"
              f"  ({'add' if self.read('CORRECTION_DIR') else 'subtract'})")
        print(f"  PHASE_FAULT_DROP = {self.read('PHASE_FAULT_DROP')}"
              f"  ({'drop to SYNC_CRANK' if self.read('PHASE_FAULT_DROP') else 'count only'})")
        print(f"  GAP_THRESH     = {self.read('GAP_THRESH')}")
        print(f"  KP             = {self.read('KP')}")
        print(f"  KI             = {self.read('KI')}")
        print(f"  MAX_CORR       = {self.read('MAX_CORR')}")
        print(f"  PHASE_ANG      = {self.read('PHASE_ANG')}"
              f"  ({self.read('PHASE_ANG')/10:.1f} deg)")
        print(f"  PHASE_TOL      = {self.read('PHASE_TOL')}"
              f"  ({self.read('PHASE_TOL')/10:.1f} deg)")
        print(f"  TDC_OFFSET     = {self.read('TDC_OFFSET')}")
        print(f"  DECIMATION     = {self.read('DECIMATION')}")
        pw = self.read('PULSE_WIDTH')
        print(f"  PULSE_WIDTH    = {pw}  ({pw/100:.1f}us at 100MHz)")

    def print_status(self):
        """Print all status registers."""
        print("=== Status ===")
        print(f"  SYNC_STATE     = {self.read('SYNC_STATE')}"
              f"  ({self.sync_state_name()})")
        print(f"  SIGNAL_PRESENT = {self.read('SIGNAL_PRESENT')}")
        print(f"  SYNCED         = {self.read('SYNCED')}")
        print(f"  PHASE_FAULT    = {self.read('PHASE_FAULT')}")
        print(f"  SYNC_LOSS      = {self.read('SYNC_LOSS')}")
        print(f"  PHASE_FLT_CNT  = {self.read('PHASE_FLT_CNT')}")
        print(f"  PKT_COUNT      = {self.read('PKT_COUNT')}")
        print(f"  OVF_COUNT      = {self.read('OVF_COUNT')}")
        print(f"  RPM            = {self.rpm()}")
        print(f"  RAW_ANGLE      = {self.read('RAW_ANGLE')}"
              f"  ({self.raw_angle_deg():.1f} deg)")
        print(f"  ENGINE_ANGLE   = {self.read('ENGINE_ANGLE')}"
              f"  ({self.read('ENGINE_ANGLE')/10:.1f} deg)")

    def print_debug(self):
        """Print all debug registers."""
        print("=== Debug ===")
        print(f"  AB_COUNT       = {self.read('AB_COUNT')}"
              f"  (of 60 expected)")
        print(f"  TOOTH_PERIOD   = {self.read('TOOTH_PERIOD')}"
              f"  ({self.tooth_period_ms():.2f}ms)")
        print(f"  GAP_PERIOD     = {self.read('GAP_PERIOD')}"
              f"  ({self.gap_period_ms():.2f}ms)")
        print(f"  NCO_INC        = {self.read('NCO_INC')}")
        print(f"  PHASE_ERR      = {self.read_signed('PHASE_ERR')}"
              f"  ({self.phase_err_deg():.3f} deg)")
        print(f"  CORRECTION     = {self.read_signed('CORRECTION')}")
        print(f"  CAM_ANGLE      = {self.read('CAM_ANGLE')}"
              f"  ({self.cam_angle_deg():.1f} deg)")

    def print_all(self):
        """Print all registers."""
        self.print_config()
        print()
        self.print_status()
        print()
        self.print_debug()
