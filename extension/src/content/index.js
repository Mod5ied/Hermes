(function bootHermesTopFrame() {
  if (window.top !== window) return;

  const bootKey = "__hermesExtensionBootstrapV1";
  if (globalThis[bootKey]) return;

  const bootState = {};
  globalThis[bootKey] = bootState;
  const ext = globalThis.browser ?? globalThis.chrome;
  const controller = new HermesOverlay(ext);
  bootState.controller = controller;

  let onMessage;
  const onKeydown = (event) => {
    if (event.key === "Escape") controller.cancel();
  };
  const ready = controller.mount().then(() => true).catch((error) => {
    console.error("Hermes failed to start", error);
    ext.runtime.onMessage.removeListener(onMessage);
    document.removeEventListener("keydown", onKeydown, true);
    if (globalThis[bootKey] === bootState) delete globalThis[bootKey];
    return false;
  });
  bootState.ready = ready;

  onMessage = (message, _sender, sendResponse) => {
    if (message?.type === "HERMES_PING") {
      ready.then((ok) => sendResponse({ ok }));
      return true;
    }
    ready.then((ok) => {
      if (ok) controller.handleMessage(message);
    });
    return false;
  };
  ext.runtime.onMessage.addListener(onMessage);

  document.addEventListener("keydown", onKeydown, true);
})();
