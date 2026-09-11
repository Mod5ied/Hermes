# Hermes WebExtension

A dependency-free Manifest V3 port of the native Hermes command bar for Chrome
and Firefox. Its overlay preserves the native app's 688×46 geometry, segmented
23 px capsules, 8 px gap, 28 px controls, colours, answer board, document panel,
and 900×510 settings layout.

## Build and load

```sh
cd extension
npm test
npm run build
```

- Chrome: open `chrome://extensions`, enable Developer mode, choose **Load
  unpacked**, and select `extension/dist/chrome`.
- Firefox 142+: open `about:debugging#/runtime/this-firefox`, choose **Load Temporary
  Add-on**, and select `extension/dist/firefox/manifest.json`.

Click the toolbar action to toggle Hermes. Click the camera for a current-tab
region, or Shift-click it to select a browser/desktop surface first. Browser
shortcut defaults are shown in Settings and can be changed in the browser's
extension-shortcut UI.

## Stealth companion

Stealth moves Hermes out of the captured webpage and into the installed native
Hermes window. Build and install `Hermes.app`, then register its Native Messaging
host using the extension ID shown on `chrome://extensions` or
`edge://extensions`:

```sh
./scripts/install-native-host.sh YOUR_32_CHARACTER_EXTENSION_ID /Applications/Hermes.app/Contents/MacOS/hermes
```

After reloading the extension, enable Stealth in General settings. Hermes first
waits for the native host to confirm that its window is ready, then removes the
in-page overlay. If the companion cannot start, Stealth is reverted so the UI
does not become inaccessible. Firefox uses its stable add-on ID and needs no ID
argument when the default Chrome/Edge ID is also correct.

Native capture protection is best effort. On Windows it maps to
`WDA_EXCLUDEFROMCAPTURE`; on macOS Hermes applies `NSWindowSharingNone`, which
modern ScreenCaptureKit clients may ignore. Sharing only a browser tab excludes
the native window; whole-screen capture still depends on operating-system and
capturing-application behaviour.

The overlay appears inside ordinary `http://` and `https://` webpages. Browser
security prevents injection into internal pages such as `chrome://extensions`,
`edge://extensions`, the Chrome Web Store, the Edge Add-ons store, and new-tab
or settings pages. Open a normal webpage before clicking Hermes. The toolbar
action injects Hermes on demand when the tab was already open during install;
if site access is blocked, its toolbar icon briefly shows a red `!` badge.

## Runtime architecture

- A tiny MV3 service worker handles privileged visible-tab capture, settings,
  provider CORS, and SSE forwarding. It stores no screenshots, audio, prompts,
  answers, or session history.
- A closed-shadow content overlay holds the in-memory session. One retained GPU
  vertex buffer renders the native panel surfaces through WebGPU, with WebGL2
  fallback. DOM is retained only for accessible text input and hit targets.
- Chrome audio uses `tabCapture` and an offscreen document so capture survives
  service-worker suspension. Firefox uses user-initiated `getDisplayMedia`.
- An AudioWorklet moves PCM off the render thread. When cross-origin isolation
  permits it, PCM travels through an eight-second SharedArrayBuffer ring; the
  fallback batches and transfers ownership of 2,048-sample buffers. A dedicated
  worker downsamples, runs lightweight VAD, bounds queued speech segments, and
  emits 16 kHz mono WAV for Groq Whisper.
- The optional `no_std` Rust/WASM DSP core is allocation-free. The checked-in JS
  worker is its functional fallback when a WASM artifact has not been built.

## Browser security boundaries

Browser extensions cannot reproduce native AppKit powers outside web content.
Hermes therefore uses its separately installed Native Messaging companion for
Stealth. Without that companion it auto-types only into the last focused webpage
field and uses explicit browser capture prompts. Chrome tab audio and Firefox
shared-surface audio start only from the user's click.

API keys are stored in the browser extension profile and sent only to the chosen
provider. Screenshots, documents, transcripts, answers, and conversation turns
remain memory-only. Transcription is remote in this port (Groq Whisper), because
shipping a competitive local Whisper model would violate the ultra-lightweight
size and memory target.

## Performance envelope

- Screenshot queue: 5 items; each encoded below 4 MiB and downscaled to 1,600 px.
- Document context: 2 MiB total.
- Answer display: 128 KiB.
- Audio ring: 8 seconds; speech upload queue: 2 segments.
- Session retention: 48 display turns; only the configured recent turns are sent.
- GPU redraws occur only for resize or panel/state transitions; there is no UI
  animation loop. `destroy()` stops every track, context, worker, port, observer,
  GPU resource, and WebGL context.
