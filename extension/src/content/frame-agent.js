(function bootHermesFrameAgent() {
  const ext = globalThis.browser ?? globalThis.chrome;
  const agentKey = "__hermesFrameAgentV1";

  // On-demand injection can reach a frame that already has the manifest
  // content script. Replace that agent so listeners never accumulate.
  globalThis[agentKey]?.dispose?.();

  let lastEditable = null;
  let typeGeneration = 0;
  const state = { active: true, dispose };
  globalThis[agentKey] = state;

  function onFocusIn(event) {
    const target = event.composedPath()[0];
    if (!isEditable(target)) return;
    lastEditable = target;
    safeRuntimeSend({ type: "FOCUS_EDITABLE", at: Date.now() });
  }

  function onKeydown(event) {
    if (event.key === "Escape") typeGeneration += 1;
  }

  function onRuntimeMessage(message, _sender, sendResponse) {
    if (message?.type === "TYPE_TEXT") {
      const ok = Boolean(lastEditable?.isConnected);
      typeIntoLastField(lastEditable, message).catch(() => {});
      sendResponse({ ok });
      return false;
    }
    if (message?.type === "TYPE_CANCEL") typeGeneration += 1;
    return false;
  }

  document.addEventListener("focusin", onFocusIn, true);
  document.addEventListener("keydown", onKeydown, true);
  try {
    ext.runtime.onMessage.addListener(onRuntimeMessage);
  } catch (error) {
    handleRuntimeFailure(error);
  }

  function safeRuntimeSend(message) {
    if (!state.active) return;
    try {
      const pending = ext.runtime.sendMessage(message);
      if (pending && typeof pending.catch === "function") pending.catch(handleRuntimeFailure);
    } catch (error) {
      // Chrome throws synchronously here when an unpacked extension is
      // reloaded while this page still owns listeners from the old context.
      handleRuntimeFailure(error);
    }
  }

  function handleRuntimeFailure(error) {
    const message = String(error?.message ?? error);
    if (/extension context invalidated|message manager disconnected/i.test(message)) dispose();
  }

  function dispose() {
    if (!state.active) return;
    state.active = false;
    typeGeneration += 1;
    lastEditable = null;
    document.removeEventListener("focusin", onFocusIn, true);
    document.removeEventListener("keydown", onKeydown, true);
    try { ext.runtime.onMessage.removeListener(onRuntimeMessage); } catch { /* invalidated context */ }
    if (globalThis[agentKey] === state) delete globalThis[agentKey];
  }

  async function typeIntoLastField(target, message) {
    if (!state.active || !target?.isConnected) return;
    target.focus({ preventScroll: true });
    const text = String(message.text ?? "");
    const delay = message.humanise ? Number(message.delayMs) : 0;
    const generation = ++typeGeneration;
    if (!delay) {
      insert(target, text);
      return;
    }
    for (const char of text) {
      if (!state.active || generation !== typeGeneration) return;
      insert(target, char);
      await new Promise((resolve) => setTimeout(resolve, jitter(delay)));
    }
  }

  function insert(target, text) {
    if (target.isContentEditable) {
      document.execCommand("insertText", false, text);
      return;
    }
    const start = target.selectionStart ?? target.value.length;
    const end = target.selectionEnd ?? start;
    target.setRangeText(text, start, end, "end");
    target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
  }

  function isEditable(target) {
    return target instanceof HTMLInputElement && !target.readOnly && !target.disabled
      || target instanceof HTMLTextAreaElement && !target.readOnly && !target.disabled
      || target instanceof HTMLElement && target.isContentEditable;
  }

  function jitter(delay) {
    return Math.max(1, delay * (0.75 + Math.random() * 0.5));
  }
})();
