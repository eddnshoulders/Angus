import React from "react";

const MONO = { fontFamily: "'JetBrains Mono', monospace" };

function MetricCard({ label, value, unit, note, noteColor }) {
  return (
    <div
      style={{
        background: "var(--color-background-secondary)",
        borderRadius: 6,
        padding: "10px 10px 8px",
      }}
    >
      <div
        style={{
          fontSize: 10,
          color: "var(--color-text-secondary)",
          letterSpacing: "0.06em",
          marginBottom: 4,
          ...MONO,
        }}
      >
        {label}
      </div>
      <div style={{ display: "flex", alignItems: "baseline", gap: 3 }}>
        <span style={{ fontSize: 20, fontWeight: 500, color: "var(--color-text-primary)", ...MONO }}>
          {value ?? "—"}
        </span>
        {unit && (
          <span style={{ fontSize: 10, color: "var(--color-text-secondary)", ...MONO }}>{unit}</span>
        )}
      </div>
      {note && (
        <div style={{ fontSize: 10, marginTop: 4, color: noteColor ?? "var(--color-text-secondary)", ...MONO }}>
          {note}
        </div>
      )}
    </div>
  );
}

function RowStat({ label, value }) {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        alignItems: "center",
        padding: "5px 0",
        borderBottom: "0.5px solid var(--color-border-tertiary)",
        ...MONO,
      }}
    >
      <span style={{ fontSize: 11, color: "var(--color-text-secondary)" }}>{label}</span>
      <span style={{ fontSize: 11, fontWeight: 500, color: "var(--color-text-primary)" }}>
        {value ?? "—"}
      </span>
    </div>
  );
}

function SectionLabel({ children }) {
  return (
    <div
      style={{
        fontSize: 10,
        letterSpacing: "0.1em",
        color: "var(--color-text-secondary)",
        fontWeight: 500,
        marginBottom: 6,
        ...MONO,
      }}
    >
      {children}
    </div>
  );
}

const SEP = (
  <div
    style={{
      borderTop: "0.5px solid var(--color-border-tertiary)",
      paddingTop: 10,
      marginTop: 4,
    }}
  />
);

export function MetricsPanel({ metrics, covMetrics, calFactor }) {
  const pressureUnit = calFactor === 1 ? "cts" : "bar";

  const pmaxVal = metrics?.pmax != null ? metrics.pmax.toFixed(1) : null;
  const pmaxAngleVal = metrics?.pmaxAngle != null ? metrics.pmaxAngle.toFixed(1) : null;
  const ca50Val = metrics?.mfb50 != null ? metrics.mfb50.toFixed(1) : null;
  const imepVal = metrics?.imepProxy != null ? metrics.imepProxy.toFixed(1) : null;

  const mfb10 = metrics?.mfb10 != null ? `${metrics.mfb10.toFixed(1)}°` : null;
  const mfb50 = metrics?.mfb50 != null ? `${metrics.mfb50.toFixed(1)}°` : null;
  const mfb90 = metrics?.mfb90 != null ? `${metrics.mfb90.toFixed(1)}°` : null;
  const burnDur = metrics?.burnDuration != null ? `${metrics.burnDuration.toFixed(1)}°` : null;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
      <SectionLabel>COMBUSTION METRICS</SectionLabel>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 12 }}>
        <MetricCard label="PMAX" value={pmaxVal} unit={pressureUnit} />
        <MetricCard label="PMAX ANGLE" value={pmaxAngleVal} unit="°CA" />
        <MetricCard label="CA50" value={ca50Val} unit="°CA" />
        <MetricCard label="IMEP INDEX" value={imepVal} unit="" />
      </div>

      {SEP}
      <SectionLabel>MFB</SectionLabel>
      <RowStat label="MFB 10%" value={mfb10} />
      <RowStat label="MFB 50% (CA50)" value={mfb50} />
      <RowStat label="MFB 90%" value={mfb90} />
      <RowStat
        label="Burn duration"
        value={burnDur}
        style={{ borderBottom: "none" }}
      />

      {SEP}
      <SectionLabel>CYCLE VARIATION</SectionLabel>
      <RowStat label="CoV Pmax" value={covMetrics?.covPmax != null ? `${covMetrics.covPmax.toFixed(2)}%` : null} />
      <RowStat label="CoV CA50" value={covMetrics?.covCa50 != null ? `${covMetrics.covCa50.toFixed(2)}°` : null} />
      <RowStat label="N cycles" value={covMetrics?.nCycles ?? null} />
    </div>
  );
}
