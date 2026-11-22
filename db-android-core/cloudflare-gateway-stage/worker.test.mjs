import test from "node:test";
import assert from "node:assert/strict";
import { handleRequest } from "./worker.mjs";

class MemoryKV {
  constructor() { this.values = new Map(); this.lastPut = null; }
  async get(key, type) {
    const value = this.values.get(key);
    if (value === undefined) return null;
    return type === "json" ? JSON.parse(value) : value;
  }
  async put(key, value, options) {
    this.values.set(key, value);
    this.lastPut = { key, value: JSON.parse(value), options };
  }
  async delete(key) { this.values.delete(key); }
}
function setup() {
  return {
    env: {
      UPSTREAMS: new MemoryKV(),
      REGISTER_TOKEN: "register-test-token-1234567890",
      EDGE_PROXY_SECRET: "edge-test-secret-12345678901234567890"
    }
  };
}
function req(path, init = {}) {
  return new Request("https://gateway.example" + path, init);
}

test("gateway health is public and accurately reports offline state", async () => {
  const { env } = setup();
  const response = await handleRequest(req("/_ani_gateway/health"), env);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { gateway: "online", upstream_active: false });
});

test("register endpoint requires bearer token and stores only trycloudflare HTTPS origin", async () => {
  const { env } = setup();
  const denied = await handleRequest(req("/_ani_gateway/register", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" })
  }), env);
  assert.equal(denied.status, 401);

  const response = await handleRequest(req("/_ani_gateway/register", {
    method: "POST",
    headers: { authorization: "Bearer " + env.REGISTER_TOKEN, "content-type": "application/json" },
    body: JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" })
  }), env);
  assert.equal(response.status, 200);
  assert.equal(env.UPSTREAMS.lastPut.options.expirationTtl, 600);
  assert.equal(env.UPSTREAMS.lastPut.value.url, "https://alpha-bravo-123.trycloudflare.com");
});

test("register rejects arbitrary hosts, HTTP, credentials, path and query", async () => {
  const { env } = setup();
  for (const url of [
    "http://alpha-bravo-123.trycloudflare.com",
    "https://example.com",
    "https://user:pass@alpha-bravo-123.trycloudflare.com",
    "https://alpha-bravo-123.trycloudflare.com/evil",
    "https://alpha-bravo-123.trycloudflare.com/?x=1"
  ]) {
    const response = await handleRequest(req("/_ani_gateway/register", {
      method: "POST",
      headers: { authorization: "Bearer " + env.REGISTER_TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ url })
    }), env);
    assert.equal(response.status, 400, url);
  }
});

test("public setup and bootstrap paths are always blocked", async () => {
  const { env } = setup();
  await env.UPSTREAMS.put("ani_games_ready_stage:upstream", JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" }));
  for (const [path, method] of [["/setup", "GET"], ["/api/admin/bootstrap", "POST"]]) {
    const response = await handleRequest(req(path, { method }), env);
    assert.equal(response.status, 403);
  }
});

test("root and normalized health paths proxy to the registered API health endpoint", async () => {
  const { env } = setup();
  await env.UPSTREAMS.put("ani_games_ready_stage:upstream", JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" }));
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async request => {
    captured = request;
    return new Response(JSON.stringify({ api: "online", database: "online" }), {
      status: 200, headers: { "content-type": "application/json" }
    });
  };
  try {
    for (const [path, expected] of [
      ["/", "/health"],
      ["/health", "/health"],
      ["/health/", "/health"],
      ["/functions/v1/ani-games-api/health", "/functions/v1/ani-games-api/health"]
    ]) {
      const response = await handleRequest(req(path), env);
      assert.equal(response.status, 200, path);
      assert.equal(new URL(captured.url).pathname, expected, path);
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("unknown routes and unsupported methods are denied", async () => {
  const { env } = setup();
  assert.equal((await handleRequest(req("/admin"), env)).status, 404);
  assert.equal((await handleRequest(req("/health", { method: "DELETE" }), env)).status, 405);
});

test("CORS accepts Android opaque file origin only", async () => {
  const { env } = setup();
  await env.UPSTREAMS.put("ani_games_ready_stage:upstream", JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" }));
  const preflight = await handleRequest(req("/auth/v1/token", {
    method: "OPTIONS", headers: { origin: "null" }
  }), env);
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-origin"), "null");

  const denied = await handleRequest(req("/auth/v1/token", {
    method: "OPTIONS", headers: { origin: "https://attacker.example" }
  }), env);
  assert.equal(denied.status, 403);
});

test("proxy pins upstream, overwrites edge identity headers and preserves path", async () => {
  const { env } = setup();
  await env.UPSTREAMS.put("ani_games_ready_stage:upstream", JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" }));
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async request => {
    captured = request;
    return new Response(JSON.stringify({ api: "online" }), {
      status: 200, headers: { "content-type": "application/json" }
    });
  };
  try {
    const response = await handleRequest(req("/rest/v1/rpc/admin_context?x=1", {
      method: "POST",
      headers: {
        origin: "null",
        "cf-connecting-ip": "203.0.113.17",
        "x-ani-edge-client-ip": "192.0.2.1",
        "x-ani-edge-secret": "attacker-value",
        "content-type": "application/json"
      },
      body: "{}"
    }), env);
    assert.equal(response.status, 200);
    assert.equal(new URL(captured.url).origin, "https://alpha-bravo-123.trycloudflare.com");
    assert.equal(new URL(captured.url).pathname, "/rest/v1/rpc/admin_context");
    assert.equal(new URL(captured.url).search, "?x=1");
    assert.equal(captured.headers.get("x-ani-edge-client-ip"), "203.0.113.17");
    assert.equal(captured.headers.get("x-ani-edge-secret"), env.EDGE_PROXY_SECRET);
    assert.equal(captured.headers.get("access-control-allow-origin"), null);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("status and clear control routes require registration token", async () => {
  const { env } = setup();
  await env.UPSTREAMS.put("ani_games_ready_stage:upstream", JSON.stringify({ url: "https://alpha-bravo-123.trycloudflare.com" }));
  assert.equal((await handleRequest(req("/_ani_gateway/status"), env)).status, 401);
  const status = await handleRequest(req("/_ani_gateway/status", {
    headers: { authorization: "Bearer " + env.REGISTER_TOKEN }
  }), env);
  assert.equal(status.status, 200);
  const cleared = await handleRequest(req("/_ani_gateway/clear", {
    method: "POST", headers: { authorization: "Bearer " + env.REGISTER_TOKEN }
  }), env);
  assert.equal(cleared.status, 200);
  assert.equal(await env.UPSTREAMS.get("ani_games_ready_stage:upstream"), null);
});
