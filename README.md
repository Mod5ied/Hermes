# Hermes (The Fastest & Best One Yet!)

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

---

## Requirements

- macOS 14 or later (speech transcription works best on macOS 26+)
- Apple Silicon or Intel Mac
- A Groq or Cerebras API key

---

## Install

Download `Hermes.app` from the [Releases](../../releases) page.

The first time you run Hermes you will be asked to grant **Screen Recording**, **Accessibility**, and **Speech Recognition** permissions in System Settings. Restart the app after granting them.

> **Tip:** If you plan to rebuild often, run `make cert` once before `make bundle`. This creates a self-signed certificate so macOS does not reset your permissions on every rebuild.

---

## Quick usage

| Shortcut | What it does |
|----------|--------------|
| `CMD+H` | Capture a screen region |
| `CMD+Enter` | Send your question |
| `CMD+T` | Count down, then type the last answer |
| `CMD+L` | Start/stop listening to the call |
| `Esc` | Cancel the countdown or stop typing |

Click the gear icon in the floating bar to add your API key, adjust typing speed, and paste your resume.

---

## Privacy

- Screenshots stay in memory; they are never saved to disk or uploaded anywhere except Groq as part of your question.
- Voice transcription happens on-device.
- No telemetry or analytics.

---

## License

MIT License — see [LICENSE](./LICENSE).
