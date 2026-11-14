const UPSTREAM_KEY = "ani_games_ready_stage:upstream";
const UPSTREAM_TTL_SECONDS = 600;
const ALLOWED_EXACT = new Set([
  "/health",
  "/auth/v1/token",
  "/auth/v1/user",
  "/auth/v1/logout"
]);

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      ...headers
    }
  });
}

function corsFor(request) {
  const origin = request.headers.get("Origin");
  if (origin === "null") {
    return {
      "access-control-allow-origin": "null",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "authorization,apikey,content-type,x-client-info,x-ani-bootstrap-token",
      "access-control-max-age": "600",
      "vary": "Origin"
    };
  }
  return {};
}

function isLoopbackOnlyRoute(path) {
  return path === "/setup" || path === "/api/admin/bootstrap" ||
    path.startsWith("/setup/") || path.startsWith("/api/admin/bootstrap/");
}

function isApiRoute(path) {
  if (isLoopbackOnlyRoute(path)) return false;
  if (ALLOWED_EXACT.has(path)) return true;
  if (/^\/rest\/v1\/rpc\/[a-z][a-z0-9_]{1,100}$/i.test(path)) return true;
  if (/^\/device\/[a-z0-9/_-]+$/i.test(path)) return true;
  if (/^\/functions\/v1\/ani-games-api(?:\/[a-z0-9/_-]+)?$/i.test(path)) return true;
  return false;
}

function equalSecret(candidate, expected) {
  if (typeof candidate !== "string" || typeof expected !== "string") return false;
  if (!expected || candidate.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= candidate.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

async function controlRequest(request, env, url) {
  if (request.method !== "POST" && !(request.method === "GET" && url.pathname.endsWith("/status"))) {
    return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  }
  const auth = request.headers.get("Authorization") || "";
  const supplied = auth.match(/^Bearer\s+(.+)$/i)?.[1] || "";
  if (!equalSecret(supplied, env.REGISTER_TOKEN)) return json({ error: "UNAUTHORIZED" }, 401);

  if (url.pathname === "/_ani_gateway/status" && request.method === "GET") {
    const value = await env.UPSTREAMS.get(UPSTREAM_KEY, "json");
    return json({ ok: true, active: Boolean(value?.url), updated_at: value?.updated_at || null });
  }
  if (url.pathname === "/_ani_gateway/clear") {
    await env.UPSTREAMS.delete(UPSTREAM_KEY);
    return json({ ok: true, cleared: true });
  }
  if (url.pathname === "/_ani_gateway/register") {
    let body;
    try { body = await request.json(); } catch { return json({ error: "INVALID_JSON" }, 400); }
    let upstream;
    try { upstream = new URL(String(body?.url || "")); } catch { return json({ error: "INVALID_UPSTREAM_URL" }, 400); }
    if (upstream.protocol !== "https:" ||
        !/^[a-z0-9-]{8,63}\.trycloudflare\.com$/i.test(upstream.hostname) ||
        upstream.username || upstream.password || upstream.pathname !== "/" ||
        upstream.search || upstream.hash) {
      return json({ error: "UPSTREAM_NOT_ALLOWED" }, 400);
    }
    await env.UPSTREAMS.put(UPSTREAM_KEY, JSON.stringify({
      url: upstream.origin,
      updated_at: new Date().toISOString()
    }), { expirationTtl: UPSTREAM_TTL_SECONDS });
    return json({ ok: true, registered: true, expires_in: UPSTREAM_TTL_SECONDS });
  }
  return json({ error: "NOT_FOUND" }, 404);
}

export async function handleRequest(request, env) {
  const url = new URL(request.url);
  const headers = corsFor(request);
  if (url.pathname.startsWith("/_ani_gateway/")) {
    return controlRequest(request, env, url);
  }
  if (url.pathname === "/_ani_gateway/health") {
    const value = await env.UPSTREAMS.get(UPSTREAM_KEY, "json");
    return json({ gateway: "online", upstream_active: Boolean(value?.url) }, value?.url ? 200 : 503);
  }

  if (isLoopbackOnlyRoute(url.pathname)) return json({ error: "LOCAL_ONLY_ROUTE" }, 403, headers);
  if (!isApiRoute(url.pathname)) return json({ error: "ROUTE_NOT_ALLOWED" }, 404, headers);
  if (!["GET", "POST", "OPTIONS"].includes(request.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405, headers);

  const origin = request.headers.get("Origin");
  if (origin && origin !== "null") return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: {
      ...headers,
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }});
  }

  const current = await env.UPSTREAMS.get(UPSTREAM_KEY, "json");
  if (!current?.url) return json({ error: "STAGE_TUNNEL_OFFLINE" }, 503, headers);

  const clientIp = request.headers.get("CF-Connecting-IP") || "";
  if (!clientIp || clientIp.length > 64 || !/^[0-9a-fA-F:.]+$/.test(clientIp)) {
    return json({ error: "CLIENT_IP_UNAVAILABLE" }, 400, headers);
  }

  const target = new URL(url.pathname + url.search, current.url);
  const outgoingHeaders = new Headers(request.headers);
  outgoingHeaders.delete("host");
  outgoingHeaders.delete("cf-connecting-ip");
  outgoingHeaders.delete("x-ani-edge-client-ip");
  outgoingHeaders.delete("x-ani-edge-secret");
  outgoingHeaders.set("x-ani-edge-client-ip", clientIp);
  outgoingHeaders.set("x-ani-edge-secret", env.EDGE_PROXY_SECRET);

  let upstreamResponse;
  try {
    const init = {
      method: request.method,
      headers: outgoingHeaders,
      redirect: "manual"
    };
    if (request.method !== "GET" && request.method !== "HEAD") init.body = request.body;
    upstreamResponse = await fetch(new Request(target.toString(), init));
  } catch {
    return json({ error: "STAGE_UPSTREAM_UNREACHABLE" }, 502, headers);
  }

  const responseHeaders = new Headers(upstreamResponse.headers);
  responseHeaders.set("cache-control", "no-store");
  responseHeaders.set("x-content-type-options", "nosniff");
  responseHeaders.set("referrer-policy", "no-referrer");
  responseHeaders.delete("set-cookie");
  if (origin === "null") {
    for (const [key, value] of Object.entries(headers)) responseHeaders.set(key, value);
  } else {
    responseHeaders.delete("access-control-allow-origin");
    responseHeaders.delete("access-control-allow-credentials");
  }
  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    statusText: upstreamResponse.statusText,
    headers: responseHeaders
  });
}

export default {
  async fetch(request, env) {
    return handleRequest(request, env);
  }
};
