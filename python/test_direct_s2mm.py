"""
Minimal direct AXI DMA S2MM test for Angus/PYNQ.

Run on the Zynq/PYNQ board, for example:

    sudo -E python test_direct_s2mm.py --dma-name axi_dma_0 --samples 7200
    sudo -E python test_direct_s2mm.py --dma-name axi_dma_1 --samples 7200

This bypasses FastAPI/websockets and uses the AXI DMA S2MM registers directly.
"""

import argparse
import time
from typing import Any, Dict

import numpy as np
from pynq import Overlay, allocate

from angus import Angus


DMA_WORDS_PER_SAMPLE = 2
N_TDC_STEPS = 7200


STARTUP_CONF = {
    "src": "crank",
    "crank_n_teeth": 60,
    "crank_n_missing": 2,
    "crank_edge": "falling",
    "ref": "cam",
    "cam_n_teeth": 1,
    "cam_edge": "rising",
    "phase_ref_deg": 93.0,
    "phase_tol_deg": 10.0,
    "ang_sel": "tooth",
    "angle_interp": True,
    "dma_buffer_size": 1,
}


RUNTIME_CONF = {
    "max_rpm": 6000,
    "trig_decimation": 1,
    "tdc_offset_deg": 0.0,
}

COMMON_SAMPLE_COUNTS = [3600, 7200, 10800, 14400, 21600, 28800, 43200, 57600]

STREAM_DEFAULTS = {
    "raw": {"dma_name": "axi_dma_0", "samples": 7200},
    "avg": {"dma_name": "axi_dma_1", "samples": 7200},
}

READ_REGS = {
    "CONTROL": 0x000,
    "CONTROL_RT": 0x004,
    "SYNC_STATE": 0x0B4,
    "PKT_COUNT": 0x104,
    "OVF_COUNT": 0x108,
    "AVG_FRAME_COUNT": 0x110,
}

SYNC_NAMES = {
    0: "STOPPED",
    1: "MOVING",
    2: "CRANK_SYNC",
    3: "FULL_SYNC",
}


def raw_debug_regs(ip: Any) -> Dict[str, Any]:
    values = {name: int(ip.read(addr) & 0xFFFFFFFF) for name, addr in READ_REGS.items()}
    values["SYNC_STATE_NAME"] = SYNC_NAMES.get(values["SYNC_STATE"], "?")
    return values


def wait_for_sync(ip: Any, level: int, timeout: float) -> bool:
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        state = int(ip.read(READ_REGS["SYNC_STATE"]) & 0xFFFFFFFF)
        if state != last:
            print(f"sync_state={state} {SYNC_NAMES.get(state, '?')}")
            last = state
        if state >= level:
            return True
        time.sleep(0.05)
    return False


class DirectS2MMDma:
    S2MM_DMACR = 0x30
    S2MM_DMASR = 0x34
    S2MM_DA = 0x48
    S2MM_DA_MSB = 0x4C
    S2MM_LENGTH = 0x58

    CR_RUNSTOP = 0x0001
    CR_RESET = 0x0004

    SR_HALTED = 0x0001
    SR_IDLE = 0x0002
    SR_ERR_MASK = 0x0070
    SR_IOC_IRQ = 0x1000
    SR_IRQ_MASK = 0x7000

    def __init__(self, dma: Any):
        self.dma = dma
        self.mmio = getattr(dma, "mmio", None) or getattr(dma, "_mmio", None)
        if self.mmio is None:
            raise RuntimeError("AXI DMA object does not expose an mmio interface")

    def status(self) -> Dict[str, Any]:
        cr = self.mmio.read(self.S2MM_DMACR)
        sr = self.mmio.read(self.S2MM_DMASR)
        return {
            "control": cr,
            "status": sr,
            "running": bool(cr & self.CR_RUNSTOP),
            "halted": bool(sr & self.SR_HALTED),
            "idle": bool(sr & self.SR_IDLE),
            "error": bool(sr & self.SR_ERR_MASK),
            "dma_internal_error": bool(sr & 0x10),
            "dma_slave_error": bool(sr & 0x20),
            "dma_decode_error": bool(sr & 0x40),
            "ioc_irq": bool(sr & self.SR_IOC_IRQ),
            "length": self.mmio.read(self.S2MM_LENGTH),
        }

    def reset(self, timeout: float = 1.0) -> Dict[str, Any]:
        before = self.status()
        self.mmio.write(self.S2MM_DMACR, self.CR_RESET)
        t0 = time.time()
        while time.time() - t0 < timeout:
            if (self.mmio.read(self.S2MM_DMACR) & self.CR_RESET) == 0:
                break
            time.sleep(0.001)
        after = self.status()
        after["reset_cleared"] = (self.mmio.read(self.S2MM_DMACR) & self.CR_RESET) == 0
        return {"before": before, "after": after}

    def start(self) -> None:
        self.mmio.write(self.S2MM_DMASR, self.SR_IRQ_MASK)
        self.mmio.write(self.S2MM_DMACR, self.CR_RUNSTOP)

    def transfer(self, buf: Any, n_bytes: int, timeout: float) -> Dict[str, Any]:
        if self.status()["error"]:
            print("DMA was in error before transfer; resetting")
            print(self.reset())

        self.start()
        addr = int(getattr(buf, "device_address", getattr(buf, "physical_address", 0)))
        self.mmio.write(self.S2MM_DA, addr & 0xFFFF_FFFF)
        if addr > 0xFFFF_FFFF:
            self.mmio.write(self.S2MM_DA_MSB, (addr >> 32) & 0xFFFF_FFFF)
        self.mmio.write(self.S2MM_LENGTH, int(n_bytes))

        t0 = time.time()
        while True:
            sr = self.mmio.read(self.S2MM_DMASR)
            if sr & self.SR_ERR_MASK:
                state = self.status()
                reset = self.reset()
                raise RuntimeError(f"AXI DMA S2MM error: state={state} reset={reset}")
            if sr & self.SR_IOC_IRQ:
                elapsed = time.time() - t0
                completed_length = self.mmio.read(self.S2MM_LENGTH)
                self.mmio.write(self.S2MM_DMASR, self.SR_IRQ_MASK)
                if hasattr(buf, "invalidate"):
                    buf.invalidate()
                return {
                    "elapsed": elapsed,
                    "requested_bytes": int(n_bytes),
                    "reported_length": int(completed_length),
                    "reported_samples": int(completed_length // (DMA_WORDS_PER_SAMPLE * 4)),
                    "status": self.status(),
                }
            if time.time() - t0 > timeout:
                state = self.status()
                reset = self.reset()
                raise TimeoutError(f"AXI DMA S2MM timeout: state={state} reset={reset}")
            time.sleep(0.0005)


def frame_stats(words: np.ndarray, max_words: int | None = None) -> Dict[str, Any]:
    if max_words is not None:
        words = words[:max(0, int(max_words))]
    complete = (words.size // DMA_WORDS_PER_SAMPLE) * DMA_WORDS_PER_SAMPLE
    frames = words[:complete].reshape((-1, DMA_WORDS_PER_SAMPLE))
    if frames.size == 0:
        return {"samples": 0, "valid": 0}

    tdc = frames[:, 0].astype(np.int64, copy=False)
    valid = (tdc >= 0) & (tdc < N_TDC_STEPS)
    unique_tdc = int(np.unique(tdc[valid]).size) if np.any(valid) else 0
    pressure = ((frames[:, 1] >> 4) & 0x0FFF).astype(np.uint32, copy=False)
    di = ((frames[:, 1] >> 24) & 0xFF).astype(np.uint8, copy=False)
    return {
        "samples": int(frames.shape[0]),
        "valid": int(np.count_nonzero(valid)),
        "coverage": float(unique_tdc / N_TDC_STEPS),
        "unique_tdc": unique_tdc,
        "tdc_min": int(tdc[valid].min()) if np.any(valid) else None,
        "tdc_max": int(tdc[valid].max()) if np.any(valid) else None,
        "first_tdc": int(frames[0, 0]),
        "last_tdc": int(frames[-1, 0]),
        "pressure_min": int(pressure.min()),
        "pressure_max": int(pressure.max()),
        "di_first": int(di[0]),
        "di_last": int(di[-1]),
        "first_words": [int(v) for v in words[:8]],
        "last_words": [int(v) for v in words[-8:]],
    }


def compact_stats(stats: Dict[str, Any]) -> str:
    return (
        f"samples={stats.get('samples')} valid={stats.get('valid')} "
        f"coverage={stats.get('coverage', 0.0) * 100:5.1f}% "
        f"tdc={stats.get('tdc_min')}..{stats.get('tdc_max')} "
        f"p={stats.get('pressure_min')}..{stats.get('pressure_max')}"
    )


def run_continuous_tests(direct_tests, words_per_sample: int, timeout: float,
                         status_interval: float) -> int:
    buffers = []
    counts = {name: 0 for name, _, _ in direct_tests}
    errors = {name: 0 for name, _, _ in direct_tests}
    last_stats = {name: "" for name, _, _ in direct_tests}
    t0 = time.time()
    last_print = t0

    try:
        for name, direct, samples in direct_tests:
            n_words = int(samples) * int(words_per_sample)
            buf = allocate(shape=(n_words,), dtype="u4")
            buffers.append((name, direct, samples, n_words * 4, buf))

        print("Running continuously. Press Ctrl-C to stop.")
        while True:
            for name, direct, samples, n_bytes, buf in buffers:
                try:
                    result = direct.transfer(buf, n_bytes, timeout)
                    reported_words = int(result.get("reported_length", n_bytes)) // 4
                    stats = frame_stats(np.asarray(buf, dtype=np.uint32), reported_words)
                    counts[name] += 1
                    last_stats[name] = compact_stats(stats)
                except Exception as exc:
                    errors[name] += 1
                    last_stats[name] = f"FAIL {type(exc).__name__}: {exc}"
                    print(f"{name} {last_stats[name]}")

            now = time.time()
            if now - last_print >= status_interval:
                elapsed = max(now - t0, 1e-9)
                parts = []
                for name in counts:
                    parts.append(
                        f"{name}={counts[name]} ({counts[name] / elapsed:.2f}/s) "
                        f"err={errors[name]} {last_stats[name]}"
                    )
                print(" | ".join(parts))
                last_print = now
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        for _, _, _, _, buf in buffers:
            if hasattr(buf, "freebuffer"):
                buf.freebuffer()
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Minimal direct AXI DMA S2MM test")
    parser.add_argument("--bitfile", default="/home/xilinx/angus.bit")
    parser.add_argument("--ip-name", default="top_0")
    parser.add_argument("--dma-name", required=True, help="Overlay AXI DMA attribute, e.g. axi_dma_0")
    parser.add_argument("--samples", type=int, default=None, help="Sample frames per transfer")
    parser.add_argument("--sweep", action="store_true", help="Try common sample counts to find the packet length")
    parser.add_argument("--isolated-sweep", action="store_true",
                        help="Reload/reconfigure the overlay for each sweep candidate")
    parser.add_argument("--sweep-samples", default=None, help="Comma-separated sample counts for --sweep")
    parser.add_argument("--words-per-sample", type=int, default=DMA_WORDS_PER_SAMPLE)
    parser.add_argument("--loops", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--no-load", action="store_true", help="Do not download the bitstream")
    parser.add_argument("--configure", action="store_true", help="Apply Angus startup/runtime configuration before DMA")
    parser.add_argument("--dma-buffer-size", type=int, default=None,
                        help="Override raw DMA_BUFFER_SIZE in cycles, 0..15")
    parser.add_argument("--avg-n", type=int, default=None, help="Write AVG_N register 0x10C before DMA")
    parser.add_argument("--settle", type=float, default=1.0, help="Seconds to wait after --configure/--avg-n")
    parser.add_argument("--wait-sync", choices=("moving", "crank", "full"), default=None,
                        help="Wait for Angus sync state before arming DMA")
    parser.add_argument("--wait-timeout", type=float, default=10.0)
    parser.add_argument("--continuous", action="store_true", help="Run transfers until Ctrl-C")
    parser.add_argument("--both", action="store_true", help="Continuously test raw then avg streams")
    parser.add_argument("--raw-dma-name", default=STREAM_DEFAULTS["raw"]["dma_name"])
    parser.add_argument("--avg-dma-name", default=STREAM_DEFAULTS["avg"]["dma_name"])
    parser.add_argument("--raw-samples", type=int, default=STREAM_DEFAULTS["raw"]["samples"])
    parser.add_argument("--avg-samples", type=int, default=STREAM_DEFAULTS["avg"]["samples"])
    parser.add_argument("--status-interval", type=float, default=1.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.dma_buffer_size is not None and not 0 <= args.dma_buffer_size <= 15:
        raise SystemExit("--dma-buffer-size is the 4-bit raw DMA_BUFFER_SIZE register value, valid range 0..15")
    if args.both:
        args.continuous = True
    if args.samples is None and not args.sweep and not args.both:
        raise SystemExit("Either --samples or --sweep is required")

    def make_overlay(download: bool) -> Any:
        print(f"Loading overlay {args.bitfile!r} download={download}")
        overlay = Overlay(args.bitfile, download=download)
        attrs = [name for name in dir(overlay) if "dma" in name.lower()]
        print(f"DMA-like overlay attrs: {attrs}")
        return overlay

    def configure_overlay(overlay: Any) -> None:
        if not args.configure:
            return
        startup_conf = dict(STARTUP_CONF)
        if args.dma_buffer_size is not None:
            startup_conf["dma_buffer_size"] = int(args.dma_buffer_size)
        print(f"Configuring Angus via overlay.{args.ip_name}")
        angus = Angus(getattr(overlay, args.ip_name))
        print(f"startup_conf: {startup_conf}")
        angus.startup_conf(**startup_conf)
        print(f"runtime_conf: {RUNTIME_CONF}")
        angus.runtime_conf(**RUNTIME_CONF)
        ip = getattr(overlay, args.ip_name)
        print("raw regs after config:", raw_debug_regs(ip))

    def write_avg_n(overlay: Any) -> None:
        if args.avg_n is None:
            return
        ip = getattr(overlay, args.ip_name)
        avg_n = max(0, min(255, int(args.avg_n)))
        print(f"Writing AVG_N 0x10C = {avg_n}")
        ip.write(0x10C, avg_n)
        print(f"AVG_N readback: {ip.read(0x10C) & 0xFFFFFFFF}")

    def wait_if_requested(overlay: Any) -> None:
        if not args.wait_sync:
            return
        levels = {"moving": 1, "crank": 2, "full": 3}
        target = levels[args.wait_sync]
        ip = getattr(overlay, args.ip_name)
        print(f"Waiting for sync >= {target} ({args.wait_sync}) for {args.wait_timeout:.1f}s")
        reached = wait_for_sync(ip, target, args.wait_timeout)
        print(f"sync wait reached={reached} regs={raw_debug_regs(ip)}")

    if args.sweep:
        if args.sweep_samples:
            sample_counts = [int(v.strip()) for v in args.sweep_samples.split(",") if v.strip()]
        else:
            sample_counts = COMMON_SAMPLE_COUNTS
    else:
        sample_counts = [int(args.samples)]

    shared_overlay = None
    shared_direct = None
    if not args.isolated_sweep:
        shared_overlay = make_overlay(download=not args.no_load)
        configure_overlay(shared_overlay)
        write_avg_n(shared_overlay)
        if args.configure or args.avg_n is not None:
            print(f"Settling for {args.settle:.3f}s")
            time.sleep(args.settle)
        wait_if_requested(shared_overlay)
        if args.both:
            ip = getattr(shared_overlay, args.ip_name)
            print("Writing AVG_N 0x10C = 1 for avg stream")
            ip.write(0x10C, 1)
            stream_tests = [
                ("raw", args.raw_dma_name, args.raw_samples),
                ("avg", args.avg_dma_name, args.avg_samples),
            ]
            direct_tests = [
                (name, DirectS2MMDma(getattr(shared_overlay, dma_name)), samples)
                for name, dma_name, samples in stream_tests
            ]
            for name, direct, samples in direct_tests:
                print(f"{name}: samples={samples} initial={direct.status()}")
            return run_continuous_tests(direct_tests, args.words_per_sample, args.timeout, args.status_interval)
        else:
            shared_direct = DirectS2MMDma(getattr(shared_overlay, args.dma_name))
            print(f"Initial status: {shared_direct.status()}")

    for samples in sample_counts:
        if args.isolated_sweep:
            overlay = make_overlay(download=True)
            configure_overlay(overlay)
            write_avg_n(overlay)
            if args.configure or args.avg_n is not None:
                print(f"Settling for {args.settle:.3f}s")
                time.sleep(args.settle)
            wait_if_requested(overlay)
            direct = DirectS2MMDma(getattr(overlay, args.dma_name))
            print(f"Initial status: {direct.status()}")
        else:
            direct = shared_direct

        n_words = int(samples) * int(args.words_per_sample)
        n_bytes = n_words * 4
        print(f"\n=== samples={samples} words={n_words} bytes={n_bytes} ===")
        buf = allocate(shape=(n_words,), dtype="u4")
        try:
            loop_index = 0
            while args.continuous or loop_index < args.loops:
                loop_index += 1
                label = f"{loop_index}" if args.continuous else f"{loop_index}/{args.loops}"
                print(f"Transfer {label}")
                print(f"Before: {direct.status()}")
                try:
                    result = direct.transfer(buf, n_bytes, args.timeout)
                    words = np.asarray(buf, dtype=np.uint32)
                    reported_words = int(result.get("reported_length", n_bytes)) // 4
                    requested_stats = frame_stats(words)
                    reported_stats = frame_stats(words, reported_words)
                    print(f"PASS result: {result}")
                    if result.get("reported_length") != result.get("requested_bytes"):
                        print(
                            "WARNING reported_length differs from requested_bytes; "
                            "packet length does not match the requested frame length"
                        )
                    print(f"Reported-length stats: {reported_stats}")
                    print(f"Requested-buffer stats: {requested_stats}")
                    if args.continuous:
                        print(f"OK {compact_stats(reported_stats)}")
                except Exception as exc:
                    print(f"FAIL {type(exc).__name__}: {exc}")
                    if not args.continuous:
                        break
        finally:
            if hasattr(buf, "freebuffer"):
                buf.freebuffer()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
