"""
angus.py -- Application API for the Angus combustion analyser v3.

Provides a clean, degree-based interface to the FPGA. All register addresses,
angfac conversions, and packet encoding/decoding are handled internally.

Usage:
    from angus import Angus
    a = Angus(overlay.axi_lite_regs_0)

    a.configure(
        crank_n_teeth     = 60,
        crank_n_missing   = 2,
        phase_centre_deg  = 180.0,
        phase_tol_deg     = 30.0,
        phase_ref_phase   = 0,
        tdc_offset_deg    = 90.0,
    )
    a.apply()
    a.wait_for_sync()

    print(a.rpm)          # current speed (RPM)
    print(a.tdc_deg)      # TDC-referenced engine angle (0.0-719.9 deg)
    print(a.is_synced)    # True when FULL_SYNC

    # Decode a DMA sample (6 x 32-bit words from DMA buffer)
    sample = Angus.decode(dma_buf[i*6 : i*6+6])
    print(sample.tdc_deg, sample.adc[0])
"""

import time
import warnings
from collections import namedtuple
from angus_regs import AngusRegs, ALL_REGS, WRITE_REGS

# =============================================================================
# Internal constants
# =============================================================================
_ANGFAC_FS   = 0xFFFF_FFFF    # full-scale angfac = 360 crank degrees
_TDC_LSB     = 0.1            # tdc_deg register units (deg/LSB)
_SYNC_STATES = ('STOPPED', 'MOVING', 'CRANK_SYNC', 'FULL_SYNC')

# CONTROL register bit positions
_CTRL_CRANK_EDGE = 0
_CTRL_CAM_EDGE   = 1
_CTRL_ENC_AB     = 2   # 2-bit field [3:2]
_CTRL_ENC_Z      = 4
_CTRL_SRC        = 5
_CTRL_REF        = 6
_CTRL_APPLY      = 7
_CTRL_ANG_SEL    = 8
_CTRL_INTERP     = 9

# CONTROL_RT bit positions
_RT_FAULT_CLR  = 0
_RT_CORR_DIR   = 1
_RT_PHASE_DROP = 2
_RT_PHASE_PH   = 3

# =============================================================================
# Internal angfac conversion (never exposed in public API)
# =============================================================================
def _to_angfac(deg):
    return max(0, min(_ANGFAC_FS, round(deg / 360.0 * (_ANGFAC_FS + 1))))

def _from_angfac(v):
    return v / (_ANGFAC_FS + 1) * 360.0

# =============================================================================
# Sample namedtuple returned by Angus.decode()
# =============================================================================
Sample = namedtuple('Sample', [
    'tdc_deg',      # engine angle, degrees (0.0-719.9)
    'rpm_slow',     # z-period RPM
    'rpm_fast',     # ab-period RPM
    'di',           # digital inputs byte (int)
    'adc',          # tuple of 6 ADC values (12-bit each, indices 0-5)
])


