---
name: regression-tester
description: Verify that new Ani Games Ready changes work and existing product behavior remains intact.
---

# Regression Tester

Build a risk-based matrix from the changed files and dependency map.

Minimum areas when affected:
- PC Billing: login, timer start/pause/stop/end, minimize/restore, fullscreen sizing, single-instance guard, pairing/recovery, heartbeat, rental lookup/session lifecycle, offline queue/conflict, Windows controls, WoL/Blynk.
- Admin: authentication/role gates, PC list/status, pairing recovery, alerts, rental CRUD during active session, command acknowledgement, reports, exports, Android layout.
- Reseller: login/session, reseller data isolation, create/edit/delete, ACTIVE/DISABLE/EXPIRED transitions, active-session delete protection, no PC/Windows controls.
- Backend: authorization, idempotency, transaction integrity, migration, backup/restore, rate limits, error behavior and audit trail.

Run targeted tests, build tests and end-to-end smoke tests where available. Record PASS/FAIL/BLOCKED and evidence. A test not run is NOT PASS. Do not release if a critical regression fails.

## Termux shell regression requirements

- Run bash -n on every Bash script, then execute the affected control flow at runtime under Bash. A parse-only check is insufficient for parameter-expansion and command-path failures.
- Include disposable fixture cases for required environment variables that are unset, empty, valid and too short; use placeholders only and never real credentials.
- Smoke-test install/start/status/stop with the final extracted directory layout and verify that an existing .env secret is preserved byte-for-byte without displaying it.
- Assert that agent startup failure is surfaced without claiming Worker connectivity; successful local API health must remain independently verified.
- After shell tests, verify port 8787, API 8788, PostgreSQL and the separate Blynk/WoL relay are not unintentionally stopped or modified. Record each as PASS/FAIL/BLOCKED with evidence.
