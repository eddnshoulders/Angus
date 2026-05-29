"""
angus_regs.py -- PYNQ register interface for Angus combustion analyser v2.

Usage:
    from angus_regs import AngusRegs
    regs = AngusRegs(overlay.axi_lite_regs_0)
    regs.write('CRANK_N_TEETH', 60)
    regs.config_apply()
    state = regs.read('SYNC_STATE')
"""

import struct, time

# ==============================================================================
# Register map (address, msb, lsb, description)
# All addresses are byte addresses. All registers 32-bit.
# ==============================================================================

WRITE_REGS = {
    # --- CONTROL (startup config, written before config_apply) ---
    'CONTROL':            (0x000, 31,  0, 'Startup config word. [0]=crank_edge_sel [1]=src_sel [2]=ref_sel [3]=config_apply [4]=cam_edge_sel [5]=ang_sel'),
    'CONTROL_RT':         (0x004, 31,  0, 'Runtime control. [0]=fault_clear [1]=pll_corr_dir [2]=phase_fault_drop'),
    'RST_CYCLES':         (0x008,  8,  0, 'Reset duration in clock cycles (default 256)'),

    # --- Filter debounce (runtime) ---
    'CAM_DBC':            (0x00C, 15,  0, 'cam filter debounce cycles (default 5 = 50ns @ 100MHz)'),
    'CRANK_DBC':          (0x010, 15,  0, 'crank filter debounce cycles (default 5)'),
    'ENC_A_DBC':          (0x014, 15,  0, 'encoder A filter debounce cycles (default 5)'),
    'ENC_B_DBC':          (0x018, 15,  0, 'encoder B filter debounce cycles (default 5)'),
    'ENC_Z_DBC':          (0x01C, 15,  0, 'encoder Z filter debounce cycles (default 5)'),

    # --- Crank config (startup) ---
    'CRANK_GAP_THRESH':   (0x020,  7,  0, 'Gap threshold, 1.7 fixed point (0xC0 = 1.5x tooth period)'),
    'CRANK_N_TEETH':      (0x024,  7,  0, 'Total crank teeth including missing (default 60)'),
    'CRANK_N_MISSING':    (0x028,  7,  0, 'Number of missing teeth (default 2)'),

    # --- Cam config (startup) ---
    'CAM_N_TEETH':        (0x02C,  7,  0, 'Cam teeth per 2 crank revolutions (default 1)'),

    # --- Encoder config (startup) ---
    'ENC_N_PPR':          (0x030, 15,  0, 'Encoder pulses per revolution'),
    'ENC_AB_EDGE_SEL':    (0x034,  1,  0, 'Encoder AB edge: 0=rising 1=falling 2=both'),
    'ENC_Z_EDGE_SEL':     (0x038,  0,  0, 'Encoder Z edge: 0=rising 1=falling'),

    # --- Phase config (runtime) ---
    'PHASE_REF_ANG':      (0x03C, 15,  0, 'Expected ref pulse angle 0-7199 0.1deg'),
    'PHASE_REF_TOL':      (0x040, 15,  0, 'Window tolerance +/-, 0-7199 0.1deg'),
    'TDC_OFFSET':         (0x044, 15,  0, 'TDC offset 0-7199 0.1deg'),

    # --- PLL config (runtime) ---
    'PLL_PHASE_ERR_THRESH': (0x048, 31, 0, 'Max abs PLL phase error before fault (NCO units)'),
    'PLL_KP':             (0x04C, 15,  0, 'PLL proportional gain (default 0)'),
    'PLL_KI':             (0x050, 15,  0, 'PLL integral gain (default 0)'),
    'PLL_CORR_MAX':       (0x054, 15,  0, 'PLL max correction NCO LSB'),

    # --- Trigger config (runtime) ---
    'TRIG_DECIMATION':    (0x058, 15,  0, 'Trigger decimation count (1=every 0.1deg)'),
    'TRIG_PULSE_WIDTH':   (0x05C, 15,  0, 'Trigger pulse width, clock cycles'),

    # --- DMA config (startup) ---
    'DMA_BUFFER_SIZE':    (0x060,  3,  0, 'DMA cycles per buffer (default 2)'),
}

