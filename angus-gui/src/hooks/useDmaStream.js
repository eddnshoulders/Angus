import { useEffect, useRef, useCallback, useState } from "react";

const RECONNECT_DELAY_MS = 2000;
const TDC_LSB = 0.1;

export function useDmaStream({ host, samples = 14400, enabled = true, onBlock }) {
  const wsRef = useRef(null);
  const reconnectTimer = useRef(null);
  const mountedRef = useRef(true);
  const [status, setStatus] = useState("disconnected");

  const connect = useCallback(() => {
    if (!mountedRef.current || !enabled) return;

    // Binary mode: server sends raw DMA buffer bytes, no server-side decode
    const url = `ws://${host}/ws/dma?samples=${samples}&decoded=false&binary=true`;
    setStatus("connecting");

    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer"; // receive as ArrayBuffer, not Blob
    wsRef.current = ws;

    ws.onopen = () => {
      if (!mountedRef.current) return ws.close();
      setStatus("connected");
    };

    ws.onmessage = (evt) => {
      if (!mountedRef.current) return;
      if (!(evt.data instanceof ArrayBuffer)) return; // ignore any text frames

      // Decode: pairs of little-endian uint32 words
      // word0: tdc_deg_count (0.1 deg/LSB)
      // word1: [31:24] di, [15:4] pressure (12-bit XADC)
      const words = new Uint32Array(evt.data);
      const n = Math.floor(words.length / 2);
      if (n === 0) return;

      const xs = new Float32Array(n); // tdc_deg
      const ys = new Float32Array(n); // pressure counts

      for (let i = 0; i < n; i++) {
        xs[i] = words[i * 2] * TDC_LSB;
        ys[i] = (words[i * 2 + 1] >> 4) & 0x0FFF;
      }

      if (onBlock) onBlock(xs, ys, n);
    };

    ws.onerror = () => setStatus("error");

    ws.onclose = (evt) => {
      if (!mountedRef.current) return;
      // 1012 = DMA reconfigured, 1013 = DMA reconfiguring (pause window)
      const delay = (evt.code === 1012 || evt.code === 1013) ? 3500 : RECONNECT_DELAY_MS;
      setStatus("reconnecting");
      reconnectTimer.current = setTimeout(connect, delay);
    };
  }, [host, samples, enabled, onBlock]);

  useEffect(() => {
    mountedRef.current = true;
    if (enabled) connect();
    return () => {
      mountedRef.current = false;
      clearTimeout(reconnectTimer.current);
      wsRef.current?.close();
    };
  }, [connect, enabled]);

  const disconnect = useCallback(() => {
    clearTimeout(reconnectTimer.current);
    wsRef.current?.close(1000, "user disconnect");
    setStatus("disconnected");
  }, []);

  return { status, disconnect };
}
