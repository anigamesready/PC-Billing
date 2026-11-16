const AGENT_PROTOCOL = "ani-db-relay-v1";
const AGENT_TOKEN_PREFIX = "ani-token-";
const AGENT_TAG = "agent";
const HUB_NAME = "redmi-db-android-stage";
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAX_IN_FLIGHT = 64;
const REQUEST_TIMEOUT_MS = 30000;
const ALLOWED_HEADERS = ["authorization", "apikey", "content-type", "x-client-info"];
const ALLOWED_EXACT_PATHS = new Set(["/health", "/auth/v1/token", "/auth/v1/user", "/auth/v1/logout"]);

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: {
    "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
    "x-content-type-options": "nosniff", "referrer-policy": "no-referrer", ...headers
  }});
}
function corsHeaders(request) {
  if (request.headers.get("Origin") !== "null") return {};
  return {
    "access-control-allow-origin": "null",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "authorization,apikey,content-type,x-client-info",
    "access-control-max-age": "600", "vary": "Origin"
  };
}
function isBootstrapRoute(path) {
  return path === "/setup" || path.startsWith("/setup/") ||
    path === "/api/admin/bootstrap" || path.startsWith("/api/admin/bootstrap/");
}
function isAllowedApiRoute(path) {
  if (isBootstrapRoute(path)) return false;
  if (ALLOWED_EXACT_PATHS.has(path)) return true;
  if (/^\/rest\/v1\/rpc\/[a-z][a-z0-9_]{1,100}$/i.test(path)) return true;
  if (/^\/device\/[a-z0-9/_-]+$/i.test(path)) return true;
  return path === "/functions/v1/ani-games-api" ||
    /^\/functions\/v1\/ani-games-api\/[a-z0-9/_-]+$/i.test(path);
}
function equalSecret(candidate, expected) {
  if (typeof candidate !== "string" || typeof expected !== "string" ||
      !expected || candidate.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= candidate.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
function clientAddress(request) {
  const ip = String(request.headers.get("CF-Connecting-IP") || "");
  return ip.length <= 64 && /^[0-9a-fA-F:.]+$/.test(ip) ? ip : "";
}
function bytesToBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}
function base64ToBytes(value) {
  if (typeof value !== "string" || value.length > Math.ceil(MAX_RESPONSE_BYTES * 4 / 3) + 8) throw new Error("INVALID_RESPONSE_BODY");
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  if (bytes.length > MAX_RESPONSE_BYTES) throw new Error("RESPONSE_TOO_LARGE");
  return bytes;
}
function parseAgentProtocols(request) {
  const entries = String(request.headers.get("Sec-WebSocket-Protocol") || "").split(",").map(x => x.trim()).filter(Boolean);
  const tokens = entries.filter(x => x.startsWith(AGENT_TOKEN_PREFIX));
  return { base: entries.includes(AGENT_PROTOCOL), token: tokens.length === 1 ? tokens[0].slice(AGENT_TOKEN_PREFIX.length) : "" };
}
function filteredRequestHeaders(request) {
  const out = {};
  for (const name of ALLOWED_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) out[name] = value;
  }
  return out;
}
async function proxyApiRequest(request, env, url) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== "null") return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  if (!isAllowedApiRoute(url.pathname)) {
    return json({ error: isBootstrapRoute(url.pathname) ? "LOCAL_ONLY_ROUTE" : "ROUTE_NOT_ALLOWED" },
      isBootstrapRoute(url.pathname) ? 403 : 404, corsHeaders(request));
  }
  if (!["GET", "POST", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, corsHeaders(request));
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request) });
  const ip = clientAddress(request);
  if (!ip) return json({ error: "CLIENT_IP_UNAVAILABLE" }, 400, corsHeaders(request));
  let bodyBytes = new Uint8Array();
  if (request.method !== "GET") {
    bodyBytes = new Uint8Array(await request.arrayBuffer());
    if (bodyBytes.byteLength > MAX_BODY_BYTES) return json({ error: "REQUEST_TOO_LARGE" }, 413, corsHeaders(request));
  }
  const envelope = {
    id: crypto.randomUUID(), method: request.method, path: url.pathname + url.search,
    clientIp: ip, headers: filteredRequestHeaders(request), bodyBase64: bytesToBase64(bodyBytes)
  };
  let upstream;
  try {
    const hub = env.RELAY_HUB.getByName(HUB_NAME);
    upstream = await hub.fetch(new Request("https://relay.internal/proxy", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(envelope)
    }));
  } catch {
    return json({ error: "RELAY_UNAVAILABLE" }, 503, corsHeaders(request));
  }
  const headers = new Headers(upstream.headers);
  headers.set("cache-control", "no-store");
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "no-referrer");
  for (const [name, value] of Object.entries(corsHeaders(request))) headers.set(name, value);
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers });
}
async function relayHealth(env) {
  const hub = env.RELAY_HUB.getByName(HUB_NAME);
  let status;
  try { status = await (await hub.fetch("https://relay.internal/status")).json(); }
  catch { return json({ relay: "offline", agent_connected: false, api: "unknown", database: "unknown" }, 503); }
  if (!status.connected) return json({ relay: "offline", agent_connected: false, api: "unknown", database: "unknown" }, 503);
  const envelope = { id: crypto.randomUUID(), method: "GET", path: "/health", clientIp: "127.0.0.1", headers: {}, bodyBase64: "" };
  try {
    const response = await hub.fetch(new Request("https://relay.internal/proxy", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(envelope)
    }));
    const data = await response.json();
    const healthy = response.status === 200 && data?.api === "online" && data?.database === "online";
    return json({ relay: "online", agent_connected: true, api: data?.api || "unknown",
      database: data?.database || "unknown", agent_connected_since: status.connected_since || null }, healthy ? 200 : 503);
  } catch {
    return json({ relay: "online", agent_connected: true, api: "unreachable", database: "unknown" }, 503);
  }
}

