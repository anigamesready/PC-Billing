import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const schemaDir = path.resolve(here, "../schema");
const server = fs.readFileSync(path.join(here, "server.mjs"), "utf8");
const rpcBlock = server.match(/const RPC = \{([\s\S]*?)\n\};/);
assert.ok(rpcBlock, "RPC allowlist not found");

const schema = fs.readdirSync(schemaDir)
  .filter(name => /^\d{3}_.+\.sql$/i.test(name) && !name.startsWith("001_"))
  .map(name => fs.readFileSync(path.join(schemaDir, name), "utf8"))
  .join("\n");

const entries = [...rpcBlock[1].matchAll(/^\s*([A-Za-z0-9_]+):\s*\{\s*auth:\s*"([^"]+)",\s*sql:\s*"([^"]+)",\s*args:\s*\[([^\]]*)\]\s*\}/gm)];
assert.equal(entries.length, 49, "RPC allowlist entry count changed; review this checker before updating");

function countParams(signature) {
  const value = signature.trim();
  if (!value) return 0;
  let depth = 0;
  let count = 1;
  for (const character of value) {
    if (character === "(") depth++;
    else if (character === ")") depth--;
    else if (character === "," && depth === 0) count++;
  }
  return count;
}

for (const match of entries) {
  const name = match[1];
  const auth = match[2];
  const sql = match[3];
  const bodyArgs = [...match[4].matchAll(/"[^"]+"/g)].length;
  const suppliedArgs = bodyArgs + (auth ? 1 : 0);
  const placeholders = [...sql.matchAll(/\$(\d+)/g)]
    .reduce((maximum, item) => Math.max(maximum, Number(item[1])), 0);

  assert.equal(
    placeholders,
    suppliedArgs,
    name + ": SQL placeholders " + placeholders + " != Node bound arguments " + suppliedArgs
  );

  const signaturePattern = new RegExp(
    "CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+api\\." + name +
    "\\s*\\(([\\s\\S]*?)\\)\\s*(?:RETURNS|returns)",
    "gi"
  );
  const definitions = [...schema.matchAll(signaturePattern)];
  const matchingOverload = definitions.some(definition => countParams(definition[1]) === placeholders);
  assert.ok(
    matchingOverload,
    name + ": no PostgreSQL api." + name + " overload with " + placeholders + " parameters"
  );
}

console.log("PASS: 49 Node RPC bindings match SQL placeholders and PostgreSQL function overloads");
