import http from "node:http";
import crypto from "node:crypto";
import { Pool } from "pg";

const HOST = process.env.ANI_BIND || "127.0.0.1";
const PORT = Number(process.env.PORT || 8787);
const DATABASE_URL = process.env.DATABASE_URL || "";
const PEPPER = process.env.ANI_API_PEPPER || "";
const BOOTSTRAP_TOKEN = process.env.ANI_ADMIN_BOOTSTRAP_TOKEN || "";
const ALLOWED_ORIGINS = (process.env.ANI_ALLOWED_ORIGINS || "").split(",").map(x => x.trim()).filter(Boolean);
const MAX_BODY = 2 * 1024 * 1024;

if (!DATABASE_URL) throw new Error("DATABASE_URL_REQUIRED");
if (PEPPER.length < 32) throw new Error("ANI_API_PEPPER_MUST_BE_AT_LEAST_32_CHARACTERS");
const isLoopback = ["127.0.0.1", "::1", "localhost"].includes(HOST);
if (!isLoopback && ALLOWED_ORIGINS.length === 0) {
  throw new Error("LAN_BIND_REQUIRES_EXPLICIT_ANI_ALLOWED_ORIGINS");
}

const pool = new Pool({
  connectionString: DATABASE_URL,
  max: 5,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  statement_timeout: 15000,
  application_name: "ani-games-ready-local-api"
});

const sha256 = value => crypto.createHash("sha256").update(String(value)).digest("hex");
const bucketHash = (...parts) => sha256(PEPPER + "|" + parts.join("|"));
const bearer = req => {
  const value = String(req.headers.authorization || "");
  const m = value.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : "";
};
const nowIso = () => new Date().toISOString();

async function query(sql, params = []) {
  return pool.query(sql, params);
}
async function scalar(sql, params = []) {
  const r = await query(sql, params);
  return r.rows[0]?.result ?? null;
}
async function callRateLimit(key, max = 5) {
  const result = await scalar("SELECT api.admin_login_rate_limit_consume($1::text) AS result", [key]);
  if (result?.allowed !== true) {
    const error = new Error("LOGIN_RATE_LIMITED");
    error.status = 429;
    error.retryAfter = Math.max(1, Math.min(900, Number(result?.retry_after_seconds) || 60));
    throw error;
  }
}
async function clearRateLimit(keys) {
  if (!keys.length) return;
  await scalar("SELECT api.admin_login_rate_limit_clear($1::text[]) AS result", [keys]);
}
function clientIp(req) {
  // Deliberately do not trust X-Forwarded-For; a future reverse proxy must be configured explicitly.
  return String(req.socket.remoteAddress || "unknown").replace(/^::ffff:/, "").slice(0, 128);
}

function send(res, status, data, headers = {}) {
  const body = status === 204 || data === undefined ? "" : JSON.stringify(data);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    ...headers
  });
  res.end(body);
}
function cors(req, res) {
  const origin = req.headers.origin;
  if (!origin) return true;
  const allow = isLoopback ? (ALLOWED_ORIGINS.length ? ALLOWED_ORIGINS : ["*"]) : ALLOWED_ORIGINS;
  if (allow.includes("*")) {
    res.setHeader("access-control-allow-origin", "*");
  } else if (allow.includes(origin)) {
    res.setHeader("access-control-allow-origin", origin);
    res.setHeader("vary", "Origin");
  } else {
    return false;
  }
  res.setHeader("access-control-allow-methods", "GET,POST,OPTIONS");
  res.setHeader("access-control-allow-headers", "authorization,apikey,content-type,x-client-info,x-ani-bootstrap-token");
  res.setHeader("access-control-max-age", "600");
  return true;
}
async function readJson(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) {
      const e = new Error("REQUEST_BODY_TOO_LARGE");
      e.status = 413;
      throw e;
    }
    chunks.push(chunk);
  }
  if (!size) return {};
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("JSON_OBJECT_REQUIRED");
    return value;
  } catch {
    const e = new Error("INVALID_JSON_BODY");
    e.status = 400;
    throw e;
  }
}
const val = (body, key, fallback = null) => Object.hasOwn(body, key) ? body[key] : fallback;
const str = (value, max = 512) => String(value ?? "").trim().slice(0, max);
const int = (value, min = 0, max = Number.MAX_SAFE_INTEGER) => Math.max(min, Math.min(max, Math.trunc(Number(value) || 0)));

function httpStatus(error) {
  if (error.status) return error.status;
  const m = String(error.message || "");
  if (/INVALID_DEVICE_TOKEN|INVALID_ENROLLMENT|ADMIN_NOT_AUTHENTICATED|ADMIN_SESSION_EXPIRED|ADMIN_REFRESH_EXPIRED|ADMIN_ACCOUNT_DISABLED|INVALID_CREDENTIALS|BILLING_NOT_AUTHENTICATED|BILLING_SESSION_EXPIRED|BILLING_ACCOUNT_DISABLED/.test(m)) return 401;
  if (/OWNER_ONLY|ORG_ACCESS_DENIED|ADMIN_ORG_ACCESS_DENIED|DEVICE_ACCESS_DENIED|DEVICE_DISABLED|RESELLER_FEATURE_NOT_AVAILABLE|COMMAND_NOT_ALLOWED|FREE_TEST_DISABLED|ADMIN_BOOTSTRAP_DENIED/.test(m)) return 403;
  if (/NOT_FOUND|RENTAL_NOT_FOUND|COMMAND_NOT_FOUND|RECOVERY_DEVICE_NOT_FOUND/.test(m)) return 404;
  if (/ACTIVE_TIMER_LOCKED|ACTIVE_OFFLINE_LEASE|OFFLINE_LEASE_HELD|CODE_ALREADY_EXISTS|RENTAL_ACTIVE_ON_OTHER_PC|RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC|PC_OFFLINE_COMMAND_BLOCKED|SHUTDOWN_TIMER_DISABLED|ADMIN_BOOTSTRAP_ALREADY_CONFIGURED/.test(m)) return 409;
  if (/RATE_LIMITED/.test(m)) return 429;
  if (/ECONNREFUSED|ETIMEDOUT|57P01|08006|08001/.test(m)) return 503;
  return 400;
}
function publicError(error) {
  const m = String(error.message || "REQUEST_FAILED");
  if (/^[A-Z0-9_:-]{3,80}$/.test(m)) return m;
  if (error.code === "23505") return "DUPLICATE_VALUE";
  if (error.code === "23503") return "RELATED_RECORD_NOT_FOUND";
  if (error.code === "23514") return "VALIDATION_FAILED";
  return "REQUEST_FAILED";
}

async function adminSessionResponse(data) {
  const expiresAt = Math.floor(new Date(data.expires_at).getTime() / 1000);
  const user = {
    id: data.auth_user_id,
    email: data.email || null,
    app_metadata: { role: data.role },
    user_metadata: { username: data.username }
  };
  return {
    access_token: data.token,
    token_type: "bearer",
    expires_in: Math.max(0, expiresAt - Math.floor(Date.now() / 1000)),
    expires_at: expiresAt,
    refresh_token: data.refresh_token,
    user
  };
}
async function adminLogin(username, password, req) {
  const ip = clientIp(req);
  const key = bucketHash("admin-login", ip, str(username, 120).toLowerCase());
  const lookupKey = bucketHash("admin-login-lookup", ip, str(username, 120).toLowerCase());
  await callRateLimit(key, 5);
  const data = await scalar("SELECT api.admin_login($1::text,$2::text) AS result", [str(username, 120), String(password || "")]);
  await clearRateLimit([key, lookupKey]);
  const user = await scalar("SELECT api.admin_get_user($1::text) AS result", [data.token]);
  return adminSessionResponse({ ...data, email: user?.email });
}
async function billingLogin(username, password, req) {
  const key = bucketHash("billing-login", clientIp(req), str(username, 120).toLowerCase());
  await callRateLimit(key, 5);
  const data = await scalar("SELECT api.billing_login($1::text,$2::text) AS result", [str(username, 120), String(password || "")]);
  await clearRateLimit([key]);
  return data;
}

