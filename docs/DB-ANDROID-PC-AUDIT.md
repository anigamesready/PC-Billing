# PC Billing — DB Android Track Audit

## Branch identity
- Work branch: `pc-billing-v12.4.8-DB-Android`
- Source repository: `anigamesready/PC-Billing`
- Source baseline branch: `fix/pc-v12.4.8-timer-size-sync`
- Source baseline commit: `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`
- This DB Android branch was created from that exact commit and verified identical before this audit document was added.
- Baseline app version: PC Billing V12.4.8.

## Source/build audit
The build workflow `.github/workflows/build-pc-v12-4-8-timer-size-sync.yml` extracts `AniGames-PC-V12.1.0-ADMIN-POPUP-FIXED-SOURCE.zip`, expects `main.js`, `preload.js`, `renderer.js`, `index.html`, `v11-cloud.js`, `package.json`, and `package-lock.json`, then applies the V12.4.5–V12.4.8 patch chain.

Important patches in the inherited source pipeline include:
- dual-DB route resolution and shared-gateway transport;
- global rental lookups, rental-session start/end, sync cursor, delta pull and offline lease/conflict handling;
- Blynk/WoL relay integration;
- fullscreen non-interference, timer geometry synchronization and Windows command controls.

The existing workflow only has an automatic push trigger for the original V12.4.8 source branch. The new DB Android branch is not added to that trigger. Manual workflow dispatch remains available, but it must not be treated as a DB Android build until a dedicated build chain is prepared.

## Existing backend contract found
The PC client expects more than a health endpoint. The V12.3.4 global-rental patch references these device API routes:
- `/device/sync-cursor`
- `/device/pull`
- `/device/rental/lookup`
- `/device/session/start`
- `/device/session/end`
- `/device/rental/release`

The inherited `ani-games-api` function also handles pairing/enrollment, disconnect, heartbeat, command acknowledgement, delta sync, pull, rental snapshots and alerts. These behaviors require server-side token validation, organization/device binding, idempotency, and durable event handling.

## DB Android separation rules
1. Keep this branch separate from `main`, the V13 dual-DB Supabase candidate and all Supabase production branches.
2. Do not route this branch to DB2 or use DB1/DB2 route-control as the Android database selector.
3. Add a dedicated Redmi/PostgreSQL API adapter and migration set; do not remove the existing PC UI, billing timer, fullscreen protections, pairing identity, offline queue, rental lease logic, Windows controls or Blynk/WoL behavior.
4. Never expose PostgreSQL credentials, Supabase service-role credentials, or privileged server secrets in the PC client.
5. Keep remote access disabled until authentication, TLS/tunnel access control, authorization and endpoint regression tests are complete.

## Current status
This commit only records the audit. No runtime source, Supabase project, DB route, Blynk relay or production configuration was changed. The Redmi Termux API currently responds to its local health check; the full PC device/rental API contract has not yet been implemented or tested against the app.

## Required regression gate before a DB Android EXE
- Node syntax checks for every patched JS file and inline Billing script.
- Preserve V12.4.8 timer size and fullscreen non-interference assertions.
- Preserve Windows control and direct shutdown semantics; do not reintroduce the automatic shutdown countdown.
- Preserve pairing recovery, heartbeat, command acknowledgement, rental lookup/session start/session end, offline lease and conflict outboxes.
- Preserve WoL/Blynk relay behavior without managing or stopping the relay from database controls.
- Run paired-PC smoke tests against a staging database before any production cutover.
