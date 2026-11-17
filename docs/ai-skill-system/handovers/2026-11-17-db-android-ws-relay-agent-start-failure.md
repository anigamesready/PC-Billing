# Handover — Redmi DB Android WebSocket agent startup failure

- Date/time (Asia/Jakarta): 2026-11-17
- Status: BLOCKED — confirmed runtime defect in installed shell script; exact installed package provenance and remaining script behavior pending sanitized inspection.
- Product/system: Redmi 6 Pro Termux, DB Android staging WebSocket relay. This is separate from Supabase dual-DB and Blynk/WoL relay.
- Authoritative source branch reviewed: `infra/db-android-ws-relay-stage-20261116`, HEAD at review `d86e7ecfa82d7af29bb53d067a316984b1fef69b`.
- Relay source contract reviewed: Worker `db-android-core/ws-relay-stage/worker.mjs`; docs `db-android-core/ws-relay-stage/README-ID.md`; existing Worker binding name `RELAY_SHARED_SECRET`; local existing `ANI_EDGE_PROXY_SECRET` in staging `.env`.
- Device evidence supplied by user at 2026-11-17 14:47 WIB:
  - start script failed at line 32 with Bash `bad substitution` on `${#ANI_EDGE_PROXY_SECRET:-0}`.
  - Local relay agent status: OFFLINE.
  - Local stage API health: `api=online`, `database=online`.
  - Public Worker `/_relay/health`: HTTP 503, `relay=offline`, `agent_connected=false`.
- Confirmed diagnosis: the start script exited during Bash parameter expansion before the agent could establish a WebSocket. Worker offline is consistent with no registered socket. This output does not establish a secret mismatch.
- Cloudflare UI evidence: adding `RELAY_SHARED_SECRET` was rejected because the variable name already exists. Do not use Add again. No Worker setting or secret value was changed in this review.
- Package output reported creation of a private `relay-worker-shared-secret.txt`. The authoritative branch README says this should be a private temporary copy of the existing `ANI_EDGE_PROXY_SECRET` from the stage `.env`, not a newly generated secret. The installed package filename (`...WS-RELAY-AGENT-FIX-1.0.0.zip`) differs from the documented final artifact filename (`...WS-RELAY-TERMUX-FINAL.zip`), so package provenance and installer implementation must be inspected. The file's value must not be displayed or shared.
- No Termux script, .env, PostgreSQL database, API process, Cloudflare Worker or production setting was changed by this review.
- Skills/decisions updated on the isolated documentation branch: runtime-test Bash control flow (not only `bash -n`), reject invalid length expansion `${#VAR:-0}`, preserve existing secrets, and diagnose shell startup / authentication / agent registration / Worker health / API / DB as separate layers.
- Next:
  1. User shares sanitized source text of installed installer, start/status/stop scripts and agent.mjs, excluding .env and secret values.
  2. Compare package files and hashes against the authoritative branch package and identify whether the conversational ZIP diverges.
  3. Apply a minimal isolated fix and test exact extracted layout with placeholder secrets, including unset/empty/present/short cases.
  4. Only then provide a corrected package or narrowly guarded patch and recheck public health.
- Acceptance: Worker `/_relay/health` HTTP 200 with `relay=online`, `agent_connected=true`, `api=online`, `database=online`; Admin login remains a separate pending device test.