const RPC = {
  admin_context: { auth: "admin", sql: "SELECT api.admin_context($1::text) AS result", args: [] },
  admin_context_v2: { auth: "admin", sql: "SELECT api.admin_context_v2($1::text) AS result", args: [] },
  admin_rental_accounts_global: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.code),'[]'::jsonb) AS result FROM api.admin_rental_accounts_global($1::text,$2::uuid) x", args: ["p_org_id"] },
  admin_create_rental_global: { auth: "admin", sql: "SELECT api.admin_create_rental_global($1::text,$2::uuid,$3::text,$4::text,$5::bigint,$6::text,$7::timestamptz) AS result", args: ["p_org_id","p_code","p_category","p_minutes","p_client_label","p_expiry_at"] },
  admin_update_rental_global: { auth: "admin", sql: "SELECT api.admin_update_rental_global($1::text,$2::uuid,$3::uuid,$4::text,$5::text,$6::bigint,$7::text,$8::timestamptz,$9::text) AS result", args: ["p_org_id","p_rental_id","p_code","p_category","p_minutes","p_client_label","p_expiry_at","p_status"] },
  admin_disable_rental_global: { auth: "admin", sql: "SELECT api.admin_disable_rental_global($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_rental_id"] },
  admin_delete_rental_global: { auth: "admin", sql: "SELECT api.admin_delete_rental_global($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_rental_id"] },
  admin_recent_alerts: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at),'[]'::jsonb) AS result FROM api.admin_recent_alerts($1::text,$2::uuid,$3::timestamptz) x", args: ["p_org_id","p_since"] },
  admin_selected_sessions: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.started_at DESC),'[]'::jsonb) AS result FROM api.admin_selected_sessions($1::text,$2::uuid,$3::uuid) x", args: ["p_org_id","p_device_id"] },
  admin_command: { auth: "admin", sql: "SELECT api.admin_command($1::text,$2::uuid,$3::uuid,$4::text,$5::jsonb) AS result", args: ["p_org_id","p_device_id","p_command","p_payload"] },
  create_device_recovery_enrollment: { auth: "admin", sql: "SELECT api.create_device_recovery_enrollment($1::text,$2::uuid,$3::bigint) AS result", args: ["p_device_id","p_minutes"] },
  report_rental_period_breakdown: { auth: "admin", sql: "SELECT api.report_rental_period_breakdown($1::text,$2::uuid,$3::timestamptz,$4::timestamptz) AS result", args: ["p_org_id","p_from","p_to"] },
  admin_change_password: { auth: "admin", sql: "SELECT api.admin_change_password($1::text,$2::text,$3::text) AS result", args: ["p_current_password","p_new_password"] },

  create_enrollment: { auth: "admin", sql: "SELECT api.create_enrollment($1::text,$2::uuid,$3::text,$4::bigint) AS result", args: ["p_org_id","p_label","p_minutes"] },
  create_reseller: { auth: "admin", sql: "SELECT api.create_reseller($1::text,$2::text,$3::text) AS result", args: ["p_name","p_slug"] },
  dashboard_billing_user: { auth: "admin", sql: "SELECT api.dashboard_billing_user($1::text,$2::text,$3::text,$4::text,$5::text,$6::uuid,$7::text,$8::uuid) AS result", args: ["p_action","p_username","p_password","p_status","p_role","p_org_id","p_display_name","p_user_id"] },
  dashboard_billing_users: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.username),'[]'::jsonb) AS result FROM api.dashboard_billing_users($1::text) x", args: [] },
  report_detailed_usage_page: { auth: "admin", sql: "SELECT api.report_detailed_usage_page($1::text,$2::uuid,$3::timestamptz,$4::timestamptz,$5::integer,$6::timestamptz,$7::uuid) AS result", args: ["p_org_id","p_from","p_to","p_limit","p_before_started_at","p_before_session_id"] },
  report_monthly_rental_summary: { auth: "admin", sql: "SELECT api.report_monthly_rental_summary($1::text,$2::uuid,$3::timestamptz,$4::timestamptz) AS result", args: ["p_org_id","p_from","p_to"] },
  report_summary_compact: { auth: "admin", sql: "SELECT api.report_summary_compact($1::text,$2::uuid,$3::timestamptz,$4::timestamptz) AS result", args: ["p_org_id","p_from","p_to"] },
  save_theme: { auth: "admin", sql: "SELECT api.save_theme($1::text,$2::uuid,$3::text,$4::text,$5::text,$6::text,$7::text,$8::text,$9::text,$10::text,$11::text) AS result", args: ["p_org_id","p_name","p_brand_title","p_brand_subtitle","p_primary_color","p_secondary_color","p_card_color","p_media_url","p_wallpaper_url","p_logo_url"] },
  admin_command_status: { auth: "admin", sql: "SELECT api.admin_command_status($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_command_id"] },
  admin_active_sessions: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.started_at DESC),'[]'::jsonb) AS result FROM api.admin_active_sessions($1::text,$2::uuid) x", args: ["p_org_id"] },
  admin_activity: { auth: "admin", sql: "SELECT api.admin_activity($1::text,$2::uuid,$3::timestamptz,$4::timestamptz,$5::integer) AS result", args: ["p_org_id","p_from","p_to","p_limit"] },
  admin_device_state: { auth: "admin", sql: "SELECT api.admin_device_state($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_device_id"] },
  admin_devices: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.device_name,x.client_id),'[]'::jsonb) AS result FROM api.admin_devices($1::text,$2::uuid) x", args: ["p_org_id"] },
  admin_disconnect_device: { auth: "admin", sql: "SELECT api.admin_disconnect_device($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_device_id"] },
  admin_get_free_test_policy: { auth: "admin", sql: "SELECT api.admin_get_free_test_policy($1::text) AS result", args: [] },
  admin_rename_device: { auth: "admin", sql: "SELECT api.admin_rename_device($1::text,$2::uuid,$3::uuid,$4::text) AS result", args: ["p_org_id","p_device_id","p_device_name"] },
  admin_rental_accounts: { auth: "admin", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.code),'[]'::jsonb) AS result FROM api.admin_rental_accounts($1::text,$2::uuid,$3::uuid) x", args: ["p_org_id","p_device_id"] },
  admin_set_free_test_policy: { auth: "admin", sql: "SELECT api.admin_set_free_test_policy($1::text,$2::boolean) AS result", args: ["p_enabled"] },
  admin_start_trial: { auth: "admin", sql: "SELECT api.admin_start_trial($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_device_id"] },

  billing_devices: { auth: "billing", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.device_name,x.client_id),'[]'::jsonb) AS result FROM api.billing_devices($1::text,$2::uuid) x", args: ["p_org_id"] },
  billing_active_sessions: { auth: "billing", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.started_at DESC),'[]'::jsonb) AS result FROM api.billing_active_sessions($1::text,$2::uuid) x", args: ["p_org_id"] },
  billing_context: { auth: "billing", sql: "SELECT api.billing_context($1::text) AS result", args: [] },
  billing_logout: { auth: "billing", sql: "SELECT api.billing_logout($1::text) AS result", args: [] },
  billing_change_password: { auth: "billing", sql: "SELECT api.billing_change_password($1::text,$2::text,$3::text) AS result", args: ["p_current_password","p_new_password"] },
  billing_reseller_rental_accounts_global: { auth: "billing", sql: "SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.code),'[]'::jsonb) AS result FROM api.billing_reseller_rental_accounts_global($1::text,$2::uuid) x", args: ["p_org_id"] },
  billing_reseller_create_rental_global: { auth: "billing", sql: "SELECT api.billing_reseller_create_rental_global($1::text,$2::uuid,$3::text,$4::text,$5::bigint,$6::text,$7::timestamptz) AS result", args: ["p_org_id","p_code","p_category","p_minutes","p_client_label","p_expiry_at"] },
  billing_reseller_edit_rental_global: { auth: "billing", sql: "SELECT api.billing_reseller_edit_rental_global($1::text,$2::uuid,$3::uuid,$4::text,$5::bigint,$6::text,$7::text,$8::timestamptz) AS result", args: ["p_org_id","p_rental_id","p_category","p_minutes","p_client_label","p_status","p_expiry_at"] },
  billing_reseller_delete_rental_global: { auth: "billing", sql: "SELECT api.billing_reseller_delete_rental_global($1::text,$2::uuid,$3::uuid) AS result", args: ["p_org_id","p_rental_id"] },
  billing_command: { auth: "billing", sql: "SELECT api.billing_command($1::text,$2::uuid,$3::uuid,$4::text,$5::jsonb) AS result", args: ["p_org_id","p_device_id","p_command","p_payload"] },
  billing_command_status: { auth: "billing", sql: "SELECT api.billing_command_status($1::text,$2::uuid) AS result", args: ["p_command_id"] }
};

async function rpcRequest(req, res, name, body) {
  if (name === "admin_login_lookup") {
    const login = str(val(body,"p_login"),120);
    const key = bucketHash("admin-login-lookup",clientIp(req),login.toLowerCase());
    await callRateLimit(key,5);
    const result = await scalar("SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::jsonb) AS result FROM api.admin_login_lookup($1::text) x",[login]);
    return send(res,200,result);
  }
  if (name === "admin_login") {
    const data = await adminLogin(val(body,"p_username",val(body,"username",val(body,"email"))), val(body,"p_password",val(body,"password")), req);
    return send(res, 200, data);
  }
  if (name === "billing_login") {
    const data = await billingLogin(val(body,"p_username"), val(body,"p_password"), req);
    return send(res, 200, data);
  }
  const spec = RPC[name];
  if (!spec) return send(res, 404, { message: "RPC_NOT_ALLOWED" });
  const token = bearer(req);
  if (spec.auth && !token) return send(res, 401, { message: "AUTH_REQUIRED" });
  const args = spec.auth ? [token, ...spec.args.map(k => val(body,k))] : spec.args.map(k => val(body,k));
  const result = await scalar(spec.sql, args);
  return send(res, 200, result);
}

async function deviceRequest(req, res, path, body) {
  // Accept the same Bearer device token used by the Supabase Edge Function client;
  // body.token remains supported for legacy compatibility. Never log either value.
  const token = bearer(req) || str(body.token, 512);
  if (path === "/device/enroll") {
    const code = str(body.code,80).toUpperCase();
    const clientId = str(body.clientId,128);
    const deviceName = str(body.deviceName,120);
    const appVersion = str(body.appVersion,64);
    if (!/^[A-Z0-9-]{4,80}$/.test(code) || !clientId) return send(res,400,{ok:false,error:"INVALID_REQUEST"});
    const keys = [
      { key: bucketHash("device-enroll-client",clientId.toUpperCase()), max: 5, clear: true },
      { key: bucketHash("device-enroll-code",code), max: 5, clear: true }
    ];
    const ip = clientIp(req);
    if (ip && ip !== "unknown") keys.unshift({key:bucketHash("device-enroll-ip",ip),max:60,clear:false});
    for (const item of keys) {
      const limit = await scalar("SELECT api.device_pairing_rate_limit_consume($1::text,$2::integer) AS result",[item.key,item.max]);
      if (limit?.allowed !== true) {
        const retry = Math.max(1,Math.min(900,Number(limit?.retry_after_seconds)||60));
        return send(res,429,{ok:false,error:"PAIRING_RATE_LIMITED",retry_after_seconds:retry},{"retry-after":String(retry)});
      }
    }
    const data = await scalar("SELECT api.redeem_device($1::text,$2::text,$3::text,$4::text) AS result",[code,clientId,deviceName,appVersion]);
    await scalar("SELECT api.device_pairing_rate_limit_clear($1::text[]) AS result",[keys.filter(x=>x.clear).map(x=>x.key)]);
    return send(res,200,{ok:true,...data});
  }
  if (path === "/device/alert") {
    if (!token || !str(body.eventId,128) || !str(body.message,240)) return send(res,400,{ok:false,error:"alert_fields_required"});
    const eventType = str(body.eventType,64);
    if (!["session_expired","session_stopped"].includes(eventType)) return send(res,400,{ok:false,error:"invalid_alert_type"});
    const data = await scalar("SELECT api.device_emit_admin_alert($1::text,$2::text,$3::text,$4::text,$5::jsonb,$6::timestamptz) AS result",
      [token,str(body.eventId,128),eventType,str(body.message,240),body.payload||{},body.occurredAt||nowIso()]);
    return send(res,200,{ok:true,...data});
  }
  if (path === "/device/disconnect") return send(res,200,{ok:true,...await scalar("SELECT api.device_disconnect($1::text) AS result",[token])});
  if (path === "/device/test-policy") return send(res,200,await scalar("SELECT api.device_free_test_policy($1::text) AS result",[token]));
  if (path === "/device/rental/lookup") return send(res,200,await scalar("SELECT api.device_rental_lookup($1::text,$2::text) AS result",[token,str(body.code,120)]));
  if (path === "/device/session/start") return send(res,200,await scalar("SELECT api.device_start_rental_session($1::text,$2::text,$3::text) AS result",[token,str(body.code,120),body.sourceEventId?str(body.sourceEventId,128):null]));
  if (path === "/device/session/end") return send(res,200,await scalar("SELECT api.device_end_rental_session($1::text,$2::text,$3::bigint,$4::text) AS result",[token,str(body.code,120),int(body.remainingSeconds),body.sourceEventId?str(body.sourceEventId,128):null]));
  if (path === "/device/rental/release") return send(res,200,await scalar("SELECT api.device_release_rental_lease($1::text,$2::text) AS result",[token,str(body.code,120)]));
  if (path === "/device/sync-cursor") return send(res,200,await scalar("SELECT api.device_sync_cursor($1::text) AS result",[token]));
  if (path === "/device/heartbeat") return send(res,200,{ok:true,...await scalar("SELECT api.device_heartbeat($1::text,$2::text,$3::jsonb) AS result",[token,str(body.appVersion,64),body.metadata||{}])});
  if (path === "/device/watchdog") return send(res,200,{ok:true,...await scalar("SELECT api.device_watchdog_poll($1::text) AS result",[token])});
  if (path === "/device/ack") {
    const commandId = str(body.commandId,64);
    const status = str(body.status||"acknowledged",32);
    const result = body.result && typeof body.result === "object" ? body.result : {};
    const ack = await scalar("SELECT api.device_ack($1::text,$2::uuid,$3::text,$4::jsonb) AS result",[token,commandId,status,result]);
    let trial = null;
    if (["completed","failed","expired"].includes(status)) {
      trial = await scalar("SELECT api.device_finalize_trial($1::text,$2::uuid,$3::text,$4::jsonb) AS result",[token,commandId,status,result]);
    }
    return send(res,200,{ok:true,...ack,...(trial?{trial}:{})});
  }
  if (path === "/device/sync") return send(res,200,{ok:true,...await scalar("SELECT api.device_sync($1::text,$2::jsonb) AS result",[token,Array.isArray(body.events)?body.events:[]])});
  if (path === "/device/pull") return send(res,200,{ok:true,...await scalar("SELECT api.device_pull_sync($1::text,$2::timestamptz) AS result",[token,body.cursor||null])});
  if (path === "/device/rentals") return send(res,200,await scalar("SELECT api.device_rentals_snapshot($1::text) AS result",[token]));
  return send(res,404,{ok:false,error:"not_found",path});
}

