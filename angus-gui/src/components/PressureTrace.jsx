import React, { useEffect, useRef, useCallback } from "react";
import createRegl from "regl";

const MONOSPACE = "'JetBrains Mono', 'Fira Mono', monospace";
const POINT_SIZE = 2.0;
const POINT_COLOR = [0.216, 0.478, 0.675, 0.85]; // #378ADD with alpha

// TDC-centre transform: 0..719.9 → -360..+360, normalised to -1..+1 for WebGL
// Y: 0..4095 counts → 0..+1 (top of clip space = max pressure)
function buildVertices(xs, ys, calFactor, yMin, yMax) {
  const n = xs.length;
  const verts = new Float32Array(n * 2);
  const invX = 1 / 360;
  const yRange = yMax - yMin || 1;
  for (let i = 0; i < n; i++) {
    const tdc = ((xs[i] + 360) % 720) - 360;
    verts[i * 2]     = tdc * invX;
    verts[i * 2 + 1] = ((ys[i] * calFactor - yMin) / yRange) * 2 - 1;
  }
  return verts;
}

// Cycle data [{tdc_deg, pressure}] → Float32Arrays
function cycleToArrays(cycleData) {
  const n = cycleData.length;
  const xs = new Float32Array(n);
  const ys = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    xs[i] = cycleData[i].tdc_deg;
    ys[i] = cycleData[i].pressure;
  }
  return { xs, ys };
}

