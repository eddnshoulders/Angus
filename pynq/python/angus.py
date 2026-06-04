"""
angus.py -- Application API for the Angus combustion analyser v3.

Provides a clean, degree-based interface to the FPGA. All register addresses,
angfac conversions, and packet encoding are handled internally.

Usage:
    from angus import Angus
    a = Angus(overlay.<ip_block_name>)

    # One-shot startup (resets hardware and latches config)
    a.startup_conf(crank_n_teeth=60, phase_ref_deg=180.0, tdc_offset_deg=90.0)
    a.wait_for_sync()

    # Runtime adjustments (no reset required)
    a.runtime_conf(tdc_offset_deg=92.5, trig_decimation=5)

    # Status
    print(a.rpm, a.tdc_deg, a.is_synced)

    # Decode DMA buffer
    samples = Angus.decode_buffer(dma_words)
"""

import time
import warnings
from collections import namedtuple
from angus_regs import AngusRegs

# =============================================================================
# Internal constants -- not part of the public API
# =============================================================================
_ANGFAC_FS   = 0xFFFF_FFFF
_TDC_LSB     = 0.1
_SYNC_STATES = ('STOPPED', 'MOVING', 'CRANK_SYNC', 'FULL_SYNC')

_CTRL_CRANK_EDGE = 0
_CTRL_CAM_EDGE   = 1
_CTRL_ENC_AB     = 2
_CTRL_ENC_Z      = 4
_CTRL_SRC        = 5
_CTRL_REF        = 6
_CTRL_APPLY      = 7
_CTRL_ANG_SEL    = 8
_CTRL_INTERP     = 9

_RT_FAULT_CLR  = 0
_RT_CORR_DIR   = 1
_RT_PHASE_DROP = 2
_RT_PHASE_PH   = 3

_UNCHANGED = object()   # sentinel for "leave this parameter as-is"


def _to_angfac(deg):
    return max(0, min(_ANGFAC_FS, round(deg / 360.0 * (_ANGFAC_FS + 1))))

def _from_angfac(v):
    return v / (_ANGFAC_FS + 1) * 360.0


# =============================================================================
# Sample namedtuple returned by Angus.decode()
# =============================================================================
Sample = namedtuple('Sample', ['tdc_deg', 'rpm_slow', 'rpm_fast', 'di', 'adc'])


