import React from "react";

const DOT = {
  ok: "#639922",
  warn: "#BA7517",
  err: "#E24B4A",
  off: "#888780",
};

function Dot({ color }) {
  return (
    <span
      style={{
        display: "inline-block",
        width: 7,
        height: 7,
        borderRadius: "50%",
        background: color,
        flexShrink: 0,
      }}
    />
  );
}

function Item({ label, value, dot }) {
  return (
    <span
      style={{
        display: "flex",
        alignItems: "center",
        gap: 5,
        fontSize: 11,
        fontFamily: "var(--font-mono, monospace)",
      }}
    >
      {dot && <Dot color={DOT[dot]} />}
      <span style={{ color: "var(--color-text-secondary)" }}>{label}</span>
      {value !== undefined && (
        <span style={{ color: "var(--color-text-primary)", fontWeight: 500 }}>
          {value}
        </span>
      )}
    </span>
  );
}

export function StatusBar({ wsStatus, status, cycleCount }) {
  const wsColor =
    wsStatus === "connected" ? "ok" : wsStatus === "connecting" || wsStatus === "reconnecting" ? "warn" : "err";

  const pllOk = status?.pll_locked !== false;
  const tdcOk = status?.tdc_synced !== false;
  const rpm = status?.rpm != null ? Math.round(status.rpm) : "—";
  const pktRate = status?.packet_rate != null ? status.packet_rate.toFixed(1) + " kHz" : "—";

  return (
    <div
      style={{
        background: "var(--color-background-secondary)",
        borderBottom: "0.5px solid var(--color-border-tertiary)",
        padding: "0 16px",
        height: 32,
        display: "flex",
        alignItems: "center",
        gap: 20,
        flexShrink: 0,
        overflowX: "auto",
      }}
    >
      <Item label="WS" value={wsStatus.toUpperCase()} dot={wsColor} />
      <Item label="PLL" value={pllOk ? "LOCK" : "UNLK"} dot={pllOk ? "ok" : "err"} />
      <Item label="TDC" value={tdcOk ? "SYNC" : "WAIT"} dot={tdcOk ? "ok" : "warn"} />
      <Item label="PKT" value={pktRate} />
      <Item label="RPM" value={rpm} />
      <Item label="CYCLES" value={cycleCount ?? "—"} />
    </div>
  );
}
