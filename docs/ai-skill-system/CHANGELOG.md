# Changelog

## 2026-11-14 — PC Billing V12.4.9 DB1 Direct recovery build
- Created isolated recovery branch `recovery/pc-v12.4.9-db1-direct-20261114` from the verified V12.4.8 source baseline.
- Removed client-side `db-route-status`/DB2/shared-gateway route lookup from PC Billing device transport; all device requests now target DB1 `ani-games-api` directly.
- Preserved device token, local outbox, sync cursor, heartbeat, watchdog, rental/session/sync flows, timer sizing, fullscreen safety and manual Windows controls.
- Preserved Electron `appId` and legacy `productName` so existing `userData` location is not renamed; build output is V12.4.9.
- GitHub Actions run `43572350285` completed successfully; artifact `14104807189`; EXE SHA-256 `9B8171EC801229B3C0EE01F763D9037B33ABB7CDCBF38396F3BC8D83C1EB0807`.
- Clean source ZIP SHA-256 `7BEFCF83D4D542FE0F7FE92866E16B7BA29C1DE05E063927B89FBD43099C75F7`.
- Static/build tests passed. Live saved-token login, heartbeat and real rental session tests remain pending on a paired customer PC.
- No master branch, Admin APK, Reseller APK, DB1 data, DB2 project or production database configuration was changed.

## 2026-11-14 — BOTH activation and live repository re-audit
- Read the current GitHub entry rules, Master Skill, state, registry, decisions, next tasks, changelog, version ledger, setup guide and relevant project/database/handover/regression Skills.
- Verified the connected GitHub repository can be read in this chat.
- Revalidated live branches and found the previous registry stale: Admin DB Android candidate is now V12.1.50; Reseller DB Android branch head advanced to `62e14e8...`; a separate `backend/db-android-core-v1` schema/contract branch exists.
- Updated the registry and version ledger to the current exact full SHAs and recorded build-workflow exclusions.
- Reviewed DB1 contract audit: 41 tables, 161 routines, 116 triggers and 14 active Edge Functions; 24 operational-table schema is only a schema reference, not a complete Redmi API.
- Recorded the last user-reported Termux state and explicitly marked it as not live-verified in this chat.
- Created a task handover. No runtime source, SQL database, Supabase project, server process, APK/EXE, build workflow or production setting was changed.

## 2026-11-14 — Hybrid ChatGPT + GitHub setup
- Added `CHATGPT_SETUP.md` with ChatGPT Project instructions, start prompt, handover prompt, setup steps, capability boundaries, and manual activation test.
- Updated README, project state, and next tasks to record the BOTH workflow.
- ChatGPT-side Project setup remained pending user confirmation.
- Documentation-only changes; no runtime source, build workflow, APK/EXE, database, Supabase project, or production configuration changed.

## 2026-11-14 — Initial AI Skill System
- Audited current GitHub repositories and active DB Android branches for PC Billing, Admin, and Reseller.
- Identified legacy repositories and recorded why their default branches are not automatically authoritative.
- Created isolated documentation branch `docs/ani-games-ready-ai-skill-system` from PC Billing DB Android branch `f938c574dfbd17ab84b07ca940115a280d3f8d78`.
- Added master instructions, modular Skills, project registry/state/decisions, version ledger, next tasks, and handover template.
- No runtime source, build workflow, APK/EXE, database, Supabase project, or production configuration changed.
