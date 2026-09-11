# Hermes (The Fastest & Best One Yet!)

<img width="872" height="237" alt="image" src="https://github.com/user-attachments/assets/0fd9faf2-b171-4bdb-a154-ea011172a21a" />


Hermes is a lightweight macOS assistant for live interviews and meetings (5mb!, yea fuck you Cluely with your 400mb). It captures what is on your screen, listens to the call, and answers questions in a natural, spoken voice, then can type the answer into the focused field for you.

No embedded browser, no telemetry, no accounts. You bring your own Groq API key.

---

## What it does

- **Screen capture**: Press `CMD+H` to grab any region of your screen and attach it to your question.
- **Voice input**: Press `CMD+L` to transcribe the call app's audio on-device.
- **Natural answers**: Hermes sends the question plus any screenshots to Groq and streams back a short, human-sounding answer.
- **Auto-type**: Press `CMD+T` or click the type button; after a visible 5-second countdown, Hermes types the answer into the field you are focused on.
- **Rate-limit guard**: A small dot on the bar shows when it is safe to send and counts down if you hit a limit.
- **Resume profile**: Paste a resume or JSON profile so answers sound like they come from you.
- **Document tasks**: Click the `+` button to paste or upload UTF-8 text, Markdown, source-code, or JSON context. Hermes switches to an accuracy-first prompt and treats the command-bar text as directions for the attached material.
- **Discussion Mode**: Click the ear icon or press `CMD+D` to answer a teammate's current statement strictly from attached document context, with a separate long-running history.
- **Discussion questions**: Click the question bubble or press `CMD+A` to produce exactly two short questions grounded in the teammate's statement and attached context.
- **Hermes Pass**: No API key handy? Activate a prepaid Pass in Settings for shared-key access instead of BYOK.
- **Overlay opacity**: Dial how visible the command bar is to your own eyes, independent of Stealth.
- **Update check**: Settings checks GitHub Releases once on open and tells you if you're current.

---

## Requirements

- macOS 14 or later (speech transcription works best on macOS 26+)
- Apple Silicon or Intel Mac
- A Groq or Cerebras API key

### Windows port status

The optimized Windows STT foundation is implemented with WASAPI loopback,
WebRTC VAD, AVX2, and quantized whisper.cpp. Low-overhead Windows capture,
single-thread hotkeys, input injection, permissions, configuration paths, and
runtime resource caps are also implemented. The native overlay must still be
ported as a faithful replica of the macOS surface, so the full desktop
application is not yet a Windows release. Build instructions, strict resource
limits, model choices, and measurable accuracy gates are in
[docs/WINDOWS_STT.md](./docs/WINDOWS_STT.md).

---

## Install

### Build from source (recommended)

The recommended way to install Hermes is to build it locally.

#### Prerequisites

- Go 1.26.4 or later
- Xcode 16 or later (the macOS 26 SDK is required for SpeechAnalyzer)
- Xcode Command Line Tools for `make`, `swiftc`, `codesign`, and `security`
- A Groq or Cerebras API key

#### Build

```bash
git clone https://github.com/Mod5ied/Hermes.git
cd Hermes
make cert
make bundle
cp -R Hermes.app /Applications/
```

Then launch `/Applications/Hermes.app` and grant the **Screen Recording**, **Accessibility**, and **Speech Recognition** prompts in System Settings. Restart the app after granting them.

#### Why build from source

macOS only shows the "Apple could not verify" Gatekeeper dialog when a file carries the `com.apple.quarantine` extended attribute. Files built locally with `go build` or `make bundle` are never quarantined, so they never trigger that dialog. The TCC prompts for Screen Recording, Accessibility, and Speech Recognition are unrelated and still appear normally.

### Prebuilt zip (quick try)

If you would rather download a release, grab `Hermes.app.zip` from the [Releases](../../releases) page and run:

```bash
./install.sh /Applications
```

The script removes the quarantine flag and re-signs the app locally for your Mac before opening it.

### Known limitation

Without Apple notarization, this fix is per-machine. If you copy or share a built `Hermes.app` to another Mac via AirDrop, Slack, or a shared drive, that Mac will quarantine the fresh copy and you will need to run `install.sh` (or rebuild from source) on that machine too. This is expected for a small developer audience and avoids the paid Developer Program.

---

## Quick usage

| Shortcut | What it does |
|----------|--------------|
| `CMD+D` | Toggle document-grounded Discussion Mode |
| `CMD+A` | Suggest two grounded questions to ask |
| `CMD+H` | Capture a screen region |
| `CMD+Shift+H` | Select or replace the remembered capture region |
| `CMD+Enter` | Send your question |
| `CMD+T` | Count down, then type the last answer |
| `CMD+L` | Start/stop listening to the call |
| `Esc` | Cancel the countdown or stop typing |

Click the gear icon in the floating bar to open Settings: General, Provider & Model, Pass, Resume, Speech, Hotkeys, and About. Add your API key or a Pass, adjust typing speed and overlay opacity, paste your resume, and check for updates.

### Chrome and Firefox extension

The bare-metal Manifest V3 port lives in [`extension/`](./extension). It keeps
the native command bar geometry and visual system, uses WebGPU with a WebGL2
fallback for panel rendering, and moves audio DSP into an AudioWorklet and
worker. See [`extension/README.md`](./extension/README.md) for build, loading,
privacy, performance, and unavoidable browser-sandbox differences.

For a document task, click the `+` icon, paste text or upload one or more files, then enter directions in **Ask me anything** and press `CMD+Enter`. Attached context stays only for the current in-memory session and is resent on follow-up turns. Click **Clear context** or start a new session to return to the fast live-interview mode.

For a live review discussion, attach the work first and turn on the ear icon. Hermes treats the transcribed or typed input as the teammate's latest statement and keeps its reply grounded in that work. Use the question-bubble action when you want two concise follow-up questions instead of an answer.

---

## Privacy

- Screenshots stay in memory; they are never saved to disk or uploaded anywhere except Groq/Cerebras as part of your question.
- Pasted and uploaded document context stays in memory and is sent only to the selected model provider as part of a document-task request.
- Voice transcription happens on-device.
- No telemetry or analytics.

---

## License

MIT License - see [LICENSE](./LICENSE).
