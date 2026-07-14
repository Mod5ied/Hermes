type DebitFn = (usage: { prompt_tokens: number; completion_tokens: number } | null, approxCompletionChars: number)
  => Promise<{ balanceMicros: number; budgetTotalMicros: number; costMicros: number }>;

export function meterStream(providerBody: ReadableStream<Uint8Array>, onDone: DebitFn): ReadableStream<Uint8Array> {
  const dec = new TextDecoder();
  const enc = new TextEncoder();
  let buf = "";
  let usage: any = null;
  let contentChars = 0;

  const t = new TransformStream<Uint8Array, Uint8Array>({
    async transform(chunk, controller) {
      buf += dec.decode(chunk, { stream: true });
      let idx: number;
      while ((idx = buf.indexOf("\n\n")) >= 0) {
        const evt = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        const dataLine = evt.split("\n").find(l => l.startsWith("data:"));
        const data = dataLine ? dataLine.slice(5).trim() : "";

        if (data === "[DONE]") {
          const r = await onDone(usage, contentChars);
          const pct = r.budgetTotalMicros > 0
            ? Math.max(0, Math.round((100 * r.balanceMicros) / r.budgetTotalMicros)) : 0;
          const inj = JSON.stringify({ hermes: { balance_micros: r.balanceMicros, balance_pct: pct, cost_micros: r.costMicros } });
          controller.enqueue(enc.encode(`data: ${inj}\n\n`));
          controller.enqueue(enc.encode(`data: [DONE]\n\n`));
          continue;
        }
        if (data) {
          try {
            const j = JSON.parse(data);
            if (j.usage) usage = j.usage;
            const piece = j.choices?.[0]?.delta?.content;
            if (typeof piece === "string") contentChars += piece.length;
          } catch { /* keep-alive or non-json line, ignore */ }
        }
        controller.enqueue(enc.encode(evt + "\n\n"));
      }
    },
    flush(controller) {
      if (buf) controller.enqueue(enc.encode(buf));
    },
  });

  return providerBody.pipeThrough(t);
}
