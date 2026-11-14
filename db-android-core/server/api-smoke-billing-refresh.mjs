import assert from "node:assert/strict";
const base = process.env.ANI_TEST_BASE_URL || "http://127.0.0.1:8787";
async function responseJson(response) {
  const text = await response.text();
  assert.ok(response.ok, `HTTP ${response.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}
async function rpc(name, body, token) {
  return responseJson(await fetch(base + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify(body)
  }));
}
const login = await responseJson(await fetch(base + "/rest/v1/rpc/billing_login", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ p_username: "CI-RESELLER-LOGIN", p_password: "CI-Reseller-New-Pass-2026" })
}));
assert.ok(login.token);
assert.ok(login.refresh_token);
assert.ok(login.org_id);
const devices = await rpc("billing_devices", { p_org_id: login.org_id }, login.token);
assert.ok(Array.isArray(devices));
const sessions = await rpc("billing_active_sessions", { p_org_id: login.org_id }, login.token);
assert.ok(Array.isArray(sessions));

const refreshed = await responseJson(await fetch(base + "/auth/v1/token?grant_type=billing_refresh", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ refresh_token: login.refresh_token })
}));
assert.ok(refreshed.token);
assert.ok(refreshed.refresh_token);
assert.notEqual(refreshed.refresh_token, login.refresh_token);

const oldContext = await fetch(base + "/rest/v1/rpc/billing_context", {
  method: "POST",
  headers: { "content-type": "application/json", authorization: "Bearer " + login.token },
  body: "{}"
});
assert.equal(oldContext.status, 401);
const newContext = await rpc("billing_context", {}, refreshed.token);
assert.equal(newContext.role, "RESELLER_ADMIN");
await rpc("billing_logout", {}, refreshed.token);
const revoked = await fetch(base + "/auth/v1/token?grant_type=billing_refresh", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ refresh_token: refreshed.refresh_token })
});
assert.equal(revoked.status, 401);
console.log("PASS: Reseller HTTP login, device/session reads, refresh rotation, old-token rejection and logout revocation");