async function authRequest(req, res, url) {
  const path = url.pathname;
  if (path === "/auth/v1/token" && req.method === "POST") {
    const body = await readJson(req);
    const grant = url.searchParams.get("grant_type");
    if (grant === "password") {
      const data = await adminLogin(val(body,"email",val(body,"username")),val(body,"password"),req);
      return send(res,200,data);
    }
    if (grant === "refresh_token") {
      const data = await scalar("SELECT api.admin_refresh_session($1::text) AS result",[str(body.refresh_token,512)]);
      const user = await scalar("SELECT api.admin_get_user($1::text) AS result",[data.token]);
      return send(res,200,await adminSessionResponse({...data,email:user?.email}));
    }
    if (grant === "billing_refresh") {
      const data = await scalar("SELECT api.billing_refresh_session($1::text) AS result",[str(body.refresh_token,512)]);
      return send(res,200,data);
    }
    return send(res,400,{message:"GRANT_TYPE_NOT_SUPPORTED"});
  }
  if (path === "/auth/v1/user" && req.method === "GET") {
    const token = bearer(req);
    if (!token) return send(res,401,{message:"AUTH_REQUIRED"});
    const user = await scalar("SELECT api.admin_get_user($1::text) AS result",[token]);
    return send(res,200,user);
  }
  if (path === "/auth/v1/logout" && req.method === "POST") {
    const token = bearer(req);
    if (!token) return send(res,204,null);
    await scalar("SELECT api.admin_logout($1::text) AS result",[token]);
    return send(res,204,null);
  }
  return send(res,404,{message:"AUTH_ROUTE_NOT_FOUND"});
}

