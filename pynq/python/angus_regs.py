"""
angus_regs.py
=============
Named AXI register access for the Angus combustion analyser overlay.

Usage:
    from angus_regs import AngusRegs
    regs = AngusRegs(ol.top_0)

    # Write startup config then apply (held in reset until config_apply)
    regs.write('N_TEETH',   60)
    regs.write('N_MISSING',  2)
    regs.write('GAP_THRESH', 192)
    regs.config_apply(edge_select=1)   # releases PL reset

    # Runtime config (can change any time)
    regs.write('KP', 256)
    regs.write('TDC_OFFSET', 0)

    # Read status
    print(regs.read('SYNC_STATE'))     # 0-3
    print(regs.phase_err_deg())        # phase error in degrees (float)

    # Pretty-print all registers
    regs.print_all()

Register map
------------
CONTROL word (0x00):
  [6] config_apply   - self-clearing, latches startup config and releases PL reset
  [5] ref_sel        - startup: 0=cam_input, 1=peak_detector
  [4] ang_sel        - startup: 0=crank_input, 1=enc_input
  [3] phase_fault_drop - 0=count only, 1=drop to SYNC_CRANK on phase fault
  [2] correction_dir - 0=subtract correction, 1=add correction
  [1] fault_clear    - self-clearing
  [0] edge_select    - startup: 0=falling edge, 1=rising edge

Startup config (latched on config_apply, PL held in reset until first apply):
  0x00 CONTROL      [0]    edge_select
  0x00 CONTROL      [4]    ang_sel
  0x00 CONTROL      [5]    ref_sel
  0x04 GAP_THRESH   [7:0]  gap_threshold
  0x64 N_TEETH      [7:0]  n_teeth (default 60)
  0x68 N_MISSING    [7:0]  n_missing (default 2)

Runtime config (direct from registers, update any time):
  0x00 CONTROL      [2]    correction_dir
  0x00 CONTROL      [3]    phase_fault_drop
  0x08 PLL_KP       [15:0] kp
  0x0C PLL_KI       [15:0] ki
  0x10 PLL_MAXC     [15:0] max_correction
  0x14 PHASE_ANG    [15:0] expected_phase_angle (0-7199, 0.1 deg)
  0x18 PHASE_TOL    [15:0] phase_tolerance (0-7199, 0.1 deg)
  0x1C TDC_OFF      [15:0] tdc_offset (0-7199, 0.1 deg)
  0x20 DECIMATION   [7:0]  decimation
  0x60 PULSE_WIDTH  [15:0] debug pulse stretch (clock cycles, default 1000)
"""

# =============================================================================
# Register map
# =============================================================================

# Write registers (PS → PL)
# Tuple: (byte_addr, hi_bit, lo_bit, description)
WRITE_REGS = {
    # CONTROL word fields
    'EDGE_SELECT':      (0x00,  0,  0, 'Startup: 0=falling edge, 1=rising edge (latched on config_apply)'),
    'FAULT_CLEAR':      (0x00,  1,  1, 'Self-clearing fault clear pulse'),
    'CORRECTION_DIR':   (0x00,  2,  2, '0=subtract correction, 1=add correction'),
    'PHASE_FAULT_DROP': (0x00,  3,  3, '0=count only, 1=drop to SYNC_CRANK on phase fault'),
    'ANG_SEL':          (0x00,  4,  4, 'Startup: 0=crank_input, 1=enc_input (latched on config_apply)'),
    'REF_SEL':          (0x00,  5,  5, 'Startup: 0=cam_input, 1=peak_detector (latched on config_apply)'),
    'CONFIG_APPLY':     (0x00,  6,  6, 'Self-clearing: latches startup config and releases PL reset'),

    # Startup config registers (written before config_apply)
    'GAP_THRESH':       (0x04,  7,  0, 'Gap threshold 1.7 fixed point (0xC0 = 1.5x tooth period)'),
    'N_TEETH':          (0x64,  7,  0, 'Total teeth on wheel including missing (default 60)'),
    'N_MISSING':        (0x68,  7,  0, 'Number of missing teeth (default 2)'),

    # Runtime config registers
    'KP':               (0x08, 15,  0, 'PI proportional gain'),
    'KI':               (0x0C, 15,  0, 'PI integral gain'),
    'MAX_CORR':         (0x10, 15,  0, 'PI maximum correction (NCO LSB)'),
    'PHASE_ANG':        (0x14, 15,  0, 'Expected cam phase angle (0-7199, 0.1 deg steps)'),
    'PHASE_TOL':        (0x18, 15,  0, 'Cam phase window tolerance (0-7199, 0.1 deg steps)'),
    'TDC_OFFSET':       (0x1C, 15,  0, 'TDC offset applied to engine angle (0-7199, 0.1 deg)'),
    'DECIMATION':       (0x20,  7,  0, 'Sample trigger decimation (1=every step)'),
    'PULSE_WIDTH':      (0x60, 15,  0, 'Debug pulse stretch width (clock cycles, 1000=10us @ 100MHz)'),
}

