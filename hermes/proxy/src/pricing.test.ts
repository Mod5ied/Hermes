import { describe, expect, it } from "vitest";
import { MODELS, costMicros } from "./pricing";

describe("Cerebras model catalogue", () => {
  it("contains only currently supported Hermes models", () => {
    const cerebras = Object.entries(MODELS)
      .filter(([, info]) => info.provider === "cerebras")
      .map(([name]) => name);

    expect(cerebras).toEqual(["gpt-oss-120b", "qwen-3.8-27b"]);
    expect(MODELS["qwen-3.8-27b"].vision).toBe(true);
  });

  it("uses the pricing currently published by the Cerebras model API", () => {
    expect(costMicros("qwen-3.8-27b", 1_000_000, 1_000_000)).toBe(0);
  });
});
