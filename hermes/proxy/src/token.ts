function b64url(buf: ArrayBuffer | Uint8Array): string {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function fromB64url(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}
async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function signToken(passId: string, ttlSec: number, secret: string): Promise<string> {
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ p: passId, e: Math.floor(Date.now()/1000) + ttlSec })));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), new TextEncoder().encode(payload));
  return `${payload}.${b64url(sig)}`;
}

export async function verifyToken(token: string, secret: string): Promise<string | null> {
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return null;
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret),
    fromB64url(sig), new TextEncoder().encode(payload));
  if (!ok) return null;
  const body = JSON.parse(new TextDecoder().decode(fromB64url(payload)));
  if (!body.e || body.e < Math.floor(Date.now()/1000)) return null; // expired
  return body.p as string;
}

export async function sha256hex(s: string): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(h)].map(b => b.toString(16).padStart(2, "0")).join("");
}
