# Handover — DB Android Termux one-touch controller 1.0.0

- Date/time (Asia/Jakarta): 2026-11-17
- Status: PACKAGE BUILT AND LOCAL MOCK TESTS PASS; Redmi installation/device acceptance pending.
- User confirmed Admin DB Android V12.1.53 login succeeds through the WSS Worker after relay health was HTTP 200.
- Source audited: `anigamesready/PC-Billing`, branch `infra/db-android-ws-relay-stage-20261116`, head `d86e7ecfa82d7af29bb53d067a316984b1fef69b`.
- Exact existing runtime scripts inspected: `db-android-core/start-stage.sh`, `status-stage.sh`, `stop-stage.sh`, `README-ID.md`, `README-STAGE-ID.txt`, and `ws-relay-stage/README-ID.md`.
- Service architecture: PostgreSQL 5432 (private; PGDATA `$PREFIX/var/lib/postgresql`) -> stage API 127.0.0.1:8788 -> Node WSS agent -> Cloudflare Worker/RelayHub. Legacy API `~/ani-games-server` at 8787 is separate and is not managed by this controller.
- Package: `ANI-GAMES-READY-DB-ANDROID-CONTROL-1.0.0.zip`; 11,168 bytes; SHA-256 `d3f51d6528695891bbf8e48f727e87a1ffd0d8e538877f66dbad19a71520aa04`.
- Package files: `ani-db-control.sh`, `install-control.sh`, four `shortcuts/DB-ANDROID-*.sh` files, `README-ID.md`, `SHA256SUMS.txt`, `tests/test-controller.sh`.
- ON: starts existing PostgreSQL only when managed PGDATA is identified and PostgreSQL is not already running; then starts API 8788; then starts WSS agent; verifies Worker status.
- Normal OFF: stops agent then API 8788, leaves PostgreSQL online. FULL OFF requires typing MATIKAN DB and only stops PostgreSQL if legacy API 8787 is not responding, no process under `~/ani-games-server` is detected, `pg_stat_activity` has zero other client backends, and the controller recognizes the PGDATA.
- Strict safety boundaries: no changes to legacy API 8787, `.env`, secrets, Worker deployment, Supabase, Blynk/WoL, DB schema, rental data, or public PostgreSQL binding. No `initdb`, PID-file deletion, SQL migration, reset or restore.
- Local tests: bash -n PASS for controller/installer/test/shortcuts; all per-file SHA256SUMS PASS; ZIP integrity PASS; simulated ON PASS; soft OFF PASS; guarded FULL OFF PASS; FULL OFF blocked by simulated DB sessions PASS; FULL OFF blocked by legacy 8787 response PASS; installer + four shortcuts created in disposable HOME PASS. No actual Redmi process was touched.
- Device next: install ZIP via Termux, run status first, then ON, verify Worker HTTP 200, then normal OFF. Use FULL OFF only if the guards allow it. For true home-screen buttons, install Termux:Widget from the same app source/signature as Termux and add the generated `~/.shortcuts` scripts.
- After device acceptance, continue latest PC Billing V12.4.8 DB Android integration audit, then Reseller DB Android.