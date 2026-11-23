# Remote Play — Embedded Media Relay API Contract

Status: design contract only. No live DB migration or runtime deployment is performed by this document.

## Non-negotiable compatibility

- Reuse the existing DB Android Node API, existing public.rental_accounts and public.devices.
- Add Remote Play data only in the remote_play schema.
- Keep DB quick settings, API gateway URL, route selector, current user login, and current API ports unchanged.
- Do not introduce Supabase, a second rental database, or direct PostgreSQL access from Android / Host Agent.
- The existing HTTP Worker / DB Android API is control-plane only. It must not carry GameStream media.

## Required additional records

### remote_play.media_relays
- id, region, public_endpoint, public_udp_port, status, health_checked_at, capacity, created_at, updated_at.
- Relay control credentials and provider API secrets must remain server-side, never in APK or Host Agent config in plaintext.
- Relay admin plane must not share its public media listener.

### remote_play.host_tunnels
- device_id (FK to public.devices), relay_id, host_overlay_address, public_key_fingerprint, status, last_seen_at, agent_version, revoked_at, created_at, updated_at.
- Host Agent private key remains DPAPI-protected on Windows. DB stores only public identity / key fingerprint and non-secret metadata.
- One Host may have a preferred relay and a fallback relay.

### remote_play.client_installations
- id, org_id, rental_account_id, install_id, client_public_key, moonlight_certificate_fingerprint, client_overlay_address, status, activated_at, last_seen_at, revoked_at.
- Client private key never leaves the Android Keystore-backed installation.
- Re-activation must revoke or explicitly replace the previous installation according to an Admin policy.

### remote_play.client_host_pairings
- client_installation_id, device_id, sunshine_certificate_fingerprint, paired_at, last_used_at, revoked_at.
- Unique active record per client-installation / Host.
- Store trust status and certificate fingerprint, not the client private key or raw activation code.

### remote_play.session_tunnel_grants
- session_id, relay_id, client_installation_id, device_id, client_overlay_address, host_overlay_address, grant_expires_at, status, revoked_at.
- Each grant is bound to one live remote_play session, one rental, one Host and one client installation.
- Firewall ACL must only allow client-to-selected-Host GameStream TCP/UDP ports for the grant lifetime.

## RPC/API operations (names are proposed and must be reconciled with the current Node API allowlist)

Admin:
- admin_remote_play_list_client_installations
- admin_remote_play_revoke_client_installation
- admin_remote_play_revoke_client_host_pairing
- admin_remote_play_set_relay_policy
- admin_remote_play_get_relay_status

Host Agent:
- remote_play_host_tunnel_enroll
- remote_play_host_tunnel_heartbeat
- remote_play_host_tunnel_rekey
- remote_play_host_tunnel_disconnect

Customer:
- remote_play_register_installation (accept public key + Moonlight cert fingerprint; never client private key)
- remote_play_refresh_installation
- remote_play_prepare_pairing (only when no active client-host trust exists)
- remote_play_complete_pairing
- remote_play_get_session_tunnel_grant
- remote_play_revoke_session_tunnel_grant

## Authentication / ordering

1. Customer logs in with rental identifier + Admin-issued one-time activation credential. Validate permission, rental state, expiry and activation lifecycle.
2. App creates the tunnel keypair locally and submits the public key and stable installation identity. Server binds it to the authenticated rental.
3. Host Agent is separately enrolled by a one-time Admin Host code. It connects outbound to an approved relay and reports its tunnel address/readiness.
4. Customer requests a session. DB takes the same organization + normalized rental-code transaction lock used by PC Billing; checks one-session-per-rental, one-session-per-Host, permission, balance, expiry, cooldown and Host freshness.
5. Only after a session row is committed does the control plane provision a short-lived relay firewall grant. No host or customer packet is forwarded before the grant is active.
6. If a client-host pairing does not exist, issue a time-limited one-time challenge. Host Agent confirms the exact Sunshine pairing request and public certificate fingerprint. Persist successful pairing. For later sessions, skip pairing but still check current authorization and session grants.
7. Once Moonlight reports video stream connected, call the existing session-connected RPC. That remains the only event that starts billable usage.
8. On stop, deadline, loss of heartbeat, Admin revoke, or tunnel loss, settle the DB lease exactly once and revoke relay ACL + client tunnel access idempotently.

## Relay policy

- Default deny; no peer-to-peer lateral traffic.
- Do not advertise a default route. Customer tunnel only receives the selected Host /32 route.
- Do not permit host LAN routes or internet egress from the client peer.
- Host Agent and customer peer keys are unique; no shared private keys.
- Peer address allocations are checked for overlap and bound to organization / session.
- Host Web UI ports, relay management port, DB APIs, and unrelated PC services are not exposed as media destinations.
- Rate-limit session control calls and pair attempts. Log identifiers, not bearer tokens, PINs or private keys.

## Migration and deployment requirements

- Additive migrations only; no edits to the Billing schema or existing DB settings.
- Test migrations on disposable PostgreSQL and isolated staging before applying to any shared live DB.
- Node API allowlist, request validation, runtime SQL role grants, rate limits and CORS must be updated together.
- The relay service must have a health check and a fail-closed status; no stale relay record can be shown as ready.
- Rollback must revoke or expire all outstanding grants safely without touching the existing Billing API or WoL sidecar.