# =============================================================================
# Angus -- application API
# =============================================================================
class Angus:
    """
    Application-level interface to the Angus combustion analyser FPGA.

    All configuration and readback uses engineering units (degrees, RPM).
    Internal register addresses, angfac encoding, and packet layout are
    hidden from the caller.
    """

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------
    def __init__(self, ip_core):
        """
        ip_core: PYNQ IP object (overlay.axi_lite_regs_0 or equivalent).
        """
        self._r = AngusRegs(ip_core)
        # Startup config shadow (set via configure(), latched by apply())
        self._cfg = dict(
            crank_edge_sel    = 1,
            cam_edge_sel      = 1,
            enc_ab_edge_sel   = 0,
            enc_z_edge_sel    = 0,
            src_sel           = 0,
            ref_sel           = 0,
            ang_sel           = 0,
            angle_interp_en   = 0,
        )

    # -------------------------------------------------------------------------
    # Configuration
    # -------------------------------------------------------------------------
    def configure(self,
                  crank_n_teeth     = 60,
                  crank_n_missing   = 2,
                  cam_n_teeth       = 1,
                  phase_centre_deg  = 180.0,
                  phase_tol_deg     = 30.0,
                  phase_ref_phase   = 0,
                  tdc_offset_deg    = 0.0,
                  trig_decimation   = 1,
                  dma_buffer_size   = 2,
                  max_rpm           = 6000,
                  src               = 'crank',
                  ref               = 'cam',
                  angle_interp      = False,
                  ang_sel           = 'tooth',
                  crank_edge        = 'rising',
                  cam_edge          = 'rising'):
        """
        Set all configuration parameters. Call apply() to latch into hardware.

        crank_n_teeth:    total teeth including missing (default 60)
        crank_n_missing:  missing teeth count (default 2)
        cam_n_teeth:      cam edges per 2 crank revs (default 1)
        phase_centre_deg: expected cam edge crank angle, 0-360 (default 180.0)
        phase_tol_deg:    detection window half-width in degrees (default 30.0)
        phase_ref_phase:  which revolution cam fires on: 0 or 1 (default 0)
        tdc_offset_deg:   crank degrees from Z edge to engine TDC (default 0.0)
        trig_decimation:  sample rate divisor; 1 = every 0.1 deg equiv (default 1)
        dma_buffer_size:  engine cycles per DMA buffer (default 2)
        max_rpm:          speed fault threshold RPM (default 6000)
        src:              angle source -- 'crank' or 'encoder' (default 'crank')
        ref:              phase reference -- 'cam' or 'peak' (default 'cam')
        angle_interp:     Bresenham interpolation between teeth (default False)
        ang_sel:          angle stream -- 'tooth' or 'pll' (default 'tooth')
        crank_edge:       crank trigger edge -- 'rising' or 'falling' (default 'rising')
        cam_edge:         cam trigger edge -- 'rising' or 'falling' (default 'rising')
        """
        self._r.write('CRANK_N_TEETH',   crank_n_teeth)
        self._r.write('CRANK_N_MISSING', crank_n_missing)
        self._r.write('CAM_N_TEETH',     cam_n_teeth)
        self._r.write('TRIG_DECIMATION', trig_decimation)
        self._r.write('DMA_BUFFER_SIZE', dma_buffer_size)
        self._r.write('MAX_RPM',         max_rpm)
        self._set_phase_window(phase_centre_deg, phase_tol_deg, phase_ref_phase)
        self._set_tdc_offset(tdc_offset_deg)

        self._cfg.update(
            src_sel         = 0 if src          == 'crank'   else 1,
            ref_sel         = 0 if ref          == 'cam'     else 1,
            ang_sel         = 0 if ang_sel      == 'tooth'   else 1,
            angle_interp_en = 1 if angle_interp else 0,
            crank_edge_sel  = 1 if crank_edge   == 'rising'  else 0,
            cam_edge_sel    = 1 if cam_edge     == 'rising'  else 0,
        )

    def set_pll(self, kp=0, ki=0, corr_max=0xFFFF, corr_dir='add'):
        """Configure the PLL PI loop gains and correction limits."""
        self._r.write('PLL_KP',       kp)
        self._r.write('PLL_KI',       ki)
        self._r.write('PLL_CORR_MAX', corr_max)
        rt = self._r.read_raw(0x004)
        if corr_dir == 'add':
            rt |=  (1 << _RT_CORR_DIR)
        else:
            rt &= ~(1 << _RT_CORR_DIR)
        self._r.write_raw(0x004, rt)

    def set_debounce(self, crank=5, cam=5, enc_a=5, enc_b=5, enc_z=5):
        """Set debounce cycles for all signal inputs (clocks @ 100MHz)."""
        self._r.write('CRANK_DBC', crank)
        self._r.write('CAM_DBC',   cam)
        self._r.write('ENC_A_DBC', enc_a)
        self._r.write('ENC_B_DBC', enc_b)
        self._r.write('ENC_Z_DBC', enc_z)

    def apply(self):
        """
        Latch the startup configuration into hardware and issue a reset pulse.
        Must be called after configure() for settings to take effect.
        """
        ctrl = (
            (self._cfg['crank_edge_sel']  & 1) << _CTRL_CRANK_EDGE |
            (self._cfg['cam_edge_sel']    & 1) << _CTRL_CAM_EDGE    |
            (self._cfg['enc_ab_edge_sel'] & 3) << _CTRL_ENC_AB      |
            (self._cfg['enc_z_edge_sel']  & 1) << _CTRL_ENC_Z       |
            (self._cfg['src_sel']         & 1) << _CTRL_SRC         |
            (self._cfg['ref_sel']         & 1) << _CTRL_REF         |
            (self._cfg['ang_sel']         & 1) << _CTRL_ANG_SEL     |
            (self._cfg['angle_interp_en'] & 1) << _CTRL_INTERP      |
            1                                  << _CTRL_APPLY
        )
        self._r.write_raw(0x000, ctrl)

    def clear_faults(self):
        """Clear all fault counters."""
        self._r.write_raw(0x004, 1 << _RT_FAULT_CLR)

    def wait_for_sync(self, level='full', timeout=10.0):
        """
        Wait for sync to reach the requested level.

        level:   'moving', 'crank', or 'full' (default 'full')
        timeout: seconds before giving up (default 10.0)
        Returns True if reached, False on timeout.
        """
        target = {'moving': 1, 'crank': 2, 'full': 3}[level]
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self._r.read('SYNC_STATE') >= target:
                return True
            time.sleep(0.01)
        return False

    # -------------------------------------------------------------------------
    # Status properties
    # -------------------------------------------------------------------------
    @property
    def rpm(self):
        """Engine speed in RPM (z-period based, low noise)."""
        return self._r.read('SPEED_RPM_SLOW')

    @property
    def rpm_fast(self):
        """Engine speed in RPM (ab-period based, high update rate)."""
        return self._r.read('SPEED_RPM_FAST')

    @property
    def tdc_deg(self):
        """TDC-referenced engine angle in degrees (0.0-719.9)."""
        return self._r.read('TDC_DEG') * _TDC_LSB

    @property
    def crank_deg(self):
        """Raw crank angle in degrees (0.0-360.0, Z-referenced)."""
        return _from_angfac(self._r.read('ANGLE_ANGFAC'))

    @property
    def sync_state(self):
        """Sync state as string: 'STOPPED', 'MOVING', 'CRANK_SYNC', or 'FULL_SYNC'."""
        return _SYNC_STATES[self._r.read('SYNC_STATE')]

    @property
    def is_synced(self):
        """True when FULL_SYNC (crank and phase both locked)."""
        return self._r.read('SYNC_STATE') == 3

    @property
    def phase_found(self):
        """True after the first successful cam reference detection."""
        return bool(self._r.read('PHASE_REF_FOUND'))

    @property
    def phase_ok(self):
        """True when cam detection is healthy (no consecutive misses)."""
        return bool(self._r.read('PHASE_REF_OK'))

    @property
    def engine_phase(self):
        """Current engine phase: 0 (compression stroke) or 1 (exhaust stroke)."""
        return self._r.read('PHASE_ENG')

    @property
    def faults(self):
        """
        Dict of active fault flags and their counts.
        Keys: 'cam', 'crank', 'pll', 'ab', 'speed', 'encoder'.
        """
        flags = self._r.read('FAULT_FLAGS')
        return {
            'cam':     bool(flags & (1 << 0)),
            'crank':   bool(flags & (1 << 1)),
            'ab':      bool(flags & (1 << 2)),
            'speed':   bool(flags & (1 << 3)),
            'pll':     bool(flags & (1 << 4)),
            'counts': {
                'cam':     self._r.read('FAULT_CAM_COUNT'),
                'crank':   self._r.read('FAULT_CRANK_COUNT'),
                'pll':     self._r.read('FAULT_PLL_COUNT'),
                'ab':      self._r.read('FAULT_AB_COUNT'),
                'speed':   self._r.read('FAULT_SPEED_COUNT'),
                'encoder': self._r.read('FAULT_ENC_COUNT'),
            }
        }

    @property
    def packet_count(self):
        """Total DMA packets transmitted since last reset."""
        return self._r.read('PKT_COUNT')

    @property
    def overflow_count(self):
        """DMA overflow count (trig pulses missed while packet in progress)."""
        return self._r.read('OVF_COUNT')

    # -------------------------------------------------------------------------
    # Packet decoding
    # -------------------------------------------------------------------------
    @staticmethod
    def decode(words):
        """
        Decode a single 6-word DMA sample.

        words: sequence of 6 unsigned 32-bit integers.
        Returns a Sample namedtuple:
            .tdc_deg   -- TDC-referenced engine angle (float, degrees)
            .rpm_slow  -- z-period RPM (int)
            .rpm_fast  -- ab-period RPM (int)
            .di        -- digital inputs byte (int)
            .adc       -- tuple of 6 ADC values, indices 0-5 (int, 12-bit)
        """
        if len(words) < 6:
            raise ValueError(f"Expected 6 words, got {len(words)}")
        w = [int(words[i]) & 0xFFFF_FFFF for i in range(6)]
        return Sample(
            tdc_deg  = ((w[1] & 0xFFFF) * _TDC_LSB),
            rpm_slow = (w[0] >> 16) & 0xFFFF,
            rpm_fast = (w[0] >>  0) & 0xFFFF,
            di       = (w[2] >> 24) & 0xFF,
            adc      = (
                (w[2] >>  0) & 0x0FFF,
                (w[3] >> 16) & 0x0FFF,
                (w[3] >>  0) & 0x0FFF,
                (w[4] >> 16) & 0x0FFF,
                (w[4] >>  0) & 0x0FFF,
                (w[5] >> 16) & 0x0FFF,
            ),
        )

    @staticmethod
    def decode_buffer(buf, n_samples=None):
        """
        Decode an entire DMA buffer.

        buf:       flat array/list of 32-bit words (6 words per sample).
        n_samples: number of samples to decode (default: all complete samples).
        Returns list of Sample namedtuples.
        """
        total = len(buf) // 6
        n = total if n_samples is None else min(n_samples, total)
        return [Angus.decode(buf[i * 6 : i * 6 + 6]) for i in range(n)]

    # -------------------------------------------------------------------------
    # Diagnostic print methods
    # -------------------------------------------------------------------------
    def status(self):
        """Print a concise operational status summary."""
        f = self.faults
        any_fault = any(f[k] for k in ('cam', 'crank', 'ab', 'speed', 'pll'))
        print("=== Angus Status ===")
        print(f"  sync          {self.sync_state}")
        print(f"  rpm           {self.rpm} (slow)  {self.rpm_fast} (fast)")
        print(f"  tdc_deg       {self.tdc_deg:.1f}")
        print(f"  crank_deg     {self.crank_deg:.2f}")
        print(f"  engine_phase  {self.engine_phase}  "
              f"phase_found={self.phase_found}  phase_ok={self.phase_ok}")
        print(f"  faults        {'ACTIVE' if any_fault else 'none'}  "
              f"pkts={self.packet_count}  ovf={self.overflow_count}")

    def pll_status(self):
        """Print PLL diagnostic values in engineering units."""
        nco_ab  = self._r.read('ANGLE_NCO_AB_INC')
        nco_clk = self._r.read('ANGLE_NCO_CLK_INC')
        ppr     = round((_ANGFAC_FS + 1) / nco_ab) if nco_ab else 0
        print("=== PLL Status ===")
        print(f"  active        {bool(self._r.read('PLL_DIV_VALID'))}")
        print(f"  pll_deg       {_from_angfac(self._r.read('PLL_ANGFAC')):.3f}")
        err_raw = self._r.read_signed('PLL_ERR_ANGFAC')
        print(f"  error         {_from_angfac(abs(err_raw)):.4f} deg  "
              f"({'ahead' if err_raw < 0 else 'behind'})")
        print(f"  p_term        {self._r.read_signed('PLL_P_TERM')}")
        print(f"  i_term        {self._r.read_signed('PLL_I_TERM')}")
        print(f"  pi_corr       {self._r.read_signed('PLL_PI_CORR')}")
        print(f"  nco_inc       {self._r.read('PLL_NCO_INC')}")
        print(f"  ppr (derived) {ppr}")
        print(f"  nco_ab_inc    {nco_ab}  "
              f"({_from_angfac(nco_ab):.3f} deg/tooth)")
        print(f"  nco_clk_inc   {nco_clk}  "
              f"({_from_angfac(nco_clk) * 1e3:.4f} mdeg/clk)")

    def full_status(self):
        """Print complete status and configuration."""
        self.status()
        print()
        self.pll_status()
        print()
        print("=== Configuration ===")
        ctrl    = self._r.read_raw(0x000)
        ctrl_rt = self._r.read_raw(0x004)
        nco_ab  = self._r.read('ANGLE_NCO_AB_INC')
        ppr     = round((_ANGFAC_FS + 1) / nco_ab) if nco_ab else 0
        phase_min = _from_angfac(self._r.read('PHASE_REF_MIN'))
        phase_max = _from_angfac(self._r.read('PHASE_REF_MAX'))
        phase_ph  = (ctrl_rt >> _RT_PHASE_PH) & 1
        tdc_off   = _from_angfac(self._r.read('TDC_OFFSET'))
        print(f"  src           {'crank' if not (ctrl >> _CTRL_SRC) & 1 else 'encoder'}")
        print(f"  ref           {'cam' if not (ctrl >> _CTRL_REF) & 1 else 'peak'}")
        print(f"  crank_teeth   {self._r.read('CRANK_N_TEETH')} "
              f"(missing={self._r.read('CRANK_N_MISSING')})")
        print(f"  ppr (derived) {ppr}")
        print(f"  phase_window  [{phase_min:.1f}, {phase_max:.1f}] deg  "
              f"(phase={phase_ph})")
        print(f"  tdc_offset    {tdc_off:.2f} deg")
        print(f"  decimation    {self._r.read('TRIG_DECIMATION')}")
        print(f"  dma_buf_size  {self._r.read('DMA_BUFFER_SIZE')} engine cycles")
        print(f"  interp        {bool((ctrl >> _CTRL_INTERP) & 1)}")
        print(f"  ang_sel       {'tooth' if not (ctrl >> _CTRL_ANG_SEL) & 1 else 'pll'}")

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------
    def _set_phase_window(self, centre_deg, tol_deg, phase_ref_phase):
        """Compute and write PHASE_REF_MIN/MAX and PHASE_REF_PHASE."""
        centre = _to_angfac(centre_deg)
        tol    = _to_angfac(tol_deg)
        lo     = centre - tol
        hi     = centre + tol

        if lo < 0 or hi > _ANGFAC_FS:
            warnings.warn(
                f"Phase detection window [{centre_deg - tol_deg:.1f}, "
                f"{centre_deg + tol_deg:.1f}] deg clips at the Z edge "
                f"boundary (0/360 deg) and has been clamped. "
                f"The detection window must not span the crank Z edge.",
                UserWarning, stacklevel=3
            )

        self._r.write('PHASE_REF_MIN', max(0, lo))
        self._r.write('PHASE_REF_MAX', min(_ANGFAC_FS, hi))

        rt = self._r.read_raw(0x004)
        rt = (rt & ~(1 << _RT_PHASE_PH)) | ((phase_ref_phase & 1) << _RT_PHASE_PH)
        self._r.write_raw(0x004, rt)

    def _set_tdc_offset(self, offset_deg):
        """Convert TDC offset from crank degrees to angfac and write."""
        self._r.write('TDC_OFFSET', _to_angfac(offset_deg))
