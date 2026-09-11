import { DEFAULT_SETTINGS, LIMITS, PROVIDERS, normaliseSettings, parseAnswer, providerRequest } from "../shared/core.js";
import { HermesGPU } from "../render/gpu-renderer.js";
import { AudioCapturePipeline } from "../audio/pipeline.js";

const BAR_X = 106;
const BAR_WIDTH = 688;
const COMPOSE_WIDTH = 459;
const PANEL_TOP = 50;

export function removeStaleHermesRoot(rootDocument) {
  const existing = rootDocument.querySelector("hermes-extension-root");
  existing?.remove();
  return Boolean(existing);
}

export class HermesOverlay {
  constructor(ext) {
    this.ext = ext;
    this.host = null;
    this.shadow = null;
    this.gpu = null;
    this.visible = false;
    this.panel = null;
    this.settings = { ...DEFAULT_SETTINGS };
    this.attachments = [];
    this.documents = [];
    this.turns = [];
    this.answer = "";
    this.answerType = "none";
    this.historyIndex = -1;
    this.port = null;
    this.audio = null;
    this.listening = false;
    this.countdown = 0;
    this.cancelGeneration = 0;
    this.stageOffset = { x: 0, y: 0 };
    this.dragState = null;
  }

  async mount() {
    // A host from the previous extension context can survive an unpacked
    // extension reload. Its closed shadow root cannot be adopted by this
    // controller, so replace it before creating the new instance.
    removeStaleHermesRoot(document);
    const response = await this.ext.runtime.sendMessage({ type: "GET_SETTINGS" });
    this.settings = normaliseSettings(response?.settings);
    this.host = document.createElement("hermes-extension-root");
    if (this.settings.stealth) this.host.style.display = "none";
    this.shadow = this.host.attachShadow({ mode: "closed" });
    const parsed = new DOMParser().parseFromString(`<body><style>${styles}</style>${template()}</body>`, "text/html");
    this.shadow.append(...parsed.body.childNodes);
    document.documentElement.append(this.host);
    this.$("#shell").hidden = true;
    this.gpu = await new HermesGPU(this.$("#gpu")).init();
    this.bind();
    this.syncSettingsForm();
    this.updateStatus();
    this.renderGPU();
  }

  $(selector) { return this.shadow.querySelector(selector); }
  $$(selector) { return [...this.shadow.querySelectorAll(selector)]; }

