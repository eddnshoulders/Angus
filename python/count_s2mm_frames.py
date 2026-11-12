"""
Count AXI DMA S2MM frames using direct register access.

This arms one S2MM DMA channel with an exact expected receive length, waits for
a completed packet/TLAST, prints one line per successful frame, discards the
data, and repeats until Ctrl-C.

AXI DMA simple-mode S2MM is not a variable-length packet sniffer here:
programming a larger-than-packet buffer can raise DMAIntErr when TLAST does not
match the programmed length. Use --samples to test the expected frame length.

Example:
    sudo -E python count_s2mm_frames.py --dma-name axi_dma_0 --samples 7200 --configure
    sudo -E python count_s2mm_frames.py --dma-name axi_dma_1 --samples 7200 --configure --avg-n 1
"""

import argparse
import time
from typing import Any, Dict

from pynq import Overlay, allocate

from angus import Angus
from angus_regs import ALL_REGS, DMA_WORDS_PER_SAMPLE, AngusRegs


DEBUG_REG_NAMES = [
    "CONTROL",
    "CONTROL_RT",
    "RAW_STREAM_RESET",
    "AVG_RESET",
    "DMA_BUFFER_SIZE",
    "SYNC_STATE",
    "PKT_COUNT",
    "OVF_COUNT",
    "RAW_DROPPED_PACKETS",
    "AVG_N",
    "AVG_FRAMES_IN",
    "AVG_FRAMES_OUT",
    "AVG_SAMPLES_IN",
    "AVG_MISSED_SAMPLES",
    "AVG_OUT_OF_ORDER",
    "AVG_BANK_OVERRUN",
    "AVG_DROPPED_SAMPLES",
    "AVG_OUT_STALL",
    "AVG_STATE_DBG",
]


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
            "length": int(self.mmio.read(self.S2MM_LENGTH)),
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
        return {"before": before, "after": after}

    def start(self) -> None:
        self.mmio.write(self.S2MM_DMASR, self.SR_IRQ_MASK)
        self.mmio.write(self.S2MM_DMACR, self.CR_RUNSTOP)

    def receive_frame(
        self,
        buf: Any,
        n_bytes: int,
        timeout: float,
        before_arm=None,
        after_arm=None,
    ) -> Dict[str, Any]:
        if self.status()["error"]:
            self.reset()

        reset_asserted = False
        if before_arm is not None:
            before_arm()
            reset_asserted = True
        try:
            self.start()
            addr = int(getattr(buf, "device_address", getattr(buf, "physical_address", 0)))
            self.mmio.write(self.S2MM_DA, addr & 0xFFFF_FFFF)
            if addr > 0xFFFF_FFFF:
                self.mmio.write(self.S2MM_DA_MSB, (addr >> 32) & 0xFFFF_FFFF)
            self.mmio.write(self.S2MM_LENGTH, int(n_bytes))
        finally:
            if reset_asserted and after_arm is not None:
                after_arm()

        t0 = time.time()
        while True:
            sr = self.mmio.read(self.S2MM_DMASR)
            if sr & self.SR_ERR_MASK:
                state = self.status()
                reset = self.reset()
                raise RuntimeError(f"S2MM error: state={state} reset={reset}")
            if sr & self.SR_IOC_IRQ:
                elapsed = time.time() - t0
                reported_bytes = int(self.mmio.read(self.S2MM_LENGTH))
                self.mmio.write(self.S2MM_DMASR, self.SR_IRQ_MASK)
                if hasattr(buf, "invalidate"):
                    buf.invalidate()
                return {
                    "elapsed": elapsed,
                    "reported_bytes": reported_bytes,
                    "status": self.status(),
                }
            if time.time() - t0 > timeout:
                state = self.status()
                reset = self.reset()
                raise TimeoutError(f"S2MM timeout: state={state} reset={reset}")
            time.sleep(0.0005)


def read_debug_regs(regs: AngusRegs) -> Dict[str, int]:
    return {name: int(regs.read(name)) for name in DEBUG_REG_NAMES if name in ALL_REGS}


def named_reg_max(name: str) -> int:
    _, msb, lsb, _ = ALL_REGS[name]
    return (1 << (msb - lsb + 1)) - 1


def pulse_raw_stream_reset(regs: AngusRegs) -> None:
    if "RAW_STREAM_RESET" not in ALL_REGS:
        raise RuntimeError("RAW_STREAM_RESET is not present in angus_regs.py")
    regs.write("RAW_STREAM_RESET", 1)


def write_reset(regs: AngusRegs, name: str, value: int, raw_addr: int | None = None) -> None:
    if name in ALL_REGS:
        regs.write(name, value)
    elif raw_addr is not None:
        regs.write_raw(raw_addr, value)
    else:
        raise RuntimeError(f"{name} is not present in angus_regs.py")


def make_stream_reset_callbacks(
    regs: AngusRegs,
    reset_name: str | None,
    reset_addr: int | None = None,
):
    if reset_name is None and reset_addr is None:
        return None, None

    label = reset_name if reset_name is not None else f"raw 0x{reset_addr:03X}"

    def before_arm() -> None:
        if reset_name is not None:
            write_reset(regs, reset_name, 1, reset_addr)
        else:
            regs.write_raw(int(reset_addr), 1)

    def after_arm() -> None:
        if reset_name is not None:
            write_reset(regs, reset_name, 0, reset_addr)
        else:
            regs.write_raw(int(reset_addr), 0)

    return label, (before_arm, after_arm)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Count direct S2MM frame lengths")
    parser.add_argument("--bitfile", default="/home/xilinx/angus.bit")
    parser.add_argument("--ip-name", default="top_0")
    parser.add_argument("--dma-name", required=True)
    parser.add_argument("--samples", type=int, required=True,
                        help="Expected sample frames per S2MM transfer")
    parser.add_argument("--words-per-sample", type=int, default=DMA_WORDS_PER_SAMPLE)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--no-load", action="store_true")
    parser.add_argument("--configure", action="store_true")
    parser.add_argument("--dma-buffer-size", type=int, default=None,
                        help="Override raw DMA_BUFFER_SIZE in cycles, 0..15")
    parser.add_argument("--avg-n", type=int, default=None)
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("--raw-stream-reset", action="store_true",
                        help="Assert RAW_STREAM_RESET before arming the first DMA transfer, then release it")
    parser.add_argument("--raw-stream-reset-each", action="store_true",
                        help="Assert/release RAW_STREAM_RESET around every DMA transfer arm")
    parser.add_argument("--avg-reset", action="store_true",
                        help="Assert AVG_RESET before arming the first DMA transfer, then release it")
    parser.add_argument("--avg-reset-each", action="store_true",
                        help="Assert/release AVG_RESET around every DMA transfer arm")
    parser.add_argument("--avg-reset-addr", type=lambda value: int(value, 0), default=None,
                        help="Raw byte address for AVG_RESET if angus_regs.py has not been updated yet")
    parser.add_argument("--regs-every", type=int, default=0,
                        help="Print Angus debug registers every N successful frames")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.dma_buffer_size is not None and not 0 <= args.dma_buffer_size <= 15:
        raise SystemExit("--dma-buffer-size is the 4-bit raw DMA_BUFFER_SIZE register value, valid range 0..15")
    n_words = int(args.samples) * int(args.words_per_sample)
    n_bytes = n_words * 4

    print(f"Loading overlay {args.bitfile!r} download={not args.no_load}")
    overlay = Overlay(args.bitfile, download=not args.no_load)
    print(f"DMA-like overlay attrs: {[name for name in dir(overlay) if 'dma' in name.lower()]}")

    ip = getattr(overlay, args.ip_name)
    regs = AngusRegs(ip)
    if args.configure:
        startup_conf = dict(STARTUP_CONF)
        if args.dma_buffer_size is not None:
            startup_conf["dma_buffer_size"] = int(args.dma_buffer_size)
        print(f"startup_conf: {startup_conf}")
        a = Angus(ip)
        a.startup_conf(**startup_conf)
        print(f"runtime_conf: {RUNTIME_CONF}")
        a.runtime_conf(**RUNTIME_CONF)

    if args.avg_n is not None:
        avg_n_max = named_reg_max("AVG_N")
        avg_n = max(0, min(avg_n_max, int(args.avg_n)))
        if avg_n != int(args.avg_n):
            print(f"Clamped AVG_N from {args.avg_n} to {avg_n} using angus_regs.py field width")
        print(f"Writing AVG_N = {avg_n}")
        regs.write("AVG_N", avg_n)
        print(f"AVG_N readback: {regs.read('AVG_N')}")

    if args.configure or args.avg_n is not None:
        print(f"Settling for {args.settle:.3f}s")
        time.sleep(args.settle)
        print(f"debug regs after setup: {read_debug_regs(regs)}")

    dma = DirectS2MMDma(getattr(overlay, args.dma_name))
    buf = allocate(shape=(n_words,), dtype="u4")
    frame = 0
    t0 = time.time()
    expected_bytes = n_bytes
    print(f"Counting frames on {args.dma_name}, expected={args.samples} samples.")
    print("Press Ctrl-C to stop.")

    def reset_callbacks_for_frame(frame_number: int):
        callbacks = []
        if args.raw_stream_reset_each or (args.raw_stream_reset and frame_number == 1):
            callbacks.append(make_stream_reset_callbacks(regs, "RAW_STREAM_RESET"))
        if args.avg_reset_each or (args.avg_reset and frame_number == 1):
            callbacks.append(make_stream_reset_callbacks(regs, "AVG_RESET", args.avg_reset_addr))

        callbacks = [item for item in callbacks if item[1] is not None]
        if not callbacks:
            return None, None

        labels = ", ".join(label for label, _ in callbacks)
        print(f"Asserting {labels} before arming DMA; releasing after arm")

        def before_arm() -> None:
            for _, pair in callbacks:
                pair[0]()

        def after_arm() -> None:
            for _, pair in reversed(callbacks):
                pair[1]()

        return before_arm, after_arm

    try:
        while True:
            frame += 1
            before_arm, after_arm = reset_callbacks_for_frame(frame)
            try:
                result = dma.receive_frame(
                    buf,
                    n_bytes,
                    args.timeout,
                    before_arm=before_arm,
                    after_arm=after_arm,
                )
            except Exception:
                print(f"debug regs on failure: {read_debug_regs(regs)}")
                raise
            words = expected_bytes // 4
            samples = expected_bytes // (4 * int(args.words_per_sample))
            rate = frame / max(time.time() - t0, 1e-9)
            print(
                f"{frame:8d} bytes={expected_bytes:8d} words={words:7d} "
                f"samples={samples:7d} "
                f"elapsed={result['elapsed'] * 1000:8.3f} ms rate={rate:7.2f}/s"
            )
            if args.regs_every > 0 and frame % args.regs_every == 0:
                print(f"debug regs frame {frame}: {read_debug_regs(regs)}")
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        if hasattr(buf, "freebuffer"):
            buf.freebuffer()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