export function PressureTrace({ scatterX, scatterY, cycleData, frozen, calFactor = 1, decayAlpha = 0.02,
  yMin: yMinProp, yMax: yMaxProp, onRescale }) {
  const canvasRef = useRef(null);
  const reglRef = useRef(null);
  const drawRef = useRef(null);
  const positionRef = useRef(null);
  const pointCountRef = useRef(0);
  const yMaxRef = useRef(4096);
  const yMinRef = useRef(0);
  const autoScaleRef = useRef(true); // whether filtered auto-scale is active
  const frozenRef = useRef(frozen);
  frozenRef.current = frozen;

  // Called by parent's "RESCALE" button -- snap EMA to current observed range
  useEffect(() => {
    if (onRescale) {
      onRescale.current = () => {
        autoScaleRef.current = true;
        yMaxRef.current = 4096;
        yMinRef.current = 0;
      };
    }
  }, [onRescale]);

  // Axis canvas for labels (drawn on a 2D overlay)
  const axisRef = useRef(null);

  const drawAxis = useCallback((yMin, yMax) => {
    const canvas = axisRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);

    const tickCol = "#5F5E5A";
    const gridCol = "rgba(0,0,0,0.07)";
    ctx.font = `10px ${MONOSPACE}`;
    ctx.fillStyle = tickCol;
    ctx.strokeStyle = gridCol;
    ctx.lineWidth = 0.5;

    const plotH = h - 20;
    const yRange = yMax - yMin || 1;

    // X axis ticks
    const xTicks = [-360, -270, -180, -90, 0, 90, 180, 270, 360];
    xTicks.forEach((deg) => {
      const px = ((deg + 360) / 720) * w;
      ctx.beginPath();
      ctx.moveTo(px, 0);
      ctx.lineTo(px, plotH);
      ctx.stroke();
      ctx.fillText(`${deg}°`, px + 2, h - 6);
    });

    // Y axis ticks: 5 evenly spaced between yMin and yMax
    [0, 0.25, 0.5, 0.75, 1.0].forEach((frac) => {
      const val = Math.round(yMin + frac * yRange);
      const py = plotH - frac * plotH;
      ctx.beginPath();
      ctx.moveTo(30, py);
      ctx.lineTo(w, py);
      ctx.stroke();
      ctx.fillText(String(val), 2, py + 4);
    });
  }, []);

  // Initialise regl
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    // Set canvas dimensions to match CSS size before creating regl context
    const rect = canvas.getBoundingClientRect();
    canvas.width = rect.width || canvas.clientWidth || 800;
    canvas.height = rect.height || canvas.clientHeight || 300;
    if (axisRef.current) {
      axisRef.current.width = canvas.width;
      axisRef.current.height = canvas.height;
    }

    const regl = createRegl({
      canvas,
      attributes: { antialias: false, alpha: true },
    });
    reglRef.current = regl;

    // Allocate buffer large enough for max block size (14400 samples * 2 floats)
    positionRef.current = regl.buffer({
      data: new Float32Array(14400 * 2),
      usage: "dynamic",
    });

    // Point sprite shader
    drawRef.current = regl({
      vert: `
        precision mediump float;
        attribute vec2 position;
        uniform float pointSize;
        void main() {
          gl_Position = vec4(position, 0.0, 1.0);
          gl_PointSize = pointSize;
        }
      `,
      frag: `
        precision mediump float;
        uniform vec4 color;
        void main() {
          // Circular point sprite
          vec2 coord = gl_PointCoord * 2.0 - 1.0;
          if (dot(coord, coord) > 1.0) discard;
          gl_FragColor = color;
        }
      `,
      attributes: {
        position: () => positionRef.current,
      },
      uniforms: {
        color: POINT_COLOR,
        pointSize: POINT_SIZE,
      },
      count: () => pointCountRef.current,
      primitive: "points",
      blend: {
        enable: true,
        func: { src: "src alpha", dst: "one minus src alpha" },
      },
    });

    drawAxis(yMinRef.current, yMaxRef.current);

    return () => {
      regl.destroy();
      reglRef.current = null;
      drawRef.current = null;
    };
  }, [drawAxis]);

  // Update data
  useEffect(() => {
    if (frozenRef.current) return;
    const regl = reglRef.current;
    if (!regl || !drawRef.current) return;

    let xs, ys;
    if (cycleData && cycleData.length > 0) {
      ({ xs, ys } = cycleToArrays(cycleData));
    } else if (scatterX && scatterY && scatterX.length > 0) {
      xs = scatterX;
      ys = scatterY;
    } else {
      return;
    }

    // Asymmetric auto-scale: instant on increase (catches knock), slow decay
    if (autoScaleRef.current) {
      let obsMax = 0, obsMin = Infinity;
      for (let i = 0; i < ys.length; i++) {
        const v = ys[i] * calFactor;
        if (v > obsMax) obsMax = v;
        if (v < obsMin) obsMin = v;
      }
      const targetMax = obsMax * 1.1;
      const targetMin = obsMin * 0.9;
      // Rise instantly, decay slowly at user-controlled alpha
      yMaxRef.current = targetMax > yMaxRef.current
        ? targetMax
        : yMaxRef.current + decayAlpha * (targetMax - yMaxRef.current);
      yMinRef.current = targetMin < yMinRef.current
        ? targetMin
        : yMinRef.current + decayAlpha * (targetMin - yMinRef.current);
      drawAxis(yMinRef.current, yMaxRef.current);
    }

    const verts = buildVertices(xs, ys, calFactor, yMinRef.current, yMaxRef.current);
    positionRef.current.subdata(verts);
    pointCountRef.current = xs.length;

    regl.clear({ color: [0.945, 0.941, 0.910, 1], depth: 1 }); // matches --color-background-primary
    drawRef.current();
  }, [scatterX, scatterY, cycleData, calFactor, drawAxis]);

  // Handle canvas resize
  useEffect(() => {
    const canvas = canvasRef.current;
    const axis = axisRef.current;
    if (!canvas) return;
    const ro = new ResizeObserver(() => {
      const { width, height } = canvas.getBoundingClientRect();
      canvas.width = width;
      canvas.height = height;
      if (axis) { axis.width = width; axis.height = height; }
      drawAxis(yMinRef.current, yMaxRef.current);
      // Redraw if we have data
      if (reglRef.current && drawRef.current && pointCountRef.current > 0) {
        reglRef.current.clear({ color: [0.945, 0.941, 0.910, 1], depth: 1 });
        drawRef.current();
      }
    });
    ro.observe(canvas);
    return () => ro.disconnect();
  }, [drawAxis]);

  return (
    <div style={{ position: "relative", width: "100%", height: "100%", minHeight: 220 }}>
      {/* regl WebGL canvas */}
      <canvas
        ref={canvasRef}
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
        aria-label="Cylinder pressure WebGL scatter plot, crank angle -360 to +360 degrees, TDC at 0"
      />
      {/* 2D axis overlay */}
      <canvas
        ref={axisRef}
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%", pointerEvents: "none" }}
      />
    </div>
  );
}
