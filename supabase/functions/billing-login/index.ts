import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
  });

function keyFromMap(name: string): string {
  const raw = Deno.env.get(name);
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") {
      const def = parsed.default;
      if (typeof def === "string" && def) return def;
      const first = Object.values(parsed).find((v) => typeof v === "string" && v.length > 0);
      if (typeof first === "string") return first;
    }
  } catch (_) {}
  return "";
}
function secretKey(): string {
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    || Deno.env.get("SUPABASE_SECRET_KEY")
    || keyFromMap("SUPABASE_SECRET_KEYS");
}
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
function invalidCredentials() {
  return json(401, { ok: false, error: "INVALID_CREDENTIALS" });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });

  const url = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
  const secret = secretKey();
  if (!url || !secret) return json(503, { ok: false, error: "LOGIN_SERVICE_UNAVAILABLE" });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return json(400, { ok: false, error: "INVALID_REQUEST" });
  }
  const username = String(body.username ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  if (!username || username.length > 80 || !password || password.length > 256) {
    return json(400, { ok: false, error: "INVALID_REQUEST" });
  }

  try {
    const admin = createClient(url, secret, {
      db: { schema: "api" },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const usernameKey = await sha256Hex(secret + "|billing-login-username|" + username);
    const keyHashes = [usernameKey];
    const clientIp = (req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "").trim().slice(0, 128);
    if (clientIp) keyHashes.push(await sha256Hex(secret + "|billing-login-ip|" + clientIp));

    for (const keyHash of keyHashes) {
      const { data: limit, error: limitError } = await admin.rpc("admin_login_rate_limit_consume", {
        p_key_hash: keyHash,
      });
      if (limitError || !limit || limit.allowed !== true) {
        const retry = Math.max(1, Math.min(900, Number(limit?.retry_after_seconds) || 60));
        return json(429, { ok: false, error: "INVALID_CREDENTIALS" }, { "Retry-After": String(retry) });
      }
    }

    // Invoke the existing billing-auth RPC server-side. The persistent rate-limit
    // transaction commits separately, so a credential exception cannot roll it back.
    const { data, error } = await admin.rpc("billing_login", {
      p_username: username,
      p_password: password,
    });

    if (error || !data || data.ok !== true || typeof data.token !== "string") {
      const msg = String(error?.message || "");
      if (msg.includes("INVALID_CREDENTIALS") || msg.includes("BILLING_CONTROL_ACCESS_DENIED")) {
        return invalidCredentials();
      }
      console.error("billing-login backend RPC failed");
      return json(503, { ok: false, error: "LOGIN_SERVICE_UNAVAILABLE" });
    }

    const { error: clearError } = await admin.rpc("admin_login_rate_limit_clear", {
      p_key_hashes: keyHashes,
    });
    if (clearError) console.error("billing-login rate-limit clear failed");

    // Preserve the existing billing_login success payload for a minimal client migration.
    return json(200, data);
  } catch (_) {
    console.error("billing-login request failed");
    return json(503, { ok: false, error: "LOGIN_SERVICE_UNAVAILABLE" });
  }
});
