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

// Native and legacy-prefixed Auth paths must return the same unauthenticated response.
for (const path of ["/auth/v1/user", "/functions/v1/ani-games-api/auth/v1/user"]) {
  const response = await fetch(base + path);
  assert.equal(response.status, 401, `Expected HTTP 401 for ${path}; received ${response.status}`);
  const body = await response.json();
  assert.equal(body.message, "AUTH_REQUIRED");
}

const login = await readJson(await post("/auth/v1/token?grant_type=password", {
  email: "CI-OWNER",
  password: "CI-Admin-New-Password-2026"
}));
assert.ok(login.access_token);
assert.ok(login.refresh_token);

const context = await readJson(await post("/rest/v1/rpc/admin_context_v2", {}, login.access_token));
assert.equal(context.role, "SUPER_ADMIN");

const adminOrgId = context.org_id;
assert.ok(adminOrgId);

// Exercise Billing Control account CRUD over HTTP, including the 9-parameter Admin wrapper.
const billingUserCreated = await readJson(await post("/rest/v1/rpc/dashboard_billing_user", {
  p_action: "create",
  p_username: "CI-API-BILLING-RPC",
  p_password: "CI-Api-Billing-Password-2026",
  p_status: "active",
  p_role: "RESELLER_ADMIN",
  p_org_id: adminOrgId,
  p_display_name: "CI API Billing RPC",
  p_user_id: null
}, login.access_token));
assert.equal(billingUserCreated.ok, true);
assert.ok(billingUserCreated.id);

const billingUsers = await readJson(await post("/rest/v1/rpc/dashboard_billing_users", {}, login.access_token));
assert.ok(Array.isArray(billingUsers));
assert.ok(billingUsers.some(user => user.id === billingUserCreated.id));

const billingUserUpdated = await readJson(await post("/rest/v1/rpc/dashboard_billing_user", {
  p_action: "update",
  p_username: "CI-API-BILLING-RPC",
  p_password: null,
  p_status: "disabled",
  p_role: "RESELLER_ADMIN",
  p_org_id: adminOrgId,
  p_display_name: "CI API Billing RPC Disabled",
  p_user_id: billingUserCreated.id
}, login.access_token));
assert.equal(billingUserUpdated.status, "disabled");

const billingUserDeleted = await readJson(await post("/rest/v1/rpc/dashboard_billing_user", {
  p_action: "delete",
  p_username: null,
  p_password: null,
  p_status: "active",
  p_role: "RESELLER_ADMIN",
  p_org_id: null,
  p_display_name: null,
  p_user_id: billingUserCreated.id
}, login.access_token));
assert.equal(billingUserDeleted.deleted, true);
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
  appVersion: "ci",
  metadata: { rentalSyncReady: true }
}, enrollment.token));
assert.equal(heartbeat.power_state, "online");

console.log("PASS: Node API health, Admin Auth login/context/user, Reseller login/context, device enrollment and heartbeat");
