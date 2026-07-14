import { PassDO, PassState } from "./pass_do";
import { MODELS, providerKey, costMicros } from "./pricing";
import { signToken, verifyToken, sha256hex } from "./token";
import { meterStream } from "./meter";

export { PassDO };

const PASS_BUDGET_MICROS = 4_000_000;   // $4 funded per $5 sale
const TOKEN_TTL_SEC = 24 * 60 * 60;

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
}
function stubFor(env: any, passId: string) {
  return env.PASS.get(env.PASS.idFromName(passId)) as unknown as PassDO;
}

export default {
  async fetch(req: Request, env: any, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // ---- admin: issue a pass (payment webhook or manual) ----
    if (url.pathname === "/admin/issue" && req.method === "POST") {
      if (req.headers.get("authorization") !== `Bearer ${env.ADMIN_SECRET}`) return json({ error: "unauthorized" }, 401);
      const { email } = (await req.json()) as any;
      const passKey = "HRMS-" + crypto.randomUUID().replace(/-/g, "").toUpperCase();
      const passId = await sha256hex(passKey);
      await stubFor(env, passId).init(PASS_BUDGET_MICROS, email ?? "");
      return json({ pass_key: passKey, budget_micros: PASS_BUDGET_MICROS });
    }

    if (url.pathname === "/admin/revoke" && req.method === "POST") {
      if (req.headers.get("authorization") !== `Bearer ${env.ADMIN_SECRET}`) return json({ error: "unauthorized" }, 401);
      const { pass_key } = (await req.json()) as any;
      const passId = await sha256hex(pass_key);
      await stubFor(env, passId).revoke();
      return json({ ok: true });
    }

    // ---- activate: pass key -> short-lived token + starting balance ----
    if (url.pathname === "/activate" && req.method === "POST") {
      const { pass_key } = (await req.json()) as any;
      if (!pass_key) return json({ error: "missing_pass_key" }, 400);
      const passId = await sha256hex(pass_key);
      const st: PassState = await stubFor(env, passId).state();
      if (!st.exists) return json({ error: "invalid_pass", message: "Pass key not recognised." }, 404);
      if (st.status === "revoked") return json({ error: "revoked", message: "This pass has been revoked." }, 403);
      if (st.budgetMicros <= 0) return json({ error: "pass_exhausted", message: "This pass is used up. Top up to continue." }, 402);
      const token = await signToken(passId, TOKEN_TTL_SEC, env.TOKEN_SECRET);
      const pct = Math.max(0, Math.round((100 * st.budgetMicros) / st.budgetTotalMicros));
      return json({ token, expires_in: TOKEN_TTL_SEC, balance_micros: st.budgetMicros, balance_pct: pct });
    }

    // ---- solve: authenticated, metered, streamed ----
    if (url.pathname === "/v1/solve" && req.method === "POST") {
      const auth = req.headers.get("authorization") || "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      const passId = await verifyToken(token, env.TOKEN_SECRET);
      if (!passId) return json({ error: "invalid_token", message: "Re-activate your pass." }, 401);

      const stub = stubFor(env, passId);
      const st: PassState = await stub.state();
      if (!st.exists || st.status === "revoked") return json({ error: "invalid_token" }, 401);
      if (st.budgetMicros <= 0) return json({ error: "pass_exhausted", message: "Your Hermes Pass is used up. Top up to continue.", balance_pct: 0 }, 402);

      const body = await req.json() as any;
      const model: string = body.model;
      const info = MODELS[model];
      if (!info) return json({ error: "unsupported_model", message: `Unknown model ${model}` }, 400);

      // Force streaming with usage accounting, no matter what the client sent.
      body.stream = true;
      body.stream_options = { include_usage: true };

      const upstream = await fetch(`${info.baseURL}/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json", "authorization": `Bearer ${providerKey(env, info.provider)}` },
        body: JSON.stringify(body),
      });

      if (!upstream.ok || !upstream.body) {
        const text = await upstream.text().catch(() => "");
        return json({ error: "provider_error", status: upstream.status, message: text.slice(0, 500) }, 502);
      }

      const onDone = async (usage: any, approxChars: number) => {
        let pt = usage?.prompt_tokens ?? 0;
        let ct = usage?.completion_tokens ?? 0;
        if (!usage) { ct = Math.ceil(approxChars / 4); pt = 1500; } // fallback so a missing usage block is never free
        const cost = costMicros(model, pt, ct);
        const balance = await stub.debit(cost);
        return { balanceMicros: balance, budgetTotalMicros: st.budgetTotalMicros, costMicros: cost };
      };

      return new Response(meterStream(upstream.body, onDone), {
        headers: {
          "content-type": "text/event-stream; charset=utf-8",
          "cache-control": "no-cache",
          "x-hermes-balance-micros": String(st.budgetMicros), // balance at request start; trailing event has the post-debit value
        },
      });
    }

    return json({ error: "not_found" }, 404);
  },
};
