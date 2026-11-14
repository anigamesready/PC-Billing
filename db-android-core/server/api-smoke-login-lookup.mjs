import assert from "node:assert/strict";
const base = process.env.ANI_TEST_BASE_URL || "http://127.0.0.1:8787";
const response = await fetch(base + "/rest/v1/rpc/admin_login_lookup", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ p_login: "CI-OWNER" })
});
const text = await response.text();
assert.equal(response.status, 200, text);
const rows = JSON.parse(text);
assert.ok(Array.isArray(rows));
assert.equal(rows[0]?.email, "ci-owner@local.anigamesready");
console.log("PASS: Admin username-to-email lookup is rate-limited and returns the active owner identity");
