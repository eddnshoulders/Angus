"""
angus_regs.py -- PYNQ register interface for Angus combustion analyser v2.

Register map matches axi_lite_regs.vhd v2 (commit 0f6395b+).

Usage:
    from angus_regs import AngusRegs
    regs = AngusRegs(overlay.axi_lite_regs_0)
    regs.write('CRANK_N_TEETH', 60)
    regs.config_apply()
    state = regs.read('SYNC_STATE')
"""

import time

# ==============================================================================
# Write register map (address, msb, lsb, description)
# ==============================================================================
WRITE_REGS = {
    'CONTROL':              (0x000, 6,  0, '[0]=crank_edge_sel [1]=src_sel [2]=ref_sel '
                                           '[3]=config_apply(self-clr) [4]=cam_edge_sel '
                                           '[5]=ang_sel [6]=angle_interp_en'),
    'CONTROL_RT':           (0x004, 2,  0, '[0]=fault_clear(self-clr) [1]=pll_corr_dir '
                                           '[2]=phase_fault_drop'),
    'RST_CYCLES':           (0x008, 8,  0, 'Reset duration clocks (default 256)'),
    'PEAK_HYST':            (0x00C, 15, 0, 'Peak detector hysteresis counts (default 128)'),
    'PEAK_PULSE_CYCLES':    (0x010, 15, 0, 'Peak pulse width clocks (default 100)'),
    'CAM_DBC':              (0x014, 15, 0, 'Cam debounce cycles (default 5 = 50ns @ 100MHz)'),
    'CRANK_DBC':            (0x018, 15, 0, 'Crank debounce cycles (default 5)'),
    'ENC_A_DBC':            (0x01C, 15, 0, 'Encoder A debounce cycles (default 5)'),
    'ENC_B_DBC':            (0x020, 15, 0, 'Encoder B debounce cycles (default 5)'),
    'ENC_Z_DBC':            (0x024, 15, 0, 'Encoder Z debounce cycles (default 5)'),
    'CRANK_GAP_THRESH':     (0x028, 7,  0, 'Gap threshold 1.7fp (0xC0=1.5x tooth period)'),
    'CRANK_N_TEETH':        (0x02C, 7,  0, 'Total teeth inc missing (default 60)'),
    'CRANK_N_MISSING':      (0x030, 7,  0, 'Missing teeth (default 2)'),
    'CAM_N_TEETH':          (0x034, 7,  0, 'Cam teeth per 2 crank revs (default 1)'),
    'ENC_N_PPR':            (0x038, 15, 0, 'Encoder edges per revolution (after A/B/both sel)'),
    'ENC_AB_EDGE_SEL':      (0x03C, 1,  0, '0=rising 1=falling 2=both'),
    'ENC_Z_EDGE_SEL':       (0x040, 0,  0, '0=rising 1=falling'),
    'PHASE_REF_ANG':        (0x044, 15, 0, 'Expected ref angle 0-7199 (0.1deg units)'),
    'PHASE_REF_TOL':        (0x048, 15, 0, 'Window tolerance +/- 0-7199 (0.1deg units)'),
    'TDC_OFFSET':           (0x04C, 15, 0, 'TDC offset 0-7199 (0.1deg units)'),
    'PLL_PHASE_ERR_THRESH': (0x050, 31, 0, 'Max abs PLL phase error NCO units before fault'),
    'PLL_KP':               (0x054, 15, 0, 'PLL proportional gain (default 0)'),
    'PLL_KI':               (0x058, 15, 0, 'PLL integral gain (default 0)'),
    'PLL_CORR_MAX':         (0x05C, 15, 0, 'PLL max correction NCO LSB'),
    'TRIG_DECIMATION':      (0x060, 15, 0, 'Sample trigger decimation (1=every 0.1deg)'),
    'TRIG_PULSE_CYCLES':    (0x064, 15, 0, 'Trigger pulse width clocks (default 1000)'),
    'MAX_RPM':              (0x068, 15, 0, 'Max RPM for speed fault check (default 6000)'),
    'DMA_BUFFER_SIZE':      (0x06C, 3,  0, 'Z-edge cycles per DMA buffer (default 2)'),
}

