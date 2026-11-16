# Handover — DB Android Owner bootstrap recovery

- Date/time (Asia/Jakarta): 2026-11-16
- Status: IN PROGRESS — source repair package and CI complete; Redmi execution and Owner acceptance pending
- User request / acceptance criteria: resolve local Admin Owner setup error `ADMIN_BOOTSTRAP_DENIED` without resetting data or affecting existing DB, main API or WoL/Blynk; provide a tested Termux repair and clear final steps.
- Repository: `anigamesready/PC-Billing`
- Work branch: `fix/db-android-stage-bootstrap-recovery-20261116`
- Exact source baseline branch + full SHA: `infra/db-android-ws-relay-stage-20261116` — `d86e7ecfa82d7af29bb53d067a316984b1fef69b`
- Current work branch head + full SHA: `8ac5491a5f7ca81a6af85256ce5a2a815a888adc`
- Source archive + SHA-256: not applicable; exact GitHub file refs used
- Build workflow + trigger: `.github/workflows/test-db-android-stage-bootstrap-recovery.yml`; branch push / PR / manual
- App/EXE version, package ID, version code: not an app build; Termux recovery utility only
- Relevant dependencies/contracts: `server.mjs` API loopback gate; `api.admin_bootstrap_owner`; `private.admin_bootstrap_control`; local `.env` token; PostgreSQL staging database; stage-only PID-validated stop/start scripts.

## What was inspected
- Repository branches/commits: live source branch verified; recovery work is 5 commits ahead / 0 behind its exact baseline.
- Source files and patch chain: stage setup installer, start/stop scripts, Node route handler, SQL bootstrap function, auth schema, migration runner and project skills/docs.
- Workflow/artifact: GitHub Actions run 43896105470 — SUCCESS. Final package archive verified.
- Backend/database/schema: no live database read from Redmi. SQL source proves the bootstrap routine rejects missing/consumed/hash-mismatched control rows.
- Related products: main API port 8787, PostgreSQL service, Supabase DB1/DB2 and independent Blynk/WoL relay are explicitly out of scope.

## Changes made
| File | Change | Reason |
|---|---|---|
| `db-android-core/repair-stage-bootstrap.sh` | Guarded local token/hash check, safe hash alignment when unconsumed, no-owner guard, optional stage-only API restart, safe POST probe | Resolve stale/missing bootstrap control state without creating an account |
| `db-android-core/tests/repair-stage-bootstrap.test.sh` | Four mocked safety tests | Prove fail-closed behavior and repair branches |
| `.github/workflows/test-db-android-stage-bootstrap-recovery.yml` | Bash syntax, mock tests and safety scans | CI regression gate |
| `db-android-core/BOOTSTRAP-RECOVERY-ID.md` | Indonesian Termux instructions | Safe device rollout |

## Verification
- Static/syntax checks: Bash syntax PASS locally and in CI.
- Build result: no application build; recovery package assembled.
- Regression checks: four mocked cases PASS (missing row, stale unconsumed hash, active Owner, consumed bootstrap); GitHub Actions 43896105470 SUCCESS.
- Fresh-install/replace test: not applicable.
- Artifact identity/checksum: `ANI-GAMES-READY-DB-ANDROID-BOOTSTRAP-RECOVERY-20261116.zip`; SHA-256 `374b6b49b45f7cb706f069ca1467a9810a66483a1d8767bf228c93046e386287`.
- Tests not run and why: actual Redmi DB row inspection, helper execution, Owner creation, Admin V12.1.53 login and feature acceptance require local user execution; assistant cannot access device-local Termux/database.

## Risks / blockers
- The stale/missing bootstrap hash is the leading source-based diagnosis, not yet proven by a read of the device DB. The helper is designed to inspect state and stop when bootstrap has been consumed or Owner exists.
- It is not operationally complete until user executes the helper and successfully creates/logs in with the Owner account.

## Rollback
- Exact previous branch/commit: original relay stage branch `infra/db-android-ws-relay-stage-20261116` at `d86e7ecfa82d7af29bb53d067a316984b1fef69b`; all runtime files remain unchanged.
- Revert procedure: no source deployment was made. Do not run the helper a second time if it already succeeded; if a runtime change is unexpectedly reported, stop only the stage API and audit state before further action.
- Data recovery procedure (if relevant): no data reset or migration was performed; do not restore or reset staging DB for this error.

## Next action
1. Run the supplied Termux helper on the Redmi and require `BERHASIL`.
2. Create Owner through Chrome at `http://127.0.0.1:8788/setup` on the Redmi, then verify login using Admin DB Android V12.1.53.

## User-facing summary
The recovery script and CI tests are ready. It does not create an Owner or reveal the secret; it checks and repairs only a safe, unused bootstrap token row, then confirms the POST path with invalid dummy input. The Redmi still needs to run the script and create the Owner account locally. PostgreSQL, port 8787, Supabase DB1/DB2 and Blynk/WoL are not changed.
