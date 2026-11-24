# Handover — Redmi DB Android Always-On Control 1.1.0

- Date/time (Asia/Jakarta): 2026-11-24
- Status: IN PROGRESS — package candidate built and fixture-tested; Redmi installation and runtime acceptance pending.
- User request / acceptance criteria: ON must keep PostgreSQL 5432, API 8788, and relay agent in RUNNING state until explicit OFF from the controller; menu exit must not stop services; desired state RUNNING must recover after device reboot.
- Repository: anigamesready/PC-Billing
- Source context branch: feature/db-android-stage-simple-menu-v1
- Exact source context SHA: bd11d9b4e53ece362715a772f210c7e3b13adba1
- Reserved isolated work branch: feature/db-android-always-on-guardian-v1.1.0-20261124 (created from source context; candidate package files not yet committed to this branch).
- Controller source archive: ANI-GAMES-READY-DB-ANDROID-CONTROL-1.0.0.zip; SHA-256 d3f51d6528695891bbf8e48f727e87a1ffd0d8e538877f66dbad19a71520aa04.
- Candidate artifact: ANI-DB-ANDROID-ALWAYSON-1.1.0.zip; SHA-256 3f6e39ff7b5c7332891f4db2412d335b260bbd1afc35e4f2036e0be80d112443.
- Build workflow: local package generation in current task; no GitHub Actions run.
- App/EXE version: not applicable; Termux controller package v1.1.0.
- Relevant dependencies: Termux, termux-services/runit, optional Termux:Boot, existing PostgreSQL PGDATA, API stage 8788, WebSocket relay agent.

## What was inspected
- Re-read Master Skill, Project State/Registry/Decisions/Next Tasks/Changelog/Version Ledger.
- Skills: Database Architect, Project Auditor, Troubleshooting Engineer, Regression Tester, Handover Keeper.
- Audited exact DB Android Control 1.0.0 archive. Status heading and menu matched user's provided Termux status output; old controller had soft stop and full stop split and no persistent supervisor.
- Audited stage one-shot start/status scripts and relay-agent scripts from the available Termux full audit archive.
- Revalidated current Git branch context and inspected Worker health behavior. Worker 503 requires API/database online in proxied health, but observed status had agent_connected=true and unknown upstream API/database.
- Read Cloudflare Worker observability records: repeated POST /proxy responses 503 and related heartbeat/sync proxy errors. Exact inner DO/local agent response body was not available in those telemetry events.

## Changes made in candidate package
- Persistent desired-state RUNNING/STOPPED file.
- Controller menu reduced to ON, OFF, STATUS, EXIT.
- Menu EXIT keeps services running.
- Termux runit guardian watches PostgreSQL, API 8788, and relay agent.
- Termux:Boot hook starts termux-services after device boot; guardian recovers only when persisted desired state is RUNNING.
- API recovery only restarts a PID whose staging working directory and command line are verified.
- PostgreSQL recovery starts the existing PGDATA only when pg_ctl confirms it is not running; no force restart of a live/unready PostgreSQL process.
- Agent restart only when process PID is dead/absent; a live PID with unknown identity is not killed.
- Worker HTTP 503 is treated as external/public path degraded and does not stop or restart healthy local PostgreSQL/API/agent.
- OFF persists STOPPED before shutdown and keeps shared-PG safety guard: PostgreSQL is stopped only when legacy API 8787 is not responding and pg_stat_activity has no other client sessions.

## Verification
- Bash syntax: PASS for every package shell file, run script, and Termux:Boot script.
- Fixture regression: PASS for ON, Worker 503 non-interference, EXIT while RUNNING, guardian idle when STOPPED, guardian recovery, OFF, shared PostgreSQL connection guard, 8787 guard, installer hooks and exact .env preservation.
- Archive extraction and file checksums: PASS.
- ShellCheck: BLOCKED — not installed in environment.
- Redmi installation, actual runit behavior, physical reboot test, Doze/battery restriction and actual end-to-end Worker relay: BLOCKED — device was not remotely accessible.
- No actual DB, PGDATA, .env, API runtime, Worker deployment, APK/EXE, or Blynk/WoL service was changed.

## Risks / blockers
- Android can still kill Termux via Force Stop, battery policies, device power loss or storage failure. No unprivileged Termux package can guarantee absolute uptime under those conditions.
- A Cloudflare Worker/DO 503 is independent of local PG/API/agent health and remains a separate unresolved problem.
- Because old API 8787 may share the same PostgreSQL cluster, OFF can leave PostgreSQL ON if 8787 or another client is active. This guard is intentional and must not be bypassed.

## Rollback
- Installer creates timestamped backup copies of the existing controller and shortcuts.
- Use sv-disable ani-db-guardian and sv down ani-db-guardian to disable the added guardian service; restore the timestamped controller/shortcut backups.
- Never remove PGDATA, .env, postmaster.pid, or database files for rollback.

## Next action
1. User installs the candidate ZIP on Redmi and sends sanitized STATUS output before selecting ON.
2. Verify guardian RUNNING, local service health, menu EXIT persistence, screen-off behavior and reboot recovery before marking accepted.

## User-facing summary
The candidate control package is built and fixture-tested, but has not yet been installed on Redmi. It implements ON-until-OFF behavior and protects the existing database. Redmi runtime acceptance is still required.