# PC Billing V12.3.1 heartbeat/session performance audit

## Production findings
- Android generated CORS `OPTIONS` records to `db-route-status` without a matching Android `GET` in the screenshot time window. Internal route-status reads were responding; p95 was about 847 ms in the sampled 30-minute window. Admin V12.1.32 removes the unnecessary browser `apikey` header, avoiding preflight.
- DB1 recorded 39 HTTP 400 heartbeat responses with `FREE_TEST_DISABLED` and 17 successful heartbeat responses during that same window. A denied `__TEST10__` insert threw from a trigger and rolled back device liveness and command delivery with the whole heartbeat.
- PC runtime forced route resolution on every API request and had no heartbeat single-flight guard, so multiple 15-second timer ticks could overlap a slow heartbeat/sync/pull cycle.

## V12.3.1 changes
- Use a 30-second cache for the last verified client route on ordinary reads/writes; force a new route resolution on retry. The shared DB gateway remains authoritative; a stale target is rejected and re-resolved on retry.
- Retry transient network/408/425/429/5xx failures, but do not retry deterministic 4xx errors.
- Serialize heartbeat cycles, coalesce overlapping events, and immediately send current state after rental/test start or stop.
- Liveness timestamps on `devices` are persisted at most every 30 seconds so the Admin UI's 45-second online threshold remains safe. `device_heartbeats` becomes event-only: it logs meaningful device/session/shutdown/version transitions, not stable polling.
- Account countdown changes are persisted at 30-second thresholds; rental session status/code transitions and stop/end events remain immediate. Paused-session liveness refreshes at most once a minute.
- If an old PC reports a new Free Test while policy is OFF, the RPC returns a normal heartbeat plus a denial flag instead of throwing and rolling back the whole heartbeat. The existing trigger still rejects new test-session inserts; already-active test sessions may finish.

## Safety scope
- No pairing token, route-control state, rental/session row, or historical heartbeat row is deleted by this migration.
- The migration replaces only `api.device_heartbeat(text,text,jsonb)`, using strict source anchors. Apply it to DB1 and DB2 separately. It does not switch active DB.
- CI checks JS syntax, route fallback/retry behavior, session event hooks, test-policy handling, and version identity. A physical Windows PC test is still required before replacing the master build.
