# DB Android Cloudflare Stage Gateway

Branch: `feature/remote-play-cloudflare-mesh-v0.4`

## Architecture
- Redmi Termux API: `127.0.0.1:8788` only.
- Public HTTPS endpoint: `https://ani-games-db-android-stage-gateway.anigamesready.workers.dev`.
- Worker upstream registry: Cloudflare KV namespace `ani-games-db-android-stage-upstreams`.
- Redmi tunnel: Cloudflare Quick Tunnel; URL rotates and must be registered periodically.
- Existing API on port 8787, Supabase, production rental data, and Blynk/WoL relay are outside this branch.

## Android DNS compatibility
- Native Termux Cloudflared remains the default runner mode.
- When Android's Go resolver incorrectly targets `[::1]:53`, an isolated rootless PRoot fallback is available. It runs only the official Linux ARM64 Cloudflared binary in a Debian guest; PostgreSQL and Node API remain native Termux services.
- Install the isolated tunnel environment with `bash setup-proot-cloudflared.sh`, then start it with `bash start-online-proot.sh`.
- The setup verifies the official Cloudflared release SHA-256 before installing the binary and tests both the API host A record and Cloudflare Tunnel SRV record from inside Debian.
- The runner verifies the Cloudflare Tunnel SRV record with public DNS resolvers `1.1.1.1` and `8.8.8.8` before starting the tunnel.
- It checks both the Worker registry and the real public `/health` route. A registry entry alone is not treated as proof that the API is reachable.
- The PRoot container is dedicated to Cloudflared and its active sessions are stopped on runner cleanup; no database or production API process is managed by that container.

## Public route restrictions
- Only health, auth, allowlisted RPC and PC device API paths are forwarded.
- `/setup` and `/api/admin/bootstrap` are always denied at the Worker.
- Tunnel upstream must be HTTPS on `*.trycloudflare.com`.
- Registration endpoint requires Worker secret `REGISTER_TOKEN`.
- The Worker adds `x-ani-edge-client-ip` and `x-ani-edge-secret`; local API trusts that IP only when the socket is loopback and the secret matches.
- Client requests from non-opaque browser origins are rejected; Android WebView's `Origin: null` is supported.

## Current rollout boundary
This is a remote-access staging proof, not a production 24/7 SLA. The public Worker URL is stable, but the Redmi uses a Quick Tunnel whose origin URL is re-registered while the Termux runner stays alive. The Redmi's power, battery management, network and Termux process lifetime therefore remain availability dependencies. Quick Tunnel depends on Termux remaining alive, Android battery/background settings, internet connectivity and the Redmi device. A named tunnel/stable hostname and tested automatic startup/reconnect are required before production use.

## Deployment records
- Worker: `ani-games-db-android-stage-gateway`
- KV namespace ID: `55b2907fc76242c99774413e9986187f`
- Worker secrets installed: `REGISTER_TOKEN`, `EDGE_PROXY_SECRET` (values are not stored in this repository).
- Worker deployment ID: `39104bf464f547b892819fea39044b38`
- workers.dev enabled; previews disabled.
- No production DB, Supabase, port 8787 or Blynk/WoL resource was modified. PostgreSQL 5432 must remain loopback-only.



## Ani Remote Play isolated staging runbook

This branch contains the Remote Play backend through migrations 013–019. Keep this first validation isolated from the existing Ani Games Ready API and rental database.

### 1. Create the isolated DB Android stage on the Redmi

Run from the extracted `Ani-Games-Ready-DB-Android-Termux-STAGE` package in Termux. Copy the separately supplied private `ani-games-db-android-stage-online-secrets.env` into its `cloudflare-gateway-stage/` directory and rename it to `online-secrets.env`, then run:

```bash
bash start-remote-play-stage.sh
```

