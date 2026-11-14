# DB Android Cloudflare Stage Gateway

Branch: `infra/db-android-cloudflare-gateway-stage`

## Architecture
- Redmi Termux API: `127.0.0.1:8788` only.
- Public HTTPS endpoint: `https://ani-games-db-android-stage-gateway.anigamesready.workers.dev`.
- Worker upstream registry: Cloudflare KV namespace `ani-games-db-android-stage-upstreams`.
- Redmi tunnel: Cloudflare Quick Tunnel; URL rotates and must be registered periodically.
- Existing API on port 8787, Supabase, production rental data, and Blynk/WoL relay are outside this branch.

## Public route restrictions
- Only health, auth, allowlisted RPC and PC device API paths are forwarded.
- `/setup` and `/api/admin/bootstrap` are always denied at the Worker.
- Tunnel upstream must be HTTPS on `*.trycloudflare.com`.
- Registration endpoint requires Worker secret `REGISTER_TOKEN`.
- The Worker adds `x-ani-edge-client-ip` and `x-ani-edge-secret`; local API trusts that IP only when the socket is loopback and the secret matches.
- Client requests from non-opaque browser origins are rejected; Android WebView's `Origin: null` is supported.

## Current rollout boundary
This is a remote-access staging proof, not a production 24/7 SLA. Quick Tunnel depends on Termux remaining alive, Android battery/background settings, internet connectivity and the Redmi device. A named tunnel/stable hostname and tested automatic startup/reconnect are required before production use.

## Deployment records
- Worker: `ani-games-db-android-stage-gateway`
- KV namespace ID: `55b2907fc76242c99774413e9986187f`
- Worker secrets installed: `REGISTER_TOKEN`, `EDGE_PROXY_SECRET` (values are not stored in this repository).
- Worker deployment ID: `39104bf464f547b892819fea39044b38`
- workers.dev enabled; previews disabled.
- No production DB, Supabase, port 8787 or Blynk/WoL resource was modified.
