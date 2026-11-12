"""
FastAPI service for the Angus PYNQ/Zynq AXI interface.

Environment variables:
    ANGUS_BITFILE        Path to the .bit file loaded by PYNQ Overlay.
    ANGUS_IP_NAME        Name of the AXI-Lite IP block in the overlay.
    ANGUS_DMA_NAME       Name of the raw AXI DMA block in the overlay.
    ANGUS_AVG_DMA_NAME   Name of the PL plot AXI DMA block in the overlay.
    ANGUS_DMA_BACKEND    "pynq" or "direct" (default: pynq).
    ANGUS_RAW_DMA_SAMPLES
                         Raw samples per DMA websocket transfer (default: 7200).
    ANGUS_AVG_DMA_SAMPLES
                         Avg/bypass samples per DMA websocket transfer (default: 7200).
    ANGUS_DMA_TIMEOUT    Seconds to wait for one DMA block (default: 2.0).
    ANGUS_SIM            Set to 1/true to run without PYNQ hardware.

Run on the PYNQ board with:
    uvicorn server:app --host 0.0.0.0 --port 8000
"""

import asyncio
import argparse
import io
import os
import sys
import threading
import time
from array import array
from contextlib import asynccontextmanager
from contextlib import redirect_stdout
from typing import Any, Dict, List, Literal, Optional

import numpy as np
from fastapi import FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from angus import Angus
from angus_regs import ALL_REGS, DMA_WORDS_PER_SAMPLE, READ_REGS, WRITE_REGS

TDC_LSB_DEG = 0.1
N_TDC_STEPS = 7200
SERVER_BUILD = "2026-06-18 00:00:00 avg-diag-regs packet-v2"

try:
    from pynq import Overlay, allocate
except ImportError:  # Allows API development/testing away from the PYNQ board.
    Overlay = None
    allocate = None

def _truthy(value: Optional[str]) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


VERBOSE = _truthy(os.getenv("ANGUS_VERBOSE")) or "-v" in sys.argv or "--verbose" in sys.argv


def _log(message: str) -> None:
    if VERBOSE:
        ts = time.strftime("%H:%M:%S")
        print(f"[angus-api {ts}] {message}", flush=True)


_log("server.py imported")


class StartupConfig(BaseModel):
    crank_n_teeth: Optional[int] = Field(None, ge=1, le=255)
    crank_n_missing: Optional[int] = Field(None, ge=0, le=255)
    cam_n_teeth: Optional[int] = Field(None, ge=0, le=255)
    phase_ref_deg: Optional[float] = Field(None, ge=0.0, lt=720.0)
    phase_tol_deg: Optional[float] = Field(None, ge=0.0, le=180.0)
    dma_buffer_size: Optional[int] = Field(None, ge=0, le=15)
    src: Optional[Literal["crank", "encoder"]] = None
    ref: Optional[Literal["cam", "peak"]] = None
    ang_sel: Optional[Literal["tooth", "pll"]] = None
    angle_interp: Optional[bool] = None
    crank_edge: Optional[Literal["rising", "falling"]] = None
    cam_edge: Optional[Literal["rising", "falling"]] = None
    enc_n_ppr: Optional[int] = Field(None, ge=0, le=65535)
    enc_ab_edge_sel: Optional[int] = Field(None, ge=0, le=2)
    enc_z_edge_sel: Optional[int] = Field(None, ge=0, le=1)

    def changed(self) -> Dict[str, Any]:
        return _changed(self)


class RuntimeConfig(BaseModel):
    tdc_offset_deg: Optional[float] = Field(None, ge=0.0, le=360.0)
    trig_decimation: Optional[int] = Field(None, ge=1, le=65535)
    max_rpm: Optional[int] = Field(None, ge=0, le=65535)
    peak_hyst: Optional[int] = Field(None, ge=0, le=65535)
    pll_kp: Optional[int] = Field(None, ge=0, le=65535)
    pll_ki: Optional[int] = Field(None, ge=0, le=65535)
    pll_corr_max: Optional[int] = Field(None, ge=0, le=65535)
    pll_corr_dir: Optional[Literal["add", "subtract"]] = None
    crank_dbc: Optional[int] = Field(None, ge=0, le=65535)
    cam_dbc: Optional[int] = Field(None, ge=0, le=65535)
    enc_a_dbc: Optional[int] = Field(None, ge=0, le=65535)
    enc_b_dbc: Optional[int] = Field(None, ge=0, le=65535)
    enc_z_dbc: Optional[int] = Field(None, ge=0, le=65535)

    def changed(self) -> Dict[str, Any]:
        return _changed(self)


class RawRegisterWrite(BaseModel):
    addr: int = Field(..., ge=0)
    value: int = Field(..., ge=0, le=0xFFFF_FFFF)


class NamedRegisterWrite(BaseModel):
    value: int = Field(..., ge=0)


class PlotConfig(BaseModel):
    n: Optional[int] = Field(None, ge=0, le=255)


