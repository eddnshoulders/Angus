import React, { useState, useCallback, useRef, useMemo, useEffect } from "react";
import { useDmaStream } from "./hooks/useDmaStream";
import { AngusApi } from "./lib/api";
import { computeMetrics, cov, splitCycles } from "./lib/metrics";
import { StatusBar } from "./components/StatusBar";
import { PressureTrace } from "./components/PressureTrace";
import { MetricsPanel } from "./components/MetricsPanel";
import { ConfigPanel } from "./components/ConfigPanel";
import { RegisterViewer } from "./components/RegisterViewer";
import { CapturePanel } from "./components/CapturePanel";
import { CycleNavigator } from "./components/CycleNavigator";

// ---- persistence helpers ----
const STORED_HOST = localStorage.getItem("angus_host_v2") ?? import.meta.env.VITE_API_HOST;

// ---- layout constants ----
const SIDEBAR_WIDTH = 240;
const PANEL_HDR = {
  padding: "7px 12px",
  borderBottom: "0.5px solid var(--color-border-tertiary)",
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  background: "var(--color-background-secondary)",
  flexShrink: 0,
};
const PANEL_LABEL = {
  fontSize: 10,
  letterSpacing: "0.1em",
  color: "var(--color-text-secondary)",
  fontFamily: "'JetBrains Mono', monospace",
  fontWeight: 500,
};

const PANEL = {
  background: "var(--color-background-primary)",
  border: "0.5px solid var(--color-border-tertiary)",
  borderRadius: 8,
  display: "flex",
  flexDirection: "column",
  overflow: "hidden",
};

const MINI_BTN = (active) => ({
  fontFamily: "'JetBrains Mono', monospace",
  fontSize: 10,
  padding: "3px 8px",
  background: active ? "var(--color-background-info)" : "none",
  border: "0.5px solid var(--color-border-secondary)",
  borderRadius: 4,
  cursor: "pointer",
  color: active ? "var(--color-text-info)" : "var(--color-text-secondary)",
});


// Max cycles to keep in memory (ring buffer style)
const MAX_CYCLES = 20;
// How many DMA blocks to accumulate before recomputing (reduces thrash)
const BLOCK_BATCH = 3;

export default function App() {
  // --- connection ---
  const [host, setHost] = useState(STORED_HOST);
  const [editHost, setEditHost] = useState(STORED_HOST);
  const [mode, setMode] = useState("live"); // "live" | "analyse"
  const [frozen, setFrozen] = useState(false);
  const [activeTab, setActiveTab] = useState("metrics"); // "metrics" | "config" | "registers"
  const [calFactor, setCalFactor] = useState(1);
  const [wsaSamples, setWsaSamples] = useState(14400);
  // Analyse mode state
  const [loadedCycle, setLoadedCycle] = useState(null);
  const [yMin, setYMin] = useState("");   // "" = auto
  const [yMax, setYMax] = useState("");   // "" = auto
  const [decayAlpha, setDecayAlpha] = useState(0.02);
  const rescaleRef = useRef(null);        // callback into PressureTrace   // [{tdc_deg, pressure}]
  const [loadedFileInfo, setLoadedFileInfo] = useState(null);

  // --- DMA data ---
  const samplesBuffer = useRef([]); // ring buffer of {tdc_deg, pressure} objects
  const blockCount = useRef(0);
  // Raw scatter arrays for the latest block (passed directly to PressureTrace)
  const [scatterX, setScatterX] = useState(null); // Float32Array of tdc_deg
  const [scatterY, setScatterY] = useState(null); // Float32Array of pressure counts
  const [avgCycle, setAvgCycle] = useState([]); // angle-binned average for overlay
  const [metrics, setMetrics] = useState(null);
  const [covMetrics, setCovMetrics] = useState(null);
  const [liveStatus, setLiveStatus] = useState({});
  const [cycleCount, setCycleCount] = useState(0);

  const api = useMemo(() => new AngusApi(host), [host]);

  // Poll /status every 2s
  useEffect(() => {
    let timer;
    async function poll() {
      try {
        const s = await api.status();
        setLiveStatus(s);
      } catch {
        // board unreachable — keep last known state
      }
      timer = setTimeout(poll, 2000);
    }
    poll();
    return () => clearTimeout(timer);
  }, [api]);

  // Poll SPEED_RPM_SLOW register at 200ms for live RPM display
  useEffect(() => {
    let timer;
    async function pollRpm() {
      try {
        const res = await api.register("SPEED_RPM_SLOW");
        // server returns {name, addr, msb, lsb, description, readable, writable, value}
        const rpm = res?.value;
        if (rpm != null) setLiveStatus((prev) => ({ ...prev, rpm }));
      } catch {
        // silently ignore — RPM display stays at last known value
      }
      timer = setTimeout(pollRpm, 200);
    }
    pollRpm();
    return () => clearTimeout(timer);
  }, [api]);

  const recompute = useCallback((allSamples) => {
    // Average cycle: bin by 1° buckets across all buffered samples
    const bins = {};
    for (const s of allSamples) {
      const bin = Math.round(s.tdc_deg);
      if (!bins[bin]) bins[bin] = [];
      bins[bin].push(s.pressure);
    }
    const avgPts = Object.keys(bins)
      .map(Number)
      .sort((a, b) => a - b)
      .map((deg) => {
        const vals = bins[deg];
        return { tdc_deg: deg, pressure: vals.reduce((a, b) => a + b, 0) / vals.length };
      });

    // Cycle split for metrics only
    const cycles = splitCycles(allSamples);
    const limited = cycles.slice(-MAX_CYCLES);
    const perCycleMetrics = limited.map((c) => computeMetrics(c, calFactor));
    const avgMetrics = computeMetrics(avgPts, calFactor);

    const pmaxVals = perCycleMetrics.map((m) => m?.pmax).filter(Boolean);
    const ca50Vals = perCycleMetrics.map((m) => m?.mfb50).filter(Boolean);

    setAvgCycle(avgPts);
    setMetrics(avgMetrics);
    setCovMetrics({
      covPmax: cov(pmaxVals),
      covCa50: ca50Vals.length > 1
        ? +(Math.sqrt(ca50Vals.reduce((a, b) => a + (b - ca50Vals.reduce((x, y) => x + y, 0) / ca50Vals.length) ** 2, 0) / ca50Vals.length)).toFixed(2)
        : null,
      nCycles: limited.length,
    });
    setCycleCount(limited.length);
  }, [calFactor]);

  const handleBlock = useCallback((xs, ys, n) => {
    if (frozen || mode !== "live") return;

    // xs/ys are Float32Arrays decoded client-side from binary WS
    setScatterX(xs);
    setScatterY(ys);

    // Accumulate into ring buffer as plain objects for metrics
    const samples = [];
    for (let i = 0; i < n; i++) {
      samples.push({ tdc_deg: xs[i], pressure: ys[i] });
    }
    samplesBuffer.current = [...samplesBuffer.current, ...samples].slice(-14400 * 10);
    blockCount.current += 1;
    if (blockCount.current % BLOCK_BATCH === 0) {
      recompute(samplesBuffer.current);
    }
  }, [frozen, mode, recompute]);

  const { status: wsStatus, disconnect } = useDmaStream({
    host,
    samples: wsaSamples,
    enabled: mode === "live" && !frozen,
    onBlock: handleBlock,
  });

  function applyHost() {
    const h = editHost.trim();
    localStorage.setItem("angus_host_v2", h);
    setHost(h);
  }

  // Handle file drop for analyse mode
  function handleDrop(e) {
    e.preventDefault();
    const file = e.dataTransfer?.files?.[0] ?? e.target?.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const data = JSON.parse(reader.result);
        if (Array.isArray(data)) {
          samplesBuffer.current = data;
          recompute(data);
        }
      } catch {
        // Could handle binary .bin here with DataView
      }
    };
    reader.readAsText(file);
  }

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100vh",
        background: "var(--color-background-tertiary)",
        fontFamily: "'JetBrains Mono', monospace",
      }}
    >
      {/* ---- TOP BAR ---- */}
      <div
        style={{
          background: "var(--color-background-primary)",
          borderBottom: "0.5px solid var(--color-border-tertiary)",
          padding: "0 16px",
          height: 44,
          display: "flex",
          alignItems: "center",
          gap: 12,
          flexShrink: 0,
        }}
      >
        <span style={{ fontSize: 13, fontWeight: 500, letterSpacing: "0.1em", color: "var(--color-text-primary)" }}>
          ANGUS
        </span>
        <div style={{ width: 0.5, height: 20, background: "var(--color-border-tertiary)" }} />

        {/* Mode toggle */}
        <div
          style={{
            display: "flex",
            border: "0.5px solid var(--color-border-secondary)",
            borderRadius: 6,
            overflow: "hidden",
          }}
        >
          {["live", "analyse"].map((m) => (
            <button
              key={m}
              style={{
                fontFamily: "var(--font-mono, monospace)",
                fontSize: 11,
                padding: "4px 12px",
                background: mode === m ? "var(--color-background-info)" : "none",
                border: "none",
                cursor: "pointer",
                color: mode === m ? "var(--color-text-info)" : "var(--color-text-secondary)",
                fontWeight: mode === m ? 500 : 400,
              }}
              onClick={() => setMode(m)}
            >
              {m.toUpperCase()}
            </button>
          ))}
        </div>

        {/* Host input */}
        <div style={{ display: "flex", gap: 4, alignItems: "center", marginLeft: 8 }}>
          <input
            value={editHost}
            onChange={(e) => setEditHost(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && applyHost()}
            style={{
              fontFamily: "var(--font-mono, monospace)",
              fontSize: 11,
              width: 160,
              padding: "3px 6px",
              border: "0.5px solid var(--color-border-secondary)",
              borderRadius: 4,
              background: "var(--color-background-secondary)",
              color: "var(--color-text-primary)",
            }}
          />
          <button style={{ ...MINI_BTN(false), padding: "3px 10px" }} onClick={applyHost}>
            CONNECT
          </button>
        </div>

        <div style={{ flex: 1 }} />

        {/* Cal factor */}
        <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
          <span style={{ fontSize: 10, color: "var(--color-text-secondary)" }}>CAL</span>
          <input
            type="number"
            step="0.001"
            value={calFactor}
            onChange={(e) => setCalFactor(parseFloat(e.target.value) || 1)}
            style={{
              fontFamily: "var(--font-mono, monospace)",
              fontSize: 11,
              width: 72,
              padding: "3px 6px",
              border: "0.5px solid var(--color-border-secondary)",
              borderRadius: 4,
              background: "var(--color-background-secondary)",
              color: "var(--color-text-primary)",
            }}
          />
          <span style={{ fontSize: 10, color: "var(--color-text-secondary)" }}>cts→bar</span>
        </div>
      </div>

      {/* ---- STATUS BAR ---- */}
      <StatusBar wsStatus={wsStatus} status={liveStatus} cycleCount={cycleCount} />

      {/* ---- MAIN LAYOUT ---- */}
      <div style={{ display: "flex", flex: 1, overflow: "hidden", gap: 8, padding: 8 }}>

        {/* LEFT: pressure trace + capture controls */}
        <div style={{ display: "flex", flexDirection: "column", flex: 1, gap: 8, minWidth: 0 }}>

          {/* Pressure trace panel */}
          <div style={{ ...PANEL, flex: 1 }}>
            <div style={PANEL_HDR}>
              <span style={PANEL_LABEL}>CYLINDER PRESSURE — ANGLE DOMAIN</span>
              <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
                <span style={{ fontSize: 10, color: "var(--color-text-secondary)", fontFamily: "monospace" }}>Y</span>
                <input
                  type="number"
                  placeholder="min"
                  value={yMin}
                  onChange={(e) => setYMin(e.target.value)}
                  style={{ fontFamily: "monospace", fontSize: 10, width: 52, padding: "2px 4px",
                    border: "0.5px solid var(--color-border-secondary)", borderRadius: 3,
                    background: "var(--color-background-secondary)", color: "var(--color-text-primary)" }}
                />
                <input
                  type="number"
                  placeholder="max"
                  value={yMax}
                  onChange={(e) => setYMax(e.target.value)}
                  style={{ fontFamily: "monospace", fontSize: 10, width: 52, padding: "2px 4px",
                    border: "0.5px solid var(--color-border-secondary)", borderRadius: 3,
                    background: "var(--color-background-secondary)", color: "var(--color-text-primary)" }}
                />
                <span style={{ fontSize: 10, color: "var(--color-text-secondary)", fontFamily: "monospace" }}>decay</span>
                <input
                  type="number"
                  min={0.001}
                  max={1}
                  step={0.01}
                  value={decayAlpha}
                  onChange={(e) => setDecayAlpha(parseFloat(e.target.value) || 0.02)}
                  style={{ fontFamily: "monospace", fontSize: 10, width: 48, padding: "2px 4px",
                    border: "0.5px solid var(--color-border-secondary)", borderRadius: 3,
                    background: "var(--color-background-secondary)", color: "var(--color-text-primary)" }}
                />
                <button
                  style={MINI_BTN(false)}
                  onClick={() => { setYMin(""); setYMax(""); if (rescaleRef.current) rescaleRef.current(); }}
                >
                  AUTO
                </button>
                <button
                  style={MINI_BTN(false)}
                  onClick={() => { if (rescaleRef.current) rescaleRef.current(); }}
                >
                  RESCALE
                </button>
                <button
                  style={{ ...MINI_BTN(frozen), borderColor: frozen ? "#185FA5" : undefined, color: frozen ? "#185FA5" : undefined }}
                  onClick={() => setFrozen((f) => !f)}
                >
                  {frozen ? "FROZEN" : "FREEZE"}
                </button>
              </div>
            </div>
            <div style={{ flex: 1, padding: "10px 12px 4px", minHeight: 0 }}>
              <PressureTrace
                scatterX={mode === "live" ? scatterX : null}
                scatterY={mode === "live" ? scatterY : null}
                cycleData={mode === "analyse" ? loadedCycle : null}
                frozen={frozen}
                calFactor={calFactor}
                decayAlpha={decayAlpha}
                yMin={yMin !== "" ? parseFloat(yMin) : undefined}
                yMax={yMax !== "" ? parseFloat(yMax) : undefined}
                onRescale={rescaleRef}
              />
            </div>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                padding: "0 16px 6px",
                fontSize: 10,
                color: "var(--color-text-secondary)",
              }}
            >
              {["-360°", "-180°", "TDC 0°", "+180°", "+360°"].map((l) => (
                <span key={l}>{l}</span>
              ))}
            </div>
          </div>

          {/* Capture / analyse panel */}
          <div style={{ ...PANEL, flexShrink: 0 }}>
            <div style={PANEL_HDR}>
              <span style={PANEL_LABEL}>
                {mode === "live" ? "LIVE CAPTURE" : "ANALYSE"}
              </span>
              {mode === "live" && (
                <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  <span style={{ fontSize: 10, color: "var(--color-text-secondary)", fontFamily: "monospace" }}>samples</span>
                  <input
                    type="number"
                    min={1024}
                    max={72000}
                    step={1024}
                    value={wsaSamples}
                    onChange={(e) => setWsaSamples(parseInt(e.target.value) || 14400)}
                    style={{
                      fontFamily: "var(--font-mono, monospace)",
                      fontSize: 11,
                      width: 72,
                      padding: "2px 6px",
                      border: "0.5px solid var(--color-border-secondary)",
                      borderRadius: 4,
                      background: "var(--color-background-secondary)",
                      color: "var(--color-text-primary)",
                    }}
                  />
                </div>
              )}
            </div>
            {mode === "live" ? (
              <CapturePanel
                api={api}
                wsStatus={wsStatus}
                sampleCount={samplesBuffer.current.length}
                calFactor={calFactor}
              />
            ) : (
              <div style={{ padding: "10px 12px" }}>
                <CycleNavigator
                  api={api}
                  onCycleLoaded={(samples, info, idx) => {
                    setLoadedCycle(samples);
                    setLoadedFileInfo(info);
                  }}
                  onFileSelected={(info) => setLoadedFileInfo(info)}
                />
              </div>
            )}
          </div>
        </div>

        {/* RIGHT SIDEBAR */}
        <div
          style={{
            width: SIDEBAR_WIDTH,
            flexShrink: 0,
            display: "flex",
            flexDirection: "column",
            gap: 8,
            overflowY: "auto",
          }}
        >
          {/* Tab selector */}
          <div
            style={{
              display: "flex",
              border: "0.5px solid var(--color-border-secondary)",
              borderRadius: 6,
              overflow: "hidden",
              flexShrink: 0,
            }}
          >
            {[
              { key: "metrics", label: "METRICS" },
              { key: "config", label: "CONFIG" },
              { key: "registers", label: "REGS" },
            ].map(({ key, label }) => (
              <button
                key={key}
                style={{
                  flex: 1,
                  fontFamily: "var(--font-mono, monospace)",
                  fontSize: 10,
                  padding: "5px 4px",
                  background: activeTab === key ? "var(--color-background-info)" : "none",
                  border: "none",
                  cursor: "pointer",
                  color: activeTab === key ? "var(--color-text-info)" : "var(--color-text-secondary)",
                  fontWeight: activeTab === key ? 500 : 400,
                }}
                onClick={() => setActiveTab(key)}
              >
                {label}
              </button>
            ))}
          </div>

          {/* Sidebar panel */}
          <div
            style={{
              ...PANEL,
              flex: 1,
              padding: "12px 12px",
              overflowY: "auto",
            }}
          >
            {activeTab === "metrics" && (
              <MetricsPanel metrics={metrics} covMetrics={covMetrics} calFactor={calFactor} />
            )}
            {activeTab === "config" && (
              <ConfigPanel api={api} onStatusUpdate={() => api.status().then(setLiveStatus).catch(() => {})} />
            )}
            {activeTab === "registers" && (
              <RegisterViewer api={api} />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
