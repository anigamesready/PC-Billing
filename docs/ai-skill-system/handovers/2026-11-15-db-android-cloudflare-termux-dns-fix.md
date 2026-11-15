# Handover — DB Android Cloudflare Termux DNS runner fix

Date: 2026-11-15
Project: Ani Games Ready — Redmi DB Android public staging gateway

## User-observed symptom
- Cloudflare Worker public `/health` returned HTTP 503 with `STAGE_TUNNEL_OFFLINE`.
- Redmi tunnel log showed DNS lookup of `_v2-origintunneld._tcp.argotunnel.com` against `[::1]:53` failing with connection refused.
- Termux `$PREFIX/etc/resolv.conf` existed and contained Google DNS entries. Python `socket.getaddrinfo` also failed.
- The staging API configure script had previously reported API online on loopback `127.0.0.1:8788`; port `8787` remained separate.

## Source reviewed
- Runtime repository: `anigamesready/PC-Billing`.
- Work branch: `infra/db-android-cloudflare-gateway-stage`.
- Exact staging baseline / merge-base: `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9`.
- Before edits, the branch head was `c4bb2ada8cf45c266840b68d6aee5540af85e24c`, 19 commits ahead / 0 behind the baseline.
- Latest runner file before fix: `db-android-core/cloudflare-gateway-stage/start-online.sh`.
- Relevant existing safeguards reviewed: loopback API origin, edge shared secret, Worker path allowlist, public bootstrap/setup denial, and the package workflow's secret exclusion.
- No master branch or production source selected.

## Root-cause assessment
The observed error is consistent with a Go binary trying the standard Linux resolver path on Android, where `/etc/resolv.conf` is absent; it then falls back to the inactive local resolver at `[::1]:53`. Termux stores its resolver file under `$PREFIX/etc/resolv.conf`. Termux's `termux-chroot` binds the Termux `etc` directory to the standard `/etc` path. This is the evidence-based fix path; actual Redmi DNS/tunnel success remains unconfirmed until the new runner is executed on-device.

## Changes made
Runtime branch:
- `start-online.sh` now detects and installs only missing `cloudflared`, `proot`, and `bind-tools` Termux packages.
- Requires the Termux resolver file and `termux-chroot`.
- Runs direct Cloudflare SRV DNS checks through `termux-chroot` using `1.1.1.1`, then `8.8.8.8`.
- Starts `cloudflared` through `termux-chroot` so the resolver path is available.
- After registration, checks both Worker internal registry health and the real public API `/health` path. An internal KV entry alone is no longer treated as end-to-end proof.
- Updated `DEPLOYMENT.md`.
- Updated the workflow with shell, DNS-runner, public-health assertions and package generation.

Runtime commit:
- `143253184bca03b96ea5233ac2a76e61723b5cf5` — runner.
- `1bdfa89ee0290b1d118bc12288093f45d5594f61` — deployment notes.
- `693289ad16a380119bba981ecdde4e2d4453ad0e` — CI workflow; current runtime branch head at handover.

## Verification
- GitHub Actions run `43689341047`: completed successfully.
- Steps passed: Worker unit/security tests; isolated server patch and Node syntax/idempotency assertions; Bash syntax; Termux DNS runner static assertions; secret-free package build and upload.
- Artifact ID: `14151522874`.
- Artifact filename: `ANI-GAMES-READY-DB-ANDROID-CLOUDFLARE-STAGE-DNS-FIX.zip`.
- Size: 17,557 bytes.
- SHA-256: `84bf654ae73c4b2b6656df058d392c8c56260b3ec41cddea1c62713907018442`.
- Downloaded artifact ZIP integrity test passed; its SHA-256 matched GitHub's artifact digest.
- The package excludes `online-secrets.env`, runtime `.env`, passwords and database files.

## Unchanged / preserved
- API source, staging DB schema/data and Worker implementation/deployment unchanged.
- Production/Supabase DB and data unchanged.
- Existing API port 8787 untouched.
- New staging API remains loopback-only on port 8788.
- Blynk/WoL relay untouched.
- Existing local `online-secrets.env` must be preserved during package replacement; the new package contains only the example file.

## Risks / not yet tested
- The new runner has not yet been installed or executed on the Redmi.
- DNS SRV, tunnel persistence, public `/health`, and Android background execution remain pending on-device.
- Quick Tunnel remains temporary and unsuitable as a production 24/7 SLA. Stable named tunnel/domain and reconnect/boot/background tests are still required.

## Rollback
- Keep the old helper folder as a timestamped backup.
- Restore the old helper folder if the new runner cannot start.
- Do not rerun `configure-online.sh` for this DNS-only runner update; existing stage server `.env` and the separate online secrets file should remain untouched.
- Do not modify port 8787, production databases, Worker secrets or relay settings for rollback.

## Next action
Stop the old reconnect loop with CTRL+C in its original Termux session, replace only the helper package while copying forward the existing `online-secrets.env`, then run the new `start-online.sh`. Accept the result only after DNS preflight succeeds and the public API `/health` response is returned.
