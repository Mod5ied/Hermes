import { PassDO, PassState } from "./pass_do";
import { MODELS, ModelInfo, providerKey, costMicros } from "./pricing";
import { signToken, verifyToken, sha256hex } from "./token";
import { meterStream } from "./meter";

export { PassDO };

const PASS_BUDGET_MICROS = 4_000_000;
const TOKEN_TTL_SEC = 24 * 60 * 60;

type RouteHandler = (req: Request, env: any) => Promise<Response>;

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
}

function stubFor(env: any, passId: string): PassDO {
  return env.PASS.get(env.PASS.idFromName(passId)) as unknown as PassDO;
}

function authorized(req: Request, env: any): boolean {
  return req.headers.get("authorization") === `Bearer ${env.ADMIN_SECRET}`;
}

async function issuePass(req: Request, env: any): Promise<Response> {
  if (!authorized(req, env)) return json({ error: "unauthorized" }, 401);
  const { email } = (await req.json()) as any;
  const passKey = "HRMS-" + crypto.randomUUID().replace(/-/g, "").toUpperCase();
  const passId = await sha256hex(passKey);
  await stubFor(env, passId).init(PASS_BUDGET_MICROS, email ?? "");
  return json({ pass_key: passKey, budget_micros: PASS_BUDGET_MICROS });
}

async function revokePass(req: Request, env: any): Promise<Response> {
  if (!authorized(req, env)) return json({ error: "unauthorized" }, 401);
  const { pass_key } = (await req.json()) as any;
  const passId = await sha256hex(pass_key);
  await stubFor(env, passId).revoke();
  return json({ ok: true });
}

function activationStateError(state: PassState): Response | null {
  if (!state.exists) return json({ error: "invalid_pass", message: "Pass key not recognised." }, 404);
  if (state.status === "revoked") return json({ error: "revoked", message: "This pass has been revoked." }, 403);
  if (state.budgetMicros <= 0) return json({ error: "pass_exhausted", message: "This pass is used up. Top up to continue." }, 402);
  return null;
}

async function activate(req: Request, env: any): Promise<Response> {
  const { pass_key } = (await req.json()) as any;
  if (!pass_key) return json({ error: "missing_pass_key" }, 400);
  const passId = await sha256hex(pass_key);
  const state: PassState = await stubFor(env, passId).state();
  const error = activationStateError(state);
  if (error) return error;
  const token = await signToken(passId, TOKEN_TTL_SEC, env.TOKEN_SECRET);
  const pct = balancePercentage(state.budgetMicros, state.budgetTotalMicros);
  return json({ token, expires_in: TOKEN_TTL_SEC, balance_micros: state.budgetMicros, balance_pct: pct });
}

function solveStateError(state: PassState): Response | null {
  if (!state.exists) return json({ error: "invalid_token", message: "Re-activate your pass." }, 401);
  if (state.status === "revoked") return json({ error: "revoked", message: "This pass has been revoked." }, 403);
  if (state.budgetMicros <= 0) {
    return json({ error: "pass_exhausted", message: "Your Hermes Pass is used up. Top up to continue.", balance_pct: 0 }, 402);
  }
  return null;
}

function bearerToken(req: Request): string {
  const auth = req.headers.get("authorization") || "";
  return auth.startsWith("Bearer ") ? auth.slice(7) : "";
}

function configureRequest(body: any, model: string): void {
  body.stream = true;
  body.stream_options = { include_usage: true };
  if (model.startsWith("gpt-oss") && !body.reasoning_effort) body.reasoning_effort = "low";
}

async function callProvider(body: any, info: ModelInfo, env: any): Promise<Response> {
  return fetch(`${info.baseURL}/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", "authorization": `Bearer ${providerKey(env, info.provider)}` },
    body: JSON.stringify(body),
  });
}

async function providerError(upstream: Response): Promise<Response | null> {
  if (upstream.ok && upstream.body) return null;
  const text = await upstream.text().catch(() => "");
  return json({ error: "provider_error", status: upstream.status, message: text.slice(0, 500) }, 502);
}

function usageTokens(usage: any, approxChars: number): [number, number] {
  if (!usage) return [1500, Math.ceil(approxChars / 4)];
  const { prompt_tokens: prompt = 0, completion_tokens: completion = 0 } = usage;
  return [prompt, completion];
}

function debitAfterStream(model: string, stub: PassDO, totalMicros: number) {
  return async (usage: any, approxChars: number) => {
    const [prompt, completion] = usageTokens(usage, approxChars);
    const cost = costMicros(model, prompt, completion);
    const balance = await stub.debit(cost);
    return { balanceMicros: balance, budgetTotalMicros: totalMicros, costMicros: cost };
  };
}

function balancePercentage(balance: number, total: number): number {
  if (total <= 0) return 0;
  return Math.max(0, Math.round((100 * balance) / total));
}

function streamResponse(upstream: Response, state: PassState, onDone: ReturnType<typeof debitAfterStream>): Response {
  return new Response(meterStream(upstream.body!, onDone), {
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      "x-hermes-balance-micros": String(state.budgetMicros),
    },
  });
}

async function solve(req: Request, env: any): Promise<Response> {
  const passId = await verifyToken(bearerToken(req), env.TOKEN_SECRET);
  if (!passId) return json({ error: "invalid_token", message: "Re-activate your pass." }, 401);
  const stub = stubFor(env, passId);
  const state: PassState = await stub.state();
  const stateError = solveStateError(state);
  if (stateError) return stateError;
  const body = await req.json() as any;
  const model: string = body.model;
  const info = MODELS[model];
  if (!info) return json({ error: "unsupported_model", message: `Unknown model ${model}` }, 400);
  configureRequest(body, model);
  const upstream = await callProvider(body, info, env);
  const error = await providerError(upstream);
  if (error) return error;
  return streamResponse(upstream, state, debitAfterStream(model, stub, state.budgetTotalMicros));
}

const routes: Record<string, RouteHandler> = {
  "POST /admin/issue": issuePass,
  "POST /admin/revoke": revokePass,
  "POST /activate": activate,
  "POST /v1/solve": solve,
};

export default {
  async fetch(req: Request, env: any, _ctx: ExecutionContext): Promise<Response> {
    const handler = routes[`${req.method} ${new URL(req.url).pathname}`];
    if (!handler) return json({ error: "not_found" }, 404);
    return handler(req, env);
  },
};
