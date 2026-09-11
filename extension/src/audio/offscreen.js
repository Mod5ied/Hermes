import { AudioCapturePipeline } from "./pipeline.js";

const pipelines = new Map();
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "OFFSCREEN_START_AUDIO") return respond(start(message), sendResponse);
  if (message?.type === "OFFSCREEN_STOP_AUDIO") return respond(stop(message.tabId), sendResponse);
  return undefined;
});

function respond(promise, sendResponse) {
  promise.then(sendResponse, (error) => sendResponse({ ok: false, error: String(error?.message || error) }));
  return true;
}

async function start({ streamId, tabId }) {
  for (const activeTabId of [...pipelines.keys()]) await stop(activeTabId);
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: streamId } },
    video: false,
  });
  const pipeline = new AudioCapturePipeline({
    stream,
    onTranscript: (text) => chrome.runtime.sendMessage({ type: "OFFSCREEN_TRANSCRIPT", tabId, text }),
    getSettings: async () => (await chrome.runtime.sendMessage({ type: "GET_SETTINGS" })).settings,
  });
  pipelines.set(tabId, pipeline);
  await pipeline.start({ monitor: true });
  return { ok: true };
}

async function stop(tabId) {
  const pipeline = pipelines.get(tabId);
  if (!pipeline) return { ok: true };
  pipelines.delete(tabId);
  await pipeline.stop();
  return { ok: true };
}
