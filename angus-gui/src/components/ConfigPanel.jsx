import React, { useState } from "react";

const MONO = { fontFamily: "'JetBrains Mono', monospace" };

function Field({ label, value, onChange, type = "text", step, min, max }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 5 }}>
      <label style={{ fontSize: 11, color: "var(--color-text-secondary)", width: 140, flexShrink: 0, ...MONO }}>
        {label}
      </label>
      <input
        type={type}
        value={value}
        step={step}
        min={min}
        max={max}
        onChange={(e) => onChange(type === "number" ? parseFloat(e.target.value) : e.target.value)}
        style={{
          fontFamily: "var(--font-mono, monospace)",
          fontSize: 11,
          width: 76,
          padding: "3px 6px",
          border: "0.5px solid var(--color-border-secondary)",
          borderRadius: 4,
          background: "var(--color-background-secondary)",
          color: "var(--color-text-primary)",
        }}
      />
    </div>
  );
}

function SelectField({ label, value, onChange, options }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 5 }}>
      <label style={{ fontSize: 11, color: "var(--color-text-secondary)", width: 140, flexShrink: 0, ...MONO }}>
        {label}
      </label>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={{
          fontFamily: "var(--font-mono, monospace)",
          fontSize: 11,
          padding: "3px 6px",
          border: "0.5px solid var(--color-border-secondary)",
          borderRadius: 4,
          background: "var(--color-background-secondary)",
          color: "var(--color-text-primary)",
        }}
      >
        {options.map((o) => (
          <option key={o} value={o}>{o}</option>
        ))}
      </select>
    </div>
  );
}

function BoolField({ label, value, onChange }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 5 }}>
      <label style={{ fontSize: 11, color: "var(--color-text-secondary)", width: 140, flexShrink: 0, ...MONO }}>
        {label}
      </label>
      <input
        type="checkbox"
        checked={!!value}
        onChange={(e) => onChange(e.target.checked)}
        style={{ width: 14, height: 14, cursor: "pointer" }}
      />
    </div>
  );
}

function SectionLabel({ children }) {
  return (
    <div style={{
      fontSize: 10,
      letterSpacing: "0.1em",
      color: "var(--color-text-secondary)",
      fontWeight: 500,
      margin: "10px 0 6px",
      borderTop: "0.5px solid var(--color-border-tertiary)",
      paddingTop: 8,
      ...MONO,
    }}>
      {children}
    </div>
  );
}

const DEFAULT_STARTUP = {
  src: "crank",
  crank_n_teeth: 60,
  crank_n_missing: 2,
  crank_edge: "falling",
  ref: "cam",
  cam_n_teeth: 1,
  cam_edge: "rising",
  phase_ref_deg: 93.0,
  phase_tol_deg: 10.0,
  ang_sel: "tooth",
  angle_interp: true,
  dma_buffer_size: 2,
  enc_n_ppr: 1000,
  enc_ab_edge_sel: 0,
  enc_z_edge_sel: 0,
};

const DEFAULT_RUNTIME = {
  max_rpm: 6000,
  trig_decimation: 1,
  tdc_offset_deg: 0.0,
  peak_hyst: 0,
  pll_kp: 0,
  pll_ki: 0,
  pll_corr_max: 0,
  pll_corr_dir: "add",
  crank_dbc: 0,
  cam_dbc: 0,
  enc_a_dbc: 0,
  enc_b_dbc: 0,
  enc_z_dbc: 0,
};

// Only send fields that differ from the server defaults (non-null fields)
// to match the server's exclude_none=True behaviour
function changedOnly(vals, defaults) {
  const out = {};
  for (const [k, v] of Object.entries(vals)) {
    // Always include core fields; skip optional extras at their default
    if (v !== defaults[k] || ["src", "crank_n_teeth", "crank_n_missing", "crank_edge", "ref",
        "cam_n_teeth", "cam_edge", "phase_ref_deg", "phase_tol_deg", "ang_sel",
        "angle_interp", "dma_buffer_size", "max_rpm", "trig_decimation", "tdc_offset_deg"].includes(k)) {
      out[k] = v;
    }
  }
  return out;
}

