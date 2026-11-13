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
