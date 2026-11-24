# Remote Coin Wallet — Android DB only design

Status: source/design preparation in isolated branch \`feature/remote-coin-wallet-android-db-v1\`.
No migration has been applied. No current Redmi database, Admin APK stable build, PC Billing or Reseller source has been changed.

## Architecture boundary

- One active business database: local Ani Games Ready Android DB PostgreSQL on Redmi.
- Remote Play control plane remains in the existing \`remote_play\` schema and shares \`public.rental_accounts\`, \`public.organizations\`, \`public.devices\`.
- Wallet, top-up and coin usage are additive modules in that same database/schema.
- No DB1/DB2 routing, dual-database switch, replication, or second rental database.
- Android Admin APK talks to the local Android DB API; its V12.1.57 SAFE TEST branch removes the old dual DB menus and route state. Existing stable Admin package is not overwritten.
- StarDesk remains the streaming engine; the Android client is the rental/wallet/catalog client.
- Important exception: the current Android DB Node source explicitly returns \`501 RELAY_IS_SEPARATE_SERVICE\` for \`/wol/*\` and \`/iot/*\`. The existing Blynk/WoL relay is still a separate sidecar and must be ported before claiming every feature/control is served by Android DB. It is not a second rental DB.

## Confirmed commercial rules

Exchange:
- Rp8,000 = 60 coins.
- Top-up Rp5,000 = 37.5 coins.
- Rp10,000 = 75 coins.
- Rp15,000 = 112.5 coins.
- Rp20,000 = 150 coins.
- Manual rupiah amount uses the same exact ratio: amount × 60 / 8,000.
- Use PostgreSQL NUMERIC precision, not binary floating-point rounding.

PC rates:
| GPU class | Rp/hour | Coins/hour | Coins/minute |
|---|---:|---:|---:|
| GTX 1050 | 6,000 | 45 | 0.75 |
| GTX 1660 | 6,000 | 45 | 0.75 |
| RTX 3060 | 7,000 | 52.5 | 0.875 |
| RTX 5060 | 8,000 | 60 | 1 |

Per-PC rate records are stored against existing \`public.devices.id\`; each session snapshots the rate so a later Admin tariff edit never changes an ongoing session.

Expiry is calculated only when Admin approves the payment and the new lot is actually credited:
| Valid wallet balance immediately before new credit + new coins | Expiry of NEW lot |
|---:|---:|
| <300 | 3 days |
| 300–<600 | 7 days |
| 600–<900 | 10 days |
| 900–<1,200 | 14 days |
| 1,200–<1,500 | 17 days |
| 1,500–<1,800 | 21 days |
| 1,800–<2,100 | 24 days |
| 2,100–<2,400 | 28 days |
| ≥2,400 | 30 days |

- Old lots keep their original expiry; no top-up extends an older lot.
- Spend nearest expiry first, then oldest credit, then lot ID.
- Expired residue becomes unusable, but remains auditable.
- If a pending order waits several days, use the valid balance at approval time to choose the new lot's expiry tier, not the date the user created the order.

## QRIS → WhatsApp → Admin approval flow

1. Client creates a \`topup_orders\` row on Android DB before WhatsApp opens. The DB snapshots rental account ID, exact whole-Rupiah amount, calculated coin amount, method and idempotency key.
2. Client shows the existing Ani Games Ready static QRIS and the exact amount. Because it is static QRIS, payer must type the amount manually in bank/e-wallet; the QR itself does not embed a unique amount.
3. Client button opens \`https://wa.me/6282298316902\` with order ID, User ID, amount, coin count and request for transfer proof. Opening WhatsApp is not an approval.
4. Admin checks the proof in WhatsApp, opens the pending order in Admin APK and taps Approve or Reject.
5. Approve RPC locks the order and wallet, checks status is still pending, credits one coin lot, writes one ledger row, sets expiry days, and changes order to approved atomically. Repeated taps return an idempotent result and cannot credit twice.
6. Admin never retypes User ID, amount or coin number; Admin screen gets those values from the stored order.

An in-app proof upload may be added later. It is not required for the first manual WhatsApp verification model.

## Login and expired accounts

Existing Remote Play API migration 013 does not allow an unauthenticated first login using only User ID. It requires a unique rental code, an activation credential issued by Admin, and client install ID; it hashes tokens, returns 12-hour access and 30-day refresh tokens, checks rental not disabled/deleted/inactive and requires Remote Play permission.
Do not weaken this to bare User ID because a public rental identifier is not a password. Desired UX can still be User-ID-only on repeat login after a first device activation/provisioning by Admin and secure storage of a revocable refresh token (Android Keystore).
Expired or zero-minute legacy rental accounts must be allowed to view the Remote client and wallet. A separate coin-billing session path must bypass only the legacy rental expiry/remaining-seconds gates. Disabled/deleted/inactive rental identities and revoked permissions remain blocked.

## Existing code compatibility — critical

Current 013–019 Remote Play migrations support host enrollment, client credentials, host permissions, PC catalog, sessions, stream-connected event, heartbeat, end-session, pairing, command queue and watchdog.

However, existing \`private.remote_play_settle_session()\` in 019 is explicitly a rental-time settlement:
- calculates used stream seconds;
- subtracts from \`public.rental_accounts.remaining_seconds\`;
- can update legacy rental status to expired;
- writes legacy \`public.usage_events\` and audit logs;
- queues the existing \`stop_stream\` command.

Existing \`api.remote_play_request_session()\` and \`api.remote_play_session_connected()\` also reject expired/time-zero rental accounts. Therefore the coin feature must be a separate billing mode that reuses the same remote host/session control-plane but has different billing gates and settlement:
- Add an explicit session \`billing_mode\`, default \`rental_seconds\`.
- Existing rental-time rows continue to use current 019 settlement unchanged.
- New coin-mode rows use a coin settlement branch; never deduct legacy \`remaining_seconds\`.
- Ensure the common stream-connected, client heartbeat, end session, watchdog and Admin-revoke paths dispatch to the same billing-mode-safe settlement. Watchdog must not call the legacy time-only path on a coin-mode session.
- Start session must reuse host online/Sunshine-ready, permissions, no-active-Billing-session, one account/one host locks, idempotency, and 10-minute cooldown guards; only the legacy expiry and remaining-seconds requirements change for coin mode.
- For each bill/heartbeat, the DB locks session and wallet, uses server time, charges precise NUMERIC coins proportionally to elapsed seconds, FIFO-debits valid lots, writes ledger idempotently, and stops when valid coins are exhausted. Catch-up settlement after disconnect/host timeout must never debit twice or make balance negative.
- Coin expiry and wallet reads must be transactionally reconciled; cached wallet totals are not authoritative unless verified against remaining non-expired lots.

## Proposed additive data model

The source-only DDL blueprint is in \`db-android-core/drafts/remote_coin_wallet_v1_NOT_APPLIED.sql\`. It defines six structures:
1. \`coin_wallets\`: one wallet per existing rental account.
2. \`coin_lots\`: balance lots with their own expiry, so old expiry never changes.
3. \`topup_orders\`: pending / approved / rejected top-up requests.
4. \`coin_ledger\`: immutable credits/debits/expiry and idempotency keys.
5. \`pc_coin_rates\`: tariff per existing PC ID.
6. \`coin_session_billing\`: billing snapshots linked to existing Remote Play session ID.

Tables must have RLS enabled; direct table access for client roles is revoked. User, Admin and Host APIs use existing token families and organization scoping, through the Node RPC allowlist only. No secrets, Admin tokens or database passwords go into the APK.

## API surface to implement next (not implemented by this draft)

Client family:
- \`remote_coin_dashboard\`: wallet, unexpired balance, soon-to-expire lots, rental identity status, PC catalog and active session.
- \`remote_coin_topup_create\`: create a pending order using integer rupiah amount and server-computed coin amount; return QRIS config + WhatsApp message fields.
- \`remote_coin_topup_whatsapp_opened\`: optional audit marker, not proof of payment.
- \`remote_coin_session_start\`: coin-mode start with all host/PC guards and server idempotency.
- \`remote_coin_session_heartbeat\`: server-authoritative incremental charge and insufficient-balance detection.
- \`remote_coin_session_end\`: idempotent final charge, release stream, record settlement.
- refresh/logout can reuse existing Remote Play token family; do not add duplicate authentication token tables.

Admin family:
- \`admin_remote_coin_topups\`: pending/recent order queue for Owner/authorized Admin, with User ID, amount, coins and order ID already populated.
- \`admin_remote_coin_approve_topup\`: transactional, idempotent credit to wallet/lot/ledger.
- \`admin_remote_coin_reject_topup\`: mark rejected with audit note.
- \`admin_remote_coin_wallet_lookup\`: read account wallet and coin lots.
- \`admin_remote_coin_rates_get/set\`: tariff administration per PC.
- \`admin_remote_coin_expiry_policy_get/set\`: display or adjust expiry tiers only if owner later authorizes editing; initially tiers remain constants.

Every new API must be added to \`db-android-core/server/server.mjs\` RPC allowlist with correct auth family and argument schema. Keep rate limiting, safe request sizes, no access to tables directly, no secrets in mobile app.

## Test and release gates

1. Audit current Redmi runtime: actual Node process PID, port, health response and applied schema version. Existing Nov 23 staging snapshot is stale and does not prove current phone state.
2. Make and verify PostgreSQL backup using the user's supported Android DB backup path before any schema apply.
3. Apply 013–019 plus coin draft to a disposable local PostgreSQL clone, not Redmi.
4. Smoke-test every existing Remote Play path: login, refresh, logout, dashboard, catalog, request start, host ack, connected, pairing prepare/poll/complete, heartbeat, end, watchdog, host offline and cooldown.
5. Add coin tests: top-up order creation, WhatsApp handoff, duplicate approval, rejection, race between two Admin approvals, decimals, expiry tier boundaries, old lot expiry preservation, FIFO, expiry sweep, wallet integrity, PC rate snapshot, one account/one host concurrency, mid-session top-up, insufficient balance, host offline, app killed, watchdog settlement and duplicate heartbeat.
6. Assert coin mode does not modify \`rental_accounts.remaining_seconds\`, \`expiry_at\` or status.
7. Run existing PC Billing, Admin, Reseller tests and reports; ensure legacy time mode still passes unchanged.
8. Build new Admin/client preview artifacts, install side-by-side and perform device tap testing.
9. Only after all gates pass may the local Android DB schema and Node server be updated. No current database changes are authorized by this draft.

## Current preview build coverage

The Remote Client v0.2.0 preview has demo-only controls for User ID entry, dashboard, wallet, preset/manual top-up calculations, QRIS zoom, WhatsApp preview handoff, copy amount, GPU rates, PC list, refresh, tabs and logout. It does not read/write Android DB, create top-up orders, credit coins or start StarDesk sessions. The Admin V12.1.57 SAFE TEST removes the DB1/DB2 menu/route concept and uses local Android DB port 8787 for its Admin core. WOL remains the separate sidecar identified above.
