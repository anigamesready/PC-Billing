# Handover — Admin login + DB Android global access

- Date/time (Asia/Jakarta): 2026-11-16
- Status: IN PROGRESS — source branches and permanent project notes updated; APK CI/artifact, Termux gateway rollout and device acceptance are pending.
- User request: fix Admin APK login, bring the Redmi DB Android API online for global access (not just localhost), and target completion Sunday 2026-11-22.
- User screenshot: Admin address http://127.0.0.1:8788; error "Server database lokal belum siap: Failed to fetch".

## Verified source tracks
- API fix branch: anigamesready/PC-Billing, fix/db-android-core-api-contracts-20261116, base commit f16d97a3dfd96f2f3598396976c3ee5d63c60e6d. User previously applied the Termux API contract patch and reported API/DB health, direct Auth and compatibility-prefixed Auth checks PASS.
- Admin candidate: anigamesready/Admin-Ani-Games, fix/admin-db-android-login-gate-v1.51, head 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5. It is 5 commits ahead and 0 behind admin-v12.1.50-DB-Android base 3ebc8b1912aef13a4833f113c9e7a4914554b146.
- The Admin candidate restores the missing setAdminAuthEnabled helper. Added scripts/patch_admin_db_android_api_fetch_reliability.py to avoid unnecessary health GET preflight and show the failing API origin; wired into the dedicated build workflow. Candidate app identity: version 12.1.51, versionCode 79, applicationId com.anigames.billingadmin.v150db.
- No verified Admin APK build/artifact/signature/hash or fresh-install login exists yet. CI lookup returned no status records.
- Gateway branch: anigamesready/PC-Billing, infra/db-android-cloudflare-global-stage-20261116, head 8c39f86410a3cd6b0ce3521029e689d63984752e. It is based exactly on API fix head f16d97a3dfd96f2f3598396976c3ee5d63c60e6d and 10 ahead/0 behind.
- Old branch infra/db-android-cloudflare-gateway-stage is divergent (49 ahead/17 behind) and must not be deployed as-is.
- New gateway API patch is written to reuse existing node:net and ANI_EDGE_PROXY_SECRET declarations, preventing duplicate imports/consts from Redmi custom code. Gateway CI result is unverified.

## Cloudflare/runtime findings
- Worker ani-games-db-android-stage-gateway is deployed at https://ani-games-db-android-stage-gateway.anigamesready.workers.dev.
- KV namespace ani-games-db-android-stage-upstreams exists, but key ani_games_ready_stage:upstream was absent when checked. No named Tunnel or DNS zone was found in the connected Cloudflare account. The public Worker therefore has no connected Redmi origin.
- Quick Tunnel design uses a rotating trycloudflare origin, Worker registration TTL 600 seconds and Termux refresh while runner stays alive. It is not a guaranteed 24/7 named tunnel.
- Prior user-provided stage check showed API and DB online on 127.0.0.1:8788, remote_access_enabled false; it is a historical check, not live-verified now.
- Never expose PostgreSQL 5432 or change port 8787. Do not blindly bind API to 0.0.0.0. Main server, production data, Supabase DB1/DB2 and Blynk/WoL remain separate.

## Changes made during this task
- Added Admin fetch reliability patch and workflow wiring on the isolated Admin V12.1.51 branch.
- Created a fresh gateway branch based on the current API fix branch; copied gateway files, hardened server patch compatibility and CI synthetic local-additions fixture.
- Updated documentation branch docs/ani-games-ready-ai-skill-system: PROJECT_STATE.md, NEXT_TASKS.md, CHANGELOG.md, VERSION_LEDGER.md, DECISIONS.md, PROJECT_REGISTRY.md. Acceptance target and detailed test plan recorded.
- No runtime source on Redmi, .env, PostgreSQL schema/data, Worker deployment or production service was modified. No APK/Termux ZIP claimed released.

## Test evidence
- Source branch comparison: Admin 5 ahead/0 behind; gateway 10 ahead/0 behind.
- Cloudflare Worker existence and KV namespace verified; current upstream key absent.
- Admin/Gateway GitHub combined status calls returned no status rows; workflow/artifact completion was not verified.
- No local Android build was run here. No fresh install, Admin login, external API request, cellular/Wi-Fi test, 24-hour background run, or restore/rollback test was performed.
- Tests still required: see NEXT_TASKS.md, section "Priority 0 — Admin login + DB Android global access".

## Immediate next action
1. Verify latest GitHub Actions build/test results and fetch exact APK/Termux artifacts plus SHA-256. Do not install unverified builds.
2. On Redmi, recheck stage API 8788 health using the PID-safe stage script; do not touch port 8787.
3. Run gateway bundle only after CI success; confirm secret variable names exist locally without printing or sharing their values.
4. Start Quick Tunnel and require public Worker /health to return API+database online.
5. Set the HTTPS Worker URL in Admin APK; test on Wi-Fi and cellular, login, dashboard and Admin CRUD.
6. Keep 2026-11-22 as target, not a claimed completion date. Mark complete only after device acceptance evidence exists.

## Rollback
- Keep previous Admin APK installed or available before replacing.
- Gateway runner Ctrl+C stops tunnel/registry and should not stop local API; verify stage /health remains online.
- Preserve timestamped .env and server.mjs backups before gateway configure/apply. No database rollback is authorized or needed for these changes.
- Do not revert the API hotfix branch or touch DB rows/schema without explicit approval.


## Runtime recheck update — 2026-11-16 09:45 WIB
- User's Termux command `curl -sS --max-time 5 http://127.0.0.1:8788/health` returned `curl: (7) Failed to connect ... Connection refused`.
- Current evidence: staging API port 8788 is not listening. PostgreSQL state is unknown from this result. No restart or DB operation was performed.
- Safe next step: run the previously verified stage-only start script and recheck health; leave port 8787 and all database data untouched.
