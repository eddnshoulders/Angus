"""
angus_regs.py -- PYNQ register interface for Angus combustion analyser v3.

Register map matches axi_lite_regs.vhd v3 (v3_dev branch).

Internal angle unit: _angfac -- unsigned 32-bit fraction of one crank revolution.
Full scale (0xFFFFFFFF) = 360 crank degrees.
This module handles all angfac <-> degree conversions transparently.

Usage:
    from angus_regs import AngusRegs
    regs = AngusRegs(overlay.axi_lite_regs_0)

    # Configure and start
    regs.write('CRANK_N_TEETH', 60)
    regs.write('CRANK_N_MISSING', 2)
    regs.write_phase_window(centre_deg=180.0, tol_deg=30.0, phase_ref_phase=0)
    regs.write_tdc_offset(offset_deg=90.0)
    regs.config_apply()
    regs.wait_sync()

    # Read status
    regs.print_status()
    tdc = regs.read_tdc_deg()     # current engine angle in degrees (0-719.9)
    rpm = regs.read('SPEED_RPM_SLOW')
"""

import time
import warnings

# =============================================================================
# Angfac conversion
# Full scale 0xFFFFFFFF = 360 crank degrees (one crank revolution).
# =============================================================================
ANGFAC_FULL_SCALE = 0xFFFF_FFFF

def deg_to_angfac(deg):
    """Convert crank degrees (0-360) to 32-bit angfac. Clamped to valid range."""
    raw = round(deg / 360.0 * (ANGFAC_FULL_SCALE + 1))
    return max(0, min(ANGFAC_FULL_SCALE, raw))

def angfac_to_deg(angfac):
    """Convert 32-bit angfac to crank degrees (0.0-360.0)."""
    return angfac / (ANGFAC_FULL_SCALE + 1) * 360.0

def engine_angfac_to_deg(phase_eng, angfac):
    """Convert {phase_eng, angfac} to engine degrees (0.0-720.0)."""
    return phase_eng * 360.0 + angfac_to_deg(angfac)

def tdc_deg_to_float(tdc_deg):
    """Convert tdc_deg register value (0-7199) to engine degrees (0.0-719.9)."""
    return tdc_deg / 10.0


# =============================================================================
# Write register map  (address, msb, lsb, description)
# =============================================================================
WRITE_REGS = {
    'CONTROL':           (0x000, 9,  0,
                          '[0]=crank_edge_sel [1]=cam_edge_sel [3:2]=enc_ab_edge_sel '
                          '[4]=enc_z_edge_sel [5]=src_sel [6]=ref_sel '
                          '[7]=config_apply(self-clr) [8]=ang_sel [9]=angle_interp_en'),
    'CONTROL_RT':        (0x004, 3,  0,
                          '[0]=fault_clear(self-clr) [1]=pll_corr_dir '
                          '[2]=phase_fault_drop [3]=phase_ref_phase'),
    'RST_CYCLES':        (0x008, 8,  0,  'Reset duration clocks (default 256)'),
    'PEAK_HYST':         (0x00C, 15, 0,  'Peak detector hysteresis counts (default 128)'),
    'CAM_DBC':           (0x010, 15, 0,  'Cam debounce cycles (default 5)'),
    'CRANK_DBC':         (0x014, 15, 0,  'Crank debounce cycles (default 5)'),
    'ENC_A_DBC':         (0x018, 15, 0,  'Encoder A debounce cycles (default 5)'),
    'ENC_B_DBC':         (0x01C, 15, 0,  'Encoder B debounce cycles (default 5)'),
    'ENC_Z_DBC':         (0x020, 15, 0,  'Encoder Z debounce cycles (default 5)'),
    'CRANK_GAP_THRESH':  (0x024, 7,  0,  'Gap threshold 1.7fp (0xC0 = 1.5x tooth period)'),
    'CRANK_N_TEETH':     (0x028, 7,  0,  'Total teeth including missing (default 60)'),
    'CRANK_N_MISSING':   (0x02C, 7,  0,  'Missing teeth (default 2)'),
    'CAM_N_TEETH':       (0x030, 7,  0,  'Cam teeth per 2 crank revs (default 1)'),
    'ENC_N_PPR':         (0x034, 15, 0,  'Encoder edges per revolution'),
    'PHASE_REF_MIN':     (0x038, 31, 0,  'Detection window lower bound (angfac, startup). '
                                          'Use write_phase_window() to set from degrees.'),
    'PHASE_REF_MAX':     (0x03C, 31, 0,  'Detection window upper bound (angfac, startup). '
                                          'Use write_phase_window() to set from degrees.'),
    'PLL_KP':            (0x040, 15, 0,  'PLL proportional gain (default 0)'),
    'PLL_KI':            (0x044, 15, 0,  'PLL integral gain (default 0)'),
    'PLL_CORR_MAX':      (0x048, 15, 0,  'PLL max correction NCO LSB (default 0xFFFF)'),
    'TRIG_DECIMATION':   (0x04C, 15, 0,  'Sample trigger decimation (1 = every 0.1 deg equiv)'),
    'MAX_RPM':           (0x050, 15, 0,  'Max RPM for speed fault check (default 6000)'),
    'PLL_PHASE_ERR_THRESH': (0x054, 31, 0, 'Max abs PLL phase error angfac before fault'),
    'TDC_OFFSET':        (0x058, 31, 0,  'TDC offset (angfac, runtime). '
                                          'Use write_tdc_offset() to set from degrees.'),
    'DMA_BUFFER_SIZE':   (0x05C, 3,  0,  'Z-edge cycles per DMA buffer (default 2)'),
}