class SimIp:
    def __init__(self):
        self._regs: Dict[int, int] = {}

    def read(self, addr: int) -> int:
        return self._regs.get(addr, 0)

    def write(self, addr: int, value: int) -> None:
        self._regs[addr] = int(value) & 0xFFFF_FFFF


class SimDmaChannel:
    def __init__(self):
        self.running = True

    def start(self) -> None:
        self.running = True

    def stop(self) -> None:
        self.running = False

    def transfer(self, buf: Any) -> None:
        if not self.running:
            raise RuntimeError("DMA channel not started")
        now = int((time.time() * 10) % 7200)
        for i in range(0, len(buf), DMA_WORDS_PER_SAMPLE):
            sample = i // DMA_WORDS_PER_SAMPLE
            tdc = (now + sample) % 7200
            di = sample & 0xFF
            pressure = 2048 + (sample % 256)
            buf[i + 0] = tdc
            buf[i + 1] = ((di & 0xFF) << 24) | ((pressure & 0x0FFF) << 4)

    def wait(self) -> None:
        time.sleep(0.01)


class SimDma:
    def __init__(self):
        self.recvchannel = SimDmaChannel()


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
            "ioc_irq": bool(sr & self.SR_IOC_IRQ),
        }

    def reset(self, timeout: float = 1.0) -> Dict[str, Any]:
        before = self.status()
        self.mmio.write(self.S2MM_DMACR, self.CR_RESET)
        t0 = time.time()
        while time.time() - t0 < timeout:
            if (self.mmio.read(self.S2MM_DMACR) & self.CR_RESET) == 0:
                break
            time.sleep(0.001)
        reset_cleared = (self.mmio.read(self.S2MM_DMACR) & self.CR_RESET) == 0
        after = self.status()
        after["reset_cleared"] = reset_cleared
        return {"before": before, "after": after}

    def start(self) -> None:
        self.mmio.write(self.S2MM_DMASR, self.SR_IRQ_MASK)
        self.mmio.write(self.S2MM_DMACR, self.CR_RUNSTOP)

    def transfer(self, buf: Any, n_bytes: int, timeout: float) -> Dict[str, Any]:
        if n_bytes <= 0:
            raise ValueError("DMA transfer length must be greater than zero")
        if not hasattr(buf, "device_address") and not hasattr(buf, "physical_address"):
            raise RuntimeError("DMA buffer does not expose a physical/device address")

        if self.status()["error"]:
            self.reset()
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
                self.reset()
                raise RuntimeError(f"AXI DMA S2MM error: {state}")
            if sr & self.SR_IOC_IRQ:
                self.mmio.write(self.S2MM_DMASR, self.SR_IRQ_MASK)
                if hasattr(buf, "invalidate"):
                    buf.invalidate()
                return {"status": self.status(), "elapsed": time.time() - t0}
            if time.time() - t0 > timeout:
                state = self.status()
                self.reset()
                raise TimeoutError(f"AXI DMA S2MM timeout after {timeout:.3f}s: {state}")
            time.sleep(0.0005)


