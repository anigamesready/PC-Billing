# Ani Games Ready — Android DB tunggal

## Status arsitektur saat ini

Sistem bisnis Ani Games Ready memakai **satu database Android DB lokal** sebagai sumber data utama. Tidak ada konsep dual DB, pergantian target database, DB1/DB2 routing, atau sinkronisasi rental ke database kedua.

- PostgreSQL lokal Android DB pada Redmi.
- Node API lokal default 127.0.0.1:8787.
- Admin, PC Billing, Reseller dan Remote Play memakai database, identitas akun rental dan device_id yang sama.
- Remote Play menambahkan schema remote_play pada database yang sama.
- Dompet koin dan top-up dirancang sebagai modul tambahan pada schema remote_play; rancangan berada di drafts dan belum diterapkan.
- Data aktif tidak boleh dihapus atau ditimpa. migrate-local.sh hanya untuk database baru dan kosong.
- Source coin-wallet branch ini adalah persiapan desain, bukan deployment ke Redmi.

Blynk/WoL saat ini masih merupakan sidecar relay tersendiri. Node Android DB mengembalikan 501 RELAY_IS_SEPARATE_SERVICE untuk /wol/* dan /iot/*. Ini bukan database rental kedua; pemindahan relay ke API lokal perlu pekerjaan backend terpisah agar fungsi WoL tidak terputus.

## Skema dan urutan migrasi database baru

server/migrate-local.sh memeriksa database harus kosong sebelum menjalankan migrasi. Urutan saat ini:

1. schema/000_prerequisites.sql
2. schema/002_core_business_schema.sql
3. schema/003_pc_device_api_functions.sql
4. schema/004_billing_reseller_api.sql
5. schema/005_runtime_privileges.sql
6. schema/006_admin_local_auth_and_rpc.sql
7. schema/007_billing_control_commands.sql
8. schema/008_local_business_triggers.sql
9. schema/009_admin_db1_business_routines.sql — nama file historis; fungsi berada pada Android DB yang sama.
10. schema/010_billing_reseller_refresh_and_devices.sql
11. schema/011_billing_control_android_rpcs.sql
12. schema/012_billing_stop_pause_policy.sql
13. schema/013_remote_play.sql
14. schema/014_remote_play_pairing.sql
15. schema/015_remote_play_admin_controls.sql
16. schema/016_remote_play_cloudflare_mesh.sql
17. schema/017_remote_play_dashboard_cooldown.sql
18. schema/018_remote_play_server_watchdog.sql
19. schema/019_remote_play_session_connected.sql

schema/001_db1_catalog_snapshot.sql adalah snapshot katalog lama, bukan migrasi; jangan diterapkan.

**Penting:** jangan jalankan migrate-local.sh pada database Redmi yang sudah berisi data. Untuk database aktif, setiap migrasi tambahan harus diuji pada PostgreSQL disposable, disertai backup dan verifikasi restore, diperiksa dependensi tabel/trigger/constraint/privilege/API allowlist, dan baru diterapkan setelah review.

## Instalasi database baru / kosong

Setelah PostgreSQL dan Node.js siap pada lingkungan Android, jalankan berurutan:

    bash migrate-local.sh
    bash provision-runtime-role.sh
    bash install-deps.sh
    bash start.sh

Server dasar mendengarkan di loopback 127.0.0.1:8787. Jangan membuka binding ke 0.0.0.0 atau mengirim HTTP biasa melalui LAN. Akses antardevice memerlukan HTTPS gateway/reverse proxy dan CORS/origin terbatas.

## API

Node hanya membuka fungsi yang masuk allowlist. Tidak ada akses langsung ke tabel bisnis melalui endpoint PostgREST generik.

- GET /health
- POST /rest/v1/rpc/<nama_fungsi>
- Jalur kompatibilitas: /functions/v1/ani-games-api/<nama_fungsi>
- Endpoint perangkat PC: /device/*

Kelompok API yang tersedia:
- Admin lokal: login, refresh, context, rental global CRUD, perangkat, laporan, policy dan perintah PC.
- Billing Control: token terpisah, daftar sesi/rental, CRUD rental, pause/resume/stop, trial, status command dan putus pairing.
- Reseller: daftar/tambah/edit/hapus rental dalam organisasi yang diizinkan.
- Remote Play client: login/refresh/logout, dashboard, request session, stream-connected, heartbeat, end-session dan pairing.
- Remote Play host: enroll, heartbeat, command queue, acknowledgement dan pairing.
- Remote Play Admin: izin host/rental, credential client, enrollment host, sesi dan dashboard.

## Keamanan

- Jangan memasukkan password PostgreSQL, runtime secret, bootstrap token atau API secret ke APK/EXE.
- Kredensial server hanya berada di .env lokal dengan izin file terbatas.
- Admin, Billing Control, Reseller, PC client, Remote Play client dan Host memakai keluarga token berbeda.
- Token disimpan sebagai hash; token refresh Android disimpan menggunakan Android Keystore.
- Tabel remote_play tidak dibuka untuk akses langsung client; RPC allowlist menjadi satu-satunya jalur.
- Fungsi Admin harus memvalidasi session token, role, organisasi dan kepemilikan data.
- Log tidak boleh menyimpan password, token, bootstrap secret atau body request.

## Catatan billing Remote Play

Migrations 013–019 menyediakan control-plane Remote Play. Namun settlement bawaan 019 masih memotong public.rental_accounts.remaining_seconds. Itu hanya untuk mode rental-time.

Sistem koin belum boleh diaktifkan sebelum:
- sesi memiliki billing mode eksplisit;
- settlement koin tidak mengubah remaining_seconds, expiry_at atau status rental lama;
- heartbeat, stream-connected, end-session, watchdog dan Admin revoke dispatch ke settlement sesuai billing mode;
- transaksi FIFO lot, expired, wallet balance dan ledger terbukti idempotent;
- tes mode rental-time lama tetap lulus.

Rancangan tabel dan API coin wallet ada di:
- docs/REMOTE-COIN-ANDROID-DB-DESIGN.md
- drafts/remote_coin_wallet_v1_NOT_APPLIED.sql

File SQL di drafts adalah blueprint, bukan migrasi. Jangan memindahkannya ke schema sebelum implementasi dan pengujian lengkap.

## Batas hasil audit

CI pada PostgreSQL disposable membuktikan skema dan fungsi yang diuji pada source lulus; CI tidak membuktikan service Redmi sedang online, port/API aktif, HTTPS gateway siap, host StarDesk telah dipasangkan, atau APK telah diuji pada perangkat fisik. Pemeriksaan runtime Android harus dilakukan terpisah sebelum deployment.

## Rollback

- Pertahankan backup PostgreSQL yang bisa direstore dan backup source sebelum migrasi aktif.
- Hentikan hanya proses Node API yang memang akan diperbarui; jangan hentikan PostgreSQL atau relay Blynk/WoL untuk update UI.
- Jangan drop database aktif untuk rollback.
- APK SAFE TEST memakai application ID berbeda agar dapat dipasang berdampingan dengan versi stabil.
