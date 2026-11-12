# Angus FastAPI Interface

## Install

```bash
pip install -r requirements.txt
```

PYNQ itself is not listed in `requirements.txt`; it should already be present on
the PYNQ-Z2 image.

## Run On The Board

```bash
export ANGUS_BITFILE=/home/xilinx/angus.bit
export ANGUS_IP_NAME=top_0
export ANGUS_DMA_NAME=axi_dma_0
export ANGUS_AVG_DMA_NAME=axi_dma_1
export ANGUS_RAW_DMA_SAMPLES=7200
export ANGUS_AVG_DMA_SAMPLES=7200
uvicorn server:app --host 0.0.0.0 --port 8000
```

The DMA websocket can use either PYNQ's DMA channel wrapper or a direct AXI DMA
S2MM register backend:

```bash
export ANGUS_DMA_BACKEND=pynq
```

or:

```bash
export ANGUS_DMA_BACKEND=direct
export ANGUS_DMA_TIMEOUT=2.0
```

The direct backend still uses PYNQ for overlay loading and CMA buffer allocation,
but it starts/polls/resets the AXI DMA S2MM channel by writing the DMA registers
directly. This is intended for the fixed S2MM block-streaming debug path.

Verbose debug prints can be enabled with either:

```bash
export ANGUS_VERBOSE=1
uvicorn server:app --host 0.0.0.0 --port 8000
```

or by running the server script directly:

```bash
python server.py -v --host 0.0.0.0 --port 8000
```

Verbose mode prints overlay loading, selected IP/DMA names, REST calls, raw
register snapshots before/after config calls, and websocket DMA block activity.

`GET /health` also reports the active server build string, DMA backend, whether
the PL plot DMA stream was found, DMA words per sample, and TDC step count. This
is useful for confirming that the PYNQ is running the same `server.py` version as
this workspace after copying files.

If both `stream=raw` and `stream=avg` report AXI DMA S2MM internal errors,
check whether Vivado assigned the AXI DMA instance names opposite to the
assumed order. Swap these two variables and restart the server:

```bash
export ANGUS_DMA_NAME=axi_dma_1
export ANGUS_AVG_DMA_NAME=axi_dma_0
```

If startup config interrupts DMA for longer than the default pause window, tune
the websocket restart delay:

```bash
export ANGUS_DMA_RESTART_DELAY=3.0
```

For off-board API development:

```bash
export ANGUS_SIM=1
uvicorn server:app --host 127.0.0.1 --port 8000
```

## REST Endpoints

- `GET /health`
- `GET /status`
- `GET /config/startup`
- `POST /config/startup`
- `POST /config/notebook`
- `GET /config/runtime`
- `POST /config/runtime`
- `POST /sync/wait?level=full&timeout=10`
- `POST /faults/clear`
- `POST /dma/recover`
- `GET /dma/status`
- `GET /plot/config`
- `POST /plot/config`
- `GET /debug/config-status`
- `GET /debug/last-startup`
- `GET /registers`
- `GET /registers/{NAME}`
- `PUT /registers/{NAME}` with `{"value": 123}`
- `GET /registers/raw/{ADDR}` where `ADDR` may be decimal or hex, such as `0x004`
- `PUT /registers/raw` with `{"addr": 4, "value": 2}`

## Startup Configuration

The fastest way to apply the currently known-good notebook configuration is:

```bash
curl -X POST http://pynq:8000/config/notebook
```

This calls:

```python
a.startup_conf(
    src="crank",
    crank_n_teeth=60,
    crank_n_missing=2,
    crank_edge="falling",
    ref="cam",
    cam_n_teeth=1,
    cam_edge="rising",
    phase_ref_deg=93.0,
    phase_tol_deg=10.0,
    ang_sel="tooth",
    angle_interp=True,
    dma_buffer_size=1,
)

a.runtime_conf(
    max_rpm=6000,
    trig_decimation=1,
    tdc_offset_deg=0.0,
)
```

To apply custom startup values, use `POST /config/startup`:

