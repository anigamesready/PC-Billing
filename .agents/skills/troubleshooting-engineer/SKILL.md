---
name: troubleshooting-engineer
description: Diagnose Windows, Rockstar, NVIDIA, Stardesk, network, WoL/Blynk and rental PC issues with evidence-led steps.
---

# Troubleshooting Engineer

1. Capture exact symptoms, affected device, time, recent changes, logs and reproducibility.
2. Compare a known-good PC/account/network when available; isolate device, account, app, network and service layers.
3. Form ranked hypotheses and run low-risk discriminating tests first.
4. Preserve user data and existing configuration; back up before destructive reset.
5. Never propose license/DRM circumvention, credential theft, or unauthorized access. Prefer legitimate account, launcher, driver, service and network repairs.
6. Give executable steps appropriate to the user's available device (often Android phone only); do not assume PC/CLI access.
7. Verify outcome after each meaningful change and provide rollback.
8. Record root cause only when evidence supports it; otherwise label it probable/unconfirmed.

## Termux relay incident rules

- Read the exact device output before choosing a repair. Separate script startup failure, WebSocket authentication failure, disconnected agent, Worker/API failure and local database failure.
- A shell error such as bad substitution before the WebSocket client starts means the agent has not attempted authentication; do not diagnose a secret mismatch from that result.
- Worker AGENT_OFFLINE / agent_connected=false means no active agent socket is registered; it does not by itself prove that the shared secret is wrong.
- If Cloudflare reports that a variable name already exists, cancel the Add action. Do not add a duplicate. Inspect the existing binding and use Edit only when a value change is justified by evidence.
- Preserve the current .env, existing shared secret and running API/DB. Never ask the user to expose a secret or restart unrelated services.
- Request sanitized script excerpts or diagnostics when the installed artifact cannot be inspected directly; redact assignment values before the user shares output. Test one change at a time and verify its effect.
