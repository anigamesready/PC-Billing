# Audit PC Billing V12.1.0 source ZIP and planned V12.1.2 patch

## Confirmed findings from the repository ZIP

- The renderer keeps local system history in localStorage under billing_system_log_v10. The ring buffer already has a 150-record cap, but repeated lines churn out older, useful events.
- A successful automatic backup was written to the system log each time it ran. The source schedules automatic backup at a minimum 10-minute interval, so on a continuously running PC this could add about 144 low-value success lines per day. Errors still matter and should remain.
- When a rental timer reaches zero, updateTimer() writes an expiry line and calls pauseSession(false), which also wrote a generic session-stopped line. That creates two local log lines for one expiry event.
- Rental data sync already has a dirty set, user fingerprints, source event IDs, an outbox, and bounds for the queue. Do not replace this with a full-table rewrite on every heartbeat.
- Cloud heartbeat currently runs every 15 seconds; it also exchanges command and status information. Changing this interval blindly can delay admin commands and make online/offline display inaccurate. The current migration doesn't change that interval.
- The existing PC source sends Admin-to-PC popup messages, but had no PC-to-Admin event endpoint for rental-ended/manual-stop messages. A local beep or PC popup alone cannot create an Android notification.

## V12.1.2 patch behavior

- Keep at most 100 local system log records.
- Coalesce consecutive equal level/message entries within 60 seconds into a single record with a count field.
- Stop logging successful automatic backup runs. Keep errors and manually requested backup success entries.
- Avoid the duplicate generic stopped log after expiry.
- Queue only session_expired and session_stopped admin alerts, assign unique source IDs, limit the durable local alert outbox to 100, retry quietly, and deduplicate in the database.
- Add a device-token-authenticated /device/alert route to the Edge Function source.
- Keep the periodic heartbeat interval and existing rental-sync, backup, and timer behavior unchanged.

## Required deployment actions before PC-to-Android alerting can work

1. Apply docs/ADMIN-ALERT-NOTIFICATIONS-MIGRATION.sql from the Admin-Ani-Games feature branch to BOTH Supabase DB1 and DB2. It creates a minimal, deduplicated alert-event table and two RPCs.
2. Deploy the updated supabase/functions/ani-games-api/index.ts from the patched PC source to the Supabase Edge Function named ani-games-api for the matching project(s). The PC Windows build does not deploy the Edge Function automatically.
3. Build/install the V12.1.7 Admin APK. Grant Android notification permission, then use the Android notification settings control to verify sound and notification-channel settings.
4. Live-test expiry and manual stop with one test rental on DB1 and DB2. Check that each action generates one Android system notification and the PC event outbox empties after acknowledgment.

## Safety boundaries and remaining validation

- This workflow only extracts, patches, tests syntax and builds a portable Windows EXE. It does not write to the live Supabase database, deploy Edge Functions, or delete production logs.
- Background delivery when the Admin app is fully closed is not guaranteed by foreground WebView polling. Reliable delivery while backgrounded or force-stopped requires a push service such as Firebase Cloud Messaging and registered device tokens. V12.1.7 is intended to show Android system notifications while the Admin app is running and connected.
- Syntax/build success does not replace end-to-end tests on the target Windows PC and Android phone.

## Follow-up audit: live runtime and current DB telemetry (2026-10-18)

### Runtime finding corrected in V12.1.7

- Electron loads `index.html`; `renderer.js` is not the active runtime. The earlier log optimization patched `renderer.js` only, so its 100-entry/coalescing rule and reduced automatic-backup success logging were not effective in the running PC app.
- V12.1.7 applies the same bounded log policy to the active `index.html` runtime. It keeps up to 100 records, coalesces adjacent identical level/message events within 60 seconds, and records manual backup success plus all backup errors, but not routine automatic-backup success.
- Rental expiry/manual-stop still produces explicit alert events. Important errors and billing/session events remain logged.

### Request-volume finding corrected in V12.1.7

- The PC already calls `pullNow()` after a successful 15-second heartbeat, but also called it again on a separate 30-second maintenance timer. That was redundant traffic; the maintenance timer now calls `syncNow()` and `flushAdminAlerts()` only. The heartbeat interval and its pull path remain unchanged.
- DB1's 24-hour sample showed 4,132 successful `device_heartbeat` RPC requests and 5,342 successful `device_pull_sync` RPC requests. The repeated pull path was therefore a meaningful avoidable source of requests; re-check after installing V12.1.7 to measure the reduction.
- DB1's heartbeat-history table contained 2,351 rows over the same 24-hour period, while the active `api.device_heartbeat` definition already limits persisted history samples to about one per device per 60 seconds. The device's live `last_heartbeat_at` is still updated per heartbeat, so command/status responsiveness is preserved. Do not increase the heartbeat interval only to cut history rows.

### Error burst observed; not counted as routine logging

- DB1 had 1,990 `device_sync` HTTP 409 responses in the inspected 24-hour window, clustered from 16:00 to 23:00 UTC on 2026-10-17. PostgreSQL logs during that window included duplicate-key conflicts on `rental_accounts_org_id_code_key`.
- The current live `api.device_sync` definition now serializes rental upserts by organization/code and checks for existing account ownership before inserting. The same route had zero 409 responses and the duplicate-key error query had zero hits in each inspected hour from 00:00 to 10:00 UTC on 2026-10-18. This indicates the historical burst had stopped by then; do not silence future 409s if they recur. Monitor the live error rate after V12.1.7 installation.

### Admin APK polling and background access logs

- The Admin V12.1.11 APK polls `admin_recent_alerts` every 15 seconds and the inspected DB1 logs showed 217 successful POST requests plus 217 OPTIONS preflights in the 24-hour window. This is read-only polling (not 434 database audit rows), but it contributes gateway access-log volume.
- V12.1.12 keeps 15-second polling while the Admin UI is visible, retains exponential retry backoff and the one-per-minute diagnostic cap, and skips polling when the WebView is hidden. Background WebView polling was not a reliable background-notification solution and needlessly generated requests while the app was hidden.
- The Admin alert table itself remains event-driven and deduplicated. Do not log each poll as an app/database event.

### Validation boundaries

- These source/build changes do not delete, compact, or mutate existing production log records. They reduce future low-value local logs and avoidable requests.
- GitHub Actions static checks verify the active runtime's log policy, cloud timer, and JavaScript syntax. Production request-count reductions should be confirmed after installing the new PC EXE and Admin APK and comparing the next 24-hour DB1/DB2 sample.