async function handler(req, res) {
  const started = Date.now();
  const url = new URL(req.url || "/", "http://127.0.0.1");
  if (!cors(req,res)) return send(res,403,{error:"ORIGIN_NOT_ALLOWED"});
  if (req.method === "OPTIONS") return send(res,204,null);
  try {
    let path = url.pathname.replace(/\/+$/,"") || "/";
    const prefix = "/functions/v1/ani-games-api";
    if (path.startsWith(prefix)) path = path.slice(prefix.length) || "/";
    if (path === "/health" && req.method === "GET") {
      await query("SELECT 1");
      return send(res,200,{app:"Ani Games Ready Local Server",api:"online",database:"online",apiVersion:"db-android-v1",remote_access_enabled:!isLoopback,bind_host:HOST,relay:"separate"});
    }
    if (path.startsWith("/auth/v1/")) return await authRequest(req,res,url);
    if (path === "/setup" && req.method === "GET") {
      if (!BOOTSTRAP_TOKEN || !isLoopback || !["127.0.0.1","::1","::ffff:127.0.0.1"].includes(req.socket.remoteAddress)) return send(res,404,{error:"NOT_FOUND"});
      res.writeHead(200,{"content-type":"text/html; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"});
      return res.end(`<!doctype html><html lang="id"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ani Games Ready — Setup Owner</title><style>body{font:16px system-ui;background:#101827;color:#eef2ff;max-width:520px;margin:40px auto;padding:20px}input,button{box-sizing:border-box;width:100%;padding:13px;margin:8px 0;border-radius:8px;border:1px solid #475569}input{background:#0f172a;color:#fff}button{background:#2563eb;color:#fff;font-weight:700}small{color:#94a3b8}</style><h2>Setup Admin Ani Games Ready</h2><p>Buat akun Owner lokal pertama. Halaman ini hanya tersedia dari Redmi/localhost dan hanya bisa berhasil sekali.</p><form id="f"><label>Username / Email</label><input name="username" required minlength="3" maxlength="120"><label>Password (minimal 12 karakter)</label><input name="password" type="password" required minlength="12" maxlength="200"><label>Nama rental / organisasi</label><input name="org_name" required minlength="2" maxlength="120"><button>Buat Admin Owner</button></form><p id="s"></p><small>Database lokal Ani Games Ready. Blynk/WoL tidak disentuh.</small><script>document.getElementById('f').addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.target),s=document.getElementById('s');s.textContent='Memproses…';try{const r=await fetch('/api/admin/bootstrap',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({username:f.get('username'),password:f.get('password'),org_name:f.get('org_name')})});const d=await r.json();if(!r.ok)throw new Error(d.error||'Gagal');s.textContent='Owner lokal berhasil dibuat. Silakan login melalui Admin DB Android.';e.target.reset()}catch(x){s.textContent='Gagal: '+x.message}});</script></html>`);
    }
    if (path === "/api/admin/bootstrap" && req.method === "POST") {
      if (!BOOTSTRAP_TOKEN || !isLoopback || !["127.0.0.1","::1","::ffff:127.0.0.1"].includes(req.socket.remoteAddress)) return send(res,403,{ok:false,error:"ADMIN_BOOTSTRAP_DENIED"});
      const body = await readJson(req);
      const data = await scalar("SELECT api.admin_bootstrap_owner($1::text,$2::text,$3::text,$4::text) AS result",
        [BOOTSTRAP_TOKEN,str(body.username,120),String(body.password||""),str(body.org_name,120)]);
      return send(res,200,data);
    }
    if (path.startsWith("/rest/v1/rpc/") && req.method === "POST") {
      const name = path.slice("/rest/v1/rpc/".length);
      const body = await readJson(req);
      return await rpcRequest(req,res,name,body);
    }
    if (path.startsWith("/device/") && req.method === "POST") {
      const body = await readJson(req);
      return await deviceRequest(req,res,path,body);
    }
    if (path.startsWith("/wol/") || path.startsWith("/iot/")) {
      return send(res,501,{ok:false,error:"RELAY_IS_SEPARATE_SERVICE",message:"Blynk/WoL relay is not hosted or controlled by the local rental database server."});
    }
    return send(res,404,{ok:false,error:"NOT_FOUND",path});
  } catch (error) {
    const status = httpStatus(error);
    const code = publicError(error);
    // Never log request bodies, bearer tokens, passwords, bootstrap secrets or database URLs.
    process.stderr.write(JSON.stringify({level:"error",path:url.pathname,code,status,elapsed_ms:Date.now()-started})+"\n");
    const headers = error.retryAfter ? {"retry-after":String(error.retryAfter)} : {};
    return send(res,status,{ok:false,error:code},headers);
  } finally {
    if (req.method !== "OPTIONS") {
      process.stdout.write(JSON.stringify({level:"access",method:req.method,path:url.pathname,status:res.statusCode||0,elapsed_ms:Date.now()-started})+"\n");
    }
  }
}

async function main() {
  await query("SELECT 1");
  const server = http.createServer(handler);
  server.requestTimeout = 30000;
  server.headersTimeout = 15000;
  server.keepAliveTimeout = 5000;
  server.listen(PORT,HOST,() => {
    process.stdout.write(JSON.stringify({level:"info",app:"Ani Games Ready Local Server",api:"online",host:HOST,port:PORT,relay:"separate"})+"\n");
  });
  const stop = async () => {
    server.close(async () => {
      await pool.end();
      process.exit(0);
    });
    setTimeout(() => process.exit(1),10000).unref();
  };
  process.on("SIGINT",stop);
  process.on("SIGTERM",stop);
}
main().catch(async error => {
  process.stderr.write(JSON.stringify({level:"fatal",error:publicError(error)})+"\n");
  await pool.end().catch(()=>{});
  process.exit(1);
});
