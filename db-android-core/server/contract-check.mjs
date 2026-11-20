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

const entries = [...rpcBlock[1].matchAll(/^\s*([A-Za-z0-9_]+):\s*\{\s*(?:auth:\s*"([^"]+)",\s*)?sql:\s*"([^"]+)",\s*args:\s*\[([^\]]*)\]\s*\}/gm)];
assert.equal(entries.length, 69, "RPC allowlist entry count changed; review this checker before updating");

function splitParameters(signature) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < signature.length; index++) {
    const character = signature[index];
    if (character === "(") depth++;
    else if (character === ")") depth--;
    else if (character === "," && depth === 0) {
      parts.push(signature.slice(start, index).trim());
      start = index + 1;
    }
  }
  if (signature.slice(start).trim()) parts.push(signature.slice(start).trim());
  return parts;
}

function normalizeType(value) {
  const type = value.toLowerCase().replace(/\s+/g, " ").trim().replace(/\s*\[\s*\]/g, "[]");
  if (type === "timestamp with time zone") return "timestamptz";
  if (type === "timestamp without time zone") return "timestamp";
  if (type === "character varying") return "varchar";
  return type;
}

function parameterTypes(signature) {
  return splitParameters(signature).map(parameter => {
    let value = parameter.replace(/^\s*(IN|OUT|INOUT|VARIADIC)\s+/i, "").trim();
    value = value.replace(/^\w+\s+/, "");
    value = value.split(/\s+(?:DEFAULT|=|:=)\s+/i)[0].trim();
    return normalizeType(value);
  });
}

function countParams(signature) {
  return splitParameters(signature).length;
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

  const castEntries = [...sql.matchAll(/\$(\d+)::([A-Za-z][A-Za-z0-9_]*(?:\[\])?)/g)]
    .sort((left, right) => Number(left[1]) - Number(right[1]));
  assert.equal(castEntries.length, placeholders, name + ": every RPC argument must have an explicit SQL cast");
  const nodeTypes = castEntries.map(entry => normalizeType(entry[2]));

  const signaturePattern = new RegExp(
    "CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+api\\." + name +
    "\\s*\\(([\\s\\S]*?)\\)\\s*(?:RETURNS|returns)",
    "gi"
  );
  const definitions = [...schema.matchAll(signaturePattern)];
  const matchingOverload = definitions.some(definition => {
    const types = parameterTypes(definition[1]);
    return types.length === placeholders && types.every((type, index) => type === nodeTypes[index]);
  });
  assert.ok(
    matchingOverload,
    name + ": no PostgreSQL api." + name + " overload matches ordered Node argument types (" + nodeTypes.join(", ") + ")"
  );
}

assert.ok(server.includes('path === "/device/session-control-policy"'), "PC stop/pause policy device route missing");
assert.ok(schema.includes("api.device_session_control_policy(p_token text)"), "PC stop/pause device SQL function missing");
console.log("PASS: 69 Node RPC bindings match PostgreSQL parameter count, order and types; existing PC stop/pause policy route is connected");
