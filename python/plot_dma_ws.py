"""
High-speed PyQt plot for Angus DMA websocket data.

The script posts fixed startup/runtime configuration values, then connects to
the DMA websocket and plots TDC angle against pressure.

Run:
    python plot_dma_ws.py --host 192.168.2.99 --port 8000
"""

import argparse
import json
import sys
import threading
import time
from typing import Dict

import numpy as np
import requests
import websocket
from PyQt5 import QtCore, QtWidgets

pg = None


STARTUP_CONF: Dict[str, object] = {
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

RUNTIME_CONF: Dict[str, object] = {
    "max_rpm": 6000,
    "trig_decimation": 1,
    "tdc_offset_deg": 0.0,
}

DMA_WORDS_PER_SAMPLE = 2
TDC_LSB_DEG = 0.1
N_TDC_STEPS = 7200


class DmaClient(QtCore.QThread):
    samples_received = QtCore.pyqtSignal(object, object, object, float)
    status_changed = QtCore.pyqtSignal(str)

    def __init__(self, host: str, port: int, samples_per_rx: int, use_binary: bool,
                 stream: str, n_value: int):
        super().__init__()
        self.host = host
        self.port = port
        self.samples_per_rx = samples_per_rx
        self.use_binary = use_binary
        self.stream = stream
        self.n_value = max(0, int(n_value))
        self._running = True
        self._ws = None
        self._lock = threading.Lock()

    def stop(self) -> None:
        self._running = False
        if self._ws is not None:
            self._ws.close()

    def run(self) -> None:
        reconnect_delay = 0.75
        while self._running:
            last_report = time.monotonic()
            sample_count = 0

            try:
                ws_url = self._make_ws_url()
                self.status_changed.emit(f"Connecting {ws_url}")
                self._ws = websocket.create_connection(ws_url, timeout=5)
                self._ws.settimeout(None)
                self.status_changed.emit("Streaming")
                reconnect_delay = 0.75

                while self._running:
                    msg = self._ws.recv()
                    if not msg:
                        raise ConnectionError("websocket closed")

                    tdc_deg, pressure, di = self._decode_message(msg)
                    sample_count += len(pressure)
                    now = time.monotonic()
                    if now - last_report >= 1.0:
                        rate = sample_count / (now - last_report)
                        self.status_changed.emit(f"Streaming {rate:,.0f} samples/s")
                        sample_count = 0
                        last_report = now

                    self.samples_received.emit(tdc_deg, pressure, di, now)
            except Exception as exc:
                if self._running:
                    self.status_changed.emit(
                        f"Stream interrupted: {exc}; reconnecting in {reconnect_delay:.1f}s"
                    )
                    time.sleep(reconnect_delay)
                    reconnect_delay = min(reconnect_delay * 1.5, 5.0)
            finally:
                if self._ws is not None:
                    self._ws.close()
                    self._ws = None

    def _decode_message(self, msg):
        if self.use_binary:
            words = np.frombuffer(msg, dtype="<u4")
        else:
            data = json.loads(msg)
            words = np.asarray(data["words"], dtype=np.uint32)

        complete = (words.size // DMA_WORDS_PER_SAMPLE) * DMA_WORDS_PER_SAMPLE
        words = words[:complete].reshape((-1, DMA_WORDS_PER_SAMPLE))
        tdc_deg = words[:, 0].astype(np.float32) * TDC_LSB_DEG
        pressure = ((words[:, 1] >> 4) & 0x0FFF).astype(np.float32)
        di = ((words[:, 1] >> 24) & 0xFF).astype(np.uint8)
        return tdc_deg, pressure, di

    def _make_ws_url(self) -> str:
        with self._lock:
            n_value = self.n_value
        return (
            f"ws://{self.host}:{self.port}/ws/dma"
            f"?samples={self.samples_per_rx}"
            f"&decoded=false"
            f"&binary={str(self.use_binary).lower()}"
            f"&stream={self.stream}"
            f"&n={n_value}"
        )

    def set_n_value(self, value: int) -> None:
        with self._lock:
            self.n_value = max(0, int(value))


class AngusPlot(QtWidgets.QMainWindow):
    plot_config_received = QtCore.pyqtSignal(object)

    def __init__(self, args):
        super().__init__()
        self.setWindowTitle("Angus DMA Pressure")
        self.resize(1100, 650)

        self.n_value = max(0, int(args.n))
        self.plot_interval = 1.0 / max(1.0, float(args.plot_fps))
        self.x_data = np.empty(0, dtype=np.float32)
        self.y_data = np.empty(0, dtype=np.float32)
        self.digital_x = np.empty(0, dtype=np.float32)
        self.digital_di = np.empty(0, dtype=np.uint8)
        self.last_update = 0.0
        self.last_fps_update = 0.0
        self.gui_fps = 0.0
        self.base_url = f"http://{args.host}:{args.port}"
        self.latest_frame_count = None

        self.plot = pg.PlotWidget()
        self.plot.setLabel("bottom", "deg_tdc", units="deg")
        self.plot.setLabel("left", "pressure")
        self.plot.setXRange(-360, 360, padding=0)
        self.plot.setYRange(0, 5000, padding=0)
        self.plot.showGrid(x=True, y=True, alpha=0.25)
        self.scatter = self.plot.plot(
            [],
            [],
            pen=None,
            symbol="o",
            symbolSize=2,
            symbolBrush=pg.mkBrush("#00a6d6"),
            symbolPen=None,
        )
        self.digital_curves = []
        self.digital_labels = []
        self.digital_base_y = 2850.0
        self.digital_lane_y = 220.0
        self.digital_high_y = 120.0
        digital_colors = ["#ffcf33", "#ff8c42", "#ec5f67", "#ab72ff",
                          "#5ccfe6", "#7bd88f", "#f6f7d7", "#c792ea"]
        for bit in range(8):
            curve = self.plot.plot(
                [],
                [],
                pen=pg.mkPen(digital_colors[bit], width=1),
                connect="finite",
            )
            self.digital_curves.append(curve)
            label = pg.TextItem(f"DI{bit}", color=digital_colors[bit], anchor=(1, 0.5))
            self.plot.addItem(label)
            label.setPos(-365, self.digital_base_y + bit * self.digital_lane_y + self.digital_high_y * 0.5)
            self.digital_labels.append(label)
        self.fps_label = pg.TextItem("0.0 FPS", color="#d8d8d8", anchor=(1, 0))
        self.plot.addItem(self.fps_label)
        self.fps_label.setPos(350, 4880)
        self.coverage_label = pg.TextItem("coverage 0.0%", color="#d8d8d8", anchor=(1, 0))
        self.plot.addItem(self.coverage_label)
        self.coverage_label.setPos(350, 4700)
        self.count_label = pg.TextItem("valid 0", color="#d8d8d8", anchor=(1, 0))
        self.plot.addItem(self.count_label)
        self.count_label.setPos(350, 4520)
        self.frame_count_label = pg.TextItem("frames --", color="#d8d8d8", anchor=(1, 0))
        self.plot.addItem(self.frame_count_label)
        self.frame_count_label.setPos(350, 4340)

        self.status = QtWidgets.QLabel("Idle")
        self.status.setContentsMargins(8, 4, 8, 4)
        self.n_spin = QtWidgets.QSpinBox()
        self.n_spin.setRange(0, 255)
        self.n_spin.setValue(self.n_value)
        self.n_spin.setPrefix("N ")
        self.n_spin.setToolTip("PL AVG_N register value")
        self.n_spin.setEnabled(not args.raw_ws)
        self.n_spin.valueChanged.connect(self.on_n_changed)

        central = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.plot, 1)
        status_row = QtWidgets.QHBoxLayout()
        status_row.setContentsMargins(0, 0, 0, 0)
        status_row.addWidget(self.status, 1)
        status_row.addWidget(QtWidgets.QLabel("N"))
        status_row.addWidget(self.n_spin)
        layout.addLayout(status_row)
        self.setCentralWidget(central)

        self.stream = "raw" if args.raw_ws else args.stream
        self.raw_ws = self.stream == "raw"
        samples_per_rx = args.avg_samples if self.stream == "avg" else args.raw_samples
        self.client = DmaClient(
            args.host,
            args.port,
            samples_per_rx,
            args.binary,
            self.stream,
            self.n_value,
        )
        self.client.samples_received.connect(self.on_samples)
        self.client.status_changed.connect(self.on_status)
        self.plot_config_received.connect(self.on_plot_config_received)
        self._post_plot_config(self.n_value)
        self.poll_timer = QtCore.QTimer(self)
        self.poll_timer.setInterval(1000)
        self.poll_timer.timeout.connect(self._poll_plot_config_async)
        self.poll_timer.start()
        self.client.start()

    @QtCore.pyqtSlot(str)
    def on_status(self, message):
        self.status.setText(message)
        if message.startswith("Connecting"):
            self.x_data = np.empty(0, dtype=np.float32)
            self.y_data = np.empty(0, dtype=np.float32)
            self.digital_x = np.empty(0, dtype=np.float32)
            self.digital_di = np.empty(0, dtype=np.uint8)
            self.last_update = 0.0
            self.last_fps_update = 0.0
            self.gui_fps = 0.0
            self.fps_label.setText("0.0 FPS")
            self.coverage_label.setText("coverage 0.0%")
            self.count_label.setText("valid 0")
            self.frame_count_label.setText("frames --")
            self.scatter.setData([], [])
            for curve in self.digital_curves:
                curve.setData([], [])

    @QtCore.pyqtSlot(object, object, object, float)
    def on_samples(self, tdc_deg, pressure, di, timestamp):
        valid = np.isfinite(tdc_deg) & np.isfinite(pressure)
        valid &= (tdc_deg >= 0.0) & (tdc_deg < 720.0)
        valid &= (pressure >= 0.0) & (pressure <= 5000.0)
        if not np.any(valid):
            self.coverage_label.setText("coverage 0.0%")
            self.count_label.setText("valid 0")
            return

        tdc_deg = tdc_deg[valid]
        pressure = pressure[valid]
        di = di[valid]
        idx = np.rint(tdc_deg / TDC_LSB_DEG).astype(np.int32) % N_TDC_STEPS
        coverage = np.unique(idx).size / N_TDC_STEPS
        x = ((tdc_deg + 360.0) % 720.0) - 360.0
        order = np.argsort(x)
        self.x_data = x[order].astype(np.float32, copy=False)
        self.y_data = pressure[order].astype(np.float32, copy=False)
        self.digital_x = self.x_data
        self.digital_di = di[order].astype(np.uint8, copy=False)
        self.coverage_label.setText(f"coverage {coverage * 100:5.1f}%")
        mode = "raw block" if self.raw_ws else f"PL N={self.n_value}"
        self.count_label.setText(f"valid {self.x_data.size:,}  {mode}")
        if self.latest_frame_count is not None:
            self.frame_count_label.setText(f"frames {self.latest_frame_count:,}")
        self._draw_latest(timestamp)

    @QtCore.pyqtSlot(int)
    def on_n_changed(self, value):
        self.n_value = max(0, int(value))
        self.client.set_n_value(self.n_value)
        self.count_label.setText(f"valid 0  PL N={self.n_value}")
        if self.stream == "avg":
            threading.Thread(
                target=self._post_plot_config,
                args=(self.n_value,),
                daemon=True,
            ).start()

    @QtCore.pyqtSlot(object)
    def on_plot_config_received(self, config):
        if "frame_count" in config and config["frame_count"] is not None:
            self.latest_frame_count = int(config["frame_count"])
            self.frame_count_label.setText(f"frames {self.latest_frame_count:,}")
        if "n" in config:
            n_value = max(0, int(config["n"]))
            if n_value != self.n_value and not self.n_spin.hasFocus():
                self.n_value = n_value
                was_blocked = self.n_spin.blockSignals(True)
                self.n_spin.setValue(n_value)
                self.n_spin.blockSignals(was_blocked)

    def _poll_plot_config_async(self):
        threading.Thread(target=self._poll_plot_config, daemon=True).start()

    def _poll_plot_config(self):
        try:
            resp = requests.get(f"{self.base_url}/plot/config", timeout=1)
            if resp.ok:
                self.plot_config_received.emit(resp.json())
        except Exception:
            pass

    def _draw_latest(self, timestamp):
        if self.last_update > 0 and timestamp - self.last_update < self.plot_interval:
            return
        if self.last_fps_update > 0:
            instant_fps = 1.0 / max(timestamp - self.last_fps_update, 1e-6)
            self.gui_fps = instant_fps if self.gui_fps == 0 else (0.85 * self.gui_fps + 0.15 * instant_fps)
        self.last_fps_update = timestamp
        self.fps_label.setText(f"{self.gui_fps:4.1f} FPS")
        self.scatter.setData(self.x_data, self.y_data)
        for bit, curve in enumerate(self.digital_curves):
            if self.digital_x.size == 0:
                curve.setData([], [])
                continue
            state = ((self.digital_di >> bit) & 1).astype(np.float32)
            y = self.digital_base_y + bit * self.digital_lane_y + state * self.digital_high_y
            curve.setData(self.digital_x, y)
        self.last_update = timestamp

    def _post_plot_config(self, n_value):
        try:
            resp = requests.post(
                f"{self.base_url}/plot/config",
                json={"n": int(n_value)},
                timeout=2,
            )
            if not resp.ok:
                print(f"Plot config failed: HTTP {resp.status_code}: {resp.text}", flush=True)
        except Exception as exc:
            print(f"Plot config failed: {exc}", flush=True)

    def closeEvent(self, event):
        self.client.stop()
        self.client.wait(1000)
        super().closeEvent(event)


def apply_config(base_url: str) -> None:
    for path, payload in (
        ("/config/startup", STARTUP_CONF),
        ("/config/runtime", RUNTIME_CONF),
    ):
        resp = requests.post(f"{base_url}{path}", json=payload, timeout=10)
        if not resp.ok:
            raise RuntimeError(f"{path} failed with HTTP {resp.status_code}: {resp.text}")


def parse_args():
    parser = argparse.ArgumentParser(description="Plot Angus DMA pressure from the FastAPI websocket.")
    parser.add_argument("--host", default="127.0.0.1", help="FastAPI server hostname or IP")
    parser.add_argument("--port", type=int, default=8000, help="FastAPI server port")
    parser.add_argument("--stream", choices=("raw", "avg"), default="avg", help="Websocket DMA stream to plot")
    parser.add_argument("--raw-samples", type=int, default=7200, help="Raw DMA samples requested per websocket message")
    parser.add_argument("--avg-samples", type=int, default=7200, help="Averaged DMA samples requested per websocket message")
    parser.add_argument("--no-config", action="store_true", help="Do not POST STARTUP_CONF/RUNTIME_CONF before streaming")
    parser.add_argument("--json", action="store_true", help="Use JSON raw words instead of binary websocket messages")
    parser.add_argument("--n", type=int, default=7, help="Initial PL AVG_N register value")
    parser.add_argument("--plot-fps", type=float, default=60.0, help="Maximum GUI redraw rate")
    parser.add_argument("--raw-ws", action="store_true", help="Alias for --stream raw")
    return parser.parse_args()


def main() -> int:
    global pg

    args = parse_args()
    args.binary = not args.json

    app = QtWidgets.QApplication(sys.argv)
    import pyqtgraph as pyqtgraph

    pg = pyqtgraph
    pg.setConfigOptions(antialias=False)

    base_url = f"http://{args.host}:{args.port}"
    if not args.no_config:
        apply_config(base_url)

    window = AngusPlot(args)
    window.show()
    return app.exec_()


if __name__ == "__main__":
    raise SystemExit(main())
