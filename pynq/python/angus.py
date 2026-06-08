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




# =============================================================================
# Sample namedtuple returned by Angus.decode()
# =============================================================================
Sample = namedtuple('Sample', ['tdc_deg', 'rpm_slow', 'rpm_fast', 'di', 'pressure'])


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
        self.regs       = AngusRegs(ip_core)
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
        self.regs.write_raw(0x004, 1 << _RT_FAULT_CLR)

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
            if self.regs.read('SYNC_STATE') >= target:
                return True
            time.sleep(0.01)
        return False

    # -------------------------------------------------------------------------
    # Status properties
    # -------------------------------------------------------------------------
    @property
    def rpm(self):
        """Engine speed in RPM (z-period based, low noise)."""
        return self.regs.read('SPEED_RPM_SLOW')

    @property
    def rpm_fast(self):
        """Engine speed in RPM (ab-period based, fast update rate)."""
        return self.regs.read('SPEED_RPM_FAST')

    @property
    def tdc_deg(self):
        """TDC-referenced engine angle in degrees (0.0-719.9)."""
        return self.regs.read('TDC_DEG') * _TDC_LSB

    @property
    def crank_deg(self):
        """Raw crank angle in degrees (0.0-360.0, Z-referenced)."""
        return Angus._angfac2deg(self.regs.read('ANGLE_ANGFAC'))

    @property
    def sync_state(self):
        """Sync state string: 'STOPPED', 'MOVING', 'CRANK_SYNC', or 'FULL_SYNC'."""
        return _SYNC_STATES[self.regs.read('SYNC_STATE')]

    @property
    def is_synced(self):
        """True when FULL_SYNC (crank and phase both locked)."""
        return self.regs.read('SYNC_STATE') == 3

    @property
    def phase_found(self):
        """True after the first successful cam detection."""
        return bool(self.regs.read('PHASE_REF_FOUND'))

    @property
    def phase_ok(self):
        """True when cam detection is healthy (no consecutive misses)."""
        return bool(self.regs.read('PHASE_REF_OK'))

    @property
    def engine_phase(self):
        """Current engine phase: 0 (compression stroke) or 1 (exhaust stroke)."""
        return self.regs.read('PHASE_ENG')

    @property
    def faults(self):
        """
        Dict of active fault flags and per-type counts.
        Flags decoded via Angus.decode_faults(). Keys:
            'cam', 'crank_tooth', 'crank_ab', 'speed', 'pll', 'counts'.
        """
        flags = self.decode_faults(self.regs.read('FAULT_FLAGS'))
        flags['counts'] = {
            'cam':         self.regs.read('FAULT_CAM_COUNT'),
            'crank_tooth': self.regs.read('FAULT_CRANK_COUNT'),
            'crank_ab':    self.regs.read('FAULT_AB_COUNT'),
            'speed':       self.regs.read('FAULT_SPEED_COUNT'),
            'pll':         self.regs.read('FAULT_PLL_COUNT'),
            'encoder':     self.regs.read('FAULT_ENC_COUNT'),
        }
        return flags

    @property
    def packet_count(self):
        """Total DMA packets transmitted since last reset."""
        return self.regs.read('PKT_COUNT')

    @property
    def overflow_count(self):
        """DMA overflow count (samples dropped while buffer not ready)."""
        return self.regs.read('OVF_COUNT')

    # -------------------------------------------------------------------------
    # Packet decoding
    # -------------------------------------------------------------------------
    @staticmethod
    def decode(words):
        """
        Decode one 3-word DMA sample.

        words: sequence of 3 unsigned 32-bit integers.
        Returns a Sample namedtuple:
            .tdc_deg   -- engine angle, 0.0-719.9 degrees (0.1 deg/LSB)
            .rpm_slow  -- z-period RPM
            .rpm_fast  -- ab-period RPM
            .di        -- digital inputs byte
            .pressure  -- 12-bit XADC VAUX1 raw count (pressure sensor)
        """
        if len(words) < 3:
            raise ValueError(f"Expected 3 words, got {len(words)}")
        w = [int(words[i]) & 0xFFFF_FFFF for i in range(3)]
        return Sample(
            tdc_deg  = w[1] * _TDC_LSB,
            rpm_slow = (w[0] >> 16) & 0xFFFF,
            rpm_fast = (w[0] >>  0) & 0xFFFF,
            di       = (w[2] >> 24) & 0xFF,
            pressure = (w[2] >>  4) & 0x0FFF,
        )

    @staticmethod
    def _deg2angfac(deg):
        """Convert crank degrees (0-360) to 32-bit angfac. Clamped to valid range."""
        return max(0, min(_ANGFAC_FS, round(deg / 360.0 * (_ANGFAC_FS + 1))))

    @staticmethod
    def _angfac2deg(v):
        """Convert 32-bit angfac to crank degrees (0.0-360.0)."""
        return v / (_ANGFAC_FS + 1) * 360.0

    @staticmethod
    def decode_faults(raw):
        """
        Decode the FAULT_FLAGS register value into a named dict.

        raw: 32-bit unsigned integer read from the FAULT_FLAGS register.
        Returns a dict of the five fault flag bits:
            'cam'         -- cam tooth count mismatch
            'crank_tooth' -- crank tooth count mismatch per revolution
            'crank_ab'    -- crank ab edge count mismatch
            'speed'       -- engine speed exceeded max_rpm
            'pll'         -- PLL phase error exceeded threshold
        """
        return {
            'cam':         bool(raw & (1 << 0)),
            'crank_tooth': bool(raw & (1 << 1)),
            'crank_ab':    bool(raw & (1 << 2)),
            'speed':       bool(raw & (1 << 3)),
            'pll':         bool(raw & (1 << 4)),
        }

    @staticmethod
    def decode_buffer(buf, n_samples=None):
        """
        Decode an entire DMA buffer.

        buf:       flat array/list of 32-bit words (3 words per sample).
        n_samples: number of samples to decode (default: all complete samples).
        Returns list of Sample namedtuples.
        """
        total = len(buf) // 3
        n = total if n_samples is None else min(n_samples, total)
        return [Angus.decode(buf[i * 3 : i * 3 + 3]) for i in range(n)]

    # -------------------------------------------------------------------------
    # Diagnostics
    # -------------------------------------------------------------------------
    def config_status(self):
        """Print a full readback of current configuration (startup and runtime)."""
        s = self._startup
        r = self._runtime
        nco_ab = self.regs.read('ANGLE_NCO_AB_INC')
        ppr    = round((_ANGFAC_FS + 1) / nco_ab) if nco_ab else 0
        print("=== Config -- Startup ===")
        print(f"  src           {s['src']}  ref={s['ref']}  ang_sel={s['ang_sel']}")
        print(f"  crank_edge    {s['crank_edge']}  cam_edge={s['cam_edge']}")
        print(f"  crank_teeth   {s['crank_n_teeth']} (missing={s['crank_n_missing']})  ppr={ppr}")
        print(f"  cam_teeth     {s['cam_n_teeth']}")
        print(f"  phase_ref_deg {s['phase_ref_deg']:.1f}  tol={s['phase_tol_deg']:.1f} deg")
        print(f"  dma_buf_size  {s['dma_buffer_size']} engine cycles")
        print(f"  interp        {s['angle_interp']}")
        print(f"  enc_n_ppr     {s['enc_n_ppr']}  ab_edge={s['enc_ab_edge_sel']}  z_edge={s['enc_z_edge_sel']}")
        print()
        print("=== Config -- Runtime ===")
        print(f"  tdc_offset    {r['tdc_offset_deg']:.2f} deg")
        print(f"  trig_decim    {r['trig_decimation']}")
        print(f"  max_rpm       {r['max_rpm']}")
        print(f"  peak_hyst     {r['peak_hyst']}")
        print(f"  pll_kp        {r['pll_kp']}  ki={r['pll_ki']}  "
              f"corr_max={r['pll_corr_max']}  dir={r['pll_corr_dir']}")
        print(f"  debounce      crank={r['crank_dbc']}  cam={r['cam_dbc']}  "
              f"enc_a={r['enc_a_dbc']}  enc_b={r['enc_b_dbc']}  enc_z={r['enc_z_dbc']}")

    def run_status(self):
        """Print runtime signal values grouped by block."""
        f      = self.faults
        nco_ab = self.regs.read('ANGLE_NCO_AB_INC')
        ppr    = round((_ANGFAC_FS + 1) / nco_ab) if nco_ab else 0
        err    = self.regs.read_signed('PLL_ERR_ANGFAC')

        print("=== Sync ===")
        print(f"  state         {self.sync_state}")
        print(f"  tooth_count   {self.regs.read('CRANK_TOOTH_COUNT')}  "
              f"(expected {self.regs.read('CRANK_N_TEETH') if hasattr(self.regs, 'read') else '?'})")
        print(f"  tooth_period  {self.regs.read('CRANK_TOOTH_PERIOD')} clks")

        print()
        print("=== Speed ===")
        print(f"  rpm_slow      {self.rpm}")
        print(f"  rpm_fast      {self.rpm_fast}")

        print()
        print("=== Angle ===")
        print(f"  crank_deg     {self.crank_deg:.2f}")
        print(f"  tdc_deg       {self.tdc_deg:.1f}")
        print(f"  nco_ab_inc    {nco_ab}  ({Angus._angfac2deg(nco_ab):.3f} deg/tooth)")
        print(f"  nco_clk_inc   {self.regs.read('ANGLE_NCO_CLK_INC')}  "
              f"({Angus._angfac2deg(self.regs.read('ANGLE_NCO_CLK_INC')) * 1e3:.4f} mdeg/clk)")

        print()
        print("=== Phase ===")
        print(f"  found         {self.phase_found}  ok={self.phase_ok}")
        print(f"  engine_phase  {self.engine_phase}")
        print(f"  det_count     {self.regs.read('PHASE_REF_DET_CNT')}")
        print(f"  ref_angfac    {self.regs.read('PHASE_REF_ANGFAC')}  "
              f"({Angus._angfac2deg(self.regs.read('PHASE_REF_ANGFAC')):.2f} crank deg)")

        print()
        print("=== PLL ===")
        print(f"  active        {bool(self.regs.read('PLL_DIV_VALID'))}")
        print(f"  pll_deg       {Angus._angfac2deg(self.regs.read('PLL_ANGFAC')):.3f}")
        print(f"  error         {Angus._angfac2deg(abs(err)):.4f} deg  "
              f"({'ahead' if err < 0 else 'behind'})")
        print(f"  p_term        {self.regs.read_signed('PLL_P_TERM')}")
        print(f"  i_term        {self.regs.read_signed('PLL_I_TERM')}")
        print(f"  pi_corr       {self.regs.read_signed('PLL_PI_CORR')}")
        print(f"  nco_inc       {self.regs.read('PLL_NCO_INC')}")

        print()
        print("=== Fault ===")
        flag_keys = ('cam', 'crank_tooth', 'crank_ab', 'speed', 'pll')
        any_fault = any(f[k] for k in flag_keys)
        print(f"  flags         {'ACTIVE' if any_fault else 'none'}")
        for name in flag_keys:
            count = f['counts'].get(name, 0)
            active = f.get(name, False)
            if count or active:
                print(f"  {name:12s}  {'ACTIVE  ' if active else '        '}"
                      f"count={count}")
        enc_count = f['counts']['encoder']
        if enc_count:
            print(f"  {'encoder':12s}  count={enc_count}")

        print()
        print("=== Pack ===")
        print(f"  pkt_count     {self.packet_count}")
        print(f"  ovf_count     {self.overflow_count}")
        print(f"  trig_count    {self.regs.read('TRIG_COUNT')}")

    # =========================================================================
    # Private implementation
    # =========================================================================
    def _apply_startup(self):
        """Write all startup registers and toggle config_apply."""
        s = self._startup

        # Crank / cam tooth counts
        self.regs.write('CRANK_N_TEETH',   s['crank_n_teeth'])
        self.regs.write('CRANK_N_MISSING', s['crank_n_missing'])
        self.regs.write('CAM_N_TEETH',     s['cam_n_teeth'])
        self.regs.write('ENC_N_PPR',       s['enc_n_ppr'])
        self.regs.write('DMA_BUFFER_SIZE', s['dma_buffer_size'])

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
        self.regs.write_raw(0x000, ctrl)

        # Apply runtime config on top (written after reset so they take effect)
        self._apply_runtime()

    def _apply_runtime(self):
        """Write all runtime registers. No reset required."""
        r = self._runtime

        self.regs.write('TDC_OFFSET',      Angus._deg2angfac(r['tdc_offset_deg']))
        self.regs.write('TRIG_DECIMATION', r['trig_decimation'])
        self.regs.write('MAX_RPM',         r['max_rpm'])
        self.regs.write('PEAK_HYST',       r['peak_hyst'])
        self.regs.write('PLL_KP',          r['pll_kp'])
        self.regs.write('PLL_KI',          r['pll_ki'])
        self.regs.write('PLL_CORR_MAX',    r['pll_corr_max'])
        self.regs.write('CRANK_DBC',       r['crank_dbc'])
        self.regs.write('CAM_DBC',         r['cam_dbc'])
        self.regs.write('ENC_A_DBC',       r['enc_a_dbc'])
        self.regs.write('ENC_B_DBC',       r['enc_b_dbc'])
        self.regs.write('ENC_Z_DBC',       r['enc_z_dbc'])

        # PLL correction direction lives in CONTROL_RT
        rt = self.regs.read_raw(0x004)
        if r['pll_corr_dir'] == 'add':
            rt |=  (1 << _RT_CORR_DIR)
        else:
            rt &= ~(1 << _RT_CORR_DIR)
        self.regs.write_raw(0x004, rt)

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

        centre = Angus._deg2angfac(crank_deg)
        tol    = Angus._deg2angfac(tol_deg)
        lo     = centre - tol
        hi     = centre + tol

        if lo < 0 or hi > _ANGFAC_FS:
            warnings.warn(
                f"Phase window [{crank_deg - tol_deg:.1f}, {crank_deg + tol_deg:.1f}] "
                f"crank deg clips at the Z edge boundary and has been clamped. "
                f"The detection window must not span the crank Z edge.",
                UserWarning, stacklevel=4
            )

        self.regs.write('PHASE_REF_MIN', max(0, lo))
        self.regs.write('PHASE_REF_MAX', min(_ANGFAC_FS, hi))

        rt = self.regs.read_raw(0x004)
        rt = (rt & ~(1 << _RT_PHASE_PH)) | (phase_bit << _RT_PHASE_PH)
        self.regs.write_raw(0x004, rt)