class AngusService:
    def __init__(self):
        self.overlay = None
        self.angus: Optional[Angus] = None
        self.dma = None
        self.plot_dma = None
        self.dma_name = None
        self.plot_dma_name = None
        self.direct_dma: Optional[DirectS2MMDma] = None
        self.plot_direct_dma: Optional[DirectS2MMDma] = None
        self.lock = asyncio.Lock()
        self.sim = _truthy(os.getenv("ANGUS_SIM"))
        self.dma_backend = os.getenv("ANGUS_DMA_BACKEND", "pynq").strip().lower()
        self.last_startup: Optional[Dict[str, Any]] = None
        self.last_runtime: Optional[Dict[str, Any]] = None
        self.dma_generation = 0
        self.dma_pause_until = 0.0
        self.pl_n = int(os.getenv("ANGUS_PL_AVG_N", "7"))

    def start(self) -> None:
        bitfile = os.getenv("ANGUS_BITFILE")
        ip_name = os.getenv("ANGUS_IP_NAME", "top_0")
        dma_name = os.getenv("ANGUS_DMA_NAME", "axi_dma_0")
        plot_dma_name = os.getenv("ANGUS_AVG_DMA_NAME", "axi_dma_1")
        self.dma_name = dma_name
        self.plot_dma_name = plot_dma_name
        _log(
            "service.start() "
            f"sim={self.sim} bitfile={bitfile!r} ip_name={ip_name!r} "
            f"dma_name={dma_name!r} plot_dma_name={plot_dma_name!r} "
            f"dma_backend={self.dma_backend!r}"
        )

        if self.sim:
            _log("creating simulated Angus/DMA objects")
            self.angus = Angus(SimIp())
            self.dma = SimDma()
            self.plot_dma = SimDma()
            self.dma_backend = "pynq"
            _log("simulation initialised")
            return

        if Overlay is None or allocate is None:
            _log("pynq import missing; cannot initialise hardware")
            raise RuntimeError("pynq is not installed. Run on the PYNQ board or set ANGUS_SIM=1.")
        if not bitfile:
            _log("ANGUS_BITFILE is not set")
            raise RuntimeError("ANGUS_BITFILE must point to your overlay .bit file.")

        _log(f"loading Overlay({bitfile!r})")
        self.overlay = Overlay(bitfile)
        _log(f"overlay loaded; is_loaded={getattr(self.overlay, 'is_loaded', None)}")
        _log(f"available overlay attrs include top_0={hasattr(self.overlay, 'top_0')}")
        _log(f"binding Angus to overlay.{ip_name}")
        self.angus = Angus(getattr(self.overlay, ip_name))
        _log(f"binding DMA to overlay.{dma_name}")
        self.dma = getattr(self.overlay, dma_name)
        if plot_dma_name:
            try:
                _log(f"binding PL plot DMA to overlay.{plot_dma_name}")
                self.plot_dma = getattr(self.overlay, plot_dma_name)
            except AttributeError:
                self.plot_dma = None
                _log(f"PL plot DMA overlay attribute {plot_dma_name!r} not found")
        if self.dma_backend == "direct":
            _log("creating direct AXI DMA S2MM backend")
            self.direct_dma = DirectS2MMDma(self.dma)
            if self.plot_dma is not None:
                _log("creating direct AXI DMA S2MM backend for PL plot stream")
                self.plot_direct_dma = DirectS2MMDma(self.plot_dma)
        elif self.dma_backend != "pynq":
            raise RuntimeError("ANGUS_DMA_BACKEND must be 'pynq' or 'direct'")
        _log("hardware initialised")

    def require_angus(self) -> Angus:
        if self.angus is None:
            raise HTTPException(status_code=503, detail="Angus hardware is not initialised")
        return self.angus

    def require_dma(self) -> Any:
        if self.dma is None:
            raise HTTPException(status_code=503, detail="DMA is not initialised")
        return self.dma

    def require_plot_dma(self) -> Any:
        if self.plot_dma is None:
            raise HTTPException(
                status_code=503,
                detail="PL plot DMA is not initialised. Set ANGUS_AVG_DMA_NAME to the second AXI DMA instance.",
            )
        return self.plot_dma


service = AngusService()


def _pause_dma_streams(reason: str) -> None:
    delay = float(os.getenv("ANGUS_DMA_RESTART_DELAY", "2.0"))
    service.dma_generation += 1
    service.dma_pause_until = max(service.dma_pause_until, time.time() + delay)
    _log(
        f"DMA generation bumped to {service.dma_generation}; "
        f"pausing streams for {delay:.2f}s after {reason}"
    )


def _select_dma(kind: str = "raw") -> Any:
    dma = service.require_plot_dma() if kind == "plot" else service.require_dma()
    return dma


def _select_direct_dma(kind: str = "raw") -> Optional[DirectS2MMDma]:
    return service.plot_direct_dma if kind == "plot" else service.direct_dma


def _recv_channel(kind: str = "raw") -> Any:
    dma = _select_dma(kind)
    return getattr(dma, "recvchannel", None)


def _channel_state(channel: Any) -> Dict[str, Any]:
    state: Dict[str, Any] = {}
    for name in ("running", "idle", "error", "transferred"):
        if hasattr(channel, name):
            try:
                value = getattr(channel, name)
                state[name] = value() if callable(value) else value
            except Exception as exc:
                state[name] = f"{type(exc).__name__}: {exc}"
    return state


def _dma_mmio(kind: str = "raw") -> Any:
    dma = _select_dma(kind)
    return getattr(dma, "mmio", None) or getattr(dma, "_mmio", None)


def _dma_status() -> Dict[str, Any]:
    status = {"backend": service.dma_backend}
    if service.direct_dma is not None:
        status["raw_direct"] = service.direct_dma.status()
    if service.plot_direct_dma is not None:
        status["plot_direct"] = service.plot_direct_dma.status()
    channel = _recv_channel("raw")
    if channel is not None:
        status["raw_pynq_recvchannel"] = _channel_state(channel)
    if service.plot_dma is not None:
        plot_channel = _recv_channel("plot")
        if plot_channel is not None:
            status["plot_pynq_recvchannel"] = _channel_state(plot_channel)
    if service.angus is not None:
        status["avg_diagnostics"] = _avg_diagnostics()
    return status


def _reset_dma_recv_mmio(kind: str = "raw", timeout: float = 1.0) -> Dict[str, Any]:
    mmio = _dma_mmio(kind)
    if mmio is None:
        return {"available": False}

    s2mm_dmacr = 0x30
    s2mm_dmasr = 0x34
    reset_bit = 0x4
    runstop_bit = 0x1
    t0 = time.time()
    before = {
        "control": mmio.read(s2mm_dmacr),
        "status": mmio.read(s2mm_dmasr),
    }

    mmio.write(s2mm_dmacr, reset_bit)
    while time.time() - t0 < timeout:
        if (mmio.read(s2mm_dmacr) & reset_bit) == 0:
            break
        time.sleep(0.001)

    reset_cleared = (mmio.read(s2mm_dmacr) & reset_bit) == 0
    mmio.write(s2mm_dmacr, runstop_bit)
    time.sleep(0.001)
    after = {
        "control": mmio.read(s2mm_dmacr),
        "status": mmio.read(s2mm_dmasr),
        "reset_cleared": reset_cleared,
    }
    return {"available": True, "before": before, "after": after}


def _ensure_dma_recv_started(reason: str, kind: str = "raw") -> Dict[str, Any]:
    channel = _recv_channel(kind)
    if channel is None:
        return {"available": False}

    before = _channel_state(channel)
    running = before.get("running")
    error = before.get("error")
    if running is False or error is True:
        raise RuntimeError(f"DMA recv channel is not ready before {reason}: {before}")
    after = _channel_state(channel)
    return {"available": True, "before": before, "after": after}


def _recover_dma_recv_channel(reason: str, kind: str = "raw") -> Dict[str, Any]:
    direct_dma = _select_direct_dma(kind)
    if direct_dma is not None:
        _log(f"recovering {kind} direct DMA backend after {reason}")
        direct_dma.reset()
        direct_dma.start()
        return {"backend": "direct", "kind": kind, "status": direct_dma.status()}

    channel = _recv_channel(kind)
    if channel is None:
        return {"available": False}

    before = _channel_state(channel)
    _log(f"recovering {kind} DMA recv channel after {reason}; before={before}")
    mmio_recovery = _reset_dma_recv_mmio(kind)
    if not mmio_recovery.get("available"):
        if hasattr(channel, "stop"):
            try:
                channel.stop()
            except Exception as exc:
                _log(f"DMA recv channel stop failed during recovery: {type(exc).__name__}: {exc}")
        if hasattr(channel, "start"):
            try:
                channel.start()
            except Exception as exc:
                _log(f"DMA recv channel start failed during recovery: {type(exc).__name__}: {exc}")
    after = _channel_state(channel)
    _log(f"{kind} DMA recv channel recovery complete; mmio={mmio_recovery} after={after}")
    return {"available": True, "kind": kind, "before": before, "after": after, "mmio": mmio_recovery}


def _pydantic_dump(model: BaseModel, **kwargs: Any) -> Dict[str, Any]:
    if hasattr(model, "model_dump"):
        return model.model_dump(**kwargs)
    return model.dict(**kwargs)


def _changed(model: BaseModel) -> Dict[str, Any]:
    return _pydantic_dump(model, exclude_none=True)


def _startup_changes(config: StartupConfig) -> Dict[str, Any]:
    changes = _changed(config)
    if changes.get("src") != "encoder":
        for name in ("enc_n_ppr", "enc_ab_edge_sel", "enc_z_edge_sel"):
            if changes.get(name) == 0:
                changes.pop(name, None)
    return changes


def _status(a: Angus) -> Dict[str, Any]:
    return {
        "rpm": a.rpm,
        "rpm_fast": a.rpm_fast,
        "tdc_deg": a.tdc_deg,
        "crank_deg": a.crank_deg,
        "sync_state": a.sync_state,
        "is_synced": a.is_synced,
        "phase_found": a.phase_found,
        "phase_ok": a.phase_ok,
        "engine_phase": a.engine_phase,
        "faults": a.faults,
        "packet_count": a.packet_count,
        "overflow_count": a.overflow_count,
    }


def _reg_metadata(name: str) -> Dict[str, Any]:
    addr, msb, lsb, desc = ALL_REGS[name]
    return {
        "name": name,
        "addr": addr,
        "msb": msb,
        "lsb": lsb,
        "description": desc,
        "readable": name in READ_REGS,
        "writable": name in WRITE_REGS,
    }


