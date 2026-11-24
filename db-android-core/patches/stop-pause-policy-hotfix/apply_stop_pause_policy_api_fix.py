#!/usr/bin/env python3
"""Surgical, idempotent hotfix for the isolated DB Android stage API.

Adds only:
- Admin allowlist entry for admin_get_billing_stop_pause_policy
- Admin allowlist entry for admin_set_billing_stop_pause_policy
- Device route for /device/session-control-policy

No rental, session, pairing, Remote Play, or WoL code is rewritten.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

GET_ENTRY = (
    '  admin_get_billing_stop_pause_policy: { auth: "admin", '
    'sql: "SELECT api.admin_get_billing_stop_pause_policy($1::text) AS result", args: [] },'
)
SET_ENTRY = (
    '  admin_set_billing_stop_pause_policy: { auth: "admin", '
    'sql: "SELECT api.admin_set_billing_stop_pause_policy($1::text,$2::boolean) AS result", '
    'args: ["p_enabled"] },'
)
DEVICE_ENTRY = (
    '  if (path === "/device/session-control-policy") return send(res,200,'
    'await scalar("SELECT api.device_session_control_policy($1::text) AS result",[token]));'
)

GET_ANCHOR = (
    '  admin_get_free_test_policy: { auth: "admin", '
    'sql: "SELECT api.admin_get_free_test_policy($1::text) AS result", args: [] },'
)
SET_ANCHOR = (
    '  admin_set_free_test_policy: { auth: "admin", '
    'sql: "SELECT api.admin_set_free_test_policy($1::text,$2::boolean) AS result", '
    'args: ["p_enabled"] },'
)
DEVICE_ANCHOR = (
    '  if (path === "/device/test-policy") return send(res,200,'
    'await scalar("SELECT api.device_free_test_policy($1::text) AS result",[token]));'
)

def _line_count(source: str, text: str) -> int:
    return source.count(text)

def _ensure_entry(source: str, name: str, entry: str, anchor: str) -> tuple[str, bool]:
    pattern = re.compile(r"(?m)^\s*" + re.escape(name) + r"\s*:")
    matches = list(pattern.finditer(source))
    if len(matches) > 1:
        raise ValueError("DUPLICATE_RPC_ENTRY:" + name)
    if matches:
        line_start = source.rfind("\n", 0, matches[0].start()) + 1
        line_end = source.find("\n", matches[0].start())
        if line_end < 0:
            line_end = len(source)
        actual = source[line_start:line_end].rstrip("\r")
        if actual != entry:
            raise ValueError("RPC_ENTRY_CONTRACT_MISMATCH:" + name)
        return source, False

    if _line_count(source, anchor) != 1:
        raise ValueError("RPC_INSERTION_ANCHOR_MISMATCH:" + name)
    return source.replace(anchor, anchor + "\n" + entry, 1), True

def patch_server_text(source: str) -> tuple[str, list[str]]:
    """Return patched source and a list of the exact additions made."""
    for marker, label in (
        ("const RPC = {", "RPC_MAP"),
        ("async function rpcRequest(", "RPC_HANDLER"),
        ('if (!spec) return send(res, 404, { message: "RPC_NOT_ALLOWED" });', "RPC_DENY_GUARD"),
        ("async function deviceRequest(", "DEVICE_HANDLER"),
    ):
        if source.count(marker) != 1:
            raise ValueError("EXPECTED_SINGLE_" + label)

    changes: list[str] = []
    source, added = _ensure_entry(source, "admin_get_billing_stop_pause_policy", GET_ENTRY, GET_ANCHOR)
    if added:
        changes.append("admin_get_billing_stop_pause_policy")

    source, added = _ensure_entry(source, "admin_set_billing_stop_pause_policy", SET_ENTRY, SET_ANCHOR)
    if added:
        changes.append("admin_set_billing_stop_pause_policy")

    device_pattern = re.compile(
        r'(?m)^\s*if \(path === "/device/session-control-policy"\) return send\(res,200,'
    )
    device_matches = list(device_pattern.finditer(source))
    if len(device_matches) > 1:
        raise ValueError("DUPLICATE_DEVICE_SESSION_CONTROL_POLICY_ROUTE")
    if device_matches:
        line_start = source.rfind("\n", 0, device_matches[0].start()) + 1
        line_end = source.find("\n", device_matches[0].start())
        if line_end < 0:
            line_end = len(source)
        actual = source[line_start:line_end].rstrip("\r")
        if actual != DEVICE_ENTRY:
            raise ValueError("DEVICE_SESSION_CONTROL_POLICY_CONTRACT_MISMATCH")
    else:
        if _line_count(source, DEVICE_ANCHOR) != 1:
            raise ValueError("DEVICE_POLICY_INSERTION_ANCHOR_MISMATCH")
        source = source.replace(DEVICE_ANCHOR, DEVICE_ANCHOR + "\n" + DEVICE_ENTRY, 1)
        changes.append("/device/session-control-policy")

    # Final invariants: exact single route definitions and the original deny-by-default
    # guard remain in place. This does not open a wildcard API/RPC route.
    for name, expected in (
        ("admin_get_billing_stop_pause_policy", GET_ENTRY),
        ("admin_set_billing_stop_pause_policy", SET_ENTRY),
    ):
        if _line_count(source, expected) != 1:
            raise ValueError("FINAL_RPC_ENTRY_COUNT_INVALID:" + name)
    if _line_count(source, DEVICE_ENTRY) != 1:
        raise ValueError("FINAL_DEVICE_ROUTE_COUNT_INVALID")
    if _line_count(source, 'if (!spec) return send(res, 404, { message: "RPC_NOT_ALLOWED" });') != 1:
        raise ValueError("DENY_BY_DEFAULT_RPC_GUARD_CHANGED")
    return source, changes

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("server_mjs", type=Path)
    args = parser.parse_args()
    path = args.server_mjs
    if not path.is_file():
        print("ERROR: STAGE_SERVER_MJS_NOT_FOUND")
        return 2
    original = path.read_text(encoding="utf-8")
    try:
        updated, changes = patch_server_text(original)
    except ValueError as exc:
        print("ERROR: " + str(exc))
        return 3
    if not changes:
        print("ALREADY_OK: all PAUSE/STOP RPC and device route entries exist exactly once.")
        return 0
    path.write_text(updated, encoding="utf-8", newline="")
    print("PATCHED: " + ", ".join(changes))
    print("UNCHANGED: all other server routes and RPC entries.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
