# Hermes Windows STT

## Scope and target

This is the native STT foundation for the Windows port, tuned for Windows 11
and an Intel Core i5-6300U (2 physical cores / 4 logical processors, 8 GB RAM).
Low-overhead Windows capture, one-thread hotkeys, `SendInput`, permission, config
path, and runtime-resource backends now exist. The pixel-faithful native overlay
is still pending, so this work does not present the desktop app as a Windows
release.

The live path is deliberately small:

```text
WASAPI loopback (event/MMCSS)
  -> Windows high-quality conversion to float32 mono/16 kHz
  -> AVX2 float-to-PCM16 conversion
  -> WebRTC VAD, 10 ms frames
  -> three bounded, preallocated utterance slots
  -> one whisper.cpp worker, two inference threads
  -> in-process ABI polled by Go every 25 ms
```

There is no subprocess, socket, browser, WASM VM, ONNX session, or unbounded
audio queue in this path.

## Build on Windows

Install Visual Studio 2022 Build Tools with **Desktop development with C++**,
CMake, and Go. From a PowerShell prompt:

```powershell
./scripts/build-windows-stt.ps1
```

The build pins checksum-verified source archives for `whisper.cpp` v1.8.6 and
libfvad. It produces `dist/windows/hermes-stt.dll` and downloads a checksum-verified
`dist/windows/models/ggml-base.en-q5_1.bin`.

The Go executable loads both paths relative to its own directory. Overrides:

```powershell
$env:HERMES_STT_DLL = "D:\Hermes\hermes-stt.dll"
$env:HERMES_STT_MODEL = "D:\Hermes\models\ggml-base.en-q5_1.bin"
$env:HERMES_STT_THREADS = "2"
```

The DLL checks its ABI before the model is opened and refuses to run on a CPU
without AVX2.

On Windows, the shortcut backend maps documented `CMD` combinations to `Ctrl`
and services every shortcut from one blocked Win32 message-loop thread rather
than the upstream library's one polling OS thread per shortcut.

### Deterministic benchmark

The build also produces `hermes-stt-bench.exe`. It streams WAV files through
the same WebRTC VAD, bounded job slots, Whisper parameters, transcript merge,
and statistics path as live capture. It does not load the entire recording into
RAM. Input must be mono 16 kHz PCM16 or float32 so the benchmark measures STT,
not an arbitrary media decoder.

```powershell
./dist/windows/hermes-stt-bench.exe `
  --model ./dist/windows/models/ggml-base.en-q5_1.bin `
  --wav D:\stt-corpus\interview-01.wav `
  --reference D:\stt-corpus\interview-01.txt `
  --language en `
  --threads 2 `
  --max-wer 0.15
```

Use `--case WAV REFERENCE` more than once, or `--manifest cases.tsv`, to keep
one model resident across a corpus. The UTF-8 TSV format has no header and one
absolute WAV path plus reference-text path per line, separated by a tab.
`--repeat 100` tears down and restarts the worker for each repetition without
reloading the model, exposing lifecycle leaks. Corpus clips should contain one
2–10 second utterance so final-latency percentiles have a useful meaning.

Omit `--reference` and `--max-wer` for latency-only runs. Add `--fast` for an
offline throughput stress test; omit it for the authoritative real-time run.
The JSON result reports model-load time, finalization latency, aggregate decode
RTF, Task-Manager-normalized CPU, peak working set, decode count, dropped jobs,
audio discontinuities, WER, and the final transcript. Exit code 4 means an
incomplete final result or dropped work; exit code 5 means the requested WER
ceiling failed. Feed-mode benchmarks report zero audio discontinuities by
construction; the live shutdown log is the authoritative WASAPI measurement.

### Target-machine acceptance run

Create a CSV manifest with paths relative to the CSV or absolute paths:

```csv
wav,reference,category
audio/interview-001.wav,text/interview-001.txt,general
audio/code-terms-001.wav,text/code-terms-001.txt,code
audio/names-001.wav,text/names-001.txt,names
```

Then run the complete gate suite with the WER measured from the same corpus on
macOS:

```powershell
./scripts/test-windows-stt-acceptance.ps1 `
  -Manifest D:\stt-corpus\manifest.csv `
  -MacBaselineWER 0.10
```

The script performs a real-time, resident-model corpus run; 100 fast
start/stop cycles; and a 60-second live WASAPI silence test. For the silence
test it plays zero-valued PCM on the default render endpoint so loopback/VAD
remain active. It verifies the exact target CPU/core/RAM/Windows build and
writes the full evidence bundle to `dist/windows/stt-acceptance.json`.
Optional `category` values produce separate accuracy reports for code terms,
names, and any other tagged subset.

## Performance decisions

### Capture and preprocessing

- WASAPI captures the default render endpoint in shared loopback mode, which
  matches Hermes' macOS behavior of listening to call/system audio instead of
  the microphone.
- Event-driven capture avoids a polling audio loop. The Windows audio engine
  performs high-quality conversion to exactly mono float32/16 kHz, eliminating
  a second resampler and its buffers.
- The capture thread joins the `Audio` MMCSS class and only copies, converts,
  and runs VAD. Whisper never executes on that thread.
- AVX2 handles float32-to-PCM16 conversion. The selected Skylake CPU supports
  AVX2/FMA/F16C; AVX-512 and AVX-VNNI are explicitly disabled.
- libfvad provides the actual WebRTC VAD engine. Mode 1 is intentionally less
  aggressive than modes 2/3 so quiet first/last syllables are not discarded.
  A 300 ms pre-roll and 450 ms trailing-silence window preserve word edges.

