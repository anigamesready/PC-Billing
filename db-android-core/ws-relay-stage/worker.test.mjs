import test from "node:test";
import assert from "node:assert/strict";
import { handleRequest } from "./worker.mjs";

function envWithHub(connected = false) {
  return {
    RELAY_SHARED_SECRET: "test-secret",
    RELAY_HUB: {
      getByName() {
        return {
          async fetch(request) {
            const path = new URL(request.url).pathname;
            if (path === "/status") return Response.json({ connected });
            return Response.json({ relay: "offline" }, { status: 503 });
          }
        };
      }
    }
  };
}

test("relay health remains offline until a Redmi agent connects", async () => {
  const response = await handleRequest(new Request("https://relay.example/_relay/health"), envWithHub(false));
  assert.equal(response.status, 503);
  assert.equal((await response.json()).agent_connected, false);
});

test("external browser origins are rejected", async () => {
  const response = await handleRequest(new Request("https://relay.example/auth/v1/token", {
    method: "POST", headers: { origin: "https://attacker.example", "content-type": "application/json" }, body: "{}"
  }), envWithHub(false));
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error, "ORIGIN_NOT_ALLOWED");
});

test("setup and owner bootstrap routes remain local-only", async () => {
  for (const path of ["/setup", "/api/admin/bootstrap"]) {
    const response = await handleRequest(new Request("https://relay.example" + path), envWithHub(false));
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, "LOCAL_ONLY_ROUTE");
  }
});

test("agent websocket requires protocol and shared secret", async () => {
  const response = await handleRequest(new Request("https://relay.example/agent/connect", {
    headers: { upgrade: "websocket", "sec-websocket-protocol": "ani-db-relay-v1, ani-token-wrong" }
  }), envWithHub(false));
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error, "AGENT_UNAUTHORIZED");
});

test("unknown application routes are not proxied", async () => {
  const response = await handleRequest(new Request("https://relay.example/admin"), envWithHub(false));
  assert.equal(response.status, 404);
  assert.equal((await response.json()).error, "ROUTE_NOT_ALLOWED");
});
