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
      while (buf.includes("\n\n")) {
        const idx = buf.indexOf("\n\n");
        const evt = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        const data = eventData(evt);
        if (data === "[DONE]") {
          await emitDone(controller, enc, onDone, usage, contentChars);
        } else {
          const parsed = parseUsageEvent(data);
          usage = parsed.usage ?? usage;
          contentChars += parsed.contentChars;
          controller.enqueue(enc.encode(evt + "\n\n"));
        }
      }
    },
    flush(controller) {
      if (buf) controller.enqueue(enc.encode(buf));
    },
  });

  return providerBody.pipeThrough(t);
}

function eventData(event: string): string {
  const line = event.split("\n").find(candidate => candidate.startsWith("data:"));
  return line ? line.slice(5).trim() : "";
}

function parseUsageEvent(data: string): { usage: any; contentChars: number } {
  if (!data) return { usage: null, contentChars: 0 };
  try {
    const parsed = JSON.parse(data);
    return { usage: parsed.usage ?? null, contentChars: contentLength(parsed) };
  } catch {
    return { usage: null, contentChars: 0 };
  }
}

function contentLength(parsed: any): number {
  const piece = parsed.choices?.[0]?.delta?.content;
  return typeof piece === "string" ? piece.length : 0;
}

async function emitDone(controller: TransformStreamDefaultController<Uint8Array>, enc: TextEncoder, onDone: DebitFn, usage: any, chars: number): Promise<void> {
  const result = await onDone(usage, chars);
  const pct = result.budgetTotalMicros > 0
    ? Math.max(0, Math.round((100 * result.balanceMicros) / result.budgetTotalMicros)) : 0;
  const injected = JSON.stringify({ hermes: { balance_micros: result.balanceMicros, balance_pct: pct, cost_micros: result.costMicros } });
  controller.enqueue(enc.encode(`data: ${injected}\n\n`));
  controller.enqueue(enc.encode("data: [DONE]\n\n"));
}