# ==============================================================================
# Read register map
# ==============================================================================
READ_REGS = {
    # Sync
    'SYNC_STATE':           (0x070, 1,  0, '0=STOPPED 1=MOVING 2=CRANK_SYNC 3=FULL_SYNC'),
    'SYNC_FAULT_COUNT':     (0x074, 15, 0, 'Sync fault count'),
    # Speed
    'SPEED_RPM_SLOW':       (0x078, 15, 0, 'RPM from z_period (updated each z_edge)'),
    'SPEED_RPM_FAST':       (0x07C, 15, 0, 'RPM from ab_period (updated each ab_edge)'),
    # Angle
    'ANGLE_DEG':            (0x080, 15, 0, 'Tooth-based angle 0-7199 (0.1deg units)'),
    # Phase
    'PHASE_RAW':            (0x084, 0,  0, '0=first crank rev 1=second'),
    'PHASE_REF_DET':        (0x088, 0,  0, 'Ref pulse detected in either window (strobe)'),
    'PHASE_REF_OK':         (0x08C, 0,  0, 'Ref pulse in correct window'),
    'PHASE_REF_FOUND':      (0x090, 0,  0, '1 after first valid ref detection'),
    'PHASE_INV':            (0x094, 0,  0, 'Ref in window 2 (inverted phase)'),
    'PHASE_INV_LATCH':      (0x098, 0,  0, 'Phase_inv latched at first detection'),
    'PHASE_ANG_CORR':       (0x09C, 15, 0, 'Phase-corrected angle 0-7199 (0.1deg)'),
    'PHASE_ENG':            (0x0A0, 0,  0, 'Engine phase = phase_raw XOR phase_inv_latch'),
    'PHASE_ENG_ANG':        (0x0A4, 15, 0, 'Engine angle with phase+TDC correction (0.1deg)'),
    'PHASE_REF_DET_CNT':    (0x0A8, 15, 0, 'Ref pulse detection count'),
    # PLL
    'PLL_ANG_HIRES':        (0x0AC, 15, 0, 'PLL NCO angle 0-7199 (0.1deg)'),
    'PLL_DIV_VALID':        (0x0B0, 0,  0, 'PLL active (sync_full)'),
    'PLL_NCO_INC':          (0x0B4, 31, 0, 'Current NCO frequency word'),
    'PLL_NCO_ACCUM':        (0x0B8, 31, 0, 'NCO accumulator (32-bit)'),
    'PLL_PHASE_ERR':        (0x0BC, 31, 0, 'Signed phase error (NCO units)'),
    'PLL_P_TERM':           (0x0C0, 31, 0, 'Signed P term'),
    'PLL_I_TERM':           (0x0C4, 31, 0, 'Signed I term (upper 32 of 64)'),
    'PLL_PI_CORR':          (0x0C8, 31, 0, 'Signed PI correction applied'),
    'PLL_NCO_AB_INC':       (0x0CC, 31, 0, '2^32/ppr -- per-tooth NCO increment (from angle.vhd)'),
    'PLL_CYCLE_AB_COUNT':   (0x0D0, 7,  0, 'Ab edge count since last 2nd z_edge'),
    # Trigger
    'TRIG_PULSE_COUNT':     (0x0D4, 31, 0, 'Trigger pulse count (resets on z_edge)'),
    # Crank
    'CRANK_TOOTH_PERIOD':   (0x0D8, 31, 0, 'Last tooth period (clocks @ 100MHz)'),
    'CRANK_GAP_PERIOD':     (0x0DC, 31, 0, 'Gap period at detection (clocks)'),
    'CRANK_TOOTH_COUNT':    (0x0E0, 7,  0, 'Real tooth count per revolution'),
    'CRANK_AB_COUNT':       (0x0E4, 7,  0, 'All ab edges per rev (inc interpolated)'),
    'CRANK_GAP_DET':        (0x0E8, 0,  0, 'Gap currently detected'),
    # Cam
    'CAM_TOOTH_COUNT':      (0x0EC, 7,  0, 'Cam edge count per 2 crank revs'),
    'REF_ANGLE':            (0x0F0, 15, 0, 'Angle at last ref detection (0.1deg)'),
    # Encoder
    'ENC_AB_COUNT':         (0x0F4, 7,  0, 'Encoder ab edge count'),
    'ENC_A_COUNT':          (0x0F8, 7,  0, 'Encoder A channel count'),
    'ENC_B_COUNT':          (0x0FC, 7,  0, 'Encoder B channel count'),
    'ENC_AB_PERIOD':        (0x100, 31, 0, 'Encoder ab period (clocks)'),
    # Fault
    'FAULT_FLAGS':          (0x104, 31, 0, '[0]=cam [1]=crank_tooth [2]=crank_ab '
                                           '[3]=speed [4]=pll_phase_err'),
    'CAM_FAULT_COUNT':      (0x108, 15, 0, 'Cam fault count'),
    'CRANK_FAULT_COUNT':    (0x10C, 15, 0, 'Crank fault count'),
    'PHASE_FAULT_COUNT':    (0x110, 15, 0, 'Phase fault count'),
    'AB_FAULT_COUNT':       (0x114, 15, 0, 'AB count mismatch fault count'),
    'SPEED_FAULT_COUNT':    (0x118, 15, 0, 'Speed fault count'),
    'PLL_ERR_COUNT':        (0x11C, 15, 0, 'PLL phase error threshold exceeded count'),
    # Pack
    'PKT_COUNT':            (0x120, 31, 0, 'DMA packet count'),
    'OVF_COUNT':            (0x124, 15, 0, 'DMA overflow count'),
}