READ_REGS = {
    # --- Sync ---
    'SYNC_STATE':         (0x070,  1,  0, 'Sync state: 0=STOPPED 1=MOVING 2=CRANK_SYNC 3=FULL_SYNC'),
    'SYNC_FAULT_COUNT':   (0x074, 15,  0, 'Sync fault event count'),

    # --- Speed ---
    'SPEED_RPM_SLOW':     (0x078, 15,  0, 'RPM from z_period (slow, updated each z_edge)'),
    'SPEED_RPM_FAST':     (0x07C, 15,  0, 'RPM from ab_period (fast, updated each ab_edge)'),

    # --- Angle ---
    'ANGLE_DEG':          (0x080, 15,  0, 'Tooth-based interpolated angle 0-7199 0.1deg'),

    # --- Phase ---
    'PHASE_RAW':          (0x084,  0,  0, 'Phase: 0=first rev 1=second rev'),
    'PHASE_REF_DET':      (0x088,  0,  0, 'Ref pulse detected in either window (strobe)'),
    'PHASE_REF_OK':       (0x08C,  0,  0, 'Ref pulse in correct window (registered)'),
    'PHASE_REF_FOUND':    (0x090,  0,  0, 'Latched: 1 after first valid ref detection'),
    'PHASE_INV':          (0x094,  0,  0, 'Ref pulse in window 2 (wrong phase)'),
    'PHASE_INV_LATCH':    (0x098,  0,  0, 'Phase_inv latched at first detection'),
    'PHASE_ANG_CORR':     (0x09C, 15,  0, 'Phase-corrected angle 0-7199 0.1deg'),
    'PHASE_ENG':          (0x0A0,  0,  0, 'Engine phase = phase_raw XOR phase_inv_latch'),
    'PHASE_ANG_ENG':      (0x0A4, 15,  0, 'Engine angle with phase+TDC correction 0-7199 0.1deg'),
    'PHASE_REF_DET_CNT':  (0x0A8, 15,  0, 'Count of ref pulse detections'),

    # --- PLL ---
    'PLL_ANG_HIRES':      (0x0AC, 15,  0, 'PLL NCO angle 0-7199 0.1deg'),
    'PLL_DIV_VALID':      (0x0B0,  0,  0, 'PLL active (sync_full)'),
    'PLL_NCO_INC':        (0x0B4, 31,  0, 'NCO frequency word'),
    'PLL_NCO_ACCUM':      (0x0B8, 31,  0, 'NCO accumulator (raw 32-bit)'),
    'PLL_PHASE_ERR':      (0x0BC, 31,  0, 'Signed phase error NCO units'),
    'PLL_P_TERM':         (0x0C0, 31,  0, 'Signed P term'),
    'PLL_I_TERM':         (0x0C4, 31,  0, 'Signed I term'),
    'PLL_PI_CORR':        (0x0C8, 31,  0, 'Signed PI correction applied'),
    'PLL_NCO_AB_INC':     (0x0CC, 31,  0, 'Startup calc: 0xFFFFFFFF / ppr_conf'),
    'PLL_CYCLE_AB_COUNT': (0x0D0,  7,  0, 'Ab edge count since last 2nd z_edge'),

    # --- Trigger ---
    'TRIG_PULSE_COUNT':   (0x0D4, 31,  0, 'Trigger pulse count (resets on z_edge)'),

    # --- Crank readback ---
    'CRANK_TOOTH_PERIOD': (0x0D8, 31,  0, 'Last tooth period clock cycles @ 100MHz'),
    'CRANK_GAP_PERIOD':   (0x0DC, 31,  0, 'Last gap period at detection clock cycles'),
    'CRANK_TOOTH_COUNT':  (0x0E0,  7,  0, 'Real tooth count per revolution'),
    'CRANK_AB_COUNT':     (0x0E4,  7,  0, 'All ab edges per revolution (inc interpolated)'),
    'CRANK_GAP_DET':      (0x0E8,  0,  0, 'Gap currently detected'),

    # --- Cam readback ---
    'CAM_TOOTH_COUNT':    (0x0EC,  7,  0, 'Cam edge count per 2 crank revolutions'),
    'REF_ANGLE':          (0x0F0, 15,  0, 'Angle at last ref pulse detection 0-7199 0.1deg'),

    # --- Encoder readback ---
    'ENC_AB_COUNT':       (0x0F4,  7,  0, 'Encoder ab edge count'),
    'ENC_A_COUNT':        (0x0F8,  7,  0, 'Encoder A channel edge count'),
    'ENC_B_COUNT':        (0x0FC,  7,  0, 'Encoder B channel edge count'),
    'ENC_AB_PERIOD':      (0x100, 31,  0, 'Encoder ab period clock cycles'),

    # --- Fault readback ---
    'FAULT_FLAGS':        (0x104, 31,  0, '[0]=cam [1]=crank_tooth [2]=crank_ab [3]=speed [4]=pll_phase_err'),
    'CAM_FAULT_COUNT':    (0x108, 15,  0, 'Cam fault event count'),
    'CRANK_FAULT_COUNT':  (0x10C, 15,  0, 'Crank fault count (tooth+ab)'),
    'PHASE_FAULT_COUNT':  (0x110, 15,  0, 'Phase fault count (falling edge of phase_ref_ok)'),
    'AB_FAULT_COUNT':     (0x114, 15,  0, 'AB count mismatch fault count'),
    'SPEED_FAULT_COUNT':  (0x118, 15,  0, 'Speed fault count'),
    'PLL_ERR_COUNT':      (0x11C, 15,  0, 'PLL phase error exceeded threshold count'),
    'PLL_PHASE_ERR_THRESH_W': (0x0E0, 31, 0, 'Write: max abs PLL phase error (NCO units)'),  # writeable

    # --- Pack readback ---
    'PKT_COUNT':          (0x120, 31,  0, 'DMA packet count'),
    'OVF_COUNT':          (0x124, 15,  0, 'DMA overflow count'),
}

