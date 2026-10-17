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
