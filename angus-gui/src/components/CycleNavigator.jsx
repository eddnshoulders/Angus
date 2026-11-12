import React, { useState, useEffect, useCallback } from "react";

const MONO = { fontFamily: "'JetBrains Mono', monospace" };

const btnStyle = (disabled) => ({
  fontFamily: "var(--font-mono, monospace)",
  fontSize: 13,
  padding: "4px 12px",
  border: "0.5px solid var(--color-border-secondary)",
  borderRadius: 4,
  cursor: disabled ? "not-allowed" : "pointer",
  background: "none",
  color: disabled ? "var(--color-text-secondary)" : "var(--color-text-primary)",
  opacity: disabled ? 0.4 : 1,
});

export function CycleNavigator({ api, onCycleLoaded, onFileSelected }) {
  const [files, setFiles] = useState([]);
  const [selectedFile, setSelectedFile] = useState(null);
  const [fileInfo, setFileInfo] = useState(null); // {n_cycles, rpm, timestamp, ...}
  const [cycleIdx, setCycleIdx] = useState(0);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState(null);

  // Fetch file list on mount
  useEffect(() => {
    api.listCaptures()
      .then((res) => setFiles(res.files ?? []))
      .catch(() => setFiles([]));
  }, [api]);

  const loadFile = useCallback(async (filename) => {
    setLoading(true);
    setMessage(null);
    try {
      const info = await api.getCaptureInfo(filename);
      setFileInfo(info);
      setSelectedFile(filename);
      setCycleIdx(0);
      onFileSelected?.(info);
      // Load first cycle immediately
      const cycle = await api.getCycle(filename, 0);
      onCycleLoaded?.(cycle.samples, info, 0);
    } catch (e) {
      setMessage({ ok: false, text: e.message });
    } finally {
      setLoading(false);
    }
  }, [api, onCycleLoaded, onFileSelected]);

  const goTo = useCallback(async (idx) => {
    if (!selectedFile || !fileInfo) return;
    if (idx < 0 || idx >= fileInfo.n_cycles) return;
    setLoading(true);
    try {
      const cycle = await api.getCycle(selectedFile, idx);
      setCycleIdx(idx);
      onCycleLoaded?.(cycle.samples, fileInfo, idx);
    } catch (e) {
      setMessage({ ok: false, text: e.message });
    } finally {
      setLoading(false);
    }
  }, [selectedFile, fileInfo, api, onCycleLoaded]);

  // Keyboard navigation
  useEffect(() => {
    function onKey(e) {
      if (e.key === "ArrowLeft") goTo(cycleIdx - 1);
      if (e.key === "ArrowRight") goTo(cycleIdx + 1);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [goTo, cycleIdx]);

  const rowSep = { borderBottom: "0.5px solid var(--color-border-tertiary)" };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>

      {/* File list */}
      <div style={{ fontSize: 10, letterSpacing: "0.1em", color: "var(--color-text-secondary)", ...MONO }}>
        SAVED CAPTURES
      </div>

      <div style={{
        border: "0.5px solid var(--color-border-tertiary)",
        borderRadius: 6,
        maxHeight: 180,
        overflowY: "auto",
      }}>
        {files.length === 0 ? (
          <div style={{ padding: "10px 8px", fontSize: 11, color: "var(--color-text-secondary)", ...MONO }}>
            no captures on board
          </div>
        ) : (
          <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 10, ...MONO }}>
            <tbody>
              {files.map((f) => (
                <tr
                  key={f.filename}
                  style={{
                    ...rowSep,
                    background: selectedFile === f.filename ? "var(--color-background-info)" : "transparent",
                    cursor: "pointer",
                  }}
                  onClick={() => loadFile(f.filename)}
                >
                  <td style={{ padding: "5px 8px", color: "var(--color-text-primary)" }}>{f.filename}</td>
                  <td style={{ padding: "5px 8px", textAlign: "right", color: "var(--color-text-secondary)" }}>
                    {f.n_cycles}cy
                  </td>
                  <td style={{ padding: "5px 4px", textAlign: "right", color: "var(--color-text-secondary)" }}>
                    <button
                      style={{
                        fontFamily: "var(--font-mono, monospace)",
                        fontSize: 10,
                        padding: "2px 6px",
                        border: "0.5px solid var(--color-border-secondary)",
                        borderRadius: 3,
                        cursor: "pointer",
                        background: "none",
                        color: "var(--color-text-secondary)",
                      }}
                      onClick={(e) => { e.stopPropagation(); api.downloadCapture(f.filename); }}
                    >
                      ↓
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <button
        style={{
          fontFamily: "var(--font-mono, monospace)",
          fontSize: 11,
          padding: "4px 10px",
          border: "0.5px solid var(--color-border-secondary)",
          borderRadius: 4,
          cursor: "pointer",
          background: "none",
          color: "var(--color-text-secondary)",
          alignSelf: "flex-start",
        }}
        onClick={() => api.listCaptures().then((r) => setFiles(r.files ?? [])).catch(() => {})}
      >
        REFRESH
      </button>

      {/* Cycle navigator */}
      {fileInfo && (
        <div style={{ borderTop: "0.5px solid var(--color-border-tertiary)", paddingTop: 10 }}>
          <div style={{ fontSize: 10, letterSpacing: "0.1em", color: "var(--color-text-secondary)", marginBottom: 8, ...MONO }}>
            CYCLE NAVIGATOR
          </div>

          {/* File metadata summary */}
          <div style={{ fontSize: 10, color: "var(--color-text-secondary)", marginBottom: 10, ...MONO, lineHeight: 1.6 }}>
            <div>{fileInfo.timestamp}</div>
            <div>{fileInfo.rpm != null ? `${Math.round(fileInfo.rpm)} RPM` : ""} · {fileInfo.n_cycles} cycles</div>
          </div>

          {/* Arrow navigator */}
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <button
              style={btnStyle(loading || cycleIdx === 0)}
              disabled={loading || cycleIdx === 0}
              onClick={() => goTo(cycleIdx - 1)}
              aria-label="Previous cycle"
            >
              ◀
            </button>
            <span style={{ fontSize: 13, fontWeight: 500, color: "var(--color-text-primary)", minWidth: 70, textAlign: "center", ...MONO }}>
              {loading ? "..." : `${cycleIdx + 1} / ${fileInfo.n_cycles}`}
            </span>
            <button
              style={btnStyle(loading || cycleIdx >= fileInfo.n_cycles - 1)}
              disabled={loading || cycleIdx >= fileInfo.n_cycles - 1}
              onClick={() => goTo(cycleIdx + 1)}
              aria-label="Next cycle"
            >
              ▶
            </button>
          </div>
          <div style={{ fontSize: 10, color: "var(--color-text-secondary)", marginTop: 6, ...MONO }}>
            ← → keyboard shortcuts
          </div>
        </div>
      )}

      {message && (
        <div style={{
          fontSize: 11,
          padding: "5px 8px",
          borderRadius: 4,
          background: "var(--color-background-danger)",
          color: "var(--color-text-danger)",
          ...MONO,
        }}>
          {message.text}
        </div>
      )}
    </div>
  );
}
