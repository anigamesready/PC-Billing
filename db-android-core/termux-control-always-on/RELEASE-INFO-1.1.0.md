# Ani Games Ready DB Android — Always-On Control 1.1.0

Status: isolated candidate package; not yet installed or device-validated.

## Source and artifact

- Repository: anigamesready/PC-Billing
- Work branch: fix/db-android-always-on-supervisor-20261124
- Base commit: bd11d9b4e53ece362715a772f210c7e3b13adba1
- Package: ANI-GAMES-READY-DB-ANDROID-ALWAYS-ON-1.1.0.zip
- SHA-256: 01c5f25ca2f4774d5209f39b9083e39bf75b74502af9f89d56265c73f75257ac
- Package contains controller, runit watchdog service, Termux:Boot helper, installer, Indonesian README, checksums, and fixture tests.

## Intended behavior

- One ON action stores desired state ON and enables a runit-supervised watchdog.
- Local start/recovery order: existing PostgreSQL PGDATA -> API 8788 -> WSS relay agent.
- Closing the menu does not stop services. Menu exit is not OFF.
- OFF is only accepted in the interactive menu after typing MATIKAN DB. Direct CLI stop/off aliases are rejected.
- Worker HTTP 503 is treated as remote degradation. It must not stop or restart local PostgreSQL/API. The agent already has its own reconnect logic; the watchdog may perform a bounded agent-only reconnect.
- Termux:Boot resumes enabled runit services on device boot when desired state is ON.
- PostgreSQL is stopped during OFF only after process/port/session safety checks. If any check is uncertain or another DB client uses the cluster, PostgreSQL is deliberately left ON.

## Safety scope

No schema/migration/restore/reset/initdb, no PGDATA deletion, no .env or secret changes, no public PostgreSQL bind, no API 8787 change, no Supabase DB1/DB2, Worker deployment, or Blynk/WoL changes.

## Test evidence

Local isolated fixture tests: 11/11 PASS, including start order, ON persistence, Worker 503 isolation, menu-only OFF, OFF cancellation, post-OFF watchdog behavior, and PostgreSQL shutdown guards. Bash syntax checks and ZIP integrity also PASS.

These are fixture/static checks only. They do not prove installation, reboot recovery, screen-off behavior, 24-hour stability, live Worker health, or Redmi device acceptance.

## Required device acceptance

1. Verify a fresh sanitized Termux inventory and a current backup/restore path before installation.
2. Install the package with the stack state preserved; inspect installation result and checksums.
3. Enable Termux and Termux:Boot unrestricted background/battery settings; open Termux:Boot once.
4. Test ON, menu exit, screen-off, Wi-Fi/mobile handover, process kill/recovery, reboot, and menu-only OFF.
5. Confirm PGDATA and existing rental data remain intact. Keep API 8787, Supabase and Blynk/WoL unchanged.

Android/Redmi may still terminate processes through force-stop, aggressive battery/RAM management, reboot, shutdown, battery depletion or OS failure. Internet and Cloudflare availability are external dependencies; this package cannot guarantee an absolute 24/7 SLA.