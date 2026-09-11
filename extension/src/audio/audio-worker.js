let inputRate = 48000;
let targetRate = 16000;
let active = false;
let control;
let ring;
let pcm = [];
let pcmLength = 0;
let voicedSamples = 0;
let silentSamples = 0;
let wasm;

self.onmessage = ({ data }) => {
  if (data.type === "init") {
    inputRate = data.inputRate;
    targetRate = data.targetRate ?? 16000;
    active = true;
    loadWasm();
    if (data.ring) {
      control = new Int32Array(data.ring, 0, 4);
      ring = new Int16Array(data.ring, Int32Array.BYTES_PER_ELEMENT * 4);
      drainRing();
    }
  } else if (data.type === "samples") {
    ingestFloat(data.samples);
  } else if (data.type === "stop") {
    active = false;
    flush(true);
    if (control) Atomics.store(control, 2, 1);
    self.postMessage({ type: "stopped" });
  }
};

async function drainRing() {
  while (active && control && ring) {
    const write = Atomics.load(control, 0);
    let read = Atomics.load(control, 1);
    if (read === write) {
      if (Atomics.waitAsync) await Atomics.waitAsync(control, 0, write, 120).value;
      else await new Promise((resolve) => setTimeout(resolve, 20));
      continue;
    }
    const available = write >= read ? write - read : ring.length - read + write;
    const block = new Float32Array(available);
    for (let index = 0; index < available; index += 1) {
      block[index] = ring[read] / 32768;
      read = (read + 1) % ring.length;
    }
    Atomics.store(control, 1, read);
    ingestFloat(block);
  }
}

function ingestFloat(samples) {
  const downsampled = downsample(samples, inputRate, targetRate);
  if (!downsampled.length) return;
  let energy = 0;
  for (let index = 0; index < downsampled.length; index += 1) energy += downsampled[index] * downsampled[index];
  const voiced = Math.sqrt(energy / downsampled.length) > 0.012;
  if (voiced) {
    voicedSamples += downsampled.length;
    silentSamples = 0;
  } else {
    silentSamples += downsampled.length;
  }
  pcm.push(downsampled);
  pcmLength += downsampled.length;
  const longEnough = pcmLength >= targetRate * 12;
  const utteranceEnded = voicedSamples >= targetRate * 0.65 && silentSamples >= targetRate * 0.9;
  if (longEnough || utteranceEnded) flush(false);
}

function flush(force) {
  if (!pcmLength || (!force && voicedSamples < targetRate * 0.35)) {
    if (force || pcmLength > targetRate * 2) reset();
    return;
  }
  const output = new Int16Array(pcmLength);
  let offset = 0;
  for (const chunk of pcm) {
    for (let index = 0; index < chunk.length; index += 1) {
      output[offset + index] = Math.max(-32768, Math.min(32767, chunk[index] * 32767));
    }
    offset += chunk.length;
  }
  const wav = encodeWav(output, targetRate);
  self.postMessage({ type: "segment", wav }, [wav]);
  reset();
}

function reset() {
  pcm = [];
  pcmLength = 0;
  voicedSamples = 0;
  silentSamples = 0;
}

function downsample(input, fromRate, toRate) {
  if (fromRate === toRate) return input;
  const wasmResult = downsampleWasm(input, fromRate, toRate);
  if (wasmResult) return wasmResult;
  const ratio = fromRate / toRate;
  const length = Math.floor(input.length / ratio);
  const output = new Float32Array(length);
  for (let out = 0; out < length; out += 1) {
    const start = Math.floor(out * ratio);
    const end = Math.min(input.length, Math.floor((out + 1) * ratio));
    let sum = 0;
    for (let index = start; index < end; index += 1) sum += input[index];
    output[out] = sum / Math.max(1, end - start);
  }
  return output;
}

async function loadWasm() {
  try {
    const url = new URL("../../wasm/audio_dsp.wasm", self.location.href);
    const response = await fetch(url);
    if (!response.ok) return;
    const module = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    wasm = module.instance.exports;
  } catch { /* The Rust artifact is optional; retain the zero-copy JS path. */ }
}

function downsampleWasm(input, fromRate, toRate) {
  if (!wasm?.memory || input.length > wasm.hermes_buffer_capacity()) return null;
  const inputPointer = wasm.hermes_input_ptr();
  const outputPointer = wasm.hermes_output_ptr();
  new Float32Array(wasm.memory.buffer, inputPointer, input.length).set(input);
  const count = wasm.hermes_downsample_i16(inputPointer, input.length, outputPointer, input.length, fromRate, toRate);
  const source = new Int16Array(wasm.memory.buffer, outputPointer, count);
  const output = new Float32Array(count);
  for (let index = 0; index < count; index += 1) output[index] = source[index] / 32768;
  return output;
}

function encodeWav(samples, rate) {
  const buffer = new ArrayBuffer(44 + samples.byteLength);
  const view = new DataView(buffer);
  writeAscii(view, 0, "RIFF");
  view.setUint32(4, 36 + samples.byteLength, true);
  writeAscii(view, 8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(view, 36, "data");
  view.setUint32(40, samples.byteLength, true);
  new Int16Array(buffer, 44).set(samples);
  return buffer;
}

function writeAscii(view, offset, value) {
  for (let index = 0; index < value.length; index += 1) view.setUint8(offset + index, value.charCodeAt(index));
}
