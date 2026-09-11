export const NATIVE_HOST = "com.hermes.app";

export class NativeCompanion {
  constructor(ext, onStealthChanged = () => {}) {
    this.ext = ext;
    this.onStealthChanged = onStealthChanged;
    this.port = null;
    this.ready = null;
    this.readyResolve = null;
    this.readyReject = null;
    this.pending = new Map();
    this.nextId = 1;
  }

  async activate(settings) {
    return this.request("SET_STEALTH", { enabled: true, settings });
  }

  async deactivate() {
    if (!this.port) return { ok: true };
    const result = await this.request("SET_STEALTH", { enabled: false });
    this.disconnect();
    return result;
  }

  async toggle(settings) {
    return this.request("TOGGLE", { settings });
  }

  async command(command, settings) {
    return this.request("COMMAND", { command, settings });
  }

  async request(type, payload = {}) {
    try {
      await this.connect();
      const id = this.nextId++;
      return await new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          resolve({ ok: false, error: "Hermes desktop companion did not respond" });
          this.disconnect();
        }, 3000);
        this.pending.set(id, { resolve, timer });
        try {
          this.port.postMessage({ id, type, ...payload });
        } catch (error) {
          clearTimeout(timer);
          this.pending.delete(id);
          resolve({ ok: false, error: String(error?.message || error) });
        }
      });
    } catch (error) {
      return { ok: false, error: String(error?.message || error || "Hermes desktop companion is unavailable") };
    }
  }

  connect() {
    if (this.port && this.ready) return this.ready;
    if (typeof this.ext.runtime.connectNative !== "function") {
      return Promise.reject(new Error("Native Messaging is unavailable in this browser"));
    }
    try {
      this.port = this.ext.runtime.connectNative(NATIVE_HOST);
    } catch (error) {
      this.port = null;
      return Promise.reject(error);
    }
    this.ready = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
      const timer = setTimeout(() => {
        reject(new Error("Hermes desktop companion did not start"));
        this.disconnect();
      }, 4000);
      this.readyTimer = timer;
    });
    this.port.onMessage.addListener((message) => this.handleMessage(message));
    this.port.onDisconnect.addListener(() => this.handleDisconnect());
    return this.ready;
  }

  handleMessage(message) {
    if (message?.type === "READY") {
      clearTimeout(this.readyTimer);
      this.readyResolve?.(message);
      return;
    }
    if (message?.type === "STEALTH_CHANGED") {
      Promise.resolve(this.onStealthChanged(Boolean(message.enabled))).catch(() => {});
      return;
    }
    if (message?.type !== "RESPONSE" || !this.pending.has(message.id)) return;
    const pending = this.pending.get(message.id);
    clearTimeout(pending.timer);
    this.pending.delete(message.id);
    pending.resolve(message);
  }

  handleDisconnect() {
    clearTimeout(this.readyTimer);
    const error = this.ext.runtime.lastError?.message || "Hermes desktop companion disconnected";
    this.readyReject?.(new Error(error));
    for (const { resolve, timer } of this.pending.values()) {
      clearTimeout(timer);
      resolve({ ok: false, error });
    }
    this.pending.clear();
    this.port = null;
    this.ready = null;
    this.readyResolve = null;
    this.readyReject = null;
  }

  disconnect() {
    try { this.port?.disconnect(); } catch { /* already disconnected */ }
  }
}
