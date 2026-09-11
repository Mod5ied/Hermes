# SKILLS.md

## Core Philosophy
- Bare-metal performance, minimalist design, zero aesthetic bloat, top speed.
- UI must be a pixel-perfect replica of the native desktop app with no visual changes.

## Browser Extension (Chrome & Mozilla)
- **APIs:** Manifest V3 (Chrome), WebExtensions API (Firefox).
- **Hardware Acceleration:** WebGPU, WebGL, zero-overhead Canvas/WebGL UI rendering.
- **Concurrency & Audio:** Web Workers, SharedArrayBuffer, Rust/WASM for audio processing and STT.
- **Capture:** `chrome.tabCapture`, `getDisplayMedia`, efficient audio stream routing.
- **Performance:** Strict memory management, minimal IPC overhead, zero main-thread blocking.

## Windows Desktop Optimization
- **Languages & Runtimes:** C++, Rust, Go, WASM.
- **STT & AI:** Whisper.cpp (quantized), ONNX Runtime, Intel MKL.
- **Hardware Optimization:** SIMD, AVX2, CPU instruction set optimizations for Intel Core i5 (Skylake).
- **Audio Processing:** WebRTC VAD, low-level Windows Speech API integration, minimal latency audio preprocessing.
- **Resource Management:** Ultra-low CPU/RAM footprint, background thread prioritization.