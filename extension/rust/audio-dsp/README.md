# Hermes audio DSP WASM

This `no_std` crate is the allocation-free DSP core for RMS/VAD and mono PCM
downsampling. Build it when a Rust WebAssembly target is available:

```sh
rustup target add wasm32-unknown-unknown
cargo build --manifest-path rust/audio-dsp/Cargo.toml --target wasm32-unknown-unknown --release
```

The extension's worker contains an equivalent JavaScript fallback, so browser
bundles remain functional on machines that do not have the Rust toolchain.