# =============================================================================
# Read register map
# =============================================================================
READ_REGS = {
    # Crank
    'CAM_TOOTH_COUNT':    (0x070, 7,  0,  'Cam edge count per 2 crank revs'),
    'CRANK_TOOTH_PERIOD': (0x074, 31, 0,  'Last tooth period (clocks @ 100MHz)'),
    'CRANK_TOOTH_COUNT':  (0x078, 7,  0,  'Real tooth count per revolution'),
    'CRANK_AB_COUNT':     (0x07C, 7,  0,  'All ab edges per rev (inc interpolated)'),
    # Encoder
    'ENC_AB_PERIOD':      (0x080, 31, 0,  'Encoder ab period (clocks)'),
    'ENC_AB_COUNT':       (0x084, 7,  0,  'Encoder ab edge count'),
    'ENC_A_COUNT':        (0x088, 7,  0,  'Encoder A channel count'),
    'ENC_B_COUNT':        (0x08C, 7,  0,  'Encoder B channel count'),
    # Angle
    'ANGLE_ANGFAC':       (0x090, 31, 0,  'Tooth-based angle (angfac). '
                                           'Use angfac_to_deg() to convert.'),
    'ANGLE_NCO_CLK_INC':  (0x094, 31, 0,  'Per-clock angfac increment (interpolation)'),
    'ANGLE_NCO_AB_INC':   (0x098, 31, 0,  '2^32/ppr -- per-tooth angfac increment'),
    # Phase
    'PHASE_REF_ANGFAC':   (0x09C, 31, 0,  'Angfac at last cam detection'),
    'PHASE_REF_DET':      (0x0A0, 0,  0,  'Cam detection strobe (1-clock)'),
    'PHASE_REF_FOUND':    (0x0A4, 0,  0,  '1 after first valid cam detection'),
    'PHASE_ENG':          (0x0A8, 0,  0,  'Engine phase: 0 or 1'),
    'PHASE_REF_OK':       (0x0AC, 0,  0,  'Cam detection healthy'),
    'PHASE_REF_DET_CNT':  (0x0B0, 15, 0,  'Cumulative cam detection count'),
    # Sync
    'SYNC_STATE':         (0x0B4, 1,  0,  '0=STOPPED 1=MOVING 2=CRANK_SYNC 3=FULL_SYNC'),
    # Speed
    'SPEED_RPM_SLOW':     (0x0B8, 15, 0,  'RPM from z_period (updated each z_edge)'),
    'SPEED_RPM_FAST':     (0x0BC, 15, 0,  'RPM from ab_period (updated each ab_edge)'),
    # PLL
    'PLL_ANGFAC':         (0x0C0, 31, 0,  'PLL NCO angle (angfac)'),
    'PLL_DIV_VALID':      (0x0C4, 0,  0,  'PLL active (sync_full)'),
    'PLL_NCO_ACCUM':      (0x0C8, 31, 0,  'Raw NCO accumulator (= PLL_ANGFAC)'),
    'PLL_ERR_ANGFAC':     (0x0CC, 31, 0,  'Signed phase error (angfac, two\'s complement)'),
    'PLL_P_TERM':         (0x0D0, 31, 0,  'Signed proportional term'),
    'PLL_I_TERM':         (0x0D4, 31, 0,  'Signed integral term (upper 32 of 64)'),
    'PLL_PI_CORR':        (0x0D8, 31, 0,  'Signed PI correction applied to NCO'),
    'PLL_NCO_INC':        (0x0DC, 31, 0,  'Current NCO increment per clock'),
    # Trigger
    'TRIG_COUNT':         (0x0E0, 31, 0,  'Trigger pulse count since last z_edge'),
    # Fault
    'FAULT_FLAGS':        (0x0E4, 31, 0,  '[0]=cam [1]=crank_tooth [2]=crank_ab '
                                           '[3]=speed [4]=pll_phase_err'),
    'FAULT_CAM_COUNT':    (0x0E8, 15, 0,  'Cam fault event count'),
    'FAULT_CRANK_COUNT':  (0x0EC, 15, 0,  'Crank fault event count'),
    'FAULT_PLL_COUNT':    (0x0F0, 15, 0,  'Phase_ref_ok fault count'),
    'FAULT_AB_COUNT':     (0x0F4, 15, 0,  'AB count mismatch fault count'),
    'FAULT_SPEED_COUNT':  (0x0F8, 15, 0,  'Speed fault event count'),
    'FAULT_ENC_COUNT':    (0x0FC, 15, 0,  'Encoder fault event count'),
    # TDC output
    'TDC_DEG':            (0x100, 15, 0,  'TDC-referenced engine angle (0-7199, 0.1 deg/LSB)'),
    # Pack
    'PKT_COUNT':          (0x104, 31, 0,  'DMA packet count'),
    'OVF_COUNT':          (0x108, 15, 0,  'DMA overflow count'),
}

ALL_REGS = {**WRITE_REGS, **READ_REGS}

# =============================================================================
# CONTROL register bit positions (v3)
# =============================================================================
CTRL_CRANK_EDGE_SEL   = 0
CTRL_CAM_EDGE_SEL     = 1
CTRL_ENC_AB_EDGE_SEL  = 2   # 2-bit field [3:2]
CTRL_ENC_Z_EDGE_SEL   = 4
CTRL_SRC_SEL          = 5
CTRL_REF_SEL          = 6
CTRL_CONFIG_APPLY     = 7
CTRL_ANG_SEL          = 8
CTRL_ANGLE_INTERP_EN  = 9

CTRL_RT_FAULT_CLEAR   = 0
CTRL_RT_PLL_CORR_DIR  = 1
CTRL_RT_PHASE_DROP    = 2
CTRL_RT_PHASE_REF_PH  = 3

# =============================================================================
# DMA packet layout (v3, 6 words x 32 bits)
# =============================================================================
PACKET_WORDS = 6

def decode_packet(words):
    """
    Decode a single 6-word DMA packet.

    words: sequence of 6 unsigned 32-bit integers (e.g. numpy uint32 array slice).

    Returns dict with all decoded fields.
    """
    if len(words) < PACKET_WORDS:
        raise ValueError(f"Expected {PACKET_WORDS} words, got {len(words)}")
    w = [int(words[i]) & 0xFFFF_FFFF for i in range(PACKET_WORDS)]

    return {
        'speed_rpm_slow':  (w[0] >> 16) & 0xFFFF,
        'speed_rpm_fast':  (w[0] >>  0) & 0xFFFF,
        'tdc_deg':         (w[1] >>  0) & 0xFFFF,    # 0-7199, 0.1 deg/LSB
        'tdc_deg_float':   ((w[1] & 0xFFFF) / 10.0), # engine degrees (0-719.9)
        'di_ch':           (w[2] >> 24) & 0xFF,
        'adc_ch1':         (w[2] >>  0) & 0x0FFF,
        'adc_ch2':         (w[3] >> 16) & 0x0FFF,
        'adc_ch3':         (w[3] >>  0) & 0x0FFF,
        'adc_ch4':         (w[4] >> 16) & 0x0FFF,
        'adc_ch5':         (w[4] >>  0) & 0x0FFF,
        'adc_ch6':         (w[5] >> 16) & 0x0FFF,
    }


# =============================================================================
# AngusRegs class
# =============================================================================
class AngusRegs:
    """PYNQ register interface for Angus combustion analyser v3."""

    def __init__(self, ip_core):
        """
        ip_core: PYNQ IP object with read(offset) and write(offset, value) methods.
        Typically overlay.axi_lite_regs_0.
        """
        self._ip = ip_core

    # -------------------------------------------------------------------------
    # Low-level register access
    # -------------------------------------------------------------------------
    def read(self, name):
        """Read a named register. Returns the masked field value (unsigned)."""
        if name not in ALL_REGS:
            raise KeyError(f"Unknown register: {name}")
        addr, msb, lsb, _ = ALL_REGS[name]
        raw = self._ip.read(addr) & 0xFFFF_FFFF
        mask = (1 << (msb - lsb + 1)) - 1
        return (raw >> lsb) & mask

    def read_signed(self, name):
        """Read a named register as a signed 32-bit integer (two's complement)."""
        val = self.read(name)
        if val >= 0x8000_0000:
            val -= 0x1_0000_0000
        return val

    def write(self, name, value):
        """Write a named register (lsb-aligned, masked to field width)."""
        reg = WRITE_REGS.get(name)
        if reg is None:
            raise KeyError(f"Unknown write register: {name}")
        addr, msb, lsb, _ = reg
        mask = (1 << (msb - lsb + 1)) - 1
        self._ip.write(addr, (int(value) & mask) << lsb)

    # -------------------------------------------------------------------------
    # Angfac conversion helpers
    # -------------------------------------------------------------------------
    def _nco_ab_inc(self):
        """Read the current angle_nco_ab_inc from hardware (2^32 / ppr)."""
        return self.read('ANGLE_NCO_AB_INC')

    def _angfac_to_deg(self, angfac):
        return angfac_to_deg(angfac)

    def _deg_to_angfac(self, deg):
        return deg_to_angfac(deg)

    # -------------------------------------------------------------------------
    # Phase window configuration
    # -------------------------------------------------------------------------
    def write_phase_window(self, centre_deg, tol_deg, phase_ref_phase=0):
        """
        Write the cam detection window from degree values.

        centre_deg:      expected cam edge angle (0-360 crank degrees)
        tol_deg:         window half-width (+/- tolerance, crank degrees)
        phase_ref_phase: which revolution the cam fires on (0 or 1)

        Clamps min/max to valid angfac range and warns if the window would
        span the Z edge (0/360 deg boundary), which is not supported.
        """
        centre_nco = self._deg_to_angfac(centre_deg)
        tol_nco    = self._deg_to_angfac(tol_deg)

        win_min = centre_nco - tol_nco
        win_max = centre_nco + tol_nco

        if win_min < 0 or win_max > ANGFAC_FULL_SCALE:
            warnings.warn(
                f"Phase detection window [{centre_deg - tol_deg:.1f}, "
                f"{centre_deg + tol_deg:.1f}] deg clips at Z edge boundary "
                f"(0/360 deg). Window has been clamped. "
                f"The detection window must not span the crank Z edge.",
                UserWarning
            )

        win_min = max(0, win_min)
        win_max = min(ANGFAC_FULL_SCALE, win_max)

        self.write('PHASE_REF_MIN', win_min)
        self.write('PHASE_REF_MAX', win_max)

        # phase_ref_phase lives in CONTROL_RT bit [3] (runtime, no latch needed)
        rt = self._ip.read(0x004) & 0xFFFF_FFFF
        rt = (rt & ~(1 << CTRL_RT_PHASE_REF_PH)) | ((phase_ref_phase & 1) << CTRL_RT_PHASE_REF_PH)
        self._ip.write(0x004, rt)

    def read_phase_window_deg(self):
        """Read back the phase detection window in degree units."""
        win_min_nco = self.read('PHASE_REF_MIN')
        win_max_nco = self.read('PHASE_REF_MAX')
        phase_rt    = (self._ip.read(0x004) >> CTRL_RT_PHASE_REF_PH) & 1
        return {
            'win_min_deg': self._angfac_to_deg(win_min_nco),
            'win_max_deg': self._angfac_to_deg(win_max_nco),
            'phase_ref_phase': phase_rt,
        }

    # -------------------------------------------------------------------------
    # TDC offset configuration
    # -------------------------------------------------------------------------
    def write_tdc_offset(self, offset_deg):
        """
        Write the TDC offset from degrees.

        offset_deg: crank degrees from Z edge to engine TDC (0-360).
                    At TDC, angle_angfac == tdc_offset, giving tdc_deg == 0.
        """
        offset_nco = self._deg_to_angfac(offset_deg)
        self.write('TDC_OFFSET', offset_nco)

    def read_tdc_offset_deg(self):
        """Read back the TDC offset in crank degrees."""
        return self._angfac_to_deg(self.read('TDC_OFFSET'))

    # -------------------------------------------------------------------------
    # Angle readback
    # -------------------------------------------------------------------------
    def read_angle_deg(self):
        """Read current crank angle in degrees (0.0-360.0)."""
        return self._angfac_to_deg(self.read('ANGLE_ANGFAC'))

    def read_tdc_deg(self):
        """Read TDC-referenced engine angle in degrees (0.0-719.9)."""
        return tdc_deg_to_float(self.read('TDC_DEG'))

    def read_phase_ref_deg(self):
        """Read angle at last cam detection in crank degrees."""
        return self._angfac_to_deg(self.read('PHASE_REF_ANGFAC'))

    def read_pll_deg(self):
        """Read PLL NCO angle in crank degrees."""
        return self._angfac_to_deg(self.read('PLL_ANGFAC'))

    def read_pll_err_deg(self):
        """Read signed PLL phase error in crank degrees."""
        raw = self.read_signed('PLL_ERR_ANGFAC')
        return raw / (ANGFAC_FULL_SCALE + 1) * 360.0

    # -------------------------------------------------------------------------
    # Startup and control
    # -------------------------------------------------------------------------
    def config_apply(self,
                     crank_edge_sel=1, cam_edge_sel=1,
                     enc_ab_edge_sel=0, enc_z_edge_sel=0,
                     src_sel=0, ref_sel=0,
                     ang_sel=0, angle_interp_en=0):
        """
        Latch startup config and pulse config_apply.

        crank_edge_sel:   0=falling 1=rising
        cam_edge_sel:     0=falling 1=rising
        enc_ab_edge_sel:  0=rising 1=falling 2=both
        enc_z_edge_sel:   0=rising 1=falling
        src_sel:          0=crank 1=encoder
        ref_sel:          0=cam 1=peak_detector
        ang_sel:          0=tooth-based 1=PLL
        angle_interp_en:  0=tooth snap only 1=Bresenham interpolation
        """
        ctrl = (
            (crank_edge_sel    & 0x1) << CTRL_CRANK_EDGE_SEL  |
            (cam_edge_sel      & 0x1) << CTRL_CAM_EDGE_SEL     |
            (enc_ab_edge_sel   & 0x3) << CTRL_ENC_AB_EDGE_SEL  |
            (enc_z_edge_sel    & 0x1) << CTRL_ENC_Z_EDGE_SEL   |
            (src_sel           & 0x1) << CTRL_SRC_SEL          |
            (ref_sel           & 0x1) << CTRL_REF_SEL          |
            (ang_sel           & 0x1) << CTRL_ANG_SEL          |
            (angle_interp_en   & 0x1) << CTRL_ANGLE_INTERP_EN  |
            1                         << CTRL_CONFIG_APPLY
        )
        self._ip.write(0x000, ctrl)

    def fault_clear(self):
        """Clear all fault counters."""
        self._ip.write(0x004, 1 << CTRL_RT_FAULT_CLEAR)

    def wait_sync(self, target=3, timeout=10.0):
        """
        Wait for SYNC_STATE >= target.
        Returns True if reached within timeout, False otherwise.
        target: 1=MOVING 2=CRANK_SYNC 3=FULL_SYNC (default)
        """
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.read('SYNC_STATE') >= target:
                return True
            time.sleep(0.01)
        return False

    # -------------------------------------------------------------------------
    # Status display
    # -------------------------------------------------------------------------
    def print_status(self):
        """Print a human-readable status summary."""
        states = ['STOPPED', 'MOVING', 'CRANK_SYNC', 'FULL_SYNC']
        state  = self.read('SYNC_STATE')
        print("=== Angus Status (v3) ===")
        print(f"  SYNC_STATE       = {states[state]} ({state})")
        print(f"  SPEED_RPM_SLOW   = {self.read('SPEED_RPM_SLOW')} RPM")
        print(f"  SPEED_RPM_FAST   = {self.read('SPEED_RPM_FAST')} RPM")
        print(f"  ANGLE_DEG        = {self.read_angle_deg():.2f} crank deg")
        print(f"  TDC_DEG          = {self.read_tdc_deg():.1f} engine deg")
        print(f"  PHASE_REF_FOUND  = {self.read('PHASE_REF_FOUND')}")
        print(f"  PHASE_ENG        = {self.read('PHASE_ENG')}")
        print(f"  PHASE_REF_OK     = {self.read('PHASE_REF_OK')}")
        print(f"  PHASE_REF_DET_CNT= {self.read('PHASE_REF_DET_CNT')}")
        print(f"  PLL_DEG          = {self.read_pll_deg():.2f} crank deg")
        print(f"  PLL_ERR_DEG      = {self.read_pll_err_deg():.4f} crank deg")
        print(f"  FAULT_FLAGS      = 0x{self.read('FAULT_FLAGS'):08X}")
        print(f"  PKT_COUNT        = {self.read('PKT_COUNT')}")
        print(f"  OVF_COUNT        = {self.read('OVF_COUNT')}")

    def print_config(self):
        """Print current register configuration."""
        ctrl    = self._ip.read(0x000) & 0xFFFF_FFFF
        ctrl_rt = self._ip.read(0x004) & 0xFFFF_FFFF
        nco_ab  = self.read('ANGLE_NCO_AB_INC')
        ppr     = round((ANGFAC_FULL_SCALE + 1) / nco_ab) if nco_ab else 0
        print("=== Angus Config (v3) ===")
        print(f"  CONTROL          = 0x{ctrl:08X}")
        print(f"    crank_edge_sel  = {(ctrl >> CTRL_CRANK_EDGE_SEL)  & 1}")
        print(f"    cam_edge_sel    = {(ctrl >> CTRL_CAM_EDGE_SEL)    & 1}")
        print(f"    enc_ab_edge_sel = {(ctrl >> CTRL_ENC_AB_EDGE_SEL) & 3}")
        print(f"    enc_z_edge_sel  = {(ctrl >> CTRL_ENC_Z_EDGE_SEL)  & 1}")
        print(f"    src_sel         = {(ctrl >> CTRL_SRC_SEL)         & 1}")
        print(f"    ref_sel         = {(ctrl >> CTRL_REF_SEL)         & 1}")
        print(f"    ang_sel         = {(ctrl >> CTRL_ANG_SEL)         & 1}")
        print(f"    angle_interp_en = {(ctrl >> CTRL_ANGLE_INTERP_EN) & 1}")
        print(f"  CONTROL_RT       = 0x{ctrl_rt:08X}")
        print(f"    pll_corr_dir    = {(ctrl_rt >> CTRL_RT_PLL_CORR_DIR) & 1}")
        print(f"    phase_fault_drop= {(ctrl_rt >> CTRL_RT_PHASE_DROP)   & 1}")
        print(f"    phase_ref_phase = {(ctrl_rt >> CTRL_RT_PHASE_REF_PH) & 1}")
        print(f"  ANGLE_NCO_AB_INC = {nco_ab} (ppr ~= {ppr})")
        print(f"  CRANK_N_TEETH    = {self.read('CRANK_N_TEETH')}")
        print(f"  CRANK_N_MISSING  = {self.read('CRANK_N_MISSING')}")
        print(f"  CAM_N_TEETH      = {self.read('CAM_N_TEETH')}")
        win = self.read_phase_window_deg()
        print(f"  PHASE_REF_WIN    = [{win['win_min_deg']:.1f}, {win['win_max_deg']:.1f}] deg "
              f"(phase_ref_phase={win['phase_ref_phase']})")
        print(f"  TDC_OFFSET       = {self.read_tdc_offset_deg():.2f} crank deg")
        print(f"  TRIG_DECIMATION  = {self.read('TRIG_DECIMATION')}")
        print(f"  MAX_RPM          = {self.read('MAX_RPM')}")
        print(f"  DMA_BUFFER_SIZE  = {self.read('DMA_BUFFER_SIZE')}")

    def print_pll(self):
        """Print PLL diagnostic values."""
        print("=== PLL Status ===")
        print(f"  PLL_DIV_VALID    = {self.read('PLL_DIV_VALID')}")
        print(f"  PLL_DEG          = {self.read_pll_deg():.3f} crank deg")
        print(f"  PLL_ERR_DEG      = {self.read_pll_err_deg():.4f} crank deg")
        print(f"  PLL_P_TERM       = {self.read_signed('PLL_P_TERM')}")
        print(f"  PLL_I_TERM       = {self.read_signed('PLL_I_TERM')}")
        print(f"  PLL_PI_CORR      = {self.read_signed('PLL_PI_CORR')}")
        print(f"  PLL_NCO_INC      = {self.read('PLL_NCO_INC')}")
        nco_clk = self.read('ANGLE_NCO_CLK_INC')
        nco_ab  = self.read('ANGLE_NCO_AB_INC')
        print(f"  ANGLE_NCO_CLK_INC= {nco_clk} ({angfac_to_deg(nco_clk) * 1e3:.4f} mdeg/clk)")
        print(f"  ANGLE_NCO_AB_INC = {nco_ab}  ({angfac_to_deg(nco_ab):.3f} deg/tooth)")