export class RelayHub {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.pending = new Map();
    if (typeof WebSocketRequestResponsePair === "function") {
      this.ctx.setWebSocketAutoResponse?.(new WebSocketRequestResponsePair("AGENT_PING", "AGENT_PONG"));
    }
  }
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/agent/connect") {
      if (request.method !== "GET" || request.headers.get("Upgrade") !== "websocket") return new Response("WebSocket upgrade required", { status: 426 });
      for (const socket of this.ctx.getWebSockets(AGENT_TAG)) {
        try { socket.close(1012, "Agent replaced by newer connection"); } catch {}
      }
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      server.serializeAttachment({ role: AGENT_TAG, connectedAt: new Date().toISOString() });
      this.ctx.acceptWebSocket(server, [AGENT_TAG]);
      return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": AGENT_PROTOCOL } });
    }
    if (url.pathname === "/status") {
      const sockets = this.ctx.getWebSockets(AGENT_TAG);
      const attachment = sockets[0]?.deserializeAttachment?.() || null;
      return json({ connected: sockets.length > 0, connected_since: attachment?.connectedAt || null, pending_requests: this.pending.size });
    }
    if (url.pathname === "/proxy" && request.method === "POST") return this.proxyRequest(request);
    return json({ error: "NOT_FOUND" }, 404);
  }
  async proxyRequest(request) {
    let envelope;
    try { envelope = await request.json(); } catch { return json({ error: "INVALID_RELAY_ENVELOPE" }, 400); }
    if (!envelope || typeof envelope !== "object" ||
      !/^[0-9a-f-]{36}$/i.test(String(envelope.id || "")) ||
      !["GET", "POST"].includes(envelope.method) ||
      typeof envelope.path !== "string" || !envelope.path.startsWith("/") ||
      !isAllowedApiRoute(new URL(envelope.path, "https://local.invalid").pathname)) {
      return json({ error: "INVALID_RELAY_ENVELOPE" }, 400);
    }
    if (this.pending.size >= MAX_IN_FLIGHT) return json({ error: "RELAY_BUSY" }, 503);
    const socket = this.ctx.getWebSockets(AGENT_TAG)[0];
    if (!socket || socket.readyState !== 1) return json({ error: "AGENT_OFFLINE" }, 503);
    const id = envelope.id;
    let timer;
    const reply = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error("AGENT_RESPONSE_TIMEOUT")), REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, socket, timer });
    });
    try {
      socket.send(JSON.stringify({ type: "request", ...envelope }));
      const result = await reply;
      const body = base64ToBytes(result.bodyBase64 || "");
      const headers = new Headers({ "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" });
      for (const name of ["content-type", "retry-after"]) {
        const value = result.headers?.[name];
        if (typeof value === "string" && value.length <= 256) headers.set(name, value);
      }
      return new Response([204, 205, 304].includes(result.status) ? null : body, { status: result.status, headers });
    } catch (error) {
      return json({ error: error?.message === "AGENT_RESPONSE_TIMEOUT" ? "AGENT_TIMEOUT" : "AGENT_UNAVAILABLE" }, 503);
    } finally {
      const pending = this.pending.get(id);
      if (pending) clearTimeout(pending.timer);
      this.pending.delete(id);
    }
  }
  async webSocketMessage(socket, message) {
    if (typeof message !== "string" || message.length > 8 * 1024 * 1024) return;
    let data;
    try { data = JSON.parse(message); } catch { return; }
    if (data?.type !== "response" || typeof data.id !== "string") return;
    const pending = this.pending.get(data.id);
    if (!pending || pending.socket !== socket) return;
    const status = Number(data.status);
    if (!Number.isInteger(status) || status < 200 || status > 599 || typeof data.bodyBase64 !== "string") {
      pending.reject(new Error("INVALID_AGENT_RESPONSE")); return;
    }
    pending.resolve({ status, headers: data.headers && typeof data.headers === "object" ? data.headers : {}, bodyBase64: data.bodyBase64 });
  }
  async webSocketClose(socket, code, reason) {
    for (const [id, pending] of this.pending.entries()) {
      if (pending.socket === socket) {
        clearTimeout(pending.timer); pending.reject(new Error("AGENT_DISCONNECTED")); this.pending.delete(id);
      }
    }
    try { socket.close(code, reason); } catch {}
  }
  async webSocketError(socket) { await this.webSocketClose(socket, 1011, "Agent socket error"); }
}
export async function handleRequest(request, env) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin");
  if (url.pathname === "/agent/connect") {
    if (request.method !== "GET" || request.headers.get("Upgrade") !== "websocket") return json({ error: "WEBSOCKET_UPGRADE_REQUIRED" }, 426);
    const auth = parseAgentProtocols(request);
    if (!auth.base || !equalSecret(auth.token, env.RELAY_SHARED_SECRET)) return json({ error: "AGENT_UNAUTHORIZED" }, 401);
    return env.RELAY_HUB.getByName(HUB_NAME).fetch(request);
  }
  if (url.pathname === "/_relay/health" && request.method === "GET") return relayHealth(env);
  if (origin && origin !== "null") return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  return proxyApiRequest(request, env, url);
}
export default { async fetch(request, env) { return handleRequest(request, env); } };