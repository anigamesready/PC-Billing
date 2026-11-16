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
`ANI-GAMES-READY-DB-ANDROID-WS-RELAY-STAGE-INSTALLER.zip`.
Installer hanya memasang agent dan script kontrol, membuat backup .env lalu menambahkan `ANI_DB_RELAY_URL`. API dan PostgreSQL tidak direstart.

Status implementasi: Worker telah terpasang; agent Redmi dan secret Worker belum dikonfigurasi, sehingga relay belum diklaim online.