### Inference

- Default model: `base.en-q5_1`, 59.7 MB on disk. It is the practical accuracy
  ceiling for sustained real-time work on this dual-core CPU.
- Accuracy trial: `small.en-q5_1`, 190.1 MB on disk. Select it with
  `-Model small.en-q5_1` and `HERMES_STT_MODEL`, but keep it only if measured
  real-time factor stays below 1.0 under the target laptop's thermal limits.
- Multilingual mode: `base-q5_1`; the Go bridge selects this default whenever
  the configured locale is not English.
- The model is loaded lazily on first listen and remains resident. That spends
  RAM to avoid repeated multi-second cold starts and model mapping churn.
- Exactly one Whisper job runs at a time with two inference threads. OpenMP is
  off and parallel processors are not used. The pinned GGML source is patched
  so both the caller and its disposable helper thread run below normal
  priority, leaving scheduling room for the UI, audio endpoint, and call.
- Intermediate decoding occurs at most every two seconds. A queued partial is
  overwritten by newer audio rather than accumulated. Final utterances replace
  stale partials.
- Full audio context remains enabled. Greedy decoding at temperature zero,
  silence suppression, a rolling text prompt, and overlap de-duplication
  protect accuracy without beam-search multiplication of CPU time.

### Hard bounds

| Resource | Bound |
|---|---:|
| Captured audio format | 16 kHz, mono, float32 |
| Active utterance | 15 seconds / 0.96 MB |
| Inference slots | 3 / 2.88 MB total |
| Pre-roll | 300 ms / 19.2 KB |
| Result queue | 16 cumulative UTF-8 results |
| Go result buffer | 64 KB, allocated once per transcriber |
| Whisper workers | 1 job, 2 threads by default |
| Poll wake-up | 25 ms while listening only |
| Go scheduler | 2 logical processors by default |
| Go heap soft limit | 384 MiB (configurable, 192–1024 MiB) |
| Global hotkeys | 1 blocked Win32 message thread |

Override the Go heap guard with `HERMES_MEMORY_LIMIT_MB`. `GOMAXPROCS` remains
an explicit escape hatch, but two is the default on the target laptop so the
Go networking/UI layer cannot compete across all four logical processors while
Whisper is decoding.

When inference cannot keep up, partial jobs are coalesced first. The engine
never grows a backlog that can consume the machine. `dropped` in the shutdown
log must remain zero; a nonzero value means the selected model is too slow.

## MKL, ONNX Runtime, Rust, and WASM

Intel oneMKL is opt-in:

```powershell
./scripts/build-windows-stt.ps1 -UseMKL -SkipModel
```

This selects GGML's Intel BLAS backend and caps MKL/OpenMP to the configured
Hermes thread count with dynamic teams disabled. It is not the default because
BLAS can add DLL footprint, memory, and nested scheduling while accelerating
only part of Whisper. Keep the MKL build only when the target laptop's measured
real-time factor improves by at least 10% with no UI latency regression.

ONNX Runtime is a sensible alternative for a Windows-native model or Silero
VAD, but running it beside GGML would duplicate allocators and thread pools.
Likewise, Rust is appropriate for a future safe Win32 UI/capture layer and
WASM for the browser extension, but either would add a boundary to this native
desktop audio hot path. The implemented desktop path therefore uses C++ for
WASAPI/SIMD/inference and Go only for lifecycle and result delivery.

Windows Speech Recognition can be added as a zero-model fallback for systems
with the required offline language pack. It should be a separate backend, not
a simultaneous second recognizer, and must be accuracy-tested against the same
corpus before automatic selection.

## Accuracy and no-lag acceptance gates

No implementation can honestly *guarantee* parity with Apple's recognizer
without measuring identical audio against ground truth. Treat Mac-level
accuracy as a release gate, not an assertion. Record at least 60 minutes of
representative interview audio (accents, laptop speakers, code terms, names)
and run the same PCM through macOS and Windows.

The Windows CI smoke test downloads the checksum-pinned model and transcribes
whisper.cpp's JFK fixture with a WER ceiling. That proves the compiled DLL,
WebRTC VAD, model, feed ABI, and decoder work together; it does not replace the
thermal/accuracy run on the i5-6300U.

Release the Windows backend only when all of these hold on the i5-6300U:

1. Word error rate is no more than 1.5 percentage points above the macOS
   baseline; named/code-term error rate is reported separately.
2. Aggregate decode time divided by voiced-audio time is below 0.80 after a
   20-minute warm run, with zero dropped jobs.
3. Final text appears within 1.5 seconds of trailing silence at p95 for
   utterances up to 10 seconds.
4. Hermes stays below 1% normalized process CPU during active loopback silence
   and below 70% across the real-time corpus, leaving the call and desktop
   responsive.
5. Process working set stays below 650 MB with `base.en-q5_1`; first-to-last
   and post-warm-up maximum growth stay within 16 MB across 100 listen/stop
   cycles (allocator/page-fault noise, not an unbounded trend).
6. WASAPI discontinuities, dropped jobs, and model/ABI errors are zero in the
   Hermes log.

If gate 2 or 4 fails, reduce `HERMES_STT_THREADS` to 1 before changing models.
If accuracy fails while performance passes comfortably, trial
`small.en-q5_1`. Do not reduce Whisper's audio context to chase a benchmark;
that optimization explicitly trades away recognition quality.
