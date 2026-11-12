// All calls go to http://<host>/...
// host should be e.g. "pynq:8000" or "192.168.2.99:8000"

export class AngusApi {
  constructor(host) {
    this.base = `http://${host}`;
  }

  async get(path) {
    const r = await fetch(`${this.base}${path}`);
    if (!r.ok) throw new Error(`GET ${path} → ${r.status}`);
    return r.json();
  }

  async post(path, body = null) {
    const r = await fetch(`${this.base}${path}`, {
      method: "POST",
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!r.ok) throw new Error(`POST ${path} → ${r.status}`);
    return r.json();
  }

  async put(path, body) {
    const r = await fetch(`${this.base}${path}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error(`PUT ${path} → ${r.status}`);
    return r.json();
  }

  // --- health / status ---
  health()         { return this.get("/health"); }
  status()         { return this.get("/status"); }
  debugConfig()    { return this.get("/debug/config-status"); }
  lastStartup()    { return this.get("/debug/last-startup"); }

  // --- config ---
  applyNotebook()                    { return this.post("/config/notebook"); }
  applyStartup(params)               { return this.post("/config/startup", params); }
  applyRuntime(params)               { return this.post("/config/runtime", params); }
  getStartupConfig()                 { return this.get("/config/startup"); }
  getRuntimeConfig()                 { return this.get("/config/runtime"); }

  // --- captures ---
  listCaptures()                          { return this.get("/captures"); }
  saveCapture(nCycles, metadata)          { return this.post("/captures/save", { n_cycles: nCycles, ...metadata }); }
  getCaptureInfo(filename)                { return this.get(`/captures/${filename}`); }
  getCycle(filename, cycleIdx)            { return this.get(`/captures/${filename}/cycles/${cycleIdx}`); }
  downloadCapture(filename) {
    window.open(`${this.base}/captures/${filename}/download`, "_blank");
  }

  // --- dma ---
  dmaStatus()   { return this.get("/dma/status"); }
  recoverDma()  { return this.post("/dma/recover"); }

  // --- sync / faults ---
  waitSync(level = "full", timeout = 10) {
    return this.post(`/sync/wait?level=${level}&timeout=${timeout}`);
  }
  clearFaults() { return this.post("/faults/clear"); }

  // --- registers ---
  registers()                        { return this.get("/registers"); }
  register(name)                     { return this.get(`/registers/${name}`); }
  setRegister(name, value)           { return this.put(`/registers/${name}`, { value }); }
  rawRegister(addr)                  { return this.get(`/registers/raw/${addr}`); }
  setRawRegister(addr, value)        { return this.put("/registers/raw", { addr, value }); }
}
