# Hermes (The Fastest & Best One Yet!)

<img width="1340" height="824" alt="image" src="https://github.com/user-attachments/assets/0dada4e4-2a6b-46b1-bfca-706944c7bb76" />


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
- **Hermes Pass**: No API key handy? Activate a prepaid Pass in Settings for shared-key access instead of BYOK.
- **Overlay opacity**: Dial how visible the command bar is to your own eyes, independent of Stealth.
- **Update check**: Settings checks GitHub Releases once on open and tells you if you're current.

---

## Requirements

- macOS 14 or later (speech transcription works best on macOS 26+)
- Apple Silicon or Intel Mac
- A Groq or Cerebras API key

---

## Install

### Build from source (recommended)

The recommended way to install Hermes is to build it locally:

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
| `CMD+H` | Capture a screen region |
| `CMD+Enter` | Send your question |
| `CMD+T` | Count down, then type the last answer |
| `CMD+L` | Start/stop listening to the call |
| `Esc` | Cancel the countdown or stop typing |

Click the gear icon in the floating bar to open Settings: General, Provider & Model, Pass, Resume, Speech, Hotkeys, and About. Add your API key or a Pass, adjust typing speed and overlay opacity, paste your resume, and check for updates.

---

## Privacy

- Screenshots stay in memory; they are never saved to disk or uploaded anywhere except Groq/Cerebras as part of your question.
- Voice transcription happens on-device.
- No telemetry or analytics.

---

## License

MIT License - see [LICENSE](./LICENSE).
