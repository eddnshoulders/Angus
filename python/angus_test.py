"""
angus_test.py
=============
Hardware bring-up test for new Angus bitstream.
Run on the PYNQ-Z2 with a crank signal connected.

Steps:
  1. Load overlay
  2. Write startup config and apply (releases PL from reset)
  3. Poll status until SYNC_CRANK, then SYNC_FULL
  4. Print full register dump once synced

Usage:
    python3 angus_test.py
    python3 angus_test.py --no-cam   # skip SYNC_FULL wait (no cam signal)
"""

import time
import argparse
import sys

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
parser = argparse.ArgumentParser()
parser.add_argument('--no-cam', action='store_true',
                    help='Do not wait for SYNC_FULL (no cam signal connected)')
parser.add_argument('--bit', default='/home/xilinx/angus.bit',
                    help='Path to bitstream (default: /home/xilinx/angus.bit)')
parser.add_argument('--n-teeth', type=int, default=60)
parser.add_argument('--n-missing', type=int, default=2)
parser.add_argument('--phase-ang', type=int, default=1800,
                    help='Expected cam angle in 0.1 deg steps (default 1800 = 180 deg)')
parser.add_argument('--phase-tol', type=int, default=600,
                    help='Cam window tolerance in 0.1 deg steps (default 600 = 60 deg)')
args = parser.parse_args()

# ---------------------------------------------------------------------------
# Load overlay
# ---------------------------------------------------------------------------
print(f"Loading overlay: {args.bit}")
from pynq import Overlay
ol = Overlay(args.bit)
print(f"IP blocks: {list(ol.ip_dict.keys())}")

# Locate the top module - name depends on block diagram
if 'top_0' in ol.ip_dict:
    mmio = ol.top_0
elif 'angus_0' in ol.ip_dict:
    mmio = ol.angus_0
else:
    # Pick the first non-DMA, non-PS block
    candidates = [k for k in ol.ip_dict if 'dma' not in k and 'ps7' not in k]
    print(f"Could not find top_0 or angus_0. Candidates: {candidates}")
    print("Set mmio manually and re-run, or pass the correct name.")
    sys.exit(1)

print(f"Using IP block: {mmio.fullpath}")

# ---------------------------------------------------------------------------
# Import angus_regs - look next to this script first, then cwd
# ---------------------------------------------------------------------------
import importlib.util, os
for search in [os.path.dirname(__file__), os.getcwd(), '/home/xilinx']:
    candidate = os.path.join(search, 'angus_regs.py')
    if os.path.exists(candidate):
        spec = importlib.util.spec_from_file_location('angus_regs', candidate)
        mod  = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        AngusRegs = mod.AngusRegs
        print(f"Loaded angus_regs from {candidate}")
        break
else:
    print("angus_regs.py not found - falling back to raw register access")
    AngusRegs = None

# ---------------------------------------------------------------------------
# Instantiate register interface
# ---------------------------------------------------------------------------
if AngusRegs:
    regs = AngusRegs(mmio)
else:
    # Minimal shim so the rest of the script still works
    class RawRegs:
        def __init__(self, m): self._m = m
        def read(self, name):
            raise RuntimeError("angus_regs.py not found")
        def write(self, name, val):
            raise RuntimeError("angus_regs.py not found")
    regs = RawRegs(mmio)

# ---------------------------------------------------------------------------
# Step 1: Verify PL is in reset (config_valid=0, sync_state=UNSYNC)
# ---------------------------------------------------------------------------
print("\n--- Step 1: Pre-config state ---")
# Read raw status - PL should be held in reset, AXI still accessible
raw_status = mmio.read(0x24)
print(f"Raw STATUS before config_apply: 0x{raw_status:08X}")
print(f"(Expected 0x00000000 - PL in reset, no signal)")

# ---------------------------------------------------------------------------
# Step 2: Write startup config
# ---------------------------------------------------------------------------
print("\n--- Step 2: Writing startup config ---")
regs.write('N_TEETH',   args.n_teeth)
regs.write('N_MISSING', args.n_missing)
regs.write('GAP_THRESH', 192)          # 1.5x tooth period
print(f"  N_TEETH   = {args.n_teeth}")
print(f"  N_MISSING = {args.n_missing}")
print(f"  GAP_THRESH = 192 (1.5x)")

# Runtime config
regs.write('KP',         0)            # PLL off initially - validate tooth-based angle first
regs.write('KI',         0)
regs.write('MAX_CORR',   65535)
regs.write('PHASE_ANG',  args.phase_ang)
regs.write('PHASE_TOL',  args.phase_tol)
regs.write('TDC_OFFSET', 0)
regs.write('DECIMATION', 1)
regs.write('PULSE_WIDTH', 1000)
print(f"  PHASE_ANG = {args.phase_ang} ({args.phase_ang/10:.1f} deg)")
print(f"  PHASE_TOL = {args.phase_tol} ({args.phase_tol/10:.1f} deg)")
print(f"  KP=0, KI=0 (PLL disabled for initial validation)")

# Apply: releases PL from reset
regs.config_apply(edge_select=1, ang_sel=0, ref_sel=0)
print("  config_apply sent (edge_select=1/rising, ang_sel=crank, ref_sel=cam)")

time.sleep(0.1)

# Verify PL is out of reset
raw_status = mmio.read(0x24)
print(f"\nRaw STATUS after config_apply: 0x{raw_status:08X}")
print(f"(Sync state: {raw_status & 0x7}  Signal present: {(raw_status >> 4) & 1})")

