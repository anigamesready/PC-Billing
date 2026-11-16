# Ani Games Ready — DB Android WebSocket Relay Stage

Branch terisolasi: `infra/db-android-ws-relay-stage-20261116`

Basis: `infra/db-android-cloudflare-global-stage-20261116` pada commit `388fe1808a32ac13ffeeeae6fff49cbef8e7f177`.

## Arsitektur
Admin APK → Worker publik → Durable Object WebSocket Hub → Node.js agent pada Redmi/Termux → API staging `127.0.0.1:8788` → PostgreSQL `127.0.0.1:5432`.

Worker: `ani-games-db-android-stage-ws-relay`
URL: `https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev`
Durable Object: `RelayHub` (SQLite), namespace terpisah.

## Batas keselamatan
- Worker hanya meneruskan GET/POST/OPTIONS pada rute API yang di-allowlist.
- `/setup`, `/api/admin/bootstrap`, rute tidak dikenal, dan origin browser non-`null` ditolak.
- Agent memverifikasi ulang rute sebelum menghubungi `127.0.0.1:8788`.
- IP client hanya diteruskan melalui header trusted-edge yang diverifikasi oleh patch API staging.
- PostgreSQL dan API tetap loopback; tidak ada pembukaan port publik, perubahan SQL, atau migrasi database.
- Port utama 8787, Supabase, serta Blynk/WoL relay tidak disentuh.
- Quick Tunnel/Cloudflared Worker lama dipertahankan untuk rollback; tidak dihapus atau diubah.

## Deployment staging (16 Nov 2026)
- Worker baru berhasil dibuat dan di-deploy.
- workers.dev subdomain aktif; previews nonaktif.
- Binding `RELAY_HUB` menunjuk namespace SQLite khusus `RelayHub`.
- Secret binding `RELAY_SHARED_SECRET` harus ditambahkan manual di Dashboard dan nilainya harus sama dengan `ANI_EDGE_PROXY_SECRET` pada .env staging Redmi. Jangan commit atau kirim nilainya.
- Endpoint penerimaan: `/_relay/health` harus menjawab HTTP 200 dengan `relay=online`, `agent_connected=true`, `api=online`, `database=online`.

## Installer Redmi
Paket instalasi Android disediakan terpisah dalam artifact percakapan bernama:
`ANI-GAMES-READY-DB-ANDROID-WS-RELAY-TERMUX-FINAL.zip`.
Installer memasang agent dan script kontrol, membuat backup timestamp `.env`, memverifikasi `ANI_EDGE_PROXY_SECRET` yang sudah ada, membuat salinan sementara rahasia itu dengan izin file privat untuk dimasukkan manual ke Worker sebagai `RELAY_SHARED_SECRET`, lalu menambahkan atau memperbarui hanya `ANI_DB_RELAY_URL`. Nilai secret di `.env` tidak diganti; API dan PostgreSQL tidak direstart.

Status implementasi: Worker telah terpasang; agent Redmi dan secret Worker belum dikonfigurasi, sehingga relay belum diklaim online.


## Final Termux installer package
- File: `ANI-GAMES-READY-DB-ANDROID-WS-RELAY-TERMUX-FINAL.zip`
- Size: 11,437 bytes
- SHA-256: `e7b448b678819b3d811c3503dfdb04d90e1b7dbb54be98f9caad836acd633a95`
- Contains `START-HERE.txt`, the guarded installer, Node agent, start/stop/status scripts, README and per-file checksums.
- Verified: archive integrity, per-file SHA-256, Node syntax, Bash syntax, and a disposable installer simulation. The simulation confirmed that only `ANI_DB_RELAY_URL` is added, the existing edge secret is preserved, a timestamped `.env` backup is created, and the install directory / secret file receive private permissions.
- Redmi installation and public health are not yet verified. Worker secret `RELAY_SHARED_SECRET` still requires manual configuration in Cloudflare Dashboard before the agent can connect.
