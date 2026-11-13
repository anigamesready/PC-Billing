# Changelog

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