# Read registers (PL → PS)
READ_REGS = {
    # Status
    'STATUS':           (0x24, 31,  0, 'Full status word'),
    'SYNC_STATE':       (0x24,  2,  0, '0=UNSYNC 1=FIRST_GAP 2=SYNC_CRANK 3=SYNC_FULL'),
    'PHASE_FAULT':      (0x24,  3,  3, 'Phase fault flag'),
    'SIGNAL_PRESENT':   (0x24,  4,  4, 'Crank signal present'),
    'SYNCED':           (0x24,  5,  5, 'Sync state = SYNC_FULL'),
    'SYNC_LOSS':        (0x28, 15,  0, 'Sync loss event count'),
    'PHASE_FLT_CNT':    (0x2C, 15,  0, 'Phase fault event count'),
    'PKT_COUNT':        (0x30, 31,  0, 'DMA packet count'),
    'OVF_COUNT':        (0x34, 15,  0, 'DMA overflow count'),

    # Angles
    'RAW_ANGLE':        (0x38, 15,  0, 'Tooth-based angle from angle_calc (0-7199, 0.1 deg)'),
    'CRANK_ANGLE':      (0x3C, 15,  0, 'TDC-corrected angle from phase_detector (0-7199, 0.1 deg)'),
    'ENGINE_ANGLE':     (0x40, 15,  0, 'NCO high-res angle from angle_engine (0-7199, 0.1 deg)'),

    # Debug
    'AB_COUNT':         (0x44,  7,  0, 'Teeth counted this revolution (expect n_teeth at Z)'),
    'TOOTH_PERIOD':     (0x48, 31,  0, 'Last tooth period (clock cycles @ 100MHz)'),
    'GAP_PERIOD':       (0x4C, 31,  0, 'Last gap period (clock cycles @ 100MHz)'),
    'NCO_INC':          (0x50, 31,  0, 'NCO frequency word (steps_per_tooth / ab_period)'),
    'PHASE_ERR':        (0x54, 31,  0, 'Signed PI phase error (NCO accumulator units)'),
    'CORRECTION':       (0x58, 31,  0, 'Signed PI correction applied to NCO (NCO LSB)'),
    'CAM_ANGLE':        (0x5C, 15,  0, 'Cam edge angle at detection (0-7199, 0.1 deg)'),
}

