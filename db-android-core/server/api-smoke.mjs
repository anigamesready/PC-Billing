import assert from "node:assert/strict";

const base = process.env.ANI_TEST_BASE_URL || "http://127.0.0.1:8787";
async function readJson(response) {
  const text = await response.text();
  assert.ok(response.ok, `HTTP ${response.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}
async function post(path, body, token = "") {
  return fetch(base + path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: "Bearer " + token } : {})
    },
    body: JSON.stringify(body)
  });
}

const healthResponse = await fetch(base + "/health");
const health = await readJson(healthResponse);
assert.equal(health.api, "online");
assert.equal(health.database, "online");

const login = await readJson(await post("/auth/v1/token?grant_type=password", {
  email: "CI-OWNER",
  password: "CI-Admin-New-Password-2026"
}));
assert.ok(login.access_token);
assert.ok(login.refresh_token);

const context = await readJson(await post("/rest/v1/rpc/admin_context_v2", {}, login.access_token));
assert.equal(context.role, "SUPER_ADMIN");

const adminOrgId = context.orgs?.[0]?.id;
assert.ok(adminOrgId);
const devices = await readJson(await post("/rest/v1/rpc/admin_devices", { p_org_id: adminOrgId }, login.access_token));
assert.ok(Array.isArray(devices));
assert.ok(devices.some(device => device.client_id === "CI-ADMIN-SCREEN-PC"));
const freeTestPolicy = await readJson(await post("/rest/v1/rpc/admin_get_free_test_policy", {}, login.access_token));
assert.equal(freeTestPolicy.enabled, false);
const activity = await readJson(await post("/rest/v1/rpc/admin_activity", {
  p_org_id: adminOrgId,
  p_from: new Date(Date.now() - 86400000).toISOString(),
  p_to: new Date(Date.now() + 60000).toISOString(),
  p_limit: 100
}, login.access_token));
assert.ok(Array.isArray(activity.accounts));
assert.ok(Array.isArray(activity.sessions));

const user = await readJson(await fetch(base + "/auth/v1/user", {
  headers: { authorization: "Bearer " + login.access_token }
}));
assert.equal(user.email, "ci-owner@local.anigamesready");

const reseller = await readJson(await post("/rest/v1/rpc/billing_login", {
  p_username: "CI-RESELLER-LOGIN",
  p_password: "CI-Reseller-New-Pass-2026"
}));
assert.ok(reseller.token);

const resellerContext = await readJson(await post("/rest/v1/rpc/billing_context", {}, reseller.token));
assert.equal(resellerContext.role, "RESELLER_ADMIN");

const enrollment = await readJson(await post("/device/enroll", {
  code: "CI-API-PAIR",
  clientId: "CI-API-PC",
  deviceName: "CI API PC",
  appVersion: "ci"
}));
assert.ok(enrollment.token);

const heartbeat = await readJson(await post("/device/heartbeat", {
  token: enrollment.token,
  appVersion: "ci",
  metadata: { rentalSyncReady: true }
}));
assert.equal(heartbeat.power_state, "online");

console.log("PASS: Node API health, Admin Auth login/context/user, Reseller login/context, device enrollment and heartbeat");
