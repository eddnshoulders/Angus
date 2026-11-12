// All metrics computed from an array of {tdc_deg, pressure} samples.
// pressure is raw XADC counts — apply calFactor (bar/count) to convert.
// Set calFactor = 1 to work in raw counts until you have calibration data.

export function computeMetrics(samples, calFactor = 1) {
  if (!samples || samples.length < 10) return null;

  // Sort by crank angle (tdc_deg)
  const pts = [...samples]
    .filter((s) => s.tdc_deg != null && s.pressure != null)
    .sort((a, b) => a.tdc_deg - b.tdc_deg);

  if (pts.length < 10) return null;

  const angles = pts.map((p) => p.tdc_deg);
  const pressures = pts.map((p) => p.pressure * calFactor);

  // --- Pmax ---
  let pmaxIdx = 0;
  for (let i = 1; i < pressures.length; i++) {
    if (pressures[i] > pressures[pmaxIdx]) pmaxIdx = i;
  }
  const pmax = pressures[pmaxIdx];
  const pmaxAngle = angles[pmaxIdx];

  // --- IMEP (trapezoidal integration of p dV, simplified to p dθ proxy) ---
  // For a real IMEP you need bore/stroke/con-rod geometry. This gives a
  // proportional index useful for cycle-to-cycle comparison.
  let imepProxy = 0;
  for (let i = 1; i < pts.length; i++) {
    const dTheta = (angles[i] - angles[i - 1]) * (Math.PI / 180);
    imepProxy += 0.5 * (pressures[i] + pressures[i - 1]) * dTheta;
  }

  // --- Heat release (Rassweiler-Withrow approximation for MFB) ---
  // Uses pressure rise ratio as a proxy for cumulative heat release.
  // Works in angle-sorted order over the combustion window (300–450° CA).
  const combStart = 300, combEnd = 450;
  const combPts = pts.filter(
    (p) => p.tdc_deg >= combStart && p.tdc_deg <= combEnd
  );

  let mfb10Angle = null, mfb50Angle = null, mfb90Angle = null;

  if (combPts.length > 5) {
    const pMin = Math.min(...combPts.map((p) => p.pressure * calFactor));
    const pMax = Math.max(...combPts.map((p) => p.pressure * calFactor));
    const pRange = pMax - pMin || 1;

    const cumMfb = combPts.map((p) => (p.pressure * calFactor - pMin) / pRange);

    for (let i = 0; i < cumMfb.length; i++) {
      if (mfb10Angle == null && cumMfb[i] >= 0.1) mfb10Angle = combPts[i].tdc_deg;
      if (mfb50Angle == null && cumMfb[i] >= 0.5) mfb50Angle = combPts[i].tdc_deg;
      if (mfb90Angle == null && cumMfb[i] >= 0.9) mfb90Angle = combPts[i].tdc_deg;
    }
  }

  const burnDuration =
    mfb10Angle != null && mfb90Angle != null
      ? mfb90Angle - mfb10Angle
      : null;

  return {
    pmax: +pmax.toFixed(1),
    pmaxAngle: +pmaxAngle.toFixed(1),
    imepProxy: +imepProxy.toFixed(1),
    mfb10: mfb10Angle != null ? +mfb10Angle.toFixed(1) : null,
    mfb50: mfb50Angle != null ? +mfb50Angle.toFixed(1) : null,
    mfb90: mfb90Angle != null ? +mfb90Angle.toFixed(1) : null,
    burnDuration: burnDuration != null ? +burnDuration.toFixed(1) : null,
    sampleCount: pts.length,
  };
}

// Coefficient of variation across an array of metric values
export function cov(values) {
  if (!values || values.length < 2) return null;
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  if (mean === 0) return null;
  const variance =
    values.reduce((a, b) => a + (b - mean) ** 2, 0) / values.length;
  return +((Math.sqrt(variance) / mean) * 100).toFixed(2);
}

// Split a flat samples array into per-cycle arrays using di (digital input) rising edges
// or, if di is absent/constant, by tdc_deg wrapping past 0°.
export function splitCycles(samples) {
  if (!samples || samples.length === 0) return [];

  const cycles = [];
  let current = [];
  let prevAngle = null;

  for (const s of samples) {
    if (prevAngle !== null && s.tdc_deg < prevAngle - 180) {
      // angle wrapped — new cycle
      if (current.length > 5) cycles.push(current);
      current = [];
    }
    current.push(s);
    prevAngle = s.tdc_deg;
  }
  if (current.length > 5) cycles.push(current);
  return cycles;
}
