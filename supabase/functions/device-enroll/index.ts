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
      if (typeof parsed.default === "string" && parsed.default) return parsed.default;
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
function safePairingError(message: string): string {
  const token = String(message || "").trim().split(/[\s:]/, 1)[0];
  return /^[A-Z0-9_]{3,64}$/.test(token) ? token : "PAIRING_FAILED";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });
  const url = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
  const secret = secretKey();
  if (!url || !secret) return json(503, { ok: false, error: "PAIRING_SERVICE_UNAVAILABLE" });

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 8192) return json(413, { ok: false, error: "REQUEST_TOO_LARGE" });
    body = JSON.parse(raw);
  } catch (_) {
    return json(400, { ok: false, error: "INVALID_REQUEST" });
  }

  const code = String(body.code ?? "").trim().toUpperCase();
  const clientId = String(body.clientId ?? "").trim();
  const deviceName = String(body.deviceName ?? "").trim().slice(0, 120);
  const appVersion = String(body.appVersion ?? "").trim().slice(0, 64);
  if (code.length < 4 || code.length > 80 || !/^[A-Z0-9-]+$/.test(code)
      || !clientId || clientId.length > 128) {
    return json(400, { ok: false, error: "INVALID_REQUEST" });
  }

  try {
    const admin = createClient(url, secret, {
      db: { schema: "api" },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const clientBucket = await sha256Hex(secret + "|device-enroll-client|" + clientId.toUpperCase());
    const codeBucket = await sha256Hex(secret + "|device-enroll-code|" + code);
    const keyBuckets: Array<{ key: string; max: number; clearAfterSuccess: boolean }> = [
      { key: clientBucket, max: 5, clearAfterSuccess: true },
      { key: codeBucket, max: 5, clearAfterSuccess: true },
    ];

    // Prefer gateway-injected address headers. The username/code bucket still
    // applies when the runtime does not provide a trusted client IP.
    const clientIp = (req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "").trim().slice(0, 128);
    if (clientIp) {
      keyBuckets.unshift({
        key: await sha256Hex(secret + "|device-enroll-ip|" + clientIp),
        max: 60,
        clearAfterSuccess: false,
      });
    }

    for (const bucket of keyBuckets) {
      const { data: limit, error } = await admin.rpc("device_pairing_rate_limit_consume", {
        p_key_hash: bucket.key,
        p_max_attempts: bucket.max,
      });
      if (error || !limit || limit.allowed !== true) {
        const retry = Math.max(1, Math.min(900, Number(limit?.retry_after_seconds) || 60));
        return json(429, { ok: false, error: "PAIRING_RATE_LIMITED" }, { "Retry-After": String(retry) });
      }
    }

    const { data, error } = await admin.rpc("redeem_device", {
      p_code: code,
      p_client_id: clientId,
      p_device_name: deviceName,
      p_app_version: appVersion,
    });
    if (error || !data || typeof data.token !== "string" || !data.device_id) {
      return json(400, { ok: false, error: safePairingError(error?.message || "INVALID_ENROLLMENT") });
    }

    const clearKeys = keyBuckets.filter((b) => b.clearAfterSuccess).map((b) => b.key);
    if (clearKeys.length) {
      const { error: clearError } = await admin.rpc("device_pairing_rate_limit_clear", {
        p_key_hashes: clearKeys,
      });
      if (clearError) console.error("device-enroll rate-limit clear failed");
    }

    return json(200, { ok: true, ...data });
  } catch (_) {
    console.error("device-enroll request failed");
    return json(503, { ok: false, error: "PAIRING_SERVICE_UNAVAILABLE" });
  }
});
