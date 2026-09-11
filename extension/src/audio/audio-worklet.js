class HermesCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const sab = options.processorOptions?.ring;
    this.control = sab ? new Int32Array(sab, 0, 4) : null;
    this.ring = sab ? new Int16Array(sab, Int32Array.BYTES_PER_ELEMENT * 4) : null;
    this.pending = new Float32Array(2048);
    this.pendingLength = 0;
  }

  process(inputs) {
    const input = inputs[0]?.[0];
    if (!input?.length) return true;
    if (this.ring) this.writeRing(input);
    else this.writeTransfer(input);
    return true;
  }

  writeRing(input) {
    let write = Atomics.load(this.control, 0);
    const read = Atomics.load(this.control, 1);
    const capacity = this.ring.length;
    const available = (read - write - 1 + capacity) % capacity;
    const count = Math.min(input.length, available);
    for (let index = 0; index < count; index += 1) {
      this.ring[write] = Math.max(-32768, Math.min(32767, input[index] * 32767));
      write = (write + 1) % capacity;
    }
    if (count < input.length) Atomics.add(this.control, 3, input.length - count);
    Atomics.store(this.control, 0, write);
    Atomics.notify(this.control, 0, 1);
  }

  writeTransfer(input) {
    let offset = 0;
    while (offset < input.length) {
      const count = Math.min(input.length - offset, this.pending.length - this.pendingLength);
      this.pending.set(input.subarray(offset, offset + count), this.pendingLength);
      this.pendingLength += count;
      offset += count;
      if (this.pendingLength === this.pending.length) {
        const block = this.pending;
        this.pending = new Float32Array(2048);
        this.pendingLength = 0;
        this.port.postMessage({ type: "samples", samples: block }, [block.buffer]);
      }
    }
  }
}

registerProcessor("hermes-capture", HermesCaptureProcessor);