```bash
curl -X POST http://pynq:8000/config/startup \
  -H "Content-Type: application/json" \
  -d '{"src":"crank","crank_n_teeth":60,"crank_n_missing":2,"crank_edge":"falling","ref":"cam","cam_n_teeth":1,"cam_edge":"rising","phase_ref_deg":93.0,"phase_tol_deg":10.0,"ang_sel":"tooth","angle_interp":true,"dma_buffer_size":1}'
```

Example runtime update:

```bash
curl -X POST http://pynq:8000/config/runtime \
  -H "Content-Type: application/json" \
  -d '{"tdc_offset_deg": 92.5, "trig_decimation": 5}'
```

## Debug Endpoints

`GET /debug/config-status` captures and returns the same text produced by
`a.config_status()`, along with the API-side startup/runtime shadow values.

`GET /debug/last-startup` returns the most recent startup/runtime request bodies
and raw AXI register snapshots from before and after the calls. This is useful
for confirming that FastAPI reached `a.startup_conf()` and that writes landed in
the expected AXI-Lite registers.

When `src` is not `encoder`, encoder fields posted as zero by the FastAPI docs
form (`enc_n_ppr`, `enc_ab_edge_sel`, `enc_z_edge_sel`) are ignored before
calling `startup_conf`.

`POST /dma/recover` resets/restarts the AXI DMA S2MM receive channel via its
control/status registers and briefly pauses websocket reconnects. Use this if a
source pause or PL reset leaves PYNQ's DMA channel in an error/stopped state
without restarting `server.py`.

`GET /dma/status` returns the selected DMA backend plus the current direct S2MM
register state and/or PYNQ receive-channel state. It also includes
`avg_diagnostics`, a low-rate snapshot of the PL avg-to-DMA1 debug counters.

`POST /plot/config` updates the PL plot-stream control register:

```json
{
  "n": 4
}
```

This writes the PL `AVG_N` AXI-Lite register at `0x10C`. The GUI's `N`
spin box posts this value when changed. `GET /plot/config` returns the
current `AVG_N` value, `AVG_FRAME_COUNT`, and the PL avg-stream diagnostic
counters:

```json
{
  "n": 4,
  "frame_count": 12345,
  "diagnostics": {
    "avg_n": 4,
    "avg_frame_count": 12345,
    "avg_in_beat_count": 88920000,
    "avg_out_beat_count": 88920000,
    "avg_out_tlast_count": 12345,
    "avg_out_stall_count": 0,
    "avg_bad_tlast_count": 0
  }
}
```

The avg diagnostic AXI-Lite registers are read-only and are intended for
health/debug polling, not the DMA hot path:

```text
0x114 AVG_IN_BEAT_COUNT    accepted beats into avg block
0x118 AVG_OUT_BEAT_COUNT   accepted beats out of avg block
0x11C AVG_OUT_TLAST_COUNT  accepted TLAST beats out of avg block
0x120 AVG_OUT_STALL_COUNT  cycles with output TVALID=1 and TREADY=0
0x124 AVG_BAD_TLAST_COUNT  TLAST asserted on the wrong word, should remain 0
```

## DMA Websocket

DMA data is sent as whole completed DMA blocks. The server does not send one
websocket message per sample frame. One websocket message contains the complete
DMA receive buffer requested by `samples`.

Calling `POST /config/startup` or `POST /config/notebook` can reset/reconfigure
the PL while a DMA websocket is waiting for a block. The server treats this as a
normal stream interruption: it closes the websocket with code `1012` instead of
logging an ASGI exception. New websocket connections are held off briefly during
the DMA restart window. The server also attempts to restart PYNQ's DMA receive
channel if it reports `DMA channel not started`. `plot_dma_ws.py` automatically
reconnects after this.

Connect to:

```text
ws://pynq:8000/ws/dma?samples=1024&decoded=true
```

### DMA Frame Format

Each PL sample frame is two little-endian `uint32` words:

```text
word 0: [31:0]  tdc_deg_count        0.1 deg/LSB, 0..7199
word 1: [31:24] digital inputs
        [23:16] reserved
        [15:4]  pressure             12-bit XADC raw count
        [3:0]   reserved
```

Decoded values:

```python
tdc_deg = word0 * 0.1
di = (word1 >> 24) & 0xFF
pressure = (word1 >> 4) & 0x0FFF
```

