import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import test from "node:test";
import vm from "node:vm";
import { DEFAULT_SETTINGS, LIMITS, PROVIDERS, normaliseSettings, parseAnswer, parseSSEBlock, providerRequest } from "../src/shared/core.js";
import { removeStaleHermesRoot } from "../src/content/app.js";
import { NATIVE_HOST, NativeCompanion } from "../src/native-companion.js";

test("settings are clamped and unknown providers fall back", () => {
  const settings = normaliseSettings({ provider: "Unknown", overlayOpacity: 4, answerFontSize: 40 });
  assert.equal(settings.provider, "Groq");
  assert.equal(settings.overlayOpacity, 20);
  assert.equal(settings.answerFontSize, 16);
  assert.equal(settings.stealth, false);
});

test("Cerebras exposes only supported models and migrates deprecated selections", () => {
  assert.deepEqual(PROVIDERS.Cerebras.models, [
    { name: "gpt-oss-120b", vision: false },
    { name: "qwen-3.8-27b", vision: true },
  ]);
  assert.equal(normaliseSettings({ provider: "Cerebras", model: "gemma-4-31b" }).model, "qwen-3.8-27b");
  assert.equal(normaliseSettings({ provider: "Cerebras", model: "zai-glm-4.7" }).model, "gpt-oss-120b");
});

test("native companion waits for readiness and correlates its response", async () => {
  const messageListeners = [];
  const disconnectListeners = [];
  const posted = [];
  const port = {
    onMessage: { addListener(listener) { messageListeners.push(listener); } },
    onDisconnect: { addListener(listener) { disconnectListeners.push(listener); } },
    postMessage(message) { posted.push(message); },
    disconnect() {},
  };
  const ext = { runtime: { connectNative(host) { assert.equal(host, NATIVE_HOST); return port; } } };
  const companion = new NativeCompanion(ext);
  const activation = companion.activate({ provider: "Groq" });
  messageListeners[0]({ type: "READY" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(posted[0].type, "SET_STEALTH");
  messageListeners[0]({ type: "RESPONSE", id: posted[0].id, ok: true, visible: true });
  assert.deepEqual(await activation, { type: "RESPONSE", id: posted[0].id, ok: true, visible: true });
});

test("provider request keeps secrets in transport metadata and bounds screenshots", () => {
  const images = Array.from({ length: 8 }, (_, index) => `data:image/jpeg;base64,${index}`);
  const request = providerRequest({ ...DEFAULT_SETTINGS, apiKeys: { Groq: "secret" }, imageWindow: 5 }, [], { instruction: "solve", images, documents: [] });
  assert.equal(request.apiKey, "secret");
  assert.equal(request.body.messages.at(-1).content.length, LIMITS.maxScreenshots + 1);
  assert.equal(JSON.stringify(request.body).includes("secret"), false);
});

test("document content is explicitly bounded and isolated", () => {
  const request = providerRequest({ ...DEFAULT_SETTINGS, apiKeys: { Groq: "key" } }, [], {
    instruction: "review",
    images: [],
    documents: [{ name: 'a\"b.md', text: "facts", bytes: 5 }],
  });
  const current = request.body.messages.at(-1).content;
  assert.match(current, /<attached_context>/);
  assert.match(current, /name="a&quot;b.md"/);
});

test("SSE and answer classification tolerate provider noise", () => {
  assert.deepEqual(parseSSEBlock('data: {"choices":[{"delta":{"content":"hi"}}]}'), { done: false, delta: "hi" });
  assert.deepEqual(parseSSEBlock("data: [DONE]"), { done: true, delta: "" });
  assert.equal(parseAnswer("Select B").type, "select");
  assert.equal(parseAnswer("```js\nconst x = 1\n```").type, "code");
  assert.equal(parseAnswer("A short answer.").type, "sentence");
});

test("a stale overlay host is removed before a new controller mounts", () => {
  let removed = false;
  const staleHost = { remove: () => { removed = true; } };
  const found = removeStaleHermesRoot({ querySelector: () => staleHost });
  assert.equal(found, true);
  assert.equal(removed, true);
  assert.equal(removeStaleHermesRoot({ querySelector: () => null }), false);
});

test("content startup guards against duplicate controllers", async () => {
  const source = await readFile(resolve(import.meta.dirname, "../src/content/index.js"), "utf8");
  assert.match(source, /if \(globalThis\[bootKey\]\) return/);
  assert.match(source, /globalThis\[bootKey\] = bootState/);
});

test("the frame agent contains extension invalidation and removes stale listeners", async () => {
  const source = await readFile(resolve(import.meta.dirname, "../src/content/frame-agent.js"), "utf8");
  const listeners = new Map();
  const removed = new Set();
  class HTMLElement {}
  class HTMLInputElement extends HTMLElement {
    constructor() {
      super();
      this.readOnly = false;
      this.disabled = false;
      this.isConnected = true;
    }
  }
  class HTMLTextAreaElement extends HTMLElement {}
  const context = {
    chrome: {
      runtime: {
        onMessage: { addListener() {}, removeListener() {} },
        sendMessage() { throw new Error("Extension context invalidated."); },
      },
    },
    document: {
      addEventListener(type, listener) { listeners.set(type, listener); },
      removeEventListener(type) { removed.add(type); },
    },
    HTMLElement,
    HTMLInputElement,
    HTMLTextAreaElement,
    InputEvent: class {},
    setTimeout,
  };
  context.globalThis = context;
  vm.runInNewContext(source, context);
  const target = new HTMLInputElement();
  assert.doesNotThrow(() => listeners.get("focusin")({ composedPath: () => [target] }));
  assert.deepEqual([...removed].sort(), ["focusin", "keydown"]);
  assert.equal(context.__hermesFrameAgentV1, undefined);
});

test("reinjection replaces the existing frame agent instead of accumulating listeners", async () => {
  const source = await readFile(resolve(import.meta.dirname, "../src/content/frame-agent.js"), "utf8");
  let additions = 0;
  let removals = 0;
  class HTMLElement {}
  const context = {
    chrome: { runtime: { onMessage: { addListener() { additions += 1; }, removeListener() { removals += 1; } } } },
    document: {
      addEventListener() { additions += 1; },
      removeEventListener() { removals += 1; },
    },
    HTMLElement,
    HTMLInputElement: class extends HTMLElement {},
    HTMLTextAreaElement: class extends HTMLElement {},
    InputEvent: class {},
    setTimeout,
  };
  context.globalThis = context;
  vm.runInNewContext(source, context);
  vm.runInNewContext(source, context);
  assert.equal(additions, 6);
  assert.equal(removals, 3);
  assert.equal(context.__hermesFrameAgentV1.active, true);
});

test("both manifests point to source files shipped by the build", async () => {
  const root = resolve(import.meta.dirname, "..");
  for (const target of ["chrome", "firefox"]) {
    const manifest = JSON.parse(await readFile(join(root, "manifests", `${target}.json`), "utf8"));
    assert.equal(manifest.manifest_version, 3);
    assert.ok(manifest.content_scripts.some((entry) => entry.js.includes("src/content-bundle.js") && entry.all_frames === false));
    assert.ok(manifest.content_scripts.some((entry) => entry.js.includes("src/content/frame-agent.js") && entry.all_frames === true));
    assert.ok(manifest.background);
    assert.ok(manifest.permissions.includes("nativeMessaging"));
  }
});
