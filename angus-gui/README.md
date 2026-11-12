# Angus GUI

React frontend for the Angus combustion analyser. Connects to the FastAPI server
running on the PYNQ-Z2.

## Quick start

```bash
npm install
npm run dev
```

Open http://localhost:5173 in a browser. Enter the board address (e.g.
`192.168.2.99:8000`) in the host field and click CONNECT.

## Modes

**LIVE** — streams DMA packets via WebSocket. The server sends whole DMA blocks
(1024 samples by default). The GUI buffers the last ~10 blocks, splits them into
cycles by crank angle wrap, and computes metrics on the averaged cycle.

**ANALYSE** — drop a previously saved `.json` capture file onto the file zone.
The GUI recomputes all metrics from the file data without needing a board
connection.

## Calibration factor

Set CAL to convert raw XADC pressure counts to bar. Until you have a calibration
curve, leave it at 1 and treat pressure values as counts. The metrics panel
labels the unit accordingly.

## Metrics computed client-side

All combustion metrics are computed in `src/lib/metrics.js`:

- **Pmax** and **Pmax angle** — peak pressure and its crank angle
- **CA50 / MFB 10/50/90** — approximated from pressure rise ratio over
  300–450° CA window (Rassweiler-Withrow proxy). Accurate enough for
  cycle-to-cycle comparison; not a substitute for a full Borg heat release
  model with geometric parameters.
- **IMEP index** — proportional to IMEP via trapezoidal p·dθ integration.
  To convert to true IMEP (bar) you need bore, stroke, and con-rod length.
- **CoV Pmax / CoV CA50** — coefficient of variation across captured cycles.

## Architecture

```
src/
  hooks/
    useDmaStream.js     WebSocket hook with auto-reconnect (handles 1012 restart)
  lib/
    api.js              Thin wrapper around all FastAPI endpoints
    metrics.js          Client-side combustion metric computation
  components/
    StatusBar.jsx       WS / PLL / TDC / RPM status strip
    PressureTrace.jsx   Chart.js angle-domain pressure chart
    MetricsPanel.jsx    Metrics display (Pmax, CA50, MFB, CoV)
    ConfigPanel.jsx     Startup + runtime config forms, sync/faults buttons
    RegisterViewer.jsx  Register table + write form
  App.jsx               Main layout and state management
```

## Build for production

```bash
npm run build
```

The `dist/` folder can be served statically from the PYNQ-Z2 itself (e.g. via
`python -m http.server 5173 -d dist`) or from any machine on the same network.

When deploying on the board alongside the FastAPI server, either configure
FastAPI to serve the static `dist/` folder, or use nginx to proxy both.

## Proxy note

In dev mode, Vite proxies `/ws/*` to `ws://pynq:8000` so you do not need CORS
configuration on the board. In production (static build), the GUI connects
directly to the host entered in the UI, so CORS headers must be set on the
FastAPI server:

```python
from fastapi.middleware.cors import CORSMiddleware
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
```