# All registers (for lookup)
ALL_REGS = {**WRITE_REGS, **READ_REGS}

# CONTROL word bit positions
CTRL_CRANK_EDGE_SEL  = 0
CTRL_SRC_SEL         = 1
CTRL_REF_SEL         = 2
CTRL_CONFIG_APPLY    = 3
CTRL_CAM_EDGE_SEL    = 4
CTRL_ANG_SEL         = 5

CTRL_RT_FAULT_CLEAR  = 0
CTRL_RT_PLL_CORR_DIR = 1
CTRL_RT_PHASE_DROP   = 2


class AngusRegs:
    """PYNQ register interface for Angus combustion analyser."""

    def __init__(self, ip_core):
        """
        ip_core: PYNQ IP core object with mmio attribute, or any object
                 with read(offset) and write(offset, value) methods.
        """
        self._ip = ip_core

    def read(self, name):
        """Read a register by name, returns field value (masked and shifted)."""
        if name not in ALL_REGS:
            raise KeyError(f"Unknown register: {name}")
        addr, msb, lsb, _ = ALL_REGS[name]
        raw = self._ip.read(addr)
        mask = (1 << (msb - lsb + 1)) - 1
        return (raw >> lsb) & mask

    def write(self, name, value):
        """Write a register by name. Writes full 32-bit word (lsb aligned)."""
        if name not in WRITE_REGS and name not in ALL_REGS:
            raise KeyError(f"Unknown register: {name}")
        addr, msb, lsb, _ = ALL_REGS.get(name) or WRITE_REGS[name]
        mask = (1 << (msb - lsb + 1)) - 1
        value = value & mask
        self._ip.write(addr, value << lsb)

    def config_apply(self, **kwargs):
        """
        Write startup config and pulse config_apply.
        Optional kwargs set config bits before applying:
            crank_edge_sel=1   (1=rising, 0=falling)
            cam_edge_sel=1
            src_sel=0          (0=crank, 1=encoder)
            ref_sel=0          (0=cam, 1=peak)
            ang_sel=0          (0=angle_deg, 1=pll_ang_hires)
        """
        ctrl = 0
        ctrl |= kwargs.get('crank_edge_sel', 1) << CTRL_CRANK_EDGE_SEL
        ctrl |= kwargs.get('src_sel',         0) << CTRL_SRC_SEL
        ctrl |= kwargs.get('ref_sel',          0) << CTRL_REF_SEL
        ctrl |= kwargs.get('cam_edge_sel',     1) << CTRL_CAM_EDGE_SEL
        ctrl |= kwargs.get('ang_sel',          0) << CTRL_ANG_SEL
        ctrl |= (1 << CTRL_CONFIG_APPLY)
        self._ip.write(0x000, ctrl)

    def fault_clear(self):
        """Clear all fault counters."""
        self._ip.write(0x004, 1 << CTRL_RT_FAULT_CLEAR)

    def wait_sync(self, target=3, timeout=10.0):
        """
        Wait for sync_state to reach target (default 3=FULL_SYNC).
        Returns True if reached, False on timeout.
        """
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.read('SYNC_STATE') >= target:
                return True
            time.sleep(0.01)
        return False

    def print_status(self):
        """Print a human-readable status summary."""
        states = ['STOPPED', 'MOVING', 'CRANK_SYNC', 'FULL_SYNC']
        state = self.read('SYNC_STATE')
        print(f"=== Angus Status ===")
        print(f"  SYNC_STATE     = {states[state]} ({state})")
        print(f"  SPEED_RPM_SLOW = {self.read('SPEED_RPM_SLOW')} RPM")
        print(f"  SPEED_RPM_FAST = {self.read('SPEED_RPM_FAST')} RPM")
        print(f"  ANGLE_DEG      = {self.read('ANGLE_DEG') / 10:.1f} deg")
        print(f"  PHASE_REF_FOUND= {self.read('PHASE_REF_FOUND')}")
        print(f"  PHASE_ANG_ENG  = {self.read('PHASE_ANG_ENG') / 10:.1f} deg")
        print(f"  PLL_ANG_HIRES  = {self.read('PLL_ANG_HIRES') / 10:.1f} deg")
        print(f"  FAULT_FLAGS    = 0x{self.read('FAULT_FLAGS'):08X}")
        print(f"  PKT_COUNT      = {self.read('PKT_COUNT')}")
        print(f"  OVF_COUNT      = {self.read('OVF_COUNT')}")

    def print_config(self):
        """Print current register configuration."""
        print("=== Angus Config ===")
        ctrl = self._ip.read(0x000)
        print(f"  CONTROL        = 0x{ctrl:08X}")
        print(f"    crank_edge_sel = {(ctrl >> 0) & 1}")
        print(f"    src_sel        = {(ctrl >> 1) & 1}")
        print(f"    ref_sel        = {(ctrl >> 2) & 1}")
        print(f"    cam_edge_sel   = {(ctrl >> 4) & 1}")
        print(f"    ang_sel        = {(ctrl >> 5) & 1}")
        print(f"  RST_CYCLES     = {self.read('RST_CYCLES')}")
        print(f"  CRANK_N_TEETH  = {self.read('CRANK_N_TEETH')}")
        print(f"  CRANK_N_MISSING= {self.read('CRANK_N_MISSING')}")
        print(f"  CAM_N_TEETH    = {self.read('CAM_N_TEETH')}")
        print(f"  CAM_DBC        = {self.read('CAM_DBC')} ({self.read('CAM_DBC')*10:.0f}ns)")
        print(f"  CRANK_DBC      = {self.read('CRANK_DBC')} ({self.read('CRANK_DBC')*10:.0f}ns)")
        print(f"  PLL_NCO_AB_INC = {self.read('PLL_NCO_AB_INC')} (startup calc)")
        print(f"  TRIG_DECIMATION= {self.read('TRIG_DECIMATION')}")
        print(f"  DMA_BUFFER_SIZE= {self.read('DMA_BUFFER_SIZE')}")