The one-command bootstrap checks prerequisites, creates the isolated stage DB and schema 000/002–019 if absent, applies Worker edge configuration, starts only API port 8788, and runs the tunnel registration loop in the foreground. Leave Termux running until it prints `API PUBLIK BERHASIL` with API and database online.

The setup script is deliberately conservative:
- It creates only database `ani_games_ready_stage`, role `ani_api_stage_login`, and API port `8788`.
- It refuses to continue if the stage folder, DB, role, or port already exists.
- The existing API on `127.0.0.1:8787` and its database are not stopped or modified.
- The stage API binds only to loopback; PostgreSQL must remain loopback-only.
- It applies the fresh schema set through `019_remote_play_session_connected.sql`, including watchdog and stream-connected billing.
- Do not run `server/migrate-local.sh` with a custom `ANI_DB_NAME` against the existing rental database.

### 2. Register the stage API behind the existing Worker

The separately supplied private `ani-games-db-android-stage-online-secrets.env` contains the current Worker credentials. Keep it private; place it at `cloudflare-gateway-stage/online-secrets.env` in the extracted package. The bootstrap sets its permissions to 600 and handles Worker configuration and tunnel startup. Do not put secret values into GitHub or chat.

If native Termux Cloudflared cannot resolve DNS, use the isolated PRoot fallback described above. The runner must report both the Worker registry active and public `/health` showing API and database online. A Worker URL by itself is not proof of connectivity.

### 3. First-owner and device enrollment

- Open `http://127.0.0.1:8788/setup` in the Redmi browser and create the stage Owner. Do not use the production Owner account or production database.
- Admin APK V12.1.53 defaults to the existing/main DB Android API on `http://127.0.0.1:8787`. Before logging in for staging, change the **Alamat API Lokal** field on the Admin login screen to `http://127.0.0.1:8788`, tap **Simpan Alamat Server**, and confirm the local health check reports API/database online. Leaving `8787` selected means the Admin app is talking to the existing main database, not this stage.
- Use the stage Admin control screen/API to enable the test rental and host, then issue one-time activation and Host Agent enrollment codes.
- The Moonlight staging APK is built with the stable stage gateway URL `https://ani-games-db-android-stage-gateway.anigamesready.workers.dev`; it can log in only while this stage API and its registered tunnel are healthy.
- Enroll the Android phone and Windows PC in the same Cloudflare One organization. Confirm both devices receive distinct `100.96.0.0/12` addresses and can reach each other before attempting Sunshine pairing.
- For the gateway registration step, keep the supplied `online-secrets.env` file private; the bootstrap sets mode `600` and loads the current Worker secrets.
- Install the Windows Host Agent only after the private Mesh path is connected. The installer restricts Sunshine's Web UI/API to the host PC and allows the GameStream media ports only over the private overlay.
- Test login, dashboard, one-user/one-host session locking, automatic pairing, game launch, stream heartbeat, stop, watchdog recovery, balance settlement, expiry, three-hour cap, and ten-minute cooldown.

### 4. Stop and rollback boundaries

- Stop the stage API with `bash ~/ani-games-db-android-stage/stop-stage.sh`.
- Stop the Quick Tunnel with CTRL+C in the runner terminal; it clears only the staging Worker KV upstream registration.
- Do not delete the stage DB or role until stage test records have been reviewed.
- Do not deploy schema migrations 013–019 to the existing production database until the owner approves a reviewed production migration and rollback plan.


## Compatibility hardening — 2026-11-16
- This branch is based directly on `fix/db-android-core-api-contracts-20261116`, not the older diverged gateway branch.
- The API edge patch detects and reuses an existing `node:net` import and `ANI_EDGE_PROXY_SECRET` declaration before adding missing declarations. This avoids duplicate JavaScript bindings in the Redmi's previously customized server.mjs.
- CI tests both a clean API source and a synthetic source containing those existing local additions, including idempotence and Node syntax checks.
- Existing deployed Worker state is not assumed to be online: the upstream KV entry and named Tunnel must be verified at deployment time.
