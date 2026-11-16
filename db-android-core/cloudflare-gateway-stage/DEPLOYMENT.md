# DB Android Cloudflare Stage Gateway

Branch: `infra/db-android-cloudflare-global-stage-20261116`

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


## Compatibility hardening — 2026-11-16
- This branch is based directly on `fix/db-android-core-api-contracts-20261116`, not the older diverged gateway branch.
- The API edge patch detects and reuses an existing `node:net` import and `ANI_EDGE_PROXY_SECRET` declaration before adding missing declarations. This avoids duplicate JavaScript bindings in the Redmi's previously customized server.mjs.
- CI tests both a clean API source and a synthetic source containing those existing local additions, including idempotence and Node syntax checks.
- Existing deployed Worker state is not assumed to be online: the upstream KV entry and named Tunnel must be verified at deployment time.
