import { DEFAULT_SETTINGS, normaliseSettings, parseSSEBlock } from "./shared/core.js";
import { NativeCompanion } from "./native-companion.js";

const ext = browser;
const focusedFrames = new Map();
const companion = new NativeCompanion(ext, syncStealthFromNative);

ext.runtime.onInstalled.addListener(async () => {
  const stored = await ext.storage.local.get("settings");
  if (!stored.settings) await ext.storage.local.set({ settings: DEFAULT_SETTINGS });
});

ext.action.onClicked.addListener((tab) => toggleHermesInTab(tab));
ext.commands.onCommand.addListener(async (command) => {
  const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) return;
  const stored = await ext.storage.local.get("settings");
  const settings = normaliseSettings(stored.settings);
  if (settings.stealth) await companion.command(command, companionSettings(settings));
  else await deliverToTab(tab, { type: "COMMAND", command });
});
ext.tabs.onRemoved.addListener((tabId) => {
  focusedFrames.delete(tabId);
  ext.storage.session.remove(`focus:${tabId}`);
});

ext.runtime.onConnect.addListener((port) => {
  if (port.name !== "hermes-ai") return;
  const controller = new AbortController();
  port.onMessage.addListener((message) => {
    if (message?.type === "SOLVE") streamAnswer(message.request, port, controller.signal).catch((error) => {
      safePost(port, { type: "ERROR", message: cleanError(error) });
    });
  });
  port.onDisconnect.addListener(() => controller.abort());
});

ext.runtime.onMessage.addListener((message, sender) => handleMessage(message, sender));

async function handleMessage(message, sender) {
  switch (message?.type) {
    case "GET_SETTINGS": {
      const stored = await ext.storage.local.get("settings");
      return { settings: normaliseSettings(stored.settings) };
    }
    case "SAVE_SETTINGS": {
      const settings = normaliseSettings(message.settings);
      let native = { ok: true };
      if (settings.stealth) native = await companion.activate(companionSettings(settings));
      else await companion.deactivate();
      if (!native.ok) settings.stealth = false;
      await ext.storage.local.set({ settings });
      await broadcastStealth(settings.stealth);
      return { ok: native.ok, error: native.error, settings };
    }
    case "CAPTURE_VISIBLE": {
      const dataUrl = await ext.tabs.captureVisibleTab(sender.tab?.windowId, { format: "jpeg", quality: 92 });
      return { dataUrl };
    }
    case "START_TAB_AUDIO":
      return { ok: false, fallback: "displayMedia" };
    case "STOP_TAB_AUDIO":
      return { ok: true };
    case "FOCUS_EDITABLE": {
      if (sender.tab?.id == null) return { ok: false };
      const focus = { frameId: sender.frameId ?? 0, at: Date.now() };
      focusedFrames.set(sender.tab.id, focus);
      await ext.storage.session.set({ [`focus:${sender.tab.id}`]: focus });
      return { ok: true };
    }
    case "AUTO_TYPE": {
      const tabId = sender.tab?.id;
      let frame = focusedFrames.get(tabId);
      if (!frame && tabId != null) frame = (await ext.storage.session.get(`focus:${tabId}`))[`focus:${tabId}`];
      if (tabId == null || !frame) return { ok: false, error: "Focus a webpage field first" };
      try {
        return await ext.tabs.sendMessage(tabId, {
          type: "TYPE_TEXT",
          text: String(message.text ?? ""),
          humanise: Boolean(message.humanise),
          delayMs: Number(message.delayMs) || 0,
        }, { frameId: frame.frameId });
      } catch {
        focusedFrames.delete(tabId);
        return { ok: false, error: "The focused field is no longer available" };
      }
    }
    case "CANCEL_AUTO_TYPE": {
      const tabId = sender.tab?.id;
      const frame = focusedFrames.get(tabId);
      if (tabId != null && frame) {
        try { await ext.tabs.sendMessage(tabId, { type: "TYPE_CANCEL" }, { frameId: frame.frameId }); } catch { /* frame closed */ }
      }
      return { ok: true };
    }
    default:
      return undefined;
  }
}