For `samples=7200`, one raw or averaged binary websocket message contains one
complete 720-degree DMA frame when `DMA_BUFFER_SIZE=1`:

```text
7200 frames * 2 words/frame = 14400 uint32 words
14400 words * 4 bytes/word  = 57600 bytes
```

### Websocket Payloads

With `decoded=true`, each websocket message contains decoded JSON samples:

```json
{
  "samples": [
    {
      "tdc_deg": 123.4,
      "di": 0,
      "pressure": 2048
    }
  ],
  "word_count": 3072
}
```

With `decoded=false&binary=false`, each websocket message contains JSON raw
words:

```json
{
  "words": [1234, 32768],
  "word_count": 2048
}
```

For higher-rate clients, request raw little-endian `uint32` binary messages:

```text
ws://pynq:8000/ws/dma?samples=7200&decoded=false&binary=true&stream=raw
```

In this mode the server sends the raw DMA receive buffer bytes directly. The
plotter decodes them with:

```python
words = np.frombuffer(msg, dtype="<u4").reshape((-1, 2))
```

For plotting at higher RPM, request the PL plot DMA stream:

```text
ws://pynq:8000/ws/dma?samples=7200&decoded=false&binary=true&stream=avg&n=4
```

In this mode the server reads from the averaged AXI DMA S2MM path selected by
`ANGUS_AVG_DMA_NAME`, then forwards each completed PL plot frame without
additional PS-side processing. The PL frame generator is controlled by the
`AVG_N` register. `AVG_N=0` is hardware bypass mode; because the PL now emits
one-rev frames in both averaged and bypass modes, the payload size and format
remain the same. The payload uses the same two-word frame format:

```text
7200 samples x 2 little-endian uint32 words
word 0: [31:0] raw tdc_deg count, 0..7199
word 1: [31:24] DI[7:0] [23:16] 0x00 [15:4] pressure[11:0] [3:0] 0x0
```

The plotter decodes this with the same path as raw websocket data, then applies
the display-only `-360..+360` shift locally. This keeps raw DMA traffic on the
PYNQ side and reduces websocket and GUI work without changing the websocket data
type or packet layout.

Use `once=true` for a single DMA receive:

```text
ws://pynq:8000/ws/dma?samples=1024&decoded=false&once=true
```

## Debug Plot

`plot_dma_ws.py` posts the hard-coded `STARTUP_CONF` and `RUNTIME_CONF`, then
plots pressure from the DMA stream against a centred TDC axis.

```bash
python plot_dma_ws.py --host pynq --port 8000
```

By default it requests `stream=avg`, 7,200 samples per websocket message, and
uses binary raw words. Use `--stream raw` or `--raw-ws` to plot the raw DMA
stream. With the current `dma_buffer_size=1` startup config, raw mode also
requests 7,200 samples per websocket message. Use `--json` to fall back to JSON raw-word
messages, or `--no-config` to skip posting the configuration before streaming.

By default the plotter asks the server for `stream=avg`. The `N` spin box
controls the `AVG_N` AXI-Lite register and the plot displays `AVG_FRAME_COUNT`
in the top-right overlay. In `stream=avg` mode, the plotter requests `7200` samples
per websocket message because each averaged PL frame is one 0.1-degree 720-degree
trace.

Use `--raw-ws` to select the original raw websocket transport and plotting path:

```bash
python plot_dma_ws.py --host pynq --raw-ws
```

In raw websocket mode, the GUI plots only the latest received DMA block. There
is no persistence; the coverage readout describes that one block only. This mode
is intended as a literal visualisation of the DMA buffer contents.

Initial values can also be set from the command line:

```bash
python plot_dma_ws.py --host pynq --n 4 --plot-fps 30
```

The PL still sends `tdc_deg` as `0..719.9`. The plotter displays it as
`-360..+360` with a display-only transform:

```python
x = ((tdc_deg + 360.0) % 720.0) - 360.0
```

The plot uses scatter points rather than line segments, filters out `NaN`/`inf`
and out-of-range samples, and shows GUI update FPS, TDC coverage, valid sample
count, `N`, and websocket sample rate.

The plotter also decodes `DI[7:0]` from word 1 and overlays eight stacked
digital traces in the upper half of the pressure plot for quick timing checks.
