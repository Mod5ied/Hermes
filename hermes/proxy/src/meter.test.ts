import { describe, it, expect } from "vitest";
import { meterStream } from "./meter";

function streamFromString(body: string): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      controller.enqueue(enc.encode(body));
      controller.close();
    },
  });
}

async function collectStream(stream: ReadableStream<Uint8Array>): Promise<string> {
  const dec = new TextDecoder();
  const reader = stream.getReader();
  let result = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    result += dec.decode(value, { stream: true });
  }
  result += dec.decode();
  return result;
}

describe("meterStream", () => {
  it("forwards provider events and injects balance before [DONE]", async () => {
    const input =
      `data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n` +
      `data: {"usage":{"prompt_tokens":10,"completion_tokens":3}}\n\n` +
      `data: [DONE]\n\n`;

    let debited = false;
    const onDone = async (usage: any, approxChars: number) => {
      debited = true;
      expect(usage).toEqual({ prompt_tokens: 10, completion_tokens: 3 });
      expect(approxChars).toBe(5);
      return { balanceMicros: 3_900_000, budgetTotalMicros: 4_000_000, costMicros: 100_000 };
    };

    const output = meterStream(streamFromString(input), onDone);
    const text = await collectStream(output);

    expect(text).toContain('data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n');
    expect(text).toContain('"balance_pct":98');
    expect(text).toContain("data: [DONE]\n\n");
    expect(debited).toBe(true);
  });

  it("falls back to character estimate when usage is missing", async () => {
    const input =
      `data: {"choices":[{"delta":{"content":"Hello world"}}]}\n\n` +
      `data: [DONE]\n\n`;

    let debited = false;
    const onDone = async (usage: any, approxChars: number) => {
      debited = true;
      expect(usage).toBeNull();
      expect(approxChars).toBe(11);
      return { balanceMicros: 3_900_000, budgetTotalMicros: 4_000_000, costMicros: 100_000 };
    };

    const output = meterStream(streamFromString(input), onDone);
    const text = await collectStream(output);

    expect(text).toContain('data: {"choices":[{"delta":{"content":"Hello world"}}]}\n\n');
    expect(text).toContain('"balance_pct":98');
    expect(text).toContain("data: [DONE]\n\n");
    expect(debited).toBe(true);
  });

  it("injects zero percent when budget is exhausted", async () => {
    const input =
      `data: {"choices":[{"delta":{"content":"x"}}]}\n\n` +
      `data: [DONE]\n\n`;

    const onDone = async () => ({
      balanceMicros: 0,
      budgetTotalMicros: 4_000_000,
      costMicros: 4_000_000,
    });

    const output = meterStream(streamFromString(input), onDone);
    const text = await collectStream(output);

    expect(text).toContain('"balance_pct":0');
  });

  it("ignores reasoning deltas and counts only content", async () => {
    const input =
      `data: {"choices":[{"delta":{"reasoning":"The user asks..."}}]}\n\n` +
      `data: {"choices":[{"delta":{"reasoning":". Should be concise..."}}]}\n\n` +
      `data: {"choices":[{"delta":{"content":"Hello!"}}]}\n\n` +
      `data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":54,"completion_tokens_details":{"reasoning_tokens":42},"prompt_tokens":87}}\n\n` +
      `data: [DONE]\n\n`;

    let debitedUsage: any = null;
    let debitedChars = 0;
    const onDone = async (usage: any, approxChars: number) => {
      debitedUsage = usage;
      debitedChars = approxChars;
      return { balanceMicros: 3_900_000, budgetTotalMicros: 4_000_000, costMicros: 100_000 };
    };

    const output = meterStream(streamFromString(input), onDone);
    const text = await collectStream(output);

    expect(text).toContain('data: {"choices":[{"delta":{"content":"Hello!"}}]}\n\n');
    expect(text).toContain('"balance_pct":98');
    expect(text).toContain("data: [DONE]\n\n");
    expect(debitedUsage).toEqual({
      completion_tokens: 54,
      completion_tokens_details: { reasoning_tokens: 42 },
      prompt_tokens: 87,
    });
    expect(debitedChars).toBe(6); // only "Hello!" counted, not the reasoning chunks
  });
});