async function streamAnswer(request, port, signal) {
  if (!request?.url?.startsWith("https://") || !request.apiKey) throw new Error("Add an API key in Hermes Settings");
  const response = await fetch(request.url, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${request.apiKey}` },
    body: JSON.stringify(request.body),
    signal,
  });
  if (!response.ok) throw new Error(await responseMessage(response));
  if (!response.body) throw new Error("Provider returned no response stream");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      buffer += decoder.decode(value, { stream: !done });
      const blocks = buffer.split(/\r?\n\r?\n/);
      buffer = blocks.pop() ?? "";
      for (const block of blocks) {
        const event = parseSSEBlock(block);
        if (event.delta) safePost(port, { type: "DELTA", delta: event.delta });
        if (event.done) { safePost(port, { type: "DONE" }); return; }
      }
      if (done) break;
    }
    if (buffer) {
      const event = parseSSEBlock(buffer);
      if (event.delta) safePost(port, { type: "DELTA", delta: event.delta });
    }
    safePost(port, { type: "DONE" });
  } finally {
    reader.releaseLock();
  }
}

async function responseMessage(response) {
  try { return (await response.json()).error?.message || `Provider request failed (${response.status})`; }
  catch { return `Provider request failed (${response.status})`; }
}

function cleanError(error) {
  return error?.name === "AbortError" ? "Request cancelled" : String(error?.message || error).slice(0, 300);
}

function safePost(port, message) {
  try { port.postMessage(message); } catch { /* content frame closed */ }
}

async function sendToTopFrame(tabId, message) {
  try { return await ext.tabs.sendMessage(tabId, message, { frameId: 0 }); } catch { return undefined; }
}

async function toggleHermesInTab(tab) {
  if (!tab?.id) return;
  const stored = await ext.storage.local.get("settings");
  const settings = normaliseSettings(stored.settings);
  if (settings.stealth) {
    const result = await companion.toggle(companionSettings(settings));
    if (!result.ok) {
      settings.stealth = false;
      await ext.storage.local.set({ settings });
      await broadcastStealth(false);
      await showActionError(tab.id, result.error || "Hermes desktop companion is unavailable; Stealth was disabled");
    }
    return;
  }
  if (!isInjectableUrl(tab.url)) {
    await showActionError(tab.id, "Hermes cannot run on browser settings or other protected pages");
    return;
  }
  const delivered = await deliverToTab(tab, { type: "TOGGLE_OVERLAY" });
  if (!delivered) await showActionError(tab.id, "Reload this page or allow Hermes access to this site");
}

function companionSettings(settings) {
  return {
    provider: settings.provider,
    model: settings.model,
    apiKey: settings.apiKeys?.[settings.provider] || "",
    humanise: settings.humanise,
    baseDelayMs: settings.baseDelayMs,
    overlayOpacity: settings.overlayOpacity,
    answerFontSize: settings.answerFontSize,
    resumeProfile: settings.resumeProfile,
    speechLocale: settings.speechLocale,
  };
}

async function syncStealthFromNative(enabled) {
  const stored = await ext.storage.local.get("settings");
  const settings = normaliseSettings({ ...stored.settings, stealth: enabled });
  await ext.storage.local.set({ settings });
  await broadcastStealth(enabled);
  if (!enabled) companion.disconnect();
}

async function broadcastStealth(enabled) {
  const tabs = await ext.tabs.query({});
  await Promise.all(tabs.map((tab) => tab.id == null ? undefined : sendToTopFrame(tab.id, { type: "STEALTH_STATE", enabled })));
}

async function deliverToTab(tab, message) {
  if (!tab?.id || !isInjectableUrl(tab.url)) return false;
  const ping = await sendToTopFrame(tab.id, { type: "HERMES_PING" });
  if (!ping?.ok) {
    try { await injectHermes(tab.id); }
    catch { return false; }
  }
  try {
    await ext.tabs.sendMessage(tab.id, message, { frameId: 0 });
    return true;
  } catch {
    return false;
  }
}

async function injectHermes(tabId) {
  try {
    await ext.scripting.executeScript({
      target: { tabId, allFrames: true },
      files: ["src/content/frame-agent.js"],
    });
  } catch {
    await ext.scripting.executeScript({
      target: { tabId, frameIds: [0] },
      files: ["src/content/frame-agent.js"],
    });
  }
  await ext.scripting.executeScript({
    target: { tabId, frameIds: [0] },
    files: ["src/content-bundle.js"],
  });
}

function isInjectableUrl(url = "") {
  try {
    return ["http:", "https:", "file:", "ftp:"].includes(new URL(url).protocol);
  } catch {
    return false;
  }
}

async function showActionError(tabId, title) {
  await Promise.all([
    ext.action.setBadgeBackgroundColor({ tabId, color: "#ff453a" }),
    ext.action.setBadgeText({ tabId, text: "!" }),
    ext.action.setTitle({ tabId, title }),
  ]);
  setTimeout(() => {
    ext.action.setBadgeText({ tabId, text: "" });
    ext.action.setTitle({ tabId, title: "Toggle Hermes" });
  }, 3500);
}
