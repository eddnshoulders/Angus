import React, { useState, useCallback } from "react";

const MONO = { fontFamily: "'JetBrains Mono', monospace" };

// Server returns {read: [{name,addr,msb,lsb,description,readable,writable,value}, ...], write: [...]}
// We merge them into a single deduplicated list keyed by name.
function mergeRegisters(data) {
  const map = {};
  for (const reg of [...(data.read ?? []), ...(data.write ?? [])]) {
    if (!map[reg.name]) map[reg.name] = reg;
    else map[reg.name] = { ...map[reg.name], ...reg };
  }
  return Object.values(map).sort((a, b) => a.addr - b.addr);
}

export function RegisterViewer({ api }) {
  const [registers, setRegisters] = useState(null); // flat sorted array
  const [loading, setLoading] = useState(false);
  const [editName, setEditName] = useState("");
  const [editVal, setEditVal] = useState("");
  const [filter, setFilter] = useState("");
  const [message, setMessage] = useState(null);

  const fetchRegisters = useCallback(async () => {
    setLoading(true);
    setMessage(null);
    try {
      const res = await api.registers();
      setRegisters(mergeRegisters(res));
    } catch (e) {
      setMessage({ ok: false, text: e.message });
    } finally {
      setLoading(false);
    }
  }, [api]);

  async function handleWrite() {
    if (!editName || editVal === "") return;
    setMessage(null);
    try {
      const res = await api.setRegister(editName, parseInt(editVal, 0));
      setMessage({ ok: true, text: `${res.name} \u2190 0x${res.value.toString(16).toUpperCase()}` });
      // Update the cached value in the table
      setRegisters((prev) =>
        prev ? prev.map((r) => (r.name === res.name ? { ...r, value: res.value } : r)) : prev
      );
    } catch (e) {
      setMessage({ ok: false, text: e.message });
    }
  }

  async function handleRefreshOne(name) {
    try {
      const res = await api.register(name);
      setRegisters((prev) =>
        prev ? prev.map((r) => (r.name === name ? { ...r, value: res.value } : r)) : prev
      );
    } catch {
      // silently ignore
    }
  }

  const displayed = registers
    ? registers.filter(
        (r) =>
          !filter ||
          r.name.toLowerCase().includes(filter.toLowerCase()) ||
          (r.description ?? "").toLowerCase().includes(filter.toLowerCase())
      )
    : null;

  const labelStyle = {
    fontSize: 10,
    color: "var(--color-text-secondary)",
    letterSpacing: "0.1em",
    marginBottom: 6,
    ...MONO,
  };

  const inputStyle = {
    fontFamily: "var(--font-mono, monospace)",
    fontSize: 11,
    padding: "3px 6px",
    border: "0.5px solid var(--color-border-secondary)",
    borderRadius: 4,
    background: "var(--color-background-secondary)",
    color: "var(--color-text-primary)",
  };

  const btnStyle = (primary) => ({
    fontFamily: "var(--font-mono, monospace)",
    fontSize: 11,
    padding: "4px 10px",
    border: primary ? "none" : "0.5px solid var(--color-border-secondary)",
    borderRadius: 4,
    background: primary ? "#185FA5" : "none",
    color: primary ? "#E6F1FB" : "var(--color-text-secondary)",
    cursor: "pointer",
  });

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
        <div style={{ ...labelStyle, marginBottom: 0 }}>REGISTERS</div>
        <div style={{ flex: 1 }} />
        <button style={btnStyle(true)} onClick={fetchRegisters} disabled={loading}>
          {loading ? "..." : "FETCH"}
        </button>
      </div>

      {registers && (
        <input
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="filter..."
          style={{ ...inputStyle, width: "100%" }}
        />
      )}

      {displayed && (
        <div
          style={{
            maxHeight: 240,
            overflowY: "auto",
            border: "0.5px solid var(--color-border-tertiary)",
            borderRadius: 6,
          }}
        >
          <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 10, ...MONO }}>
            <thead>
              <tr
                style={{
                  borderBottom: "0.5px solid var(--color-border-tertiary)",
                  background: "var(--color-background-secondary)",
                  position: "sticky",
                  top: 0,
                }}
              >
                <th style={{ padding: "4px 6px", textAlign: "left", color: "var(--color-text-secondary)", fontWeight: 500 }}>NAME</th>
                <th style={{ padding: "4px 6px", textAlign: "right", color: "var(--color-text-secondary)", fontWeight: 500 }}>HEX</th>
                <th style={{ padding: "4px 4px", textAlign: "center", color: "var(--color-text-secondary)", fontWeight: 500 }}>R/W</th>
              </tr>
            </thead>
            <tbody>
              {displayed.map((reg, i) => (
                <tr
                  key={reg.name}
                  title={`${reg.description ?? ""} (addr 0x${reg.addr.toString(16).toUpperCase().padStart(3, "0")})`}
                  style={{
                    borderBottom: "0.5px solid var(--color-border-tertiary)",
                    background: i % 2 === 0 ? "transparent" : "var(--color-background-secondary)",
                    cursor: reg.writable ? "pointer" : "default",
                  }}
                  onClick={() => {
                    if (reg.writable) {
                      setEditName(reg.name);
                      setEditVal(reg.value != null ? String(reg.value) : "");
                    }
                    if (reg.readable) handleRefreshOne(reg.name);
                  }}
                >
                  <td style={{ padding: "3px 6px", color: "var(--color-text-primary)" }}>{reg.name}</td>
                  <td style={{ padding: "3px 6px", textAlign: "right", color: reg.value != null ? "var(--color-text-primary)" : "var(--color-text-secondary)" }}>
                    {reg.value != null
                      ? `0x${reg.value.toString(16).toUpperCase().padStart(8, "0")}`
                      : "—"}
                  </td>
                  <td style={{ padding: "3px 4px", textAlign: "center", color: "var(--color-text-secondary)" }}>
                    {reg.readable ? "R" : ""}{reg.writable ? "W" : ""}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Write form */}
      <div style={{ borderTop: "0.5px solid var(--color-border-tertiary)", paddingTop: 8 }}>
        <div style={{ ...labelStyle }}>WRITE REGISTER</div>
        <div style={{ display: "flex", gap: 5, alignItems: "center" }}>
          <input
            value={editName}
            onChange={(e) => setEditName(e.target.value.toUpperCase())}
            placeholder="NAME"
            style={{ ...inputStyle, flex: 1 }}
          />
          <input
            value={editVal}
            onChange={(e) => setEditVal(e.target.value)}
            placeholder="value"
            style={{ ...inputStyle, width: 72 }}
          />
          <button
            style={{ ...btnStyle(false), borderColor: "#185FA5", color: "#185FA5" }}
            onClick={handleWrite}
          >
            WRITE
          </button>
        </div>
        <div style={{ fontSize: 10, color: "var(--color-text-secondary)", marginTop: 4, ...MONO }}>
          accepts decimal or 0x hex · click a row to select
        </div>
      </div>

      {/* DMA controls */}
      <div style={{ borderTop: "0.5px solid var(--color-border-tertiary)", paddingTop: 8 }}>
        <div style={{ ...labelStyle }}>DMA</div>
        <div style={{ display: "flex", gap: 6 }}>
          <button
            style={btnStyle(false)}
            onClick={async () => {
              setMessage(null);
              try {
                const res = await api.dmaStatus();
                setMessage({ ok: true, text: `backend: ${res.backend}` });
              } catch (e) {
                setMessage({ ok: false, text: e.message });
              }
            }}
          >
            STATUS
          </button>
          <button
            style={{ ...btnStyle(false), color: "#A32D2D", borderColor: "#A32D2D" }}
            onClick={async () => {
              setMessage(null);
              try {
                await api.recoverDma();
                setMessage({ ok: true, text: "DMA recovery sent" });
              } catch (e) {
                setMessage({ ok: false, text: e.message });
              }
            }}
          >
            RECOVER
          </button>
        </div>
      </div>

      {message && (
        <div
          style={{
            fontSize: 11,
            padding: "5px 8px",
            borderRadius: 4,
            background: message.ok ? "var(--color-background-success)" : "var(--color-background-danger)",
            color: message.ok ? "var(--color-text-success)" : "var(--color-text-danger)",
            ...MONO,
            wordBreak: "break-all",
          }}
        >
          {message.text}
        </div>
      )}
    </div>
  );
}