  bind() {
    this.$$("[data-action]").forEach((element) => element.addEventListener("click", (event) => this.action(element.dataset.action, event)));
    this.$("#prompt").addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        this.send();
      }
    });
    this.$("#document-files").addEventListener("change", (event) => this.addFiles(event.target.files));
    this.$("#settings-form").addEventListener("input", () => this.$("#save-settings").disabled = false);
    this.$("#settings-provider").addEventListener("change", () => this.populateModels());
    this.$("#opacity").addEventListener("input", (event) => {
      this.$("#opacity-value").textContent = `${event.target.value}%`;
      this.$(".bar").style.opacity = String(Number(event.target.value) / 100);
    });
    this.$("#font-size").addEventListener("input", (event) => {
      this.$("#font-value").textContent = `${event.target.value} pt`;
      this.$("#answer-text").style.fontSize = `${event.target.value}px`;
    });
    this.$$(".nav-button").forEach((button) => button.addEventListener("click", () => this.showSettingsPane(button.dataset.pane)));
    const bar = this.$(".bar");
    bar.addEventListener("pointerdown", (event) => this.startDrag(event));
    bar.addEventListener("pointermove", (event) => this.moveDrag(event));
    bar.addEventListener("pointerup", (event) => this.endDrag(event));
    bar.addEventListener("pointercancel", (event) => this.endDrag(event));
    window.addEventListener("beforeunload", () => this.destroy(), { once: true });
  }

  startDrag(event) {
    if (event.button !== 0 || event.target.closest("button,input,textarea,select,a")) return;
    const bar = this.$(".bar");
    this.dragState = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      offsetX: this.stageOffset.x,
      offsetY: this.stageOffset.y,
      barRect: bar.getBoundingClientRect(),
    };
    bar.setPointerCapture(event.pointerId);
    bar.classList.add("dragging");
    event.preventDefault();
  }

  moveDrag(event) {
    const drag = this.dragState;
    if (!drag || drag.pointerId !== event.pointerId) return;
    const margin = 8;
    const dx = clampNumber(event.clientX - drag.startX, margin - drag.barRect.left, innerWidth - margin - drag.barRect.right);
    const dy = clampNumber(event.clientY - drag.startY, margin - drag.barRect.top, innerHeight - margin - drag.barRect.bottom);
    this.stageOffset.x = drag.offsetX + dx;
    this.stageOffset.y = drag.offsetY + dy;
    const stage = this.$("#stage");
    stage.style.setProperty("--hermes-x", `${this.stageOffset.x}px`);
    stage.style.setProperty("--hermes-y", `${this.stageOffset.y}px`);
  }

  endDrag(event) {
    if (!this.dragState || this.dragState.pointerId !== event.pointerId) return;
    const bar = this.$(".bar");
    if (bar.hasPointerCapture(event.pointerId)) bar.releasePointerCapture(event.pointerId);
    bar.classList.remove("dragging");
    this.dragState = null;
  }

  async action(name, event) {
    if (name === "discussion") return this.toggleDiscussion();
    if (name === "listen") return this.toggleListen();
    if (name === "questions") return this.send({ questions: true });
    if (name === "capture") return event.shiftKey ? this.captureDisplayRegion() : this.captureRegion();
    if (name === "tray") return this.flash(`${this.attachments.length} screenshot${this.attachments.length === 1 ? "" : "s"} queued`);
    if (name === "documents") return this.showPanel(this.panel === "documents" ? null : "documents");
    if (name === "history") return this.enterHistory();
    if (name === "settings") return this.showPanel(this.panel === "settings" ? null : "settings");
    if (name === "close-panel") return this.showPanel(null);
    if (name === "copy") return navigator.clipboard.writeText(this.answer);
    if (name === "type") return this.typeAnswer();
    if (name === "history-prev") return this.moveHistory(-1);
    if (name === "history-next") return this.moveHistory(1);
    if (name === "add-paste") return this.addPastedDocument();
    if (name === "upload-documents") return this.$("#document-files").click();
    if (name === "clear-documents") return this.clearDocuments();
    if (name === "save-settings") return this.saveSettings();
  }

  handleMessage(message) {
    if (message?.type === "TOGGLE_OVERLAY") this.toggle();
    if (message?.type === "STEALTH_STATE") this.setStealthMode(Boolean(message.enabled));
    if (message?.type === "TRANSCRIPT") this.appendTranscript(message.text);
    if (message?.type === "COMMAND") {
      if (message.command === "capture-region") {
        if (!this.visible) this.toggle();
        this.captureRegion();
      }
      if (message.command === "toggle-listen") this.toggleListen();
      if (message.command === "type-answer") this.typeAnswer();
    }
  }

  toggle() {
    if (this.settings.stealth) return;
    this.visible = !this.visible;
    this.$("#shell").hidden = !this.visible;
    if (!this.visible) this.showPanel(null);
  }

  setStealthMode(enabled) {
    this.settings.stealth = enabled;
    this.host.style.display = enabled ? "none" : "";
    if (!enabled) {
      this.visible = true;
      this.$("#shell").hidden = false;
      this.syncSettingsForm();
    }
  }

  showPanel(panel) {
    this.panel = panel;
    this.$("#answer-panel").hidden = panel !== "answer";
    this.$("#document-panel").hidden = panel !== "documents";
    this.$("#settings-panel").hidden = panel !== "settings";
    this.$("#stage").className = `stage ${panel || "bar-only"}`;
    this.renderGPU();
  }

  renderGPU() {
    const opacity = this.settings.overlayOpacity / 100;
    const rectangles = [
      { x: BAR_X, y: 0, width: COMPOSE_WIDTH, height: 46, radius: 23, color: [0.12, 0.12, 0.12, 0.92 * opacity] },
      { x: BAR_X + COMPOSE_WIDTH + 8, y: 0, width: 221, height: 46, radius: 23, color: [0.12, 0.12, 0.12, 0.92 * opacity] },
    ];
    if (this.panel === "answer") {
      rectangles.push({ x: BAR_X, y: PANEL_TOP, width: 688, height: 260, radius: 10, color: [0.25, 0.25, 0.25, 1] });
      rectangles.push({ x: BAR_X + 1, y: PANEL_TOP + 1, width: 686, height: 258, radius: 9, color: [0.10, 0.10, 0.10, 1] });
    } else if (this.panel === "documents") {
      rectangles.push({ x: BAR_X, y: PANEL_TOP, width: 688, height: 292, radius: 10, color: [0.10, 0.10, 0.10, 1] });
    } else if (this.panel === "settings") {
      rectangles.push({ x: 0, y: PANEL_TOP, width: 900, height: 510, radius: 12, color: [0.086, 0.086, 0.106, 1] });
    }
    this.gpu?.render(rectangles);
  }

  updateStatus() {
    const hasKey = Boolean(this.settings.apiKeys?.[this.settings.provider]);
    this.$("#status-dot").className = `status-dot ${hasKey ? "ready" : "blocked"}`;
    this.$("#status-dot").title = hasKey ? "Ready" : "Add an API key in Settings";
    this.$("#tray-badge").textContent = this.attachments.length || "";
    this.$("#document-badge").textContent = this.documents.length || "";
    this.$("#document-badge").hidden = this.documents.length === 0;
    this.$("#document-summary").textContent = this.documents.length
      ? `${this.documents.length} item${this.documents.length === 1 ? "" : "s"} · ${formatBytes(this.documents.reduce((sum, doc) => sum + doc.bytes, 0))}`
      : "No context attached";
    this.$("#document-names").textContent = this.documents.length
      ? this.documents.map((doc) => doc.name).join("  •  ")
      : "Paste source material below or upload UTF-8 text, Markdown, source-code, or JSON files.";
  }

  async send({ questions = false } = {}) {
    if (this.port) return;
    const instruction = this.$("#prompt").value.trim();
    if (!instruction && !this.attachments.length && !this.documents.length) return;
    if (questions && (!this.documents.length || !instruction)) return this.flash("Questions need document context and a teammate statement");
    if (this.discussion && !this.documents.length) return this.flash("Attach document context before Discussion Mode");
    if (this.discussion && !instruction) return this.flash("Add the teammate's current statement first");
    const current = {
      instruction,
      images: this.attachments.map((item) => item.dataUrl),
      documents: this.documents,
      discussion: this.discussion,
      questions,
    };
    const request = providerRequest(this.settings, this.turns, current);
    if (!request.apiKey) return this.flash("Add an API key in Settings");
    this.answer = "";
    this.answerType = "none";
    this.showPanel("answer");
    this.$("#answer-text").textContent = "";
    this.$("#spinner").hidden = false;
    this.port = this.ext.runtime.connect({ name: "hermes-ai" });
    this.port.onMessage.addListener((message) => {
      if (message.type === "DELTA") {
        this.answer = (this.answer + message.delta).slice(0, LIMITS.maxAnswerChars);
        this.$("#answer-text").textContent = this.answer;
      } else if (message.type === "DONE") this.finishAnswer(current);
      else if (message.type === "ERROR") this.failAnswer(message.message);
    });
    this.port.onDisconnect.addListener(() => {
      if (this.port) this.failAnswer("Response stream closed");
    });
    this.port.postMessage({ type: "SOLVE", request });
  }

  finishAnswer(current) {
    const result = parseAnswer(this.answer);
    this.answer = result.text;
    this.answerType = result.type;
    this.$("#answer-text").textContent = result.text;
    this.$("#answer-header").textContent = result.type === "none" ? "Hermes" : `Hermes · ${titleCase(result.type)}`;
    this.turns.push({ instruction: current.instruction, answer: result.text, type: result.type, images: current.images });
    if (this.turns.length > 48) this.turns.splice(0, this.turns.length - 48);
    const keepImagesFrom = Math.max(0, this.turns.length - this.settings.imageWindow);
    for (let index = 0; index < keepImagesFrom; index += 1) this.turns[index].images = [];
    this.attachments.length = 0;
    this.updateStatus();
    this.closePort();
  }

  failAnswer(message) {
    if (message !== "Request cancelled") this.flash(message);
    this.closePort();
  }

  closePort() {
    const port = this.port;
    this.port = null;
    this.$("#spinner").hidden = true;
    try { port?.disconnect(); } catch { /* already disconnected */ }
  }

  async captureRegion() {
    try {
      const bounds = await this.selectRegion();
      this.host.style.display = "none";
      await nextFrame();
      const { dataUrl } = await this.ext.runtime.sendMessage({ type: "CAPTURE_VISIBLE" });
      const cropped = await cropDataUrl(dataUrl, bounds);
      this.attachments.push({ dataUrl: cropped, createdAt: Date.now() });
      if (this.attachments.length > LIMITS.maxScreenshots) this.attachments.shift();
      this.updateStatus();
    } catch (error) {
      if (error?.name !== "AbortError") this.flash(String(error?.message || error));
    } finally {
      this.host.style.display = "";
    }
  }

  async captureDisplayRegion() {
    let stream;
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: 1 }, audio: false });
      const video = this.$("#capture-preview");
      video.srcObject = stream;
      video.muted = true;
      video.hidden = false;
      await video.play();
      const bounds = await this.selectRegion("Select a region from the shared surface");
      const scaleX = video.videoWidth / innerWidth;
      const scaleY = video.videoHeight / innerHeight;
      const canvas = new OffscreenCanvas(Math.max(1, Math.round(bounds.width * scaleX)), Math.max(1, Math.round(bounds.height * scaleY)));
      canvas.getContext("2d").drawImage(video, bounds.x * scaleX, bounds.y * scaleY, bounds.width * scaleX, bounds.height * scaleY, 0, 0, canvas.width, canvas.height);
      const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.88 });
      this.attachments.push({ dataUrl: await blobToDataUrl(blob), createdAt: Date.now() });
      if (this.attachments.length > LIMITS.maxScreenshots) this.attachments.shift();
      this.updateStatus();
    } catch (error) {
      if (error?.name !== "AbortError" && error?.name !== "NotAllowedError") this.flash(String(error?.message || error));
    } finally {
      const preview = this.$("#capture-preview");
      preview.hidden = true;
      preview.srcObject = null;
      stream?.getTracks().forEach((track) => track.stop());
    }
  }

  selectRegion(label = "Drag to capture a region · Esc to cancel") {
    return new Promise((resolve, reject) => {
      const layer = this.$("#selection-layer");
      const box = this.$("#selection-box");
      const hint = this.$("#selection-hint");
      hint.textContent = label;
      layer.hidden = false;
      let start;
      const move = (event) => {
        if (!start) return;
        const x = Math.min(start.x, event.clientX);
        const y = Math.min(start.y, event.clientY);
        const width = Math.abs(event.clientX - start.x);
        const height = Math.abs(event.clientY - start.y);
        Object.assign(box.style, { left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
      };
      const down = (event) => { start = { x: event.clientX, y: event.clientY }; move(event); };
      const cleanup = () => {
        layer.hidden = true;
        box.removeAttribute("style");
        layer.removeEventListener("pointerdown", down);
        layer.removeEventListener("pointermove", move);
        layer.removeEventListener("pointerup", up);
        window.removeEventListener("keydown", key, true);
      };
      const up = (event) => {
        if (!start) return;
        const bounds = { x: Math.min(start.x, event.clientX), y: Math.min(start.y, event.clientY), width: Math.abs(event.clientX - start.x), height: Math.abs(event.clientY - start.y) };
        cleanup();
        if (bounds.width < 8 || bounds.height < 8) reject(new DOMException("Selection is too small", "AbortError"));
        else resolve(bounds);
      };
      const key = (event) => { if (event.key === "Escape") { cleanup(); reject(new DOMException("Cancelled", "AbortError")); } };
      layer.addEventListener("pointerdown", down);
      layer.addEventListener("pointermove", move);
      layer.addEventListener("pointerup", up);
      window.addEventListener("keydown", key, true);
    });
  }

  async toggleListen() {
    if (this.listening) {
      this.listening = false;
      this.$("#listen").classList.remove("active", "listening");
      await this.ext.runtime.sendMessage({ type: "STOP_TAB_AUDIO" }).catch(() => {});
      await this.audio?.stop();
      this.audio = null;
      return;
    }
    try {
      let result;
      try { result = await this.ext.runtime.sendMessage({ type: "START_TAB_AUDIO" }); } catch { result = { ok: false }; }
      if (!result?.ok) await this.startDisplayAudio();
      this.listening = true;
      this.$("#listen").classList.add("active", "listening");
    } catch (error) {
      this.flash(String(error?.message || error));
    }
  }

  async startDisplayAudio() {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    if (!stream.getAudioTracks().length) {
      stream.getTracks().forEach((track) => track.stop());
      throw new Error("The shared surface did not include audio");
    }
    this.audio = new AudioCapturePipeline({
      stream,
      onTranscript: (text) => this.appendTranscript(text),
      onError: (message) => this.flash(message),
      getSettings: async () => this.settings,
    });
    await this.audio.start();
  }

  appendTranscript(text) {
    const input = this.$("#prompt");
    input.value = `${input.value}${input.value && !input.value.endsWith(" ") ? " " : ""}${String(text).trim()}`;
  }

  async typeAnswer() {
    if (!this.answer) return this.flash("No answer to type");
    const generation = ++this.cancelGeneration;
    for (let seconds = 5; seconds > 0; seconds -= 1) {
      if (generation !== this.cancelGeneration) return;
      this.$("#countdown").hidden = false;
      this.$("#countdown").textContent = `Typing in ${seconds}…`;
      await sleep(1000);
    }
    this.$("#countdown").hidden = true;
    const result = await this.ext.runtime.sendMessage({
      type: "AUTO_TYPE",
      text: this.answer,
      humanise: this.settings.humanise,
      delayMs: this.settings.baseDelayMs,
    });
    if (!result?.ok) this.flash(result?.error || "Focus a webpage field first");
  }

  cancel() {
    this.cancelGeneration += 1;
    this.$("#countdown").hidden = true;
    if (this.port) this.closePort();
    this.ext.runtime.sendMessage({ type: "CANCEL_AUTO_TYPE" }).catch(() => {});
  }

  enterHistory() {
    if (!this.turns.length) return this.flash("No answer history");
    this.historyIndex = this.turns.length - 1;
    this.showHistory();
  }

  moveHistory(delta) {
    if (this.historyIndex < 0) return;
    this.historyIndex = Math.max(0, Math.min(this.turns.length - 1, this.historyIndex + delta));
    this.showHistory();
  }

  showHistory() {
    const turn = this.turns[this.historyIndex];
    this.answer = turn.answer;
    this.answerType = turn.type;
    this.$("#answer-header").textContent = turn.instruction || "(screenshot)";
    this.$("#history-position").textContent = `${this.historyIndex + 1} / ${this.turns.length}`;
    this.$("#history-controls").hidden = false;
    this.$("#answer-text").textContent = turn.answer;
    this.showPanel("answer");
  }

  toggleDiscussion() {
    this.discussion = !this.discussion;
    this.$("#discussion").classList.toggle("active", this.discussion);
    if (this.discussion && !this.documents.length) this.flash("Discussion Mode needs document context");
  }

  async addFiles(fileList) {
    for (const file of fileList) {
      if (file.size > LIMITS.maxDocumentBytes) { this.flash(`${file.name} is too large`); continue; }
      const text = await file.text();
      this.addDocument(file.name, text);
    }
    this.$("#document-files").value = "";
    this.updateStatus();
  }

  addPastedDocument() {
    const field = this.$("#document-paste");
    if (!field.value.trim()) return;
    this.addDocument(`Pasted text ${this.documents.length + 1}`, field.value);
    field.value = "";
    this.updateStatus();
  }

  addDocument(name, text) {
    const bytes = new TextEncoder().encode(text).byteLength;
    const total = this.documents.reduce((sum, doc) => sum + doc.bytes, 0);
    if (total + bytes > LIMITS.maxDocumentBytes) return this.flash("Document context limit is 2 MB");
    this.documents.push({ name: String(name).slice(0, 160), text, bytes });
  }

  clearDocuments() {
    this.documents.length = 0;
    this.updateStatus();
  }

  syncSettingsForm() {
    this.$("#stealth").checked = Boolean(this.settings.stealth);
    this.$("#settings-provider").value = this.settings.provider;
    this.populateModels(this.settings.model);
    this.$("#api-key").value = this.settings.apiKeys[this.settings.provider] ?? "";
    this.$("#humanise").checked = this.settings.humanise;
    this.$("#typing-delay").value = this.settings.baseDelayMs;
    this.$("#opacity").value = this.settings.overlayOpacity;
    this.$("#opacity-value").textContent = `${this.settings.overlayOpacity}%`;
    this.$("#font-size").value = this.settings.answerFontSize;
    this.$("#font-value").textContent = `${this.settings.answerFontSize} pt`;
    this.$("#resume").value = this.settings.resumeProfile;
    this.$("#locale").value = this.settings.speechLocale;
    this.$(".bar").style.opacity = String(this.settings.overlayOpacity / 100);
    this.$("#answer-text").style.fontSize = `${this.settings.answerFontSize}px`;
    this.$("#save-settings").disabled = true;
  }

  populateModels(selected) {
    const provider = this.$("#settings-provider").value;
    const field = this.$("#settings-model");
    field.replaceChildren(...PROVIDERS[provider].models.map((model) => new Option(`${model.name} · ${model.vision ? "vision" : "text"}`, model.name)));
    field.value = selected && [...field.options].some((option) => option.value === selected) ? selected : field.options[0].value;
    this.$("#api-key").value = this.settings.apiKeys[provider] ?? "";
  }

  async saveSettings() {
    const provider = this.$("#settings-provider").value;
    const apiKeys = { ...this.settings.apiKeys, [provider]: this.$("#api-key").value.trim() };
    const value = normaliseSettings({
      ...this.settings,
      provider,
      model: this.$("#settings-model").value,
      apiKeys,
      stealth: this.$("#stealth").checked,
      humanise: this.$("#humanise").checked,
      baseDelayMs: Number(this.$("#typing-delay").value),
      overlayOpacity: Number(this.$("#opacity").value),
      answerFontSize: Number(this.$("#font-size").value),
      resumeProfile: this.$("#resume").value,
      speechLocale: this.$("#locale").value,
    });
    const result = await this.ext.runtime.sendMessage({ type: "SAVE_SETTINGS", settings: value });
    this.settings = result.settings;
    this.$("#stealth").checked = Boolean(this.settings.stealth);
    if (!result.ok) {
      this.flash(result.error || "Couldn't activate Stealth");
      return;
    }
    this.$("#save-settings").disabled = true;
    this.updateStatus();
    this.renderGPU();
    if (this.settings.stealth) this.setStealthMode(true);
  }

  showSettingsPane(name) {
    this.$$(".nav-button").forEach((button) => button.classList.toggle("active", button.dataset.pane === name));
    this.$$(".settings-pane").forEach((pane) => pane.hidden = pane.dataset.pane !== name);
  }

  flash(message) {
    this.showPanel(this.panel || "answer");
    const target = this.$("#countdown");
    target.hidden = false;
    target.textContent = String(message).slice(0, 220);
    const generation = ++this.cancelGeneration;
    setTimeout(() => { if (generation === this.cancelGeneration) target.hidden = true; }, 2400);
  }

  destroy() {
    this.closePort();
    this.audio?.stop();
    this.gpu?.destroy();
    this.host?.remove();
  }
}

function template() {
  return `<div id="shell"><div id="stage" class="stage bar-only">
    <canvas id="gpu"></canvas>
    <div class="bar">
      <div class="compose">
        ${button("discussion", "ear", "Discussion Mode")}${button("listen", "mic", "Toggle Listen", "listen")}
        <input id="prompt" type="text" autocomplete="off" spellcheck="false" placeholder="Ask me anything..." aria-label="Ask Hermes">
        <span id="spinner" class="spinner" hidden></span><span id="status-dot" class="status-dot"></span>
      </div>
      <div class="tools">
        ${button("questions", "suggest", "Suggest two discussion questions")}${button("capture", "camera", "Capture region (Shift-click for another surface)")}
        ${button("tray", "paperclip", "Attachment Tray", "", "tray-badge")}${button("documents", "plus", "Add document context", "", "document-badge")}
        ${button("history", "clock", "History")}${button("settings", "sliders", "Settings")}
      </div>
    </div>
    <section id="answer-panel" class="answer-panel" hidden>
      <header><strong id="answer-header">Hermes</strong><span id="history-position"></span>
        <span id="history-controls" hidden>${button("history-prev", "up", "Older turn")}${button("history-next", "down", "Newer turn")}</span>
        <span class="answer-actions">${button("type", "type", "Type response")}${button("copy", "copy", "Copy response")}${button("close-panel", "close", "Close")}</span>
      </header>
      <pre id="answer-text"></pre><div id="countdown" class="countdown" hidden></div>
    </section>
    <section id="document-panel" class="document-panel" hidden>
      <h2>Document context</h2>${button("close-panel", "close", "Close document context")}
      <div id="document-summary" class="summary">No context attached</div><div id="document-names" class="names"></div>
      <label for="document-paste">Paste text or JSON</label><textarea id="document-paste" spellcheck="false"></textarea>
      <div class="document-actions"><button data-action="upload-documents">Upload files...</button><button data-action="add-paste">Add pasted text</button><button data-action="clear-documents">Clear context</button></div>
      <input id="document-files" type="file" accept=".txt,.md,.json,.js,.ts,.tsx,.jsx,.go,.rs,.py,.java,.c,.cpp,.h,.css,.html,.yaml,.yml,.toml,.csv" multiple hidden>
    </section>
    <section id="settings-panel" class="settings-panel" hidden>
      <aside><h2>Hermes</h2>${nav("general", "General", "sliders")}${nav("provider", "Provider & Model", "cpu")}${nav("pass", "Pass", "card")}${nav("resume", "Resume", "file")}${nav("speech", "Speech", "wave")}${nav("hotkeys", "Hotkeys", "keyboard")}${nav("about", "About", "info")}<footer><span>● Browser protected</span><span>v0.1.0</span></footer></aside>
      <form id="settings-form">
        ${settingsPanes()}
      </form>
    </section>
  </div><div id="selection-layer" hidden><video id="capture-preview" playsinline muted hidden></video><div id="selection-hint"></div><div id="selection-box"></div></div></div>`;
}

function settingsPanes() {
  return `<div class="settings-pane" data-pane="general"><h1>General</h1><p>Behaviour of the command bar during a session.</p><div class="card rows">
    <label title="Uses the installed Hermes desktop companion"><span>Stealth</span><input id="stealth" type="checkbox"></label>
    <label><span>Humanise typing</span><input id="humanise" type="checkbox"></label>
    <label><span>Typing delay</span><select id="typing-delay"><option value="35">Fast · 35 ms</option><option value="90">Natural · 90 ms</option><option value="160">Slow · 160 ms</option></select></label>
    <label><span>Overlay opacity</span><input id="opacity" type="range" min="20" max="100"><output id="opacity-value"></output></label>
    <label><span>Font-size</span><input id="font-size" type="range" min="9" max="16"><output id="font-value"></output></label>
    </div><button id="save-settings" class="save" data-action="save-settings" type="button">Save</button></div>
  <div class="settings-pane" data-pane="provider" hidden><h1>Provider & Model</h1><p>Bring your own key. Credentials stay in browser extension storage.</p><div class="card rows">
    <label><span>Provider</span><select id="settings-provider"><option>Groq</option><option>Cerebras</option></select></label>
    <label><span>Model</span><select id="settings-model"></select></label>
    <label><span>API Key (BYOK)</span><input id="api-key" type="password" autocomplete="off" placeholder="gsk_…"></label>
    </div><button class="save" data-action="save-settings" type="button">Save</button></div>
  <div class="settings-pane" data-pane="pass" hidden><h1>Pass</h1><p>Hermes Pass is not available in this browser build.</p><div class="card notice">Use your own provider key for direct, account-free requests.</div></div>
  <div class="settings-pane" data-pane="resume" hidden><h1>Resume</h1><p>Grounds behavioural answers in your background.</p><div class="card resume-card"><label for="resume">Candidate profile</label><textarea id="resume" spellcheck="false"></textarea></div><button class="save" data-action="save-settings" type="button">Save</button></div>
  <div class="settings-pane" data-pane="speech" hidden><h1>Speech</h1><p>Captured audio is sent directly to Groq Whisper for transcription.</p><div class="card rows"><label><span>Locale</span><select id="locale"><option>en-US</option><option>en-GB</option><option>es-ES</option><option>fr-FR</option><option>de-DE</option><option>pt-BR</option><option>ja-JP</option><option>ko-KR</option></select></label></div><button class="save" data-action="save-settings" type="button">Save</button></div>
  <div class="settings-pane" data-pane="hotkeys" hidden><h1>Hotkeys</h1><p>Configure global shortcuts in the browser's extension shortcuts page.</p><div class="card hotkeys"><span>Toggle Hermes <kbd>⌘⇧H</kbd></span><span>Capture <kbd>⌃⇧H</kbd></span><span>Auto-type <kbd>⌃⇧T</kbd></span><span>Listen <kbd>⌃⇧L</kbd></span></div></div>
  <div class="settings-pane about" data-pane="about" hidden><div class="glyph">H</div><h1>Hermes</h1><p>Messenger god, god of stealth.</p><small>Version 0.1.0 · Built with WebExtensions and WebGPU</small></div>`;
}

function nav(name, title, iconName) { return `<button class="nav-button ${name === "general" ? "active" : ""}" data-pane="${name}" type="button">${icon(iconName)}<span>${title}</span></button>`; }
function button(action, iconName, label, id = "", badge = "") { return `<button ${id ? `id="${id}"` : ""} class="icon-button" data-action="${action}" title="${label}" aria-label="${label}">${icon(iconName)}${badge ? `<b id="${badge}" class="badge" ${badge === "document-badge" ? "hidden" : ""}></b>` : ""}</button>`; }

function icon(name) {
  const paths = {
    ear: '<path d="M12 20c-1.9 0-3-1.2-3-3.1 0-1.8 1-2.8 2.1-3.7 1.2-1 1.9-1.7 1.9-3.2a3 3 0 0 0-6 0"/><path d="M16 10a6 6 0 0 0-12 0"/>',
    mic: '<rect x="8" y="3" width="8" height="12" rx="4"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    suggest: '<circle cx="12" cy="12" r="9"/><path d="M9.6 9a2.55 2.55 0 1 1 4.82 1.16C13.85 11.3 12 11.55 12 13.4M12 17h.01"/>',
    camera: '<path d="M4 8V5h3M17 5h3v3M20 16v3h-3M7 19H4v-3"/><circle cx="12" cy="12" r="4"/>',
    paperclip: '<path d="m20 11-8.5 8.5a5 5 0 0 1-7-7L13 4a3.5 3.5 0 0 1 5 5l-8.5 8.5a2 2 0 0 1-3-3L15 6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>', clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
    cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 1v3M15 1v3M9 20v3M15 20v3M20 9h3M20 14h3M1 9h3M1 14h3M10 10h4v4h-4z"/>',
    card: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 10h18M7 15h3"/>',
    file: '<path d="M6 2h8l4 4v16H6zM14 2v5h5M9 12h6M9 16h6"/>',
    wave: '<path d="M3 12h2l2-6 3 12 3-9 2 6 2-3h4"/>',
    keyboard: '<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M6 9h.01M10 9h.01M14 9h.01M18 9h.01M6 13h.01M10 13h.01M14 13h4M7 16h10"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
    copy: '<rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>', up: '<path d="m6 14 6-6 6 6"/>', down: '<path d="m6 10 6 6 6-6"/>',
    type: '<path d="M5 5h14M12 5v14M8 19h8"/>',
  };
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name] ?? ""}</svg>`;
}

async function cropDataUrl(dataUrl, bounds) {
  const image = await loadImage(dataUrl);
  const scaleX = image.naturalWidth / innerWidth;
  const scaleY = image.naturalHeight / innerHeight;
  const sourceWidth = Math.max(1, Math.round(bounds.width * scaleX));
  const sourceHeight = Math.max(1, Math.round(bounds.height * scaleY));
  const scale = Math.min(1, 1600 / Math.max(sourceWidth, sourceHeight));
  const width = Math.max(1, Math.round(sourceWidth * scale));
  const height = Math.max(1, Math.round(sourceHeight * scale));
  const canvas = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(width, height) : Object.assign(document.createElement("canvas"), { width, height });
  canvas.getContext("2d", { alpha: false }).drawImage(image, bounds.x * scaleX, bounds.y * scaleY, sourceWidth, sourceHeight, 0, 0, width, height);
  let quality = 0.88;
  let blob;
  do {
    blob = canvas.convertToBlob ? await canvas.convertToBlob({ type: "image/jpeg", quality }) : await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
    quality -= 0.1;
  } while (blob.size > LIMITS.maxImageBytes && quality >= 0.48);
  image.src = "";
  return blobToDataUrl(blob);
}

function loadImage(url) { return new Promise((resolve, reject) => { const image = new Image(); image.onload = () => resolve(image); image.onerror = reject; image.src = url; }); }
function blobToDataUrl(blob) { return new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = reject; reader.readAsDataURL(blob); }); }
function nextFrame() { return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function formatBytes(bytes) { return bytes < 1024 ? `${bytes} B` : bytes < 1048576 ? `${(bytes / 1024).toFixed(1)} KB` : `${(bytes / 1048576).toFixed(1)} MB`; }
function titleCase(value) { return value ? value[0].toUpperCase() + value.slice(1) : value; }
function clampNumber(value, minimum, maximum) { return Math.min(maximum, Math.max(minimum, value)); }

const styles = `
  :host{all:initial;color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#fff}
  *{box-sizing:border-box}button,input,textarea,select{font:inherit}button{color:inherit}
  #shell{position:fixed;inset:0;z-index:2147483647;pointer-events:none;color:#fff;font-size:13px}
  .stage{--hermes-x:0px;--hermes-y:0px;position:absolute;top:8px;left:50%;width:900px;transform:translate(calc(-50% + var(--hermes-x)),var(--hermes-y));pointer-events:none}.stage.bar-only{height:46px}.stage.answer{height:310px}.stage.documents{height:342px}.stage.settings{height:560px}
  #gpu{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
  .bar{position:absolute;left:${BAR_X}px;top:0;width:688px;height:46px;pointer-events:auto;touch-action:none;filter:drop-shadow(0 8px 15px rgba(0,0,0,.34))}.bar::before,.bar::after{content:"";position:absolute;left:76px;right:243px;height:8px;z-index:5;cursor:grab}.bar::before{top:0}.bar::after{bottom:0}.bar.dragging,.bar.dragging .compose,.bar.dragging .tools{cursor:grabbing!important;user-select:none}
  .compose,.tools{position:absolute;top:0;height:46px;cursor:grab}.compose{left:0;width:459px}.tools{left:467px;width:221px;transition:background-color .12s}.tools:hover{background:rgba(51,51,51,.15);border-radius:23px}
  .icon-button{position:relative;width:28px;height:28px;padding:4px;border:0;background:transparent;border-radius:50%;display:inline-grid;place-items:center;cursor:pointer;opacity:.96}.icon-button:hover{background:rgba(255,255,255,.1)}.icon-button.active{color:#ffa600}.icon-button svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
  .compose>.icon-button{position:absolute;top:9px}.compose>.icon-button:nth-of-type(1){left:8px}.compose>.icon-button:nth-of-type(2){left:42px}
  #prompt{position:absolute;left:76px;top:13px;width:325px;height:20px;padding:0;border:0;outline:0;background:transparent;color:#fff;font-size:13px;line-height:20px}#prompt::placeholder{color:rgba(255,255,255,.55)}
  .spinner{position:absolute;right:36px;top:15px;width:16px;height:16px;border:2px solid rgba(255,255,255,.22);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite}.status-dot{position:absolute;right:20px;top:18px;width:10px;height:10px;border-radius:50%}.status-dot.ready{background:#35c759}.status-dot.blocked{background:#ff453a;animation:pulse 1.2s ease-in-out infinite}
  .tools>.icon-button{position:absolute;top:9px}.tools>.icon-button:nth-of-type(1){left:9px}.tools>.icon-button:nth-of-type(2){left:44px}.tools>.icon-button:nth-of-type(3){left:79px}.tools>.icon-button:nth-of-type(4){left:114px}.tools>.icon-button:nth-of-type(5){left:149px}.tools>.icon-button:nth-of-type(6){left:184px}
  .badge{position:absolute;right:-2px;bottom:-1px;min-width:14px;height:14px;font-size:9px;line-height:14px;text-align:center;color:#ffd60a}.tools .icon-button:nth-of-type(4) .badge{color:#59d9ff}
  .answer-panel,.document-panel{position:absolute;left:${BAR_X}px;top:${PANEL_TOP}px;width:688px;pointer-events:auto;background:#1a1a1a;border-radius:10px}
  .answer-panel{height:260px;border:1px solid #404040}.answer-panel header{height:40px;padding:10px;color:#999;display:flex;align-items:center;position:relative}.answer-panel header strong{font-size:13px;max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.answer-actions{position:absolute;right:10px;top:6px;display:flex;gap:2px}.answer-actions .icon-button{width:24px;height:24px;padding:3px}#history-controls{position:absolute;left:315px;top:6px;display:flex;gap:8px}#history-controls .icon-button{width:24px;height:24px}#history-position{margin-left:14px;font-size:12px}
  #answer-text{position:absolute;left:16px;top:46px;width:642px;height:174px;margin:0;padding:8px 9px;overflow:auto;border:1px solid rgba(255,255,255,.11);color:#fff;background:rgba(0,0,0,.08);font:11px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;white-space:pre-wrap;overflow-wrap:anywhere;user-select:text}
  .countdown{position:absolute;left:10px;right:20px;top:226px;height:24px;color:#ffd60a;font-weight:700;font-size:14px;text-align:center;line-height:24px}
  .document-panel{height:292px;padding:13px 16px}.document-panel h2{font-size:14px;margin:0 0 7px}.document-panel>.icon-button{position:absolute;right:14px;top:9px}.summary{font-size:11px;color:#b8b8b8;height:18px}.names{height:34px;color:#949494;font-size:10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.document-panel label{font-weight:700;font-size:11px;display:block;margin:3px 0 7px}.document-panel textarea{width:656px;height:120px;resize:none;border:1px solid rgba(255,255,255,.2);outline:0;background:#212121;color:#fff;padding:8px;font:11px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace}.document-actions{display:flex;gap:10px;margin-top:12px}.document-actions button,.save{height:28px;padding:0 14px;border:1px solid rgba(255,255,255,.18);border-radius:6px;background:#25252c;cursor:pointer}.document-actions button:last-child{margin-left:auto}
  .settings-panel{position:absolute;left:0;top:${PANEL_TOP}px;width:900px;height:510px;pointer-events:auto;display:grid;grid-template-columns:212px 688px;overflow:hidden;border:1px solid rgba(255,255,255,.08);border-radius:12px;background:#141419;box-shadow:0 20px 50px rgba(0,0,0,.65)}
  .settings-panel aside{position:relative;padding:38px 10px 10px;background:#0b0b0e;border-right:1px solid rgba(255,255,255,.09)}.settings-panel aside h2{margin:0 6px 25px;font-size:13.5px}.nav-button{width:192px;height:32px;margin:0 0 4px;padding:0 10px;border:0;border-radius:7px;background:transparent;display:flex;align-items:center;gap:10px;text-align:left;color:#8a8a96;cursor:pointer;font-size:12.5px}.nav-button svg{width:16px;height:16px;flex:0 0 16px;fill:none;stroke:currentColor;stroke-width:1.65;stroke-linecap:round;stroke-linejoin:round}.nav-button:hover{background:#1e1e25;color:#ededf2}.nav-button.active{background:rgba(183,183,192,.14);color:#ededf2}.settings-panel aside footer{position:absolute;bottom:14px;left:10px;right:10px;display:flex;justify-content:space-between;color:#8a8a96;font-size:10px}.settings-panel aside footer span:first-child{color:#3ecf8e}
  #settings-form{position:relative;padding:30px 40px;overflow:auto;background:#141419}.settings-pane h1{margin:0 0 3px;font-size:17px}.settings-pane>p{margin:0 0 30px;color:#8a8a96;font-size:11px}.card{border:1px solid rgba(255,255,255,.09);border-radius:12px;background:#16161b;overflow:hidden}.rows>label{height:46px;padding:0 16px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid rgba(255,255,255,.09)}.rows>label:last-child{border-bottom:0}.rows input[type=range]{width:150px}.rows select,.rows input[type=password]{width:240px;height:26px;border:1px solid rgba(255,255,255,.09);border-radius:7px;background:#1e1e25;color:#ededf2;padding:0 8px}.rows output{width:45px;color:#8a8a96;font:11px ui-monospace,monospace}.save{width:100%;height:36px;margin-top:14px;background:#b7b7c0;color:#08080a;border:0;border-radius:8px}.save:disabled{opacity:.35}.notice{padding:18px;color:#8a8a96}.resume-card{padding:16px}.resume-card label{display:block;margin-bottom:10px}.resume-card textarea{width:100%;height:204px;resize:none;background:#1e1e25;color:#ededf2;border:1px solid rgba(255,255,255,.09);border-radius:8px;padding:10px;font-size:12px}.hotkeys{display:grid;grid-template-columns:1fr 1fr}.hotkeys span{height:40px;padding:10px 16px;color:#8a8a96;border-bottom:1px solid rgba(255,255,255,.09)}kbd{float:right;padding:2px 7px;border:1px solid rgba(255,255,255,.09);border-radius:5px;background:#1e1e25;color:#ededf2}.about{text-align:center;padding-top:68px}.about .glyph{width:80px;height:80px;margin:auto;border-radius:20px;display:grid;place-items:center;background:linear-gradient(135deg,#b7b7c0,#6e6e78);font-size:22px;font-weight:700}.about h1{margin-top:14px}.about p{margin-bottom:8px}.about small{color:#8a8a96}
  #selection-layer{position:fixed;inset:0;pointer-events:auto;cursor:crosshair;background:rgba(0,0,0,.18)}#capture-preview{position:absolute;inset:0;width:100%;height:100%;object-fit:fill}#selection-hint{position:absolute;top:18px;left:50%;transform:translateX(-50%);padding:7px 12px;border-radius:8px;background:rgba(20,20,22,.94);color:#fff;font:12px -apple-system,sans-serif}#selection-box{position:absolute;border:1px solid #ffa600;background:rgba(255,166,0,.1);box-shadow:0 0 0 9999px rgba(0,0,0,.25)}
  [hidden]{display:none!important}@keyframes spin{to{transform:rotate(360deg)}}@keyframes pulse{50%{opacity:.3}}
  @media(max-width:920px){.stage{left:50%;transform:translate(calc(-50% + var(--hermes-x)),var(--hermes-y)) scale(min(1,calc((100vw - 16px)/900)));transform-origin:top center}}
`;
