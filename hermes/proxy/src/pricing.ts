export type Provider = "cerebras" | "groq";
export interface ModelInfo {
  provider: Provider;
  baseURL: string;
  inPerM: number;   // USD per 1M input tokens (image tokens are counted in prompt_tokens)
  outPerM: number;  // USD per 1M output tokens
  vision: boolean;
}

export const MODELS: Record<string, ModelInfo> = {
  "gemma-4-31b":  { provider: "cerebras", baseURL: "https://api.cerebras.ai/v1", inPerM: 0.99, outPerM: 1.49, vision: true  },
  "gpt-oss-120b": { provider: "cerebras", baseURL: "https://api.cerebras.ai/v1", inPerM: 0.35, outPerM: 0.75, vision: false },
  "zai-glm-4.7":  { provider: "cerebras", baseURL: "https://api.cerebras.ai/v1", inPerM: 2.25, outPerM: 2.75, vision: false }, // verified price
  "meta-llama/llama-4-scout-17b-16e-instruct":
                  { provider: "groq",     baseURL: "https://api.groq.com/openai/v1", inPerM: 0.11, outPerM: 0.34, vision: true }, // from Groq docs
};

export function providerKey(env: any, p: Provider): string {
  return p === "cerebras" ? env.CEREBRAS_API_KEY : env.GROQ_API_KEY;
}

// micros = dollars * 1e6, and dollars = tokens * pricePerMillion / 1e6,
// so micros = tokens * pricePerMillion. Integer-friendly.
export function costMicros(model: string, promptTokens: number, completionTokens: number): number {
  const m = MODELS[model];
  if (!m) return 0;
  return Math.round(promptTokens * m.inPerM + completionTokens * m.outPerM);
}