# =============================================================================
# Angus
# =============================================================================
class Angus:
    """
    Application-level interface to the Angus combustion analyser FPGA.

    Configuration is split into two calls:
      startup_conf()  -- parameters that require a hardware reset to take
                         effect. Applies immediately; no separate apply() needed.
      runtime_conf()  -- parameters that can be changed at any time during
                         normal operation without resetting the hardware.

    All parameters are keyword arguments with sensible defaults so only the
    values you want to change need to be specified.
    """

    # -------------------------------------------------------------------------
    # Default configuration shadows
    # -------------------------------------------------------------------------
    _STARTUP_DEFAULTS = dict(
        crank_n_teeth   = 60,
        crank_n_missing = 2,
        cam_n_teeth     = 1,
        phase_ref_deg   = 180.0,    # engine degrees 0-720; phase bit derived
        phase_tol_deg   = 30.0,
        dma_buffer_size = 2,
        src             = 'crank',  # 'crank' or 'encoder'
        ref             = 'cam',    # 'cam' or 'peak'
        ang_sel         = 'tooth',  # 'tooth' or 'pll'
        angle_interp    = False,
        crank_edge      = 'rising',
        cam_edge        = 'rising',
        enc_n_ppr       = 96,
        enc_ab_edge_sel = 0,        # 0=rising 1=falling 2=both
        enc_z_edge_sel  = 0,        # 0=rising 1=falling
    )

    _RUNTIME_DEFAULTS = dict(
        tdc_offset_deg  = 0.0,
        trig_decimation = 1,
        max_rpm         = 6000,
        peak_hyst       = 128,
        pll_kp          = 0,
        pll_ki          = 0,
        pll_corr_max    = 0xFFFF,
        pll_corr_dir    = 'add',    # 'add' or 'subtract'
        crank_dbc       = 5,
        cam_dbc         = 5,
        enc_a_dbc       = 5,
        enc_b_dbc       = 5,
        enc_z_dbc       = 5,
    )

    # -------------------------------------------------------------------------
    def __init__(self, ip_core):
        """
        ip_core: PYNQ IP object (e.g. overlay.angus_0).
        Use ol.ip_dict.keys() to find the correct block name.
        """
        self._r       = AngusRegs(ip_core)
        self._startup = dict(self._STARTUP_DEFAULTS)
        self._runtime = dict(self._RUNTIME_DEFAULTS)

    # -------------------------------------------------------------------------
    # Startup configuration
    # -------------------------------------------------------------------------
    def startup_conf(self,
                     crank_n_teeth   = _UNCHANGED,
                     crank_n_missing = _UNCHANGED,
                     cam_n_teeth     = _UNCHANGED,
                     phase_ref_deg   = _UNCHANGED,
                     phase_tol_deg   = _UNCHANGED,
                     dma_buffer_size = _UNCHANGED,
                     src             = _UNCHANGED,
                     ref             = _UNCHANGED,
                     ang_sel         = _UNCHANGED,
                     angle_interp    = _UNCHANGED,
                     crank_edge      = _UNCHANGED,
                     cam_edge        = _UNCHANGED,
                     enc_n_ppr       = _UNCHANGED,
                     enc_ab_edge_sel = _UNCHANGED,
                     enc_z_edge_sel  = _UNCHANGED):
        """
        Set startup configuration and immediately apply it to hardware.

        Any parameter not supplied retains its previous value (or the default
        if startup_conf() has not been called before). The hardware is reset
        and all startup registers are latched on every call.

        crank_n_teeth:   total teeth including missing (default 60)
        crank_n_missing: number of missing teeth (default 2)
        cam_n_teeth:     cam edges per 2 crank revolutions (default 1)
        phase_ref_deg:   expected cam edge in engine degrees (0-719.9).
                         0-359.9 = phase 0 (compression stroke),
                         360-719.9 = phase 1 (exhaust stroke).
                         The phase bit is derived automatically. (default 180.0)
        phase_tol_deg:   detection window half-width in crank degrees (default 30.0)
        dma_buffer_size: engine cycles per DMA buffer (default 2)
        src:             angle source -- 'crank' or 'encoder' (default 'crank')
        ref:             phase reference -- 'cam' or 'peak' (default 'cam')
        ang_sel:         angle stream -- 'tooth' or 'pll' (default 'tooth')
        angle_interp:    Bresenham interpolation between teeth (default False)
        crank_edge:      crank trigger edge -- 'rising' or 'falling' (default 'rising')
        cam_edge:        cam trigger edge -- 'rising' or 'falling' (default 'rising')
        enc_n_ppr:       encoder pulses per revolution (default 96)
        enc_ab_edge_sel: encoder AB edge -- 0=rising 1=falling 2=both (default 0)
        enc_z_edge_sel:  encoder Z edge -- 0=rising 1=falling (default 0)
        """
        locs = locals()
        for k in self._STARTUP_DEFAULTS:
            if locs[k] is not _UNCHANGED:
                self._startup[k] = locs[k]
        self._apply_startup()

    # -------------------------------------------------------------------------
    # Runtime configuration
    # -------------------------------------------------------------------------
    def runtime_conf(self,
                     tdc_offset_deg  = _UNCHANGED,
                     trig_decimation = _UNCHANGED,
                     max_rpm         = _UNCHANGED,
                     peak_hyst       = _UNCHANGED,
                     pll_kp          = _UNCHANGED,
                     pll_ki          = _UNCHANGED,
                     pll_corr_max    = _UNCHANGED,
                     pll_corr_dir    = _UNCHANGED,
                     crank_dbc       = _UNCHANGED,
                     cam_dbc         = _UNCHANGED,
                     enc_a_dbc       = _UNCHANGED,
                     enc_b_dbc       = _UNCHANGED,
                     enc_z_dbc       = _UNCHANGED):
        """
        Update runtime configuration without resetting the hardware.

        Any parameter not supplied retains its previous value. Safe to call
        at any time during normal operation.

        tdc_offset_deg:  crank degrees from Z edge to engine TDC (default 0.0)
        trig_decimation: sample rate divisor; 1 = every 0.1 deg equiv (default 1)
        max_rpm:         speed fault threshold in RPM (default 6000)
        peak_hyst:       peak detector hysteresis counts (default 128)
        pll_kp:          PLL proportional gain (default 0)
        pll_ki:          PLL integral gain (default 0)
        pll_corr_max:    PLL max correction NCO LSB (default 0xFFFF)
        pll_corr_dir:    PLL correction direction -- 'add' or 'subtract' (default 'add')
        crank_dbc:       crank debounce cycles @ 100 MHz (default 5)
        cam_dbc:         cam debounce cycles (default 5)
        enc_a_dbc:       encoder A debounce cycles (default 5)
        enc_b_dbc:       encoder B debounce cycles (default 5)
        enc_z_dbc:       encoder Z debounce cycles (default 5)
        """
        locs = locals()
        for k in self._RUNTIME_DEFAULTS:
            if locs[k] is not _UNCHANGED:
                self._runtime[k] = locs[k]
        self._apply_runtime()

    # -------------------------------------------------------------------------
    # Control
    # -------------------------------------------------------------------------
    def clear_faults(self):
        """Clear all fault counters."""
        self._r.write_raw(0x004, 1 << _RT_FAULT_CLR)

    def wait_for_sync(self, level='full', timeout=10.0):
        """
        Block until sync reaches the requested level.

        level:   'moving', 'crank', or 'full' (default)
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
        """Engine speed in RPM (ab-period based, fast update rate)."""
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
        """Sync state string: 'STOPPED', 'MOVING', 'CRANK_SYNC', or 'FULL_SYNC'."""
        return _SYNC_STATES[self._r.read('SYNC_STATE')]

    @property
    def is_synced(self):
        """True when FULL_SYNC (crank and phase both locked)."""
        return self._r.read('SYNC_STATE') == 3

    @property
    def phase_found(self):
        """True after the first successful cam detection."""
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
        Dict of active fault flags and per-type counts.
        Keys: 'cam', 'crank', 'ab', 'speed', 'pll', 'counts'.
        """
        flags = self._r.read('FAULT_FLAGS')
        return {
            'cam':    bool(flags & (1 << 0)),
            'crank':  bool(flags & (1 << 1)),
            'ab':     bool(flags & (1 << 2)),
            'speed':  bool(flags & (1 << 3)),
            'pll':    bool(flags & (1 << 4)),
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
        """DMA overflow count (samples dropped while buffer not ready)."""
        return self._r.read('OVF_COUNT')

    # -------------------------------------------------------------------------
    # Packet decoding
    # -------------------------------------------------------------------------
    @staticmethod
    def decode(words):
        """
        Decode one 6-word DMA sample.

        words: sequence of 6 unsigned 32-bit integers.
        Returns a Sample namedtuple:
            .tdc_deg   -- engine angle, 0.0-719.9 degrees
            .rpm_slow  -- z-period RPM
            .rpm_fast  -- ab-period RPM
            .di        -- digital inputs byte
            .adc       -- tuple of 6 ADC values (12-bit, indices 0-5)
        """
        if len(words) < 6:
            raise ValueError(f"Expected 6 words, got {len(words)}")
        w = [int(words[i]) & 0xFFFF_FFFF for i in range(6)]
        return Sample(
            tdc_deg  = (w[1] & 0xFFFF) * _TDC_LSB,
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
    # Diagnostics
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
        err_raw = self._r.read_signed('PLL_ERR_ANGFAC')
        print("=== PLL Status ===")
        print(f"  active        {bool(self._r.read('PLL_DIV_VALID'))}")
        print(f"  pll_deg       {_from_angfac(self._r.read('PLL_ANGFAC')):.3f}")
        print(f"  error         {_from_angfac(abs(err_raw)):.4f} deg  "
              f"({'ahead' if err_raw < 0 else 'behind'})")
        print(f"  p_term        {self._r.read_signed('PLL_P_TERM')}")
        print(f"  i_term        {self._r.read_signed('PLL_I_TERM')}")
        print(f"  pi_corr       {self._r.read_signed('PLL_PI_CORR')}")
        print(f"  ppr (derived) {ppr}")
        print(f"  nco_ab_inc    {nco_ab}  ({_from_angfac(nco_ab):.3f} deg/tooth)")
        print(f"  nco_clk_inc   {nco_clk}  "
              f"({_from_angfac(nco_clk) * 1e3:.4f} mdeg/clk)")

    def full_status(self):
        """Print combined status, PLL, and configuration summary."""
        self.status()
        print()
        self.pll_status()
        print()
        s = self._startup
        r = self._runtime
        print("=== Configuration ===")
        print(f"  src / ref     {s['src']} / {s['ref']}")
        print(f"  crank_teeth   {s['crank_n_teeth']} (missing={s['crank_n_missing']})")
        print(f"  phase_ref_deg {s['phase_ref_deg']:.1f}  tol={s['phase_tol_deg']:.1f} deg")
        print(f"  tdc_offset    {r['tdc_offset_deg']:.2f} deg")
        print(f"  decimation    {r['trig_decimation']}")
        print(f"  dma_buf_size  {s['dma_buffer_size']} engine cycles")
        print(f"  interp        {s['angle_interp']}")
        print(f"  ang_sel       {s['ang_sel']}")

    # =========================================================================
    # Private implementation
    # =========================================================================
    def _apply_startup(self):
        """Write all startup registers and toggle config_apply."""
        s = self._startup

        # Crank / cam tooth counts
        self._r.write('CRANK_N_TEETH',   s['crank_n_teeth'])
        self._r.write('CRANK_N_MISSING', s['crank_n_missing'])
        self._r.write('CAM_N_TEETH',     s['cam_n_teeth'])
        self._r.write('ENC_N_PPR',       s['enc_n_ppr'])
        self._r.write('DMA_BUFFER_SIZE', s['dma_buffer_size'])

        # Phase window -- phase bit derived from engine degree range
        self._write_phase_window(s['phase_ref_deg'], s['phase_tol_deg'])

        # CONTROL register -- all startup mux/edge selections + config_apply pulse
        ctrl = (
            (1 if s['crank_edge']   == 'rising' else 0) << _CTRL_CRANK_EDGE |
            (1 if s['cam_edge']     == 'rising' else 0) << _CTRL_CAM_EDGE   |
            (s['enc_ab_edge_sel'] & 0x3)                << _CTRL_ENC_AB     |
            (s['enc_z_edge_sel']  & 0x1)                << _CTRL_ENC_Z      |
            (0 if s['src']          == 'crank'  else 1) << _CTRL_SRC        |
            (0 if s['ref']          == 'cam'    else 1) << _CTRL_REF        |
            (0 if s['ang_sel']      == 'tooth'  else 1) << _CTRL_ANG_SEL   |
            (1 if s['angle_interp'] else 0)             << _CTRL_INTERP     |
            1                                           << _CTRL_APPLY
        )
        self._r.write_raw(0x000, ctrl)

        # Apply runtime config on top (written after reset so they take effect)
        self._apply_runtime()

    def _apply_runtime(self):
        """Write all runtime registers. No reset required."""
        r = self._runtime

        self._r.write('TDC_OFFSET',      _to_angfac(r['tdc_offset_deg']))
        self._r.write('TRIG_DECIMATION', r['trig_decimation'])
        self._r.write('MAX_RPM',         r['max_rpm'])
        self._r.write('PEAK_HYST',       r['peak_hyst'])
        self._r.write('PLL_KP',          r['pll_kp'])
        self._r.write('PLL_KI',          r['pll_ki'])
        self._r.write('PLL_CORR_MAX',    r['pll_corr_max'])
        self._r.write('CRANK_DBC',       r['crank_dbc'])
        self._r.write('CAM_DBC',         r['cam_dbc'])
        self._r.write('ENC_A_DBC',       r['enc_a_dbc'])
        self._r.write('ENC_B_DBC',       r['enc_b_dbc'])
        self._r.write('ENC_Z_DBC',       r['enc_z_dbc'])

        # PLL correction direction lives in CONTROL_RT
        rt = self._r.read_raw(0x004)
        if r['pll_corr_dir'] == 'add':
            rt |=  (1 << _RT_CORR_DIR)
        else:
            rt &= ~(1 << _RT_CORR_DIR)
        self._r.write_raw(0x004, rt)

    def _write_phase_window(self, ref_deg, tol_deg):
        """
        Derive phase bit from engine degree range, normalise to crank degrees,
        compute angfac window, and write registers.
        """
        if ref_deg >= 360.0:
            phase_bit = 1
            crank_deg = ref_deg - 360.0
        else:
            phase_bit = 0
            crank_deg = ref_deg

        centre = _to_angfac(crank_deg)
        tol    = _to_angfac(tol_deg)
        lo     = centre - tol
        hi     = centre + tol

        if lo < 0 or hi > _ANGFAC_FS:
            warnings.warn(
                f"Phase window [{crank_deg - tol_deg:.1f}, {crank_deg + tol_deg:.1f}] "
                f"crank deg clips at the Z edge boundary and has been clamped. "
                f"The detection window must not span the crank Z edge.",
                UserWarning, stacklevel=4
            )

        self._r.write('PHASE_REF_MIN', max(0, lo))
        self._r.write('PHASE_REF_MAX', min(_ANGFAC_FS, hi))

        rt = self._r.read_raw(0x004)
        rt = (rt & ~(1 << _RT_PHASE_PH)) | (phase_bit << _RT_PHASE_PH)
        self._r.write_raw(0x004, rt)
