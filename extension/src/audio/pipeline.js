export class AudioCapturePipeline {
  constructor({ stream, onTranscript, onError = () => {}, getSettings }) {
    this.stream = stream;
    this.onTranscript = onTranscript;
    this.onError = onError;
    this.getSettings = getSettings;
    this.context = null;
    this.worker = null;
    this.source = null;
    this.node = null;
    this.pendingSegments = [];
    this.transcribing = false;
    this.drainPromise = null;
    this.stopping = false;
  }

  async start({ monitor = false } = {}) {
    this.context = new AudioContext({ latencyHint: "interactive" });
    await this.context.audioWorklet.addModule(runtimeUrl("src/audio/audio-worklet.js"));
    this.worker = new Worker(runtimeUrl("src/audio/audio-worker.js"));
    const ring = createRing(this.context.sampleRate);
    this.worker.postMessage({ type: "init", inputRate: this.context.sampleRate, targetRate: 16000, ring });
    this.worker.onmessage = ({ data }) => {
      if (data.type === "segment") this.queueSegment(data.wav);
      if (data.type === "stopped") this.resolveStopped?.();
    };
    this.source = this.context.createMediaStreamSource(this.stream);
    this.node = new AudioWorkletNode(this.context, "hermes-capture", { processorOptions: { ring } });
    this.node.port.onmessage = ({ data }) => {
      if (data?.type === "samples" && this.worker) {
        this.worker.postMessage(data, [data.samples.buffer]);
      }
    };
    this.source.connect(this.node);
    const sink = this.context.createGain();
    sink.gain.value = 0;
    this.node.connect(sink).connect(this.context.destination);
    if (monitor) this.source.connect(this.context.destination);
    for (const track of this.stream.getTracks()) track.addEventListener("ended", () => this.stop(), { once: true });
    await this.context.resume();
  }

  queueSegment(wav) {
    if (this.pendingSegments.length >= 2) this.pendingSegments.shift();
    this.pendingSegments.push(wav);
    if (!this.transcribing) this.drainPromise = this.drainSegments();
  }

  async drainSegments() {
    this.transcribing = true;
    while (this.pendingSegments.length) {
      const wav = this.pendingSegments.shift();
      try {
        const text = await this.transcribe(wav);
        if (text) this.onTranscript(text);
      } catch (error) {
        this.onError(String(error?.message || error));
      }
    }
    this.transcribing = false;
  }

  async transcribe(wav) {
    const settings = await this.getSettings();
    const apiKey = settings?.apiKeys?.Groq;
    if (!apiKey) throw new Error("A Groq API key is required for transcription");
    const form = new FormData();
    form.set("file", new Blob([wav], { type: "audio/wav" }), "hermes.wav");
    form.set("model", "whisper-large-v3-turbo");
    form.set("response_format", "json");
    if (settings.speechLocale) form.set("language", settings.speechLocale.split("-")[0]);
    const response = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}` },
      body: form,
      signal: AbortSignal.timeout?.(20_000),
    });
    if (!response.ok) throw new Error(`Transcription failed (${response.status})`);
    return String((await response.json()).text ?? "").trim();
  }

  async stop() {
    if (this.stopping) return;
    this.stopping = true;
    const stopped = new Promise((resolve) => { this.resolveStopped = resolve; });
    this.worker?.postMessage({ type: "stop" });
    await Promise.race([stopped, new Promise((resolve) => setTimeout(resolve, 300))]);
    this.source?.disconnect();
    this.node?.disconnect();
    for (const track of this.stream?.getTracks() ?? []) track.stop();
    await this.context?.close().catch(() => {});
    this.worker?.terminate();
    await this.drainPromise?.catch(() => {});
    this.worker = null;
    this.context = null;
    this.source = null;
    this.node = null;
    this.pendingSegments.length = 0;
    this.stopping = false;
  }
}

function createRing(sampleRate) {
  if (!globalThis.SharedArrayBuffer || !globalThis.crossOriginIsolated) return undefined;
  const controlBytes = Int32Array.BYTES_PER_ELEMENT * 4;
  const sampleBytes = Int16Array.BYTES_PER_ELEMENT * Math.ceil(sampleRate * 8);
  return new SharedArrayBuffer(controlBytes + sampleBytes);
}

function runtimeUrl(path) {
  const api = globalThis.browser ?? globalThis.chrome;
  return api.runtime.getURL(path);
}