# Write registers are also readable - same address map
READ_REGS.update({
    'CONTROL':          (0x00, 31,  0, 'Full control word (readback)'),
})

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
        """Write a named register field (read-modify-write for sub-word fields)."""
        if name not in WRITE_REGS:
            raise KeyError(f"'{name}' is not a writable register")
        addr, hi, lo, _ = WRITE_REGS[name]
        width = hi - lo + 1
        if width < 32:
            # Sub-field: read-modify-write
            word = self._raw_read(addr)
            mask = ((1 << width) - 1) << lo
            word = (word & ~mask) | ((int(value) << lo) & mask)
            self._raw_write(addr, word)
        else:
            self._raw_write(addr, int(value))

    # -------------------------------------------------------------------------
    # Config apply
    # Startup config must be written before calling this.
    # Pulses config_apply (CONTROL[6]), which latches edge_select, ang_sel,
    # ref_sel, gap_threshold, n_teeth, n_missing and releases PL from reset.
    # -------------------------------------------------------------------------
    def config_apply(self, edge_select=1, ang_sel=0, ref_sel=0,
                     correction_dir=0, phase_fault_drop=0):
        """
        Latch startup config and release PL reset.

        Write N_TEETH, N_MISSING, GAP_THRESH before calling this.
        Runtime config (KP, KI, etc.) can be written before or after.

        Args:
            edge_select:      0=falling edge, 1=rising edge
            ang_sel:          0=crank_input, 1=enc_input
            ref_sel:          0=cam_input, 1=peak_detector
            correction_dir:   0=subtract correction, 1=add correction
            phase_fault_drop: 0=count only, 1=drop to SYNC_CRANK on fault
        """
        ctrl = (
            (edge_select      & 0x1)       |
            ((correction_dir  & 0x1) << 2) |
            ((phase_fault_drop & 0x1) << 3) |
            ((ang_sel          & 0x1) << 4) |
            ((ref_sel          & 0x1) << 5) |
            (1 << 6)   # config_apply self-clears in PL next cycle
        )
        self._raw_write(0x00, ctrl)

    def fault_clear(self):
        """Pulse fault_clear bit (CONTROL[1]). Self-clears in PL."""
        ctrl = self._raw_read(0x00)
        self._raw_write(0x00, ctrl | 0x02)

    # -------------------------------------------------------------------------
    # Quick-start helper
    # -------------------------------------------------------------------------
    def configure(self, n_teeth=60, n_missing=2, gap_thresh=192,
                  kp=256, ki=16, max_corr=1024,
                  phase_ang=1800, phase_tol=600, tdc_offset=0,
                  decimation=1, pulse_width=1000,
                  edge_select=1, ang_sel=0, ref_sel=0,
                  correction_dir=0, phase_fault_drop=0):
        """
        Write all registers and apply startup config in one call.

        Startup config (edge_select, ang_sel, ref_sel, gap_thresh,
        n_teeth, n_missing) is latched by config_apply at the end,
        which also releases the PL from reset.
        """
        # Startup config - write before config_apply
        self.write('N_TEETH',    n_teeth)
        self.write('N_MISSING',  n_missing)
        self.write('GAP_THRESH', gap_thresh)

        # Runtime config
        self.write('KP',         kp)
        self.write('KI',         ki)
        self.write('MAX_CORR',   max_corr)
        self.write('PHASE_ANG',  phase_ang)
        self.write('PHASE_TOL',  phase_tol)
        self.write('TDC_OFFSET', tdc_offset)
        self.write('DECIMATION', decimation)
        self.write('PULSE_WIDTH', pulse_width)

        # Latch startup config and release PL reset
        self.config_apply(
            edge_select=edge_select,
            ang_sel=ang_sel,
            ref_sel=ref_sel,
            correction_dir=correction_dir,
            phase_fault_drop=phase_fault_drop,
        )

    # -------------------------------------------------------------------------
    # Convenience computed values
    # -------------------------------------------------------------------------
    def rpm(self):
        """Current engine speed in RPM (based on tooth period)."""
        tp = self.read('TOOTH_PERIOD')
        n  = self.read('N_TEETH')
        if tp == 0 or n == 0:
            return 0
        # One crank revolution = n_teeth tooth periods (one revolution = 360 deg)
        return round(CLK_FREQ / tp / n * 60)

    def phase_err_deg(self):
        """Phase error in degrees (float, NCO-referenced)."""
        pe = self.read_signed('PHASE_ERR')
        return pe / NCO_FULL * 360.0

    def raw_angle_deg(self):
        """Tooth-based angle in degrees (float)."""
        return self.read('RAW_ANGLE') / 10.0

    def engine_angle_deg(self):
        """NCO high-res angle in degrees (float)."""
        return self.read('ENGINE_ANGLE') / 10.0

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
    # Pretty-print helpers
    # -------------------------------------------------------------------------
    def print_config(self):
        """Print all configuration registers."""
        n = self.read('N_TEETH')
        print("=== Configuration ===")
        print(f"  N_TEETH          = {n}")
        print(f"  N_MISSING        = {self.read('N_MISSING')}")
        print(f"  GAP_THRESH       = {self.read('GAP_THRESH')}")
        print(f"  EDGE_SELECT      = {self.read('EDGE_SELECT')}"
              f"  ({'rising' if self.read('EDGE_SELECT') else 'falling'})")
        print(f"  ANG_SEL          = {self.read('ANG_SEL')}"
              f"  ({'enc_input' if self.read('ANG_SEL') else 'crank_input'})")
        print(f"  REF_SEL          = {self.read('REF_SEL')}"
              f"  ({'peak_detector' if self.read('REF_SEL') else 'cam_input'})")
        print(f"  CORRECTION_DIR   = {self.read('CORRECTION_DIR')}"
              f"  ({'add' if self.read('CORRECTION_DIR') else 'subtract'})")
        print(f"  PHASE_FAULT_DROP = {self.read('PHASE_FAULT_DROP')}"
              f"  ({'drop to SYNC_CRANK' if self.read('PHASE_FAULT_DROP') else 'count only'})")
        print(f"  KP               = {self.read('KP')}")
        print(f"  KI               = {self.read('KI')}")
        print(f"  MAX_CORR         = {self.read('MAX_CORR')}")
        print(f"  PHASE_ANG        = {self.read('PHASE_ANG')}"
              f"  ({self.read('PHASE_ANG')/10:.1f} deg)")
        print(f"  PHASE_TOL        = {self.read('PHASE_TOL')}"
              f"  ({self.read('PHASE_TOL')/10:.1f} deg)")
        print(f"  TDC_OFFSET       = {self.read('TDC_OFFSET')}"
              f"  ({self.read('TDC_OFFSET')/10:.1f} deg)")
        print(f"  DECIMATION       = {self.read('DECIMATION')}")
        pw = self.read('PULSE_WIDTH')
        print(f"  PULSE_WIDTH      = {pw}  ({pw/100:.1f}us @ 100MHz)")

    def print_status(self):
        """Print all status registers."""
        print("=== Status ===")
        print(f"  SYNC_STATE       = {self.read('SYNC_STATE')}"
              f"  ({self.sync_state_name()})")
        print(f"  SIGNAL_PRESENT   = {self.read('SIGNAL_PRESENT')}")
        print(f"  SYNCED           = {self.read('SYNCED')}")
        print(f"  PHASE_FAULT      = {self.read('PHASE_FAULT')}")
        print(f"  SYNC_LOSS        = {self.read('SYNC_LOSS')}")
        print(f"  PHASE_FLT_CNT    = {self.read('PHASE_FLT_CNT')}")
        print(f"  PKT_COUNT        = {self.read('PKT_COUNT')}")
        print(f"  OVF_COUNT        = {self.read('OVF_COUNT')}")
        print(f"  RPM              = {self.rpm()}")
        print(f"  RAW_ANGLE        = {self.read('RAW_ANGLE')}"
              f"  ({self.raw_angle_deg():.1f} deg, tooth-based)")
        print(f"  CRANK_ANGLE      = {self.read('CRANK_ANGLE')}"
              f"  ({self.read('CRANK_ANGLE')/10:.1f} deg, TDC-corrected)")
        print(f"  ENGINE_ANGLE     = {self.read('ENGINE_ANGLE')}"
              f"  ({self.engine_angle_deg():.1f} deg, NCO)")

    def print_debug(self):
        """Print all debug registers."""
        n = self.read('N_TEETH')
        print("=== Debug ===")
        print(f"  AB_COUNT         = {self.read('AB_COUNT')}"
              f"  (of {n} expected)")
        print(f"  TOOTH_PERIOD     = {self.read('TOOTH_PERIOD')}"
              f"  ({self.tooth_period_ms():.3f} ms)")
        print(f"  GAP_PERIOD       = {self.read('GAP_PERIOD')}"
              f"  ({self.gap_period_ms():.3f} ms)")
        print(f"  NCO_INC          = {self.read('NCO_INC')}")
        print(f"  PHASE_ERR        = {self.read_signed('PHASE_ERR')}"
              f"  ({self.phase_err_deg():.3f} deg)")
        print(f"  CORRECTION       = {self.read_signed('CORRECTION')}")
        print(f"  CAM_ANGLE        = {self.read('CAM_ANGLE')}"
              f"  ({self.cam_angle_deg():.1f} deg)")

    def print_all(self):
        """Print all registers."""
        self.print_config()
        print()
        self.print_status()
        print()
        self.print_debug()