ALL_REGS = {**WRITE_REGS, **READ_REGS}

# CONTROL bit positions
CTRL_CRANK_EDGE_SEL  = 0
CTRL_SRC_SEL         = 1
CTRL_REF_SEL         = 2
CTRL_CONFIG_APPLY    = 3
CTRL_CAM_EDGE_SEL    = 4
CTRL_ANG_SEL         = 5
CTRL_ANGLE_INTERP_EN = 6

CTRL_RT_FAULT_CLEAR  = 0
CTRL_RT_PLL_CORR_DIR = 1
CTRL_RT_PHASE_DROP   = 2


class AngusRegs:
    """PYNQ register interface for Angus combustion analyser."""

    def __init__(self, ip_core):
        """ip_core: PYNQ IP object with read(offset)/write(offset, value) methods."""
        self._ip = ip_core

    def read(self, name):
        """Read a register by name, returns masked field value."""
        if name not in ALL_REGS:
            raise KeyError(f"Unknown register: {name}")
        addr, msb, lsb, _ = ALL_REGS[name]
        raw = self._ip.read(addr)
        mask = (1 << (msb - lsb + 1)) - 1
        return (raw >> lsb) & mask

    def write(self, name, value):
        """Write a register by name (lsb aligned, masked)."""
        reg = WRITE_REGS.get(name) or ALL_REGS.get(name)
        if reg is None:
            raise KeyError(f"Unknown register: {name}")
        addr, msb, lsb, _ = reg
        mask = (1 << (msb - lsb + 1)) - 1
        self._ip.write(addr, (value & mask) << lsb)

    def config_apply(self, crank_edge_sel=1, src_sel=0, ref_sel=0,
                     cam_edge_sel=1, ang_sel=0, angle_interp_en=0):
        """Latch startup config and pulse config_apply."""
        ctrl = ((crank_edge_sel  & 1) << CTRL_CRANK_EDGE_SEL  |
                (src_sel         & 1) << CTRL_SRC_SEL          |
                (ref_sel         & 1) << CTRL_REF_SEL          |
                (cam_edge_sel    & 1) << CTRL_CAM_EDGE_SEL     |
                (ang_sel         & 1) << CTRL_ANG_SEL          |
                (angle_interp_en & 1) << CTRL_ANGLE_INTERP_EN  |
                1                    << CTRL_CONFIG_APPLY)
        self._ip.write(0x000, ctrl)

    def fault_clear(self):
        """Clear all fault counters."""
        self._ip.write(0x004, 1 << CTRL_RT_FAULT_CLEAR)

    def wait_sync(self, target=3, timeout=10.0):
        """Wait for sync_state >= target. Returns True if reached, False on timeout."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.read('SYNC_STATE') >= target:
                return True
            time.sleep(0.01)
        return False

    def print_status(self):
        """Print human-readable status summary."""
        states = ['STOPPED', 'MOVING', 'CRANK_SYNC', 'FULL_SYNC']
        state = self.read('SYNC_STATE')
        print(f"=== Angus Status ===")
        print(f"  SYNC_STATE     = {states[state]} ({state})")
        print(f"  SPEED_RPM_SLOW = {self.read('SPEED_RPM_SLOW')} RPM")
        print(f"  SPEED_RPM_FAST = {self.read('SPEED_RPM_FAST')} RPM")
        print(f"  ANGLE_DEG      = {self.read('ANGLE_DEG') / 10:.1f} deg")
        print(f"  PHASE_REF_FOUND= {self.read('PHASE_REF_FOUND')}")
        print(f"  PHASE_ENG_ANG  = {self.read('PHASE_ENG_ANG') / 10:.1f} deg")
        print(f"  PLL_ANG_HIRES  = {self.read('PLL_ANG_HIRES') / 10:.1f} deg")
        print(f"  FAULT_FLAGS    = 0x{self.read('FAULT_FLAGS'):08X}")
        print(f"  PKT_COUNT      = {self.read('PKT_COUNT')}")
        print(f"  OVF_COUNT      = {self.read('OVF_COUNT')}")

    def print_config(self):
        """Print current register configuration."""
        ctrl = self._ip.read(0x000)
        print(f"=== Angus Config ===")
        print(f"  CONTROL        = 0x{ctrl:08X}")
        print(f"    crank_edge_sel  = {(ctrl >> 0) & 1}")
        print(f"    src_sel         = {(ctrl >> 1) & 1}")
        print(f"    ref_sel         = {(ctrl >> 2) & 1}")
        print(f"    cam_edge_sel    = {(ctrl >> 4) & 1}")
        print(f"    ang_sel         = {(ctrl >> 5) & 1}")
        print(f"    angle_interp_en = {(ctrl >> 6) & 1}")
        print(f"  RST_CYCLES     = {self.read('RST_CYCLES')}")
        print(f"  PEAK_HYST      = {self.read('PEAK_HYST')}")
        print(f"  PEAK_PULSE_CYCLES = {self.read('PEAK_PULSE_CYCLES')}")
        print(f"  CRANK_N_TEETH  = {self.read('CRANK_N_TEETH')}")
        print(f"  CRANK_N_MISSING= {self.read('CRANK_N_MISSING')}")
        print(f"  CAM_N_TEETH    = {self.read('CAM_N_TEETH')}")
        print(f"  PLL_NCO_AB_INC = {self.read('PLL_NCO_AB_INC')} (from angle.vhd)")
        print(f"  TRIG_DECIMATION= {self.read('TRIG_DECIMATION')}")
        print(f"  MAX_RPM        = {self.read('MAX_RPM')}")
        print(f"  DMA_BUFFER_SIZE= {self.read('DMA_BUFFER_SIZE')}")