NOTEBOOK_STARTUP_CONF: Dict[str, Any] = {
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


NOTEBOOK_RUNTIME_CONF: Dict[str, Any] = {
    "max_rpm": 6000,
    "trig_decimation": 1,
    "tdc_offset_deg": 0.0,
}


def _raw_debug_registers(a: Angus) -> Dict[str, int]:
    return {
        "CONTROL_0x000": a.regs.read_raw(0x000),
        "CONTROL_RT_0x004": a.regs.read_raw(0x004),
        "CRANK_N_TEETH_0x028": a.regs.read_raw(0x028),
        "CRANK_N_MISSING_0x02C": a.regs.read_raw(0x02C),
        "CAM_N_TEETH_0x030": a.regs.read_raw(0x030),
        "PHASE_REF_MIN_0x038": a.regs.read_raw(0x038),
        "PHASE_REF_MAX_0x03C": a.regs.read_raw(0x03C),
        "TRIG_DECIMATION_0x04C": a.regs.read_raw(0x04C),
        "TDC_OFFSET_0x058": a.regs.read_raw(0x058),
        "DMA_BUFFER_SIZE_0x05C": a.regs.read_raw(0x05C),
        "SYNC_STATE_0x0B4": a.regs.read_raw(0x0B4),
        "PKT_COUNT_0x104": a.regs.read_raw(0x104),
        "OVF_COUNT_0x108": a.regs.read_raw(0x108),
        "AVG_N_0x10C": a.regs.read_raw(0x10C),
        "AVG_FRAME_COUNT_0x110": a.regs.read_raw(0x110),
        "AVG_IN_BEAT_COUNT_0x114": a.regs.read_raw(0x114),
        "AVG_OUT_BEAT_COUNT_0x118": a.regs.read_raw(0x118),
        "AVG_OUT_TLAST_COUNT_0x11C": a.regs.read_raw(0x11C),
        "AVG_OUT_STALL_COUNT_0x120": a.regs.read_raw(0x120),
        "AVG_BAD_TLAST_COUNT_0x124": a.regs.read_raw(0x124),
    }


def _make_dma_buffer(n_words: int) -> Any:
    if service.sim:
        return [0] * n_words
    return allocate(shape=(n_words,), dtype="u4")


def _dma_receive_block(buf: Any, n_words: int, kind: str = "raw") -> Dict[str, Any]:
    direct_dma = _select_direct_dma(kind)
    if direct_dma is not None:
        timeout = float(os.getenv("ANGUS_DMA_TIMEOUT", "2.0"))
        return direct_dma.transfer(buf, n_words * 4, timeout)

    dma = _select_dma(kind)
    _ensure_dma_recv_started(f"{kind} websocket transfer", kind)
    dma.recvchannel.transfer(buf)
    dma.recvchannel.wait()
    if hasattr(buf, "invalidate"):
        buf.invalidate()
    return {"backend": "pynq", "kind": kind, "state": _channel_state(dma.recvchannel)}


def _buffer_to_bytes(buf: Any) -> bytes:
    if hasattr(buf, "tobytes"):
        return buf.tobytes()
    return array("I", (int(v) & 0xFFFF_FFFF for v in buf)).tobytes()


def _buffer_to_words(buf: Any) -> List[int]:
    return [int(v) & 0xFFFF_FFFF for v in buf]


def _buffer_words_view(buf: Any) -> np.ndarray:
    return np.asarray(buf, dtype=np.uint32)


def _bytes_words_view(data: bytes) -> np.ndarray:
    return np.frombuffer(data, dtype="<u4")


def _fixed_offset_frames(buf: Any) -> np.ndarray:
    return _fixed_offset_frames_from_words(_buffer_words_view(buf))


def _fixed_offset_frames_from_words(words: np.ndarray) -> np.ndarray:
    complete = (words.size // DMA_WORDS_PER_SAMPLE) * DMA_WORDS_PER_SAMPLE
    if complete == 0:
        return np.empty((0, DMA_WORDS_PER_SAMPLE), dtype=np.uint32)
    return words[:complete].reshape((-1, DMA_WORDS_PER_SAMPLE))


def _buffer_frame_stats(buf: Any) -> Dict[str, Any]:
    return _frames_frame_stats(_fixed_offset_frames(buf))


def _frames_frame_stats(frames: np.ndarray) -> Dict[str, Any]:
    if frames.size == 0:
        return {"valid": 0, "samples": 0, "unique_tdc": 0, "tdc_min": None, "tdc_max": None}

    tdc_counts = frames[:, 0].astype(np.int64, copy=False)
    valid = (tdc_counts >= 0) & (tdc_counts < N_TDC_STEPS)
    if not np.any(valid):
        return {
            "valid": 0,
            "samples": int(frames.shape[0]),
            "unique_tdc": 0,
            "coverage": 0.0,
            "tdc_min": None,
            "tdc_max": None,
            "first_tdc": int(frames[0, 0]),
            "last_tdc": int(frames[-1, 0]),
        }

    idx = tdc_counts[valid].astype(np.int32, copy=False)
    unique_tdc = int(np.unique(idx).size)
    return {
        "valid": int(np.count_nonzero(valid)),
        "samples": int(frames.shape[0]),
        "unique_tdc": unique_tdc,
        "coverage": float(unique_tdc / N_TDC_STEPS),
        "tdc_min": int(idx.min()),
        "tdc_max": int(idx.max()),
        "first_tdc": int(frames[0, 0]),
        "last_tdc": int(frames[-1, 0]),
    }


def _plot_config() -> Dict[str, Any]:
    n_value = service.pl_n
    frame_count = None
    diagnostics: Optional[Dict[str, int]] = None
    if service.angus is not None:
        try:
            n_value = int(service.angus.regs.read("AVG_N"))
            frame_count = int(service.angus.regs.read("AVG_FRAME_COUNT"))
            diagnostics = _avg_diagnostics()
        except Exception as exc:
            _log(f"plot config register read failed: {type(exc).__name__}: {exc}")
    return {
        "n": n_value,
        "frame_count": frame_count,
        "diagnostics": diagnostics,
    }


def _avg_diagnostics() -> Dict[str, int]:
    a = service.require_angus()
    return {
        "avg_n": int(a.regs.read("AVG_N")),
        "avg_frame_count": int(a.regs.read("AVG_FRAME_COUNT")),
        "avg_in_beat_count": int(a.regs.read("AVG_IN_BEAT_COUNT")),
        "avg_out_beat_count": int(a.regs.read("AVG_OUT_BEAT_COUNT")),
        "avg_out_tlast_count": int(a.regs.read("AVG_OUT_TLAST_COUNT")),
        "avg_out_stall_count": int(a.regs.read("AVG_OUT_STALL_COUNT")),
        "avg_bad_tlast_count": int(a.regs.read("AVG_BAD_TLAST_COUNT")),
    }


def _set_pl_n(value: int) -> int:
    n_value = max(0, min(255, int(value)))
    service.pl_n = n_value
    if service.angus is not None:
        service.angus.regs.write("AVG_N", n_value)
        n_value = int(service.angus.regs.read("AVG_N"))
        service.pl_n = n_value
    return n_value


def _sample_to_dict(sample: Any) -> Dict[str, Any]:
    return {
        "tdc_deg": sample.tdc_deg,
        "di": sample.di,
        "pressure": sample.pressure,
    }


@asynccontextmanager
async def lifespan(_: FastAPI):
    _log("lifespan startup entered")
    service.start()
    _log("lifespan startup complete")
    yield
    _log("lifespan shutdown")


app = FastAPI(
    title="Angus PYNQ API",
    description="REST and websocket API for Angus AXI-Lite registers and AXI DMA samples.",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS middleware to allow serving frontend from dev machine 
from fastapi.middleware.cors import CORSMiddleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    body = await request.body()
    errors = jsonable_encoder(exc.errors())
    _log(
        "validation error "
        f"path={request.url.path} errors={errors} body={body.decode(errors='replace')}"
    )
    return JSONResponse(status_code=422, content={"detail": errors})


@app.get("/health")
def health() -> Dict[str, Any]:
    _log("GET /health")
    return {
        "ok": service.angus is not None,
        "sim": service.sim,
        "dma_backend": service.dma_backend,
        "raw_dma_name": service.dma_name,
        "avg_dma_name": service.plot_dma_name,
        "plot_dma_available": service.plot_dma is not None,
        "build": SERVER_BUILD,
        "dma_words_per_sample": DMA_WORDS_PER_SAMPLE,
        "tdc_steps": N_TDC_STEPS,
        "raw_dma_samples_default": int(os.getenv("ANGUS_RAW_DMA_SAMPLES", os.getenv("ANGUS_DMA_SAMPLES", "7200"))),
        "avg_dma_samples_default": int(os.getenv("ANGUS_AVG_DMA_SAMPLES", "7200")),
    }


@app.get("/status")
def status() -> Dict[str, Any]:
    _log("GET /status")
    return _status(service.require_angus())


@app.get("/debug/config-status")
def config_status() -> Dict[str, Any]:
    _log("GET /debug/config-status")
    a = service.require_angus()
    out = io.StringIO()
    with redirect_stdout(out):
        a.config_status()
    return {
        "startup": dict(a._startup),
        "runtime": dict(a._runtime),
        "text": out.getvalue(),
    }


@app.get("/debug/last-startup")
def last_startup() -> Dict[str, Any]:
    _log("GET /debug/last-startup")
    return {
        "last_startup": service.last_startup,
        "last_runtime": service.last_runtime,
    }


@app.post("/config/startup")
async def startup_config(config: StartupConfig) -> Dict[str, Any]:
    changes = _startup_changes(config)
    _log(f"POST /config/startup received {changes}")
    async with service.lock:
        a = service.require_angus()
        _pause_dma_streams("startup config")
        before = _raw_debug_registers(a)
        _log(f"startup before raw regs {before}")
        _log("calling a.startup_conf(**changes)")
        a.startup_conf(**changes)
        _log("a.startup_conf returned")
        after = _raw_debug_registers(a)
        _log(f"startup after raw regs {after}")
        service.last_startup = {
            "received": changes,
            "before": before,
            "after": after,
            "time": time.time(),
        }
        return {"applied": changes, "debug": service.last_startup, "status": _status(a)}


@app.post("/config/notebook")
async def notebook_config() -> Dict[str, Any]:
    _log("POST /config/notebook received")
    async with service.lock:
        a = service.require_angus()
        _pause_dma_streams("notebook config")
        before = _raw_debug_registers(a)
        _log(f"notebook before raw regs {before}")
        _log(f"calling a.startup_conf(**{NOTEBOOK_STARTUP_CONF})")
        a.startup_conf(**NOTEBOOK_STARTUP_CONF)
        _log("a.startup_conf returned")
        after_startup = _raw_debug_registers(a)
        _log(f"notebook after startup raw regs {after_startup}")
        _log(f"calling a.runtime_conf(**{NOTEBOOK_RUNTIME_CONF})")
        a.runtime_conf(**NOTEBOOK_RUNTIME_CONF)
        _log("a.runtime_conf returned")
        after_runtime = _raw_debug_registers(a)
        _log(f"notebook after runtime raw regs {after_runtime}")
        service.last_startup = {
            "received": dict(NOTEBOOK_STARTUP_CONF),
            "before": before,
            "after": after_startup,
            "time": time.time(),
            "preset": "notebook",
        }
        service.last_runtime = {
            "received": dict(NOTEBOOK_RUNTIME_CONF),
            "before": after_startup,
            "after": after_runtime,
            "time": time.time(),
            "preset": "notebook",
        }
        return {
            "startup": service.last_startup,
            "runtime": service.last_runtime,
            "status": _status(a),
        }


@app.get("/config/startup")
def get_startup_config() -> Dict[str, Any]:
    _log("GET /config/startup")
    return dict(service.require_angus()._startup)


@app.post("/config/runtime")
async def runtime_config(config: RuntimeConfig) -> Dict[str, Any]:
    changes = _changed(config)
    _log(f"POST /config/runtime received {changes}")
    async with service.lock:
        a = service.require_angus()
        before = _raw_debug_registers(a)
        _log(f"runtime before raw regs {before}")
        _log("calling a.runtime_conf(**changes)")
        a.runtime_conf(**changes)
        _log("a.runtime_conf returned")
        after = _raw_debug_registers(a)
        _log(f"runtime after raw regs {after}")
        service.last_runtime = {
            "received": changes,
            "before": before,
            "after": after,
            "time": time.time(),
        }
        return {"applied": changes, "debug": service.last_runtime, "status": _status(a)}


@app.get("/config/runtime")
def get_runtime_config() -> Dict[str, Any]:
    _log("GET /config/runtime")
    return dict(service.require_angus()._runtime)


@app.post("/faults/clear")
async def clear_faults() -> Dict[str, Any]:
    _log("POST /faults/clear")
    async with service.lock:
        a = service.require_angus()
        a.clear_faults()
        return {"ok": True, "faults": a.faults}


@app.post("/dma/recover")
async def recover_dma() -> Dict[str, Any]:
    _log("POST /dma/recover")
    async with service.lock:
        _pause_dma_streams("manual DMA recovery")
        raw_recovery = await asyncio.to_thread(_recover_dma_recv_channel, "manual recovery", "raw")
        plot_recovery = None
        if service.plot_dma is not None:
            plot_recovery = await asyncio.to_thread(_recover_dma_recv_channel, "manual recovery", "plot")
        recovery = {"raw": raw_recovery, "plot": plot_recovery}
        return {"ok": True, "recovery": recovery}


@app.get("/plot/config")
def get_plot_config() -> Dict[str, Any]:
    _log("GET /plot/config")
    return _plot_config()


@app.post("/plot/config")
async def set_plot_config(config: PlotConfig) -> Dict[str, Any]:
    changes = _changed(config)
    _log(f"POST /plot/config received {changes}")
    if "n" in changes:
        async with service.lock:
            n_value = _set_pl_n(int(changes["n"]))
            _log(f"wrote AVG_N=0x{n_value:02X}")
    return _plot_config()


@app.get("/dma/status")
def dma_status() -> Dict[str, Any]:
    _log("GET /dma/status")
    return _dma_status()


@app.post("/sync/wait")
async def wait_for_sync(
    level: Literal["moving", "crank", "full"] = "full",
    timeout: float = Query(10.0, ge=0.0),
) -> Dict[str, Any]:
    _log(f"POST /sync/wait level={level!r} timeout={timeout}")
    async with service.lock:
        a = service.require_angus()
        reached = await asyncio.to_thread(a.wait_for_sync, level, timeout)
        return {"reached": reached, "sync_state": a.sync_state}


@app.get("/registers")
def list_registers() -> Dict[str, List[Dict[str, Any]]]:
    _log("GET /registers")
    return {
        "read": [_reg_metadata(name) for name in READ_REGS],
        "write": [_reg_metadata(name) for name in WRITE_REGS],
    }


@app.get("/registers/{name}")
def read_register(name: str) -> Dict[str, Any]:
    _log(f"GET /registers/{name}")
    reg_name = name.upper()
    if reg_name not in ALL_REGS:
        raise HTTPException(status_code=404, detail=f"Unknown register: {name}")
    a = service.require_angus()
    return {**_reg_metadata(reg_name), "value": a.regs.read(reg_name)}


@app.put("/registers/{name}")
async def write_register(name: str, body: NamedRegisterWrite) -> Dict[str, Any]:
    _log(f"PUT /registers/{name} value={body.value}")
    reg_name = name.upper()
    if reg_name not in WRITE_REGS:
        raise HTTPException(status_code=400, detail=f"Register is not writable: {name}")
    async with service.lock:
        a = service.require_angus()
        a.regs.write(reg_name, body.value)
        return {**_reg_metadata(reg_name), "value": a.regs.read(reg_name)}


@app.get("/registers/raw/{addr}")
def read_raw_register(addr: str) -> Dict[str, Any]:
    _log(f"GET /registers/raw/{addr}")
    parsed = int(addr, 0)
    return {"addr": parsed, "value": service.require_angus().regs.read_raw(parsed)}


@app.put("/registers/raw")
async def write_raw_register(body: RawRegisterWrite) -> Dict[str, Any]:
    _log(f"PUT /registers/raw addr=0x{body.addr:03X} value=0x{body.value:08X}")
    async with service.lock:
        a = service.require_angus()
        a.regs.write_raw(body.addr, body.value)
        return {"addr": body.addr, "value": a.regs.read_raw(body.addr)}


@app.websocket("/ws/dma")
async def dma_stream(
    websocket: WebSocket,
    samples: Optional[int] = Query(None, ge=1, le=65536),
    decoded: bool = Query(True),
    binary: bool = Query(False),
    stream: Literal["raw", "avg"] = Query("raw"),
    n: int = Query(7, ge=0, le=255),
    once: bool = Query(False),
) -> None:
    _log(
        "WS /ws/dma connect "
        f"samples={samples} decoded={decoded} binary={binary} "
        f"stream={stream} n={n} once={once}"
    )
    await websocket.accept()
    if binary and decoded:
        _log("WS /ws/dma closing: binary mode requires decoded=false")
        await websocket.close(code=1003, reason="binary mode requires decoded=false")
        return
    pause_remaining = service.dma_pause_until - time.time()
    if pause_remaining > 0:
        _log(f"WS /ws/dma closing: DMA reconfiguring for another {pause_remaining:.2f}s")
        await websocket.close(code=1013, reason="DMA reconfiguring")
        return
    if samples is None:
        if stream == "avg":
            samples = int(os.getenv("ANGUS_AVG_DMA_SAMPLES", "7200"))
        else:
            samples = int(os.getenv("ANGUS_RAW_DMA_SAMPLES", os.getenv("ANGUS_DMA_SAMPLES", "7200")))
    stream_generation = service.dma_generation
    n_words = samples * DMA_WORDS_PER_SAMPLE
    buf = _make_dma_buffer(n_words)
    dma_kind = "plot" if stream == "avg" else "raw"
    if stream == "avg":
        service.require_plot_dma()
        actual_n = _set_pl_n(int(n))
        _log(f"WS /ws/dma allocated PL plot DMA buffer words={n_words} AVG_N=0x{actual_n:02X}")
    else:
        _log(f"WS /ws/dma allocated buffer words={n_words}")
    blocks = 0
    last_log = time.time()

    try:
        while True:
            pause_remaining = service.dma_pause_until - time.time()
            if pause_remaining > 0:
                _log(f"WS /ws/dma closing because DMA is paused for {pause_remaining:.2f}s")
                await websocket.close(code=1013, reason="DMA reconfiguring")
                break
            if stream_generation != service.dma_generation:
                _log("WS /ws/dma closing because DMA generation changed before transfer")
                await websocket.close(code=1012, reason="DMA reconfigured")
                break
            try:
                await asyncio.to_thread(_dma_receive_block, buf, n_words, dma_kind)
            except Exception as exc:
                _log(f"WS /ws/dma {dma_kind} DMA interrupted: {type(exc).__name__}: {exc}")
                _pause_dma_streams("DMA exception")
                try:
                    await websocket.close(code=1012, reason="DMA interrupted by config")
                except RuntimeError:
                    pass
                break
            if stream_generation != service.dma_generation:
                _log("WS /ws/dma closing because DMA generation changed after transfer")
                await websocket.close(code=1012, reason="DMA reconfigured")
                break
            blocks += 1
            now = time.time()
            if binary:
                if VERBOSE and now - last_log >= 1.0:
                    stats = _buffer_frame_stats(buf)
                    _log(f"WS /ws/dma {dma_kind} block stats last_block={stats}")
                await websocket.send_bytes(_buffer_to_bytes(buf))
            else:
                words = _buffer_to_words(buf)
                if decoded:
                    payload: Dict[str, Any] = {
                        "samples": [_sample_to_dict(s) for s in Angus.decode_buffer(words, samples)],
                        "word_count": len(words),
                    }
                    await websocket.send_json(payload)
                else:
                    payload = {"words": words, "word_count": len(words), "samples": samples}
                    if stream == "avg":
                        payload["n"] = service.pl_n
                        payload["frame_count"] = service.require_angus().regs.read("AVG_FRAME_COUNT")
                    await websocket.send_json(payload)
            if VERBOSE and now - last_log >= 1.0:
                _log(f"WS /ws/dma sent {blocks} {dma_kind} blocks over {now - last_log:.2f}s")
                blocks = 0
                last_log = now
            if once:
                _log("WS /ws/dma once=true complete")
                break
    except WebSocketDisconnect:
        _log("WS /ws/dma disconnected")
        pass
    finally:
        if buf is not None and hasattr(buf, "freebuffer"):
            buf.freebuffer()
        _log("WS /ws/dma buffer released")


def _parse_main_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Angus FastAPI server.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    args = _parse_main_args()
    if args.verbose:
        os.environ["ANGUS_VERBOSE"] = "1"
        VERBOSE = True
    _log(f"running uvicorn directly host={args.host} port={args.port}")
    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port, log_level="debug" if VERBOSE else "info")
