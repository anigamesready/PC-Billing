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
function publishableKey(): string {
  return Deno.env.get("SUPABASE_ANON_KEY")
    || Deno.env.get("SUPABASE_PUBLISHABLE_KEY")
    || keyFromMap("SUPABASE_PUBLISHABLE_KEYS");
}
function secretKey(): string {
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    || Deno.env.get("SUPABASE_SECRET_KEY")
    || keyFromMap("SUPABASE_SECRET_KEYS");
}
async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
function invalidCredentials() {
  return json(401, { ok: false, error: "INVALID_CREDENTIALS" });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });

  const url = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
  const publicKey = publishableKey();
  const secret = secretKey();
  if (!url || !publicKey || !secret) {
    return json(503, { ok: false, error: "LOGIN_SERVICE_UNAVAILABLE" });
  }

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
    // Keep the service credential server-side. The database stores only hashes
    // of the username/IP buckets, never the username, IP, or password.
    const admin = createClient(url, secret, {
      db: { schema: "api" },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const usernameKey = await sha256Hex(secret + "|admin-login-username|" + username);
    const keyHashes = [usernameKey];

    // Trust only gateway-supplied client-IP headers; do not use arbitrary X-Forwarded-For.
    const clientIp = (req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "").trim().slice(0, 128);
    if (clientIp) keyHashes.push(await sha256Hex(secret + "|admin-login-ip|" + clientIp));

    for (const keyHash of keyHashes) {
      const { data: limit, error: limitError } = await admin.rpc("admin_login_rate_limit_consume", {
        p_key_hash: keyHash,
      });
      if (limitError || !limit || limit.allowed !== true) {
        const retry = Math.max(1, Math.min(900, Number(limit?.retry_after_seconds) || 60));
        return json(429, { ok: false, error: "INVALID_CREDENTIALS" }, { "Retry-After": String(retry) });
      }
    }

    const { data: accounts, error: lookupError } = await admin.rpc("resolve_admin_username", {
      p_username: username,
    });
    if (lookupError) {
      console.error("admin-login lookup failed");
      return json(503, { ok: false, error: "LOGIN_SERVICE_UNAVAILABLE" });
    }

    const account = Array.isArray(accounts)
      ? accounts.find((a: any) => a?.status === "active" && a?.role === "SUPER_ADMIN" && typeof a?.email === "string")
      : null;

    const authClient = createClient(url, publicKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });

    // A dummy auth request reduces the response-time difference for unknown/inactive usernames.
    const emailForAuth = account?.email || ("invalid-" + usernameKey.slice(0, 12) + "@invalid.example");
    const { data: authData, error: authError } = await authClient.auth.signInWithPassword({
      email: emailForAuth,
      password,
    });

    if (!account || authError || !authData?.session || !authData?.user) {
      return invalidCredentials();
    }

    const { error: clearError } = await admin.rpc("admin_login_rate_limit_clear", {
      p_key_hashes: keyHashes,
    });
    if (clearError) {
      // Authentication succeeded. Do not fail it because housekeeping failed;
      // the short-lived bucket will expire/reset automatically.
      console.error("admin-login rate-limit clear failed");
    }

    const session = authData.session;
    return json(200, {
      ok: true,
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_in: session.expires_in,
      expires_at: session.expires_at,
      token_type: session.token_type,
      user: { id: authData.user.id, email: authData.user.email },
      admin_role: account.role,
    });
  } catch (_) {
    console.error("admin-login request failed");
    return json(503, { ok: false, error: "LOGIN_SERVICE_UNAVAILABLE" });
  }
});
