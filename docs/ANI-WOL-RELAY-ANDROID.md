# Ani Games Ready Android WoL Relay v1

## Architecture
- The Android app is a separate relay identity; it is not inserted into \`public.devices\` and does not impersonate a PC Billing client.
- Admin uses authenticated \`api.wol_relay_*\` RPCs to create a one-time pairing code, inspect relay health, and queue a wake command.
- The Android app calls the DB1 \`ani-games-api\` gateway. DB1 forwards relay endpoints to DB2 when the coordinated global route is on backup.
- The relay polls a separate \`wol_relay_commands\` queue, sends UDP Magic Packet broadcasts to ports 9 and 7 on its local Wi-Fi LAN, then acknowledges packet delivery.
- A PC is only shown as ONLINE after its normal Billing heartbeat is received.

## Compatibility
- Redmi 6 Pro is the primary target (Android 8.1-class device; app minSdk 23).
- The relay is low-CPU, foreground-service based, Wi-Fi locked while active, and requests exemption from battery optimization.
- The relay reports battery percentage, battery temperature and charging state only. It does not attempt to control the charging circuit.
- PC targets must have a recent Billing build that reports \`metadata.wolLanMac\` (V12.3.8 or newer), wired LAN, and BIOS/NIC Wake-on-LAN enabled.

## Safety and isolation
- Relay tokens are generated server-side and stored hashed in the database; the Android app stores the returned token using EncryptedSharedPreferences.
- Pairing codes are one-time and expire after 10 minutes.
- Commands are scoped to the owner's org, target device, relay identity and a 90-second expiry. Duplicate wake requests are guarded.
- Existing billing command queue, PC pairing, rental accounts, sessions and report tables are unchanged.
- DB1 and DB2 receive the same additive migration. DB1 gateway path allowlist includes relay routes; DB2 runs the local handler without forwarding to itself.

## DB1/DB2 failover limitation
The additive schema and API handlers are deployed to both DB1 and DB2, and the DB1 gateway routes relay requests to the active target. Relay enrollment/device/command rows are currently written to the active database only; no dual-write replication for these new rows has been enabled yet. The live route state currently reports `active_target=primary`, `backup_ready=false`, and `sync_ready=false`. Do not switch the active database expecting an existing relay pairing or pending WoL command to appear on the other database. Before enabling DB2 failover, include all three `wol_relay_*` tables in the approved DB sync/replication procedure or add authenticated peer replication and verify parity.

## Required field tests
1. Pair Redmi from Admin-generated code.
2. Confirm relay heartbeat and battery/temperature in Admin.
3. Lock screen for at least 30 minutes and confirm relay stays online.
4. Turn router Wi-Fi off/on and confirm auto reconnect.
5. Reboot Redmi and confirm boot receiver restarts the service.
6. Wake a PC that is powered off but still connected to LAN.
7. Confirm Magic Packet ACK is distinct from PC-online heartbeat.
8. Switch DB1/DB2 global route and verify the same relay registration remains reachable.