# ---------------------------------------------------------------------------
# Step 3: Poll for SYNC_CRANK
# ---------------------------------------------------------------------------
print("\n--- Step 3: Waiting for SYNC_CRANK (spin up crank signal now) ---")
TIMEOUT = 30.0
t0 = time.time()
last_state = -1

while time.time() - t0 < TIMEOUT:
    raw = mmio.read(0x24)
    state = raw & 0x7
    sig   = (raw >> 4) & 1

    if state != last_state:
        states = {0:'UNSYNC', 1:'FIRST_GAP', 2:'SYNC_CRANK', 3:'SYNC_FULL'}
        print(f"  [{time.time()-t0:5.1f}s] State -> {states.get(state,'?')}  "
              f"signal_present={sig}")
        last_state = state

    if state >= 2:  # SYNC_CRANK or better
        break
    time.sleep(0.05)
else:
    print("TIMEOUT waiting for SYNC_CRANK")
    print("Check: crank signal connected? edge_select correct? n_teeth correct?")
    regs.print_debug()
    sys.exit(1)

# ---------------------------------------------------------------------------
# Step 4: Print debug state at SYNC_CRANK
# ---------------------------------------------------------------------------
print("\n--- Step 4: SYNC_CRANK reached - debug snapshot ---")
regs.print_debug()

ab = regs.read('AB_COUNT')
tp = regs.read('TOOTH_PERIOD')
gp = regs.read('GAP_PERIOD')
if tp > 0 and args.n_teeth > 0:
    rpm = round(100_000_000 / tp / args.n_teeth * 60)
    gap_ratio = gp / (tp * args.n_missing) if tp > 0 else 0
    print(f"\n  Estimated RPM     = {rpm}")
    print(f"  Gap/tooth ratio   = {gap_ratio:.2f}  (expect ~{args.n_missing:.1f}x for {args.n_missing} missing teeth)")
    print(f"  AB count at Z     = {ab}  (expect {args.n_teeth})")

if ab != args.n_teeth:
    print(f"\nWARNING: AB count {ab} != n_teeth {args.n_teeth}")
    print("  Possible causes: wrong n_teeth, wrong edge_select, signal noise")

# ---------------------------------------------------------------------------
# Step 5: Wait for SYNC_FULL (cam signal)
# ---------------------------------------------------------------------------
if args.no_cam:
    print("\n--- Skipping SYNC_FULL wait (--no-cam) ---")
else:
    print(f"\n--- Step 5: Waiting for SYNC_FULL ---")
    print(f"  Cam window: {args.phase_ang/10:.1f} deg +/- {args.phase_tol/10:.1f} deg")
    print(f"  Apply cam signal now if not already connected.")

    t0 = time.time()
    while time.time() - t0 < TIMEOUT:
        raw   = mmio.read(0x24)
        state = raw & 0x7
        if state == 3:
            print(f"  [{time.time()-t0:5.1f}s] SYNC_FULL acquired")
            break
        # Print cam detection angle periodically to help tune window
        if int(time.time() - t0) % 3 == 0:
            cam_ang = regs.read('CAM_ANGLE')
            raw_ang = regs.read('RAW_ANGLE')
            print(f"  [{time.time()-t0:5.1f}s] waiting... "
                  f"raw_angle={raw_ang} ({raw_ang/10:.1f}deg)  "
                  f"last_cam={cam_ang} ({cam_ang/10:.1f}deg)")
        time.sleep(0.5)
    else:
        print("TIMEOUT waiting for SYNC_FULL")
        cam_ang = regs.read('CAM_ANGLE')
        print(f"  Last cam detection angle: {cam_ang} ({cam_ang/10:.1f} deg)")
        print(f"  Window centre: {args.phase_ang/10:.1f} deg +/- {args.phase_tol/10:.1f} deg")
        print(f"  If cam_angle is valid but outside window, adjust --phase-ang")
        regs.print_status()
        sys.exit(1)

# ---------------------------------------------------------------------------
# Step 6: Full status dump
# ---------------------------------------------------------------------------
print("\n--- Step 6: Full register dump ---")
regs.print_all()

# ---------------------------------------------------------------------------
# Step 7: Live poll
# ---------------------------------------------------------------------------
print("\n--- Step 7: Live poll (10s, Ctrl-C to stop) ---")
print(f"{'Time':>6}  {'State':12}  {'RPM':>5}  {'Raw':>5}  {'Crank':>5}  "
      f"{'Engine':>6}  {'PhErr_deg':>9}  Losses")
print("-" * 75)

t0 = time.time()
try:
    while time.time() - t0 < 10.0:
        raw    = mmio.read(0x24)
        state  = raw & 0x7
        states = {0:'UNSYNC', 1:'FIRST_GAP', 2:'SYNC_CRANK', 3:'SYNC_FULL'}
        raw_ang   = regs.read('RAW_ANGLE')
        crk_ang   = regs.read('CRANK_ANGLE')
        eng_ang   = regs.read('ENGINE_ANGLE')
        losses    = regs.read('SYNC_LOSS')
        ph_err    = regs.phase_err_deg()
        rpm       = regs.rpm()
        elapsed   = time.time() - t0
        print(f"{elapsed:6.1f}  {states.get(state,'?'):12}  {rpm:>5}  "
              f"{raw_ang:>5}  {crk_ang:>5}  {eng_ang:>6}  {ph_err:>+9.3f}  {losses}")
        time.sleep(0.2)
except KeyboardInterrupt:
    print("\nStopped.")

print("\nDone.")
