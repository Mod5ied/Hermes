# Hermes

Hermes is a minimal, single-binary macOS desktop assistant for live interviews and meetings. It captures a region of the screen (or no screen at all), sends the image plus an optional instruction to Groq's Llama 4 Scout vision model, streams the answer back, and can type the result into the focused field with a visible countdown.

Name rationale: Hermes is the messenger god and the god of stealth - the two jobs of the app.

It is a stripped-down, native alternative to Electron-based tools like Natively / Cluely / Interview Coder. No embedded browser, no telemetry, no server, no accounts. You bring your own Groq API key.

---

## Table of contents

- [The loop](#the-loop)
- [What is in scope](#what-is-in-scope)
- [What is deliberately out of scope](#what-is-deliberately-out-of-scope)
- [Project structure](#project-structure)
- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [First run and macOS permissions](#first-run-and-macos-permissions)
- [Usage](#usage)
- [Settings and configuration](#settings-and-configuration)
- [Architecture highlights](#architecture-highlights)
- [Security and privacy](#security-and-privacy)
- [Development notes](#development-notes)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## The loop

1. **CMD+H** - Capture the remembered screen region straight into memory. The screenshot is added to the attachment tray. Nothing is sent yet. The first capture opens a region selector.
2. **Type or dictate a question** - Use the overlay input field, or press **CMD+L** to transcribe the call app's audio into the input box on-device.
3. **CMD+Enter** - If the rate-limit indicator is green, Hermes sends the question plus the queued screenshots to Groq. If it is red, the send is blocked and the overlay shows when it will clear.
4. **Groq streams an answer** classified as **SELECT**, **SENTENCE**, or **CODE**. The answer appears in the overlay panel and is held in a buffer.
5. **CMD+T** - A visible 5-second countdown runs in the overlay, then the auto-typer types the buffered answer into the focused window.
6. **ESC** - Cancels the countdown or aborts an in-progress type.

---

## What is in scope

- Native macOS NSPanel overlay with a command bar and drop-down answer panel.
- Stealth mode (on by default) that tries to hide the overlay from legacy and browser-based screen capture.
- Global hotkeys: CMD+H, CMD+Enter, CMD+T, CMD+L, ESC.
- In-process screen capture, memory-only, no clipboard and no disk.
- Attachment tray that queues up to 5 screenshots for the next send.
- Groq streaming client with session threading.
- On-device speech transcription of the call app's audio (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer fallback).
- Resume/profile upload for tailored SENTENCE answers.
- Rate-limit indicator driven by real Groq headers plus a local RPM window.
- Auto-typer with humanise mode and abort.
- Settings persisted to `~/Library/Application Support/Hermes/config.json`.

## What is deliberately out of scope

- Audio recording, meeting notes, transcription history.
- RAG, reference files, profile intelligence beyond the resume prompt block.
- Multi-display picker (MVP captures the primary display / selected region).
- OCR - the vision model reads the image directly.
- Windows build - the interfaces are designed so it can be ported later.

---

## Project structure

```
.
├── cmd/hermes/main.go              # Application wiring and state machine
├── Info.plist                      # Bundle metadata and TCC usage strings
├── Makefile                        # Build, test, sign, and cert targets
├── install.sh                      # Copy Hermes.app to /Applications and remove quarantine
├── scripts/setup-codesign.sh       # Create a self-signed code-signing certificate
├── go.mod / go.sum                 # Go module dependencies
├── internal/
│   ├── capture/                    # Screen region selection and in-memory capture
│   │   ├── capture.go
│   │   ├── capture_darwin.m
│   │   ├── encode.go
│   │   └── encode_test.go
│   ├── config/                     # Config load/save and env overrides
│   │   ├── config.go
│   │   └── config_test.go
│   ├── hotkey/                     # Global hotkey registration wrapper
│   │   ├── hotkey.go
│   │   └── hotkey_test.go
│   ├── llm/                        # Groq / OpenAI-compatible streaming client
│   │   ├── llm.go
│   │   └── llm_test.go
│   ├── overlay/                    # Native NSPanel command bar (cgo/Objective-C)
│   │   ├── overlay.go
│   │   └── overlay_darwin.m
│   ├── permissions/                # TCC preflight checks and startup alert
│   │   ├── permissions.go
│   │   └── permissions_darwin.m
│   ├── ratelimit/                  # RPM/RPD/TPM tracker from Groq headers
│   │   ├── ratelimit.go
│   │   └── ratelimit_test.go
│   ├── resume/                     # PDF/text resume extraction and profile compaction
│   │   ├── resume.go
│   │   └── resume_test.go
│   ├── session/                    # In-memory conversation thread
│   │   ├── session.go
│   │   └── session_test.go
│   ├── speech/                     # On-device transcription bridge (Swift + Objective-C)
│   │   ├── speech.go
│   │   ├── speech_darwin.m
│   │   ├── speech_analyzer.swift
│   │   └── speech_test.go
│   ├── tray/                       # Current-turn screenshot queue (up to 5)
│   │   ├── tray.go
│   │   └── tray_test.go
│   └── typer/                      # CGEvent auto-typer with humanise and abort
│       ├── typer.go
│       └── typer_darwin.c
└── tech-specs.md                   # Full product specification
```

### Key packages

| Package | Responsibility |
|---------|----------------|
| `cmd/hermes` | Wires everything, owns the state machine, runs UI on the main thread. |
| `internal/capture` | Region selector, in-memory screen capture, image encoding under 4MB. |
| `internal/tray` | Queues up to 5 base64 screenshots for the current turn. |
| `internal/llm` | Builds the OpenAI-compatible chat request, streams deltas from Groq, classifies answers. |
| `internal/session` | Maintains the in-memory thread of prior turns; applies turn limit and image window. |
| `internal/ratelimit` | Tracks RPM locally and folds in RPD/TPM/429 headers from Groq. |
| `internal/speech` | Captures call-app audio with ScreenCaptureKit and transcribes with Apple's on-device speech APIs. |
| `internal/resume` | Extracts text from PDF or plain text and builds a compact candidate profile. |
| `internal/typer` | Injects keystrokes via CoreGraphics with optional humanised cadence and ESC abort. |
| `internal/hotkey` | Wraps `golang.design/x/hotkey` for global combos. |
| `internal/overlay` | Native NSPanel with the command bar, answer panel, countdown, and rate-limit indicator. |
| `internal/permissions` | Checks Screen Recording, Accessibility, and Speech Recognition; shows a startup alert. |

---

## Requirements

- macOS 14+; SpeechAnalyzer support requires the macOS 26 SDK (Xcode 16 / macOS 26 SDK or later).
- Apple Silicon or Intel Mac.
- Go 1.26.4 or later.
- Xcode Command Line Tools.
- `swiftc` for the speech static library.
- A Groq API key.

---

## Build and install

### 1. Build the binary

```bash
make build
```

This compiles the Swift speech static library (`internal/speech/libspeechswift.a`) and the Go binary (`./hermes`).

### 2. (Recommended) Create a stable code-signing certificate

Ad-hoc signing (`codesign --sign -`) works, but every rebuild changes the binary's `cdhash`, which invalidates existing macOS TCC permissions (Accessibility, Screen Recording, Speech Recognition). To avoid resetting permissions after every build, create a self-signed certificate once:

```bash
make cert
```

This creates:

- `HermesSigning.keychain-db` - a project-local keychain.
- `.codesign/` - certificate and key material.

Both are gitignored. The keychain password is empty; the P12 export password defaults to `hermes` and can be overridden with `HERMES_CERT_PASS`.

### 3. Build the `.app` bundle

```bash
make bundle
```

If the keychain from step 2 exists, the bundle is signed with `Hermes Code Signing`. Otherwise it is signed ad-hoc and a warning is printed.

### 4. Install to `/Applications`

```bash
./install.sh
```

This kills any running Hermes, copies `Hermes.app` to `/Applications`, removes the quarantine flag, and launches it.

### Other useful targets

```bash
make test      # run all Go unit tests
make run       # build and run ./hermes from the repo
make clean     # remove ./hermes and ./Hermes.app
```

---

## First run and macOS permissions

Hermes needs three TCC permissions:

| Permission | Why it is needed |
|------------|------------------|
| **Screen Recording** | In-process screen capture and call-app audio capture for transcription. |
| **Accessibility** | Global hotkeys and keystroke injection via `CGEvent`. |
| **Speech Recognition** | On-device transcription of the call app's audio output. |

On first launch a modal alert lists the missing permissions. Grant them in **System Settings > Privacy & Security**, then restart Hermes.

### Important: TCC grants are tied to the code signature

If you rebuild and the binary's signature changes, macOS may deny permissions even though Hermes still appears in System Settings. `tccd` logs this as:

```
Failed to match existing code requirement for subject com.hermes.app
and service kTCCServiceScreenCapture
    cdhash H"..."
```

To fix:

1. Use `make cert` and `make bundle` so the same self-signed identity signs every build.
2. Or, after an ad-hoc rebuild, reset TCC for `com.hermes.app`:

```bash
tccutil reset Accessibility com.hermes.app
tccutil reset ScreenCapture com.hermes.app
tccutil reset SpeechRecognition com.hermes.app
```

Then relaunch and grant the prompts again.

### Known current behaviour

The app now starts and shows a startup permission alert instead of silently exiting. The overlay renders after the alert is dismissed and permissions are granted. Global hotkeys are optional: if Accessibility is not granted, hotkeys are disabled but the overlay can still be used via its buttons.

---

## Usage

### Global hotkeys

| Action | Combo | Behaviour |
|--------|-------|-----------|
| Capture | **CMD+H** | Capture the remembered region into the attachment tray. First use opens the region selector. |
| Send | **CMD+Enter** | Send the input + queued screenshots to Groq if the rate-limit indicator is green. |
| Type answer | **CMD+T** | Run a 5-second countdown, then type the buffered answer into the focused field. |
| Toggle listen | **CMD+L** | Start or stop live transcription of the call app's audio into the input box. |
| Cancel / abort | **ESC** | Cancel the countdown or abort an in-progress type. |

### Overlay UI

The command bar is a floating native panel with:

- **Mic button** - toggles Listen (CMD+L).
- **Input field** - type or edit the question; Return sends.
- **Status cluster** - busy spinner, rate-limit dot (green steady / red pulsing), and clears-in countdown.
- **Monitor button** - capture (CMD+H).
- **Paperclip** - attachment tray with a count badge.
- **History** - in-session questions and answers.
- **Gear** - Settings.

The answer panel drops down under the bar and streams the response. Code is rendered monospaced. The most recent answer is buffered for CMD+T.

---

## Settings and configuration

Open Settings from the gear icon in the overlay. The following are persisted to `~/Library/Application Support/Hermes/config.json` with `0600` permissions:

| Setting | Default | Notes |
|---------|---------|-------|
| Groq API key | (empty) | Required to send. Can be overridden with the `HERMES_API_KEY` env var for development. |
| Model | `meta-llama/llama-4-scout-17b-16e-instruct` | Any OpenAI-compatible Groq model. |
| Stealth | `true` | Tries to hide the overlay from screen capture. |
| Humanise typing | `false` | Adds variable cadence to the auto-typer. |
| Typing delay | (set in UI) | Base delay between keystrokes. |
| Resume | (empty) | PDF or text resume used to build the candidate profile. |
| Speech locale | system locale | Locale passed to the on-device transcriber. |
| Context turns | `12` | Max prior turns kept in the session thread. |
| Image window | `1` | Recent screenshots resent as images for visual continuity. Max `5`. |

---

## Architecture highlights

### Request to Groq

Each send is an OpenAI-compatible `chat/completions` request:

```json
{
  "model": "meta-llama/llama-4-scout-17b-16e-instruct",
  "stream": true,
  "temperature": 0,
  "top_p": 1,
  "max_completion_tokens": 2048,
  "messages": [
    { "role": "system", "content": "<Hermes system prompt + candidate profile>" },
    { "role": "user", "content": [{ "type": "text", "text": "..." }] },
    { "role": "assistant", "content": "..." },
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "<current question>" },
        { "type": "image_url", "image_url": { "url": "data:image/png;base64,<shot 1>" } }
      ]
    }
  ]
}
```

The system prompt forces a three-way classification:

- **SELECT** - output `Select X` (or `Select A and B`).
- **CODE** - output only the code, in the language implied by the screen.
- **SENTENCE** - output natural prose, obeying the humanizer rules (no em dashes, no banned AI vocabulary, British spelling, varied rhythm).

If no question is found, the model outputs exactly `No question detected`.

### Session threading

The conversation is kept in memory as a thread of turns. Each send carries prior assistant answers as text and prior user instructions as text. Old screenshots are dropped by default; only a small configurable image window of recent screenshots is resent to control token cost.

### Stealth overlay

Stealth is best-effort, not guaranteed, especially against native ScreenCaptureKit capture on current macOS. The technique applied:

- `setSharingType:NSWindowSharingNone` blocks the legacy capture path.
- `setLevel:kCGAssistiveTechHighWindowLevelKey` floats the panel above the normally captured desktop layer.
- Collection behaviour keeps it off Mission Control and the app switcher.
- Hermes is excluded from its own screenshots via `SCContentFilter`, so the overlay never pollutes the image sent to Groq.

### Speech transcription

On macOS 26+, Hermes uses `SpeechAnalyzer` with `SpeechTranscriber` for long-form, on-device, progressive transcription of the call app's audio output. On older macOS it falls back to `SFSpeechRecognizer`. No microphone permission is required because the audio source is the call app, not the mic.

---

## Security and privacy

- No telemetry, no analytics, no network calls except to the configured Groq endpoint.
- Screenshots are captured in-process and held in memory only. They are never written to disk or placed on the clipboard.
- The session thread is never persisted.
- Transcription runs on-device; audio is not uploaded or written to disk.
- The Groq API key is never hardcoded. It is loaded from config or the `HERMES_API_KEY` env var.
- The local config file is created with `0600` permissions.

---

## Development notes

- All UI code runs on the macOS main thread. The app uses `golang.design/x/mainthread`, and native UI calls are dispatched to the main queue where necessary.
- The overlay is implemented in Objective-C via cgo (`internal/overlay/overlay_darwin.m`).
- The transcriber is implemented in Swift and linked as a static library (`internal/speech/libspeechswift.a`).
- Code signing: prefer `make cert` for stable TCC grants. Ad-hoc signing works but requires resetting TCC after each rebuild.

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---------|--------------|-----|
| App launches then immediately exits | Hotkey registration failed due to missing Accessibility permission. | This should no longer fatal-exit. If it still does, check `~/Library/Logs/DiagnosticReports/` and ensure Accessibility is granted. |
| "Failed to match existing code requirement" in `tccd` logs | Binary signature changed; TCC entry is stale. | Use `make cert`, or run `tccutil reset` for all three services and re-grant. |
| Overlay does not appear | Modal permission alert is blocking, or permissions are still missing. | Click OK on the alert, grant the three permissions, restart Hermes. |
| Hotkeys do not work | Accessibility not granted. | Grant Accessibility to Hermes in System Settings and restart. |
| Capture is black | Screen Recording not granted. | Grant Screen Recording and restart. |
| Listen does not transcribe | Speech Recognition not granted, or SDK is too old. | Grant Speech Recognition; ensure macOS 26 SDK for SpeechAnalyzer. |
| Build fails with SDK error | SDK major version < 26. | Install Xcode 16 / macOS 26 SDK or later. |

Useful diagnostic commands:

```bash
# Verify the signature
codesign -dvv /Applications/Hermes.app

# Watch TCC decisions for Hermes
log stream --predicate 'process == "tccd" AND eventMessage CONTAINS "hermes"'

# Watch Hermes logs
log stream --predicate 'process == "hermes"'
```

---

## License

MIT License - see [LICENSE](./LICENSE).
