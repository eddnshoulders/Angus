import React, { useState, useEffect, useCallback } from "react";

const MONO = { fontFamily: "'JetBrains Mono', monospace" };

const inputStyle = {
  fontFamily: "var(--font-mono, monospace)",
  fontSize: 11,
  padding: "3px 6px",
  border: "0.5px solid var(--color-border-secondary)",
  borderRadius: 4,
  background: "var(--color-background-secondary)",
  color: "var(--color-text-primary)",
};

const btnStyle = (primary, danger) => ({
  fontFamily: "var(--font-mono, monospace)",
  fontSize: 11,
  padding: "4px 10px",
  border: danger ? "0.5px solid #A32D2D" : primary ? "none" : "0.5px solid var(--color-border-secondary)",
  borderRadius: 4,
  cursor: "pointer",
  background: primary ? "#185FA5" : "none",
  color: danger ? "#A32D2D" : primary ? "#E6F1FB" : "var(--color-text-secondary)",
});

export function CapturePanel({ api, wsStatus, sampleCount, calFactor, runtimeConfig }) {
  const [nCycles, setNCycles] = useState(10);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState(null);

  async function handleSave() {
    setSaving(true);
    setMessage(null);
    try {
      const res = await api.saveCapture(nCycles, {
        cal_factor: calFactor,
        ...runtimeConfig,
      });
      setMessage({ ok: true, text: `saved: ${res.filename}` });
    } catch (e) {
      setMessage({ ok: false, text: e.message });
    } finally {
      setSaving(false);
    }
  }

  return (
    <div style={{ padding: "10px 12px", display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <span style={{ fontSize: 11, color: "var(--color-text-secondary)", ...MONO }}>cycles</span>
        <input
          type="number"
          min={1}
          max={1000}
          value={nCycles}
          onChange={(e) => setNCycles(parseInt(e.target.value) || 1)}
          style={{ ...inputStyle, width: 64 }}
        />
        <button
          style={btnStyle(true)}
          disabled={saving || wsStatus !== "connected"}
          onClick={handleSave}
        >
          {saving ? "SAVING..." : "SAVE TO BOARD"}
        </button>
      </div>

      <div style={{ fontSize: 10, color: "var(--color-text-secondary)", ...MONO }}>
        {sampleCount.toLocaleString()} samples buffered · ws {wsStatus}
      </div>

      {message && (
        <div style={{
          fontSize: 11,
          padding: "5px 8px",
          borderRadius: 4,
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