export function ConfigPanel({ api, onStatusUpdate }) {
  const [startup, setStartup] = useState(DEFAULT_STARTUP);
  const [runtime, setRuntime] = useState(DEFAULT_RUNTIME);
  const [showEncoder, setShowEncoder] = useState(false);
  const [showAdvRuntime, setShowAdvRuntime] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(null);

  const setS = (key) => (val) => setStartup((p) => ({ ...p, [key]: val }));
  const setR = (key) => (val) => setRuntime((p) => ({ ...p, [key]: val }));

  async function runAction(fn, label) {
    setBusy(true);
    setMessage(null);
    try {
      await fn();
      setMessage({ ok: true, text: `${label} OK` });
      onStatusUpdate?.();
    } catch (e) {
      setMessage({ ok: false, text: `${label} failed: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }

  const btnStyle = (primary, danger) => ({
    fontFamily: "var(--font-mono, monospace)",
    fontSize: 11,
    padding: "5px 10px",
    border: danger ? "0.5px solid #A32D2D" : primary ? "none" : "0.5px solid var(--color-border-secondary)",
    borderRadius: 4,
    cursor: busy ? "not-allowed" : "pointer",
    background: primary ? "#185FA5" : "none",
    color: danger ? "#A32D2D" : primary ? "#E6F1FB" : "var(--color-text-secondary)",
    opacity: busy ? 0.6 : 1,
  });

  const toggleStyle = {
    fontFamily: "var(--font-mono, monospace)",
    fontSize: 10,
    padding: "2px 6px",
    border: "0.5px solid var(--color-border-secondary)",
    borderRadius: 4,
    cursor: "pointer",
    background: "none",
    color: "var(--color-text-secondary)",
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>

      {/* Quick apply */}
      <div style={{ marginBottom: 4 }}>
        <div style={{ fontSize: 10, letterSpacing: "0.1em", color: "var(--color-text-secondary)", marginBottom: 6, ...MONO }}>
          QUICK APPLY
        </div>
        <button
          style={{ ...btnStyle(true), width: "100%" }}
          disabled={busy}
          onClick={() => runAction(() => api.applyNotebook(), "notebook config")}
        >
          APPLY NOTEBOOK CONFIG
        </button>
        <div style={{ fontSize: 10, color: "var(--color-text-secondary)", marginTop: 3, ...MONO }}>
          60T-2 / cam / phase 93° / interp on / 6000 RPM max
        </div>
      </div>

      {/* Startup config */}
      <SectionLabel>STARTUP CONFIG</SectionLabel>

      <SelectField label="src" value={startup.src} onChange={setS("src")} options={["crank", "encoder"]} />
      <Field label="crank_n_teeth" value={startup.crank_n_teeth} onChange={setS("crank_n_teeth")} type="number" min={1} max={255} />
      <Field label="crank_n_missing" value={startup.crank_n_missing} onChange={setS("crank_n_missing")} type="number" min={0} max={255} />
      <SelectField label="crank_edge" value={startup.crank_edge} onChange={setS("crank_edge")} options={["falling", "rising"]} />
      <SelectField label="ref" value={startup.ref} onChange={setS("ref")} options={["cam", "peak"]} />
      <Field label="cam_n_teeth" value={startup.cam_n_teeth} onChange={setS("cam_n_teeth")} type="number" min={0} max={255} />
      <SelectField label="cam_edge" value={startup.cam_edge} onChange={setS("cam_edge")} options={["falling", "rising"]} />
      <Field label="phase_ref_deg" value={startup.phase_ref_deg} onChange={setS("phase_ref_deg")} type="number" step={0.5} min={0} max={719.9} />
      <Field label="phase_tol_deg" value={startup.phase_tol_deg} onChange={setS("phase_tol_deg")} type="number" step={0.5} min={0} max={180} />
      <SelectField label="ang_sel" value={startup.ang_sel} onChange={setS("ang_sel")} options={["tooth", "pll"]} />
      <BoolField label="angle_interp" value={startup.angle_interp} onChange={setS("angle_interp")} />
      <Field label="dma_buffer_size" value={startup.dma_buffer_size} onChange={setS("dma_buffer_size")} type="number" min={0} max={15} />

      <div style={{ marginTop: 4 }}>
        <button style={toggleStyle} onClick={() => setShowEncoder((v) => !v)}>
          {showEncoder ? "▾" : "▸"} encoder fields
        </button>
      </div>
      {showEncoder && (
        <>
          <Field label="enc_n_ppr" value={startup.enc_n_ppr} onChange={setS("enc_n_ppr")} type="number" min={1} max={65535} />
          <Field label="enc_ab_edge_sel" value={startup.enc_ab_edge_sel} onChange={setS("enc_ab_edge_sel")} type="number" min={0} max={2} />
          <Field label="enc_z_edge_sel" value={startup.enc_z_edge_sel} onChange={setS("enc_z_edge_sel")} type="number" min={0} max={1} />
        </>
      )}

      <div style={{ marginTop: 6 }}>
        <button style={btnStyle(false)} disabled={busy} onClick={() => runAction(() => api.applyStartup(startup), "startup config")}>
          APPLY STARTUP
        </button>
      </div>

      {/* Runtime config */}
      <SectionLabel>RUNTIME CONFIG</SectionLabel>

      <Field label="max_rpm" value={runtime.max_rpm} onChange={setR("max_rpm")} type="number" min={0} max={65535} />
      <Field label="trig_decimation" value={runtime.trig_decimation} onChange={setR("trig_decimation")} type="number" min={1} max={65535} />
      <Field label="tdc_offset_deg" value={runtime.tdc_offset_deg} onChange={setR("tdc_offset_deg")} type="number" step={0.1} min={0} max={360} />

      <div style={{ marginTop: 4 }}>
        <button style={toggleStyle} onClick={() => setShowAdvRuntime((v) => !v)}>
          {showAdvRuntime ? "▾" : "▸"} PLL / debounce / peak
        </button>
      </div>
      {showAdvRuntime && (
        <>
          <Field label="peak_hyst" value={runtime.peak_hyst} onChange={setR("peak_hyst")} type="number" min={0} max={65535} />
          <Field label="pll_kp" value={runtime.pll_kp} onChange={setR("pll_kp")} type="number" min={0} max={65535} />
          <Field label="pll_ki" value={runtime.pll_ki} onChange={setR("pll_ki")} type="number" min={0} max={65535} />
          <Field label="pll_corr_max" value={runtime.pll_corr_max} onChange={setR("pll_corr_max")} type="number" min={0} max={65535} />
          <SelectField label="pll_corr_dir" value={runtime.pll_corr_dir} onChange={setR("pll_corr_dir")} options={["add", "subtract"]} />
          <Field label="crank_dbc" value={runtime.crank_dbc} onChange={setR("crank_dbc")} type="number" min={0} max={65535} />
          <Field label="cam_dbc" value={runtime.cam_dbc} onChange={setR("cam_dbc")} type="number" min={0} max={65535} />
          <Field label="enc_a_dbc" value={runtime.enc_a_dbc} onChange={setR("enc_a_dbc")} type="number" min={0} max={65535} />
          <Field label="enc_b_dbc" value={runtime.enc_b_dbc} onChange={setR("enc_b_dbc")} type="number" min={0} max={65535} />
          <Field label="enc_z_dbc" value={runtime.enc_z_dbc} onChange={setR("enc_z_dbc")} type="number" min={0} max={65535} />
        </>
      )}

      <div style={{ marginTop: 6 }}>
        <button style={btnStyle(false)} disabled={busy} onClick={() => runAction(() => api.applyRuntime(runtime), "runtime config")}>
          APPLY RUNTIME
        </button>
      </div>

      {/* Sync / faults */}
      <SectionLabel>SYNC / FAULTS</SectionLabel>
      <div style={{ display: "flex", gap: 6 }}>
        <button style={btnStyle(false)} disabled={busy} onClick={() => runAction(() => api.waitSync(), "sync wait")}>
          WAIT SYNC
        </button>
        <button style={btnStyle(false, true)} disabled={busy} onClick={() => runAction(() => api.clearFaults(), "clear faults")}>
          CLEAR FAULTS
        </button>
      </div>

      {message && (
        <div style={{
          fontSize: 11,
          padding: "5px 8px",
          borderRadius: 4,
          marginTop: 4,
          background: message.ok ? "var(--color-background-success)" : "var(--color-background-danger)",
          color: message.ok ? "var(--color-text-success)" : "var(--color-text-danger)",
          ...MONO,
          wordBreak: "break-all",
        }}>
          {message.text}
        </div>
      )}
    </div>
  );
}
