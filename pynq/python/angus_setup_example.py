"""
angus_setup_example.py

Example setup and first-run script for Angus combustion analyser v3.
Adjust the constants in the CONFIGURATION section for your engine and
sensor installation before running.

Typical workflow:
  1. Edit the CONFIGURATION section for your engine
  2. Run this script in a PYNQ notebook cell
  3. Check a.status() -- confirm FULL_SYNC and no faults
  4. Refine tdc_offset_deg once you have a TDC reference
  5. Start DMA and call Angus.decode_buffer() on the result
"""

from pynq import Overlay
from angus import Angus, Sample
import numpy as np

# =============================================================================
# Load bitstream
# =============================================================================
try:
    ol = Overlay('/home/xilinx/angus/angus_v3.bit')
except OSError as e:
    raise SystemExit(f"Bitstream or HWH file not found: {e}")
except RuntimeError as e:
    raise SystemExit(f"Overlay load failed (check HWH matches bitstream): {e}")

# Find the correct IP block name with: print(ol.ip_dict.keys())
a = Angus(ol.angus_0)

# =============================================================================
# STARTUP CONFIGURATION
# Edit these constants for your engine and sensor installation.
# startup_conf() resets the hardware and latches all startup parameters.
# Only call this at initialisation or when changing hardware topology.
# =============================================================================

a.startup_conf(
    # Crank wheel
    crank_n_teeth   = 60,       # total teeth including missing (e.g. 60-2 wheel)
    crank_n_missing = 2,        # number of missing teeth
    crank_edge      = 'rising',

    # Cam / phase reference
    # phase_ref_deg uses engine degrees (0-719.9):
    #   0-359.9  = cam fires during compression stroke (phase 0)
    #   360-719.9 = cam fires during exhaust stroke (phase 1)
    # The phase bit is derived automatically from this value.
    cam_n_teeth     = 1,
    phase_ref_deg   = 180.0,   # expected cam edge position in engine degrees
    phase_tol_deg   = 45.0,    # detection window half-width in crank degrees
    cam_edge        = 'rising',

    # Signal routing
    src             = 'crank',  # angle source: 'crank' or 'encoder'
    ref             = 'cam',    # phase reference: 'cam' or 'peak'
    ang_sel         = 'tooth',  # angle stream: 'tooth' or 'pll'
    angle_interp    = True,     # Bresenham interpolation between teeth

    # DMA
    dma_buffer_size = 2,        # engine cycles per DMA buffer
)

# =============================================================================
# RUNTIME CONFIGURATION
# These can be changed at any time without resetting the hardware.
# runtime_conf() writes them immediately, no reset required.
# =============================================================================

a.runtime_conf(
    tdc_offset_deg  = 0.0,      # crank degrees from Z edge to engine TDC
                                # Set to 0 initially -- measure and refine
                                # once you have a TDC reference on the data.
    trig_decimation = 1,        # 1 = one sample per 0.1 crank deg equivalent
    max_rpm         = 8000,
)

# =============================================================================
# Wait for sync
# =============================================================================
print("Waiting for sync...")

if a.wait_for_sync(level='full', timeout=15.0):
    print(f"FULL_SYNC -- {a.rpm} RPM")
else:
    print(f"Sync not achieved -- state: {a.sync_state}")
    print("Check: crank signal present, correct edge selection, tooth count matches wheel.")

a.status()

# =============================================================================
# Check faults
# =============================================================================
faults = a.faults
if any(faults[k] for k in ('cam', 'crank', 'ab', 'speed', 'pll')):
    print("\nActive faults:")
    for name in ('cam', 'crank', 'ab', 'speed', 'pll'):
        if faults[name]:
            print(f"  {name:8s}  count = {faults['counts'][name]}")
else:
    print("\nNo faults.")

# =============================================================================
# DMA capture example
# Uncomment and adapt once sync is confirmed.
# =============================================================================

# SAMPLES_PER_BUFFER = 3600 * a._startup['dma_buffer_size']  # at decimation=1
# BYTES_PER_BUFFER   = SAMPLES_PER_BUFFER * 6 * 4

# buf = ol.dma.recvchannel.transfer(BYTES_PER_BUFFER)
# ol.dma.recvchannel.wait()

# words   = np.frombuffer(buf, dtype=np.uint32)
# samples = Angus.decode_buffer(words)

# tdc  = np.array([s.tdc_deg for s in samples])
# adc1 = np.array([s.adc[0]  for s in samples])

# print(f"Captured {len(samples)} samples")
# print(f"TDC range: {tdc.min():.1f} -- {tdc.max():.1f} deg")

# =============================================================================
# Refine TDC offset
# Once you have a TDC reference (e.g. scope trigger at known crank angle):
# =============================================================================
# a.runtime_conf(tdc_offset_deg=92.5)

# =============================================================================
# Enable PLL (optional -- once basic sync is solid)
# =============================================================================
# a.runtime_conf(pll_kp=10, pll_ki=1, pll_corr_max=500, pll_corr_dir='add')
# a.startup_conf(ang_sel='pll')  # switch angle stream to PLL output
# a.pll_status()
