# Ani Games Ready — DB Android Local API

## Status
Cabang ini adalah backend DB Android terpisah. Bukan cutover produksi dan tidak mengubah Supabase DB1/DB2.

- Skema lokal: 24 tabel operasional DB1 tanpa data akun, hash password, token, atau secret produksi.
- Migrasi yang diizinkan: `000` dan `002–017`; snapshot katalog `001` bukan migrasi.
- API Node: protokol perangkat PC, pairing, heartbeat, sesi, delta sync, Admin, Billing Control dan Reseller.
- Hak akses runtime minimum: Node memakai `ani_api_login` atau `ani_api_stage_login`; tidak mendapat akses langsung ke tabel bisnis.
- Endpoint bawaan server dasar: loopback `127.0.0.1:8787`.
- Paket STAGING terpisah: database `ani_games_ready_stage`, role `ani_api_stage_login`, API `127.0.0.1:8788`.
- Blynk/WoL relay tetap service terpisah dan tidak diproxy, dihentikan, atau diubah oleh API database.
- Source adapter/build PC Billing V12.4.8, Admin V12.1.50 dan Reseller V1.0.6 telah disiapkan di branch DB Android masing-masing.
- CI PostgreSQL berhasil: migrasi lengkap, role/API allowlist, uji PC/Billing/Reseller/Admin, backup–restore, setup staging, Owner bootstrap, login dan context.
- Instalasi dan uji perangkat nyata di Redmi belum dilakukan pada saat catatan ini dibuat.
- Data Supabase DB1 belum diimpor. Database staging baru kosong dan bukan salinan produksi.

## Aturan migrasi
Hanya jalankan pada database BARU dan kosong. Urutan file:

1. `schema/000_prerequisites.sql`
2. `schema/002_core_business_schema.sql`
3. `schema/003_pc_device_api_functions.sql`
4. `schema/004_billing_reseller_api.sql`
5. `schema/005_runtime_privileges.sql`
6. `schema/006_admin_local_auth_and_rpc.sql`
7. `schema/007_billing_control_commands.sql`
8. `schema/008_local_business_triggers.sql`
9. `schema/009_admin_db1_business_routines.sql`
10. `schema/010_billing_reseller_refresh_and_devices.sql`
11. `schema/011_billing_control_android_rpcs.sql`\n12. `schema/012_billing_stop_pause_policy.sql`

JANGAN menerapkan `schema/001_db1_catalog_snapshot.sql`. Jangan memasukkan tabel kontrol DB1/DB2, route-quiesce/before-image, Telegram outbox, atau shutdown scheduler sidecar.

## Instalasi
Untuk server dasar setelah PostgreSQL dan Node.js siap:
```bash
bash migrate-local.sh
bash provision-runtime-role.sh
bash install-deps.sh
bash start.sh
```
Server dasar menggunakan port 8787. Jangan jalankan migrasi pada database yang sudah berisi tabel aplikasi.

Paket Redmi STAGING menggunakan file `setup-stage.sh` dan membuat database/role/API terpisah pada port 8788. Petunjuk lengkap ada di `README-STAGE-ID.txt`. Setup staging berhenti bila database, role, folder, atau port 8788 sudah digunakan. Layanan lama port 8787 tidak ditargetkan.

## API
### PC Billing
- `POST /device/enroll`
- `POST /device/heartbeat`
- `POST /device/disconnect`
- `POST /device/watchdog`
- `POST /device/ack`
- `POST /device/alert`
- `POST /device/sync`
- `POST /device/pull`
- `POST /device/sync-cursor`
- `POST /device/rentals`
- `POST /device/test-policy`\n- `POST /device/session-control-policy` — dibaca PC hanya ketika tombol PAUSE/STOP ditekan
- `POST /device/rental/lookup`
- `POST /device/session/start`
- `POST /device/session/end`
- `POST /device/rental/release`

Jalur yang sama tersedia di bawah `/functions/v1/ani-games-api/` untuk kompatibilitas bentuk URL Edge Function lama.

### Admin
Login lokal, refresh session, context, daftar perangkat, state, pairing recovery, alerts, policy free test, izin PAUSE/STOP Billing, perintah PC, global rental CRUD, dan laporan periodik tersedia melalui allowlist `/rest/v1/rpc/*`.

### Billing Control pada Admin APK
Login Billing Control, context, ganti password, daftar perangkat/sesi/rental per PC, tambah/edit/hapus rental, pause/resume/stop, restart Billing, trial, status command, serta putus pairing memakai token Billing Control terpisah. Reseller tidak diberi izin Windows/PC Control.

### Reseller
List/create/edit/delete global rental, status rental, refresh token dan session API memakai token yang dibatasi ke organisasi reseller. Reseller tidak memiliki akses tabel langsung dan tidak dapat mengirim Windows/PC command.

### Health
- `GET /health`

API tidak menyediakan akses tabel PostgREST langsung. Hanya fungsi yang ada di allowlist yang dapat dipanggil oleh role runtime.

## Batas keamanan
- Jangan pernah memasukkan password PostgreSQL, service-role key, bootstrap token atau API secret ke APK/EXE.
- Simpan kredensial runtime hanya pada `.env` lokal dengan izin file terbatas.
- Admin, Billing Control, Reseller dan PC Device memakai keluarga token terpisah; token disimpan sebagai hash di database.
- Refresh token Admin/Billing/Reseller di Android menggunakan Android Keystore-backed storage.
- Binding default hanya loopback. Jangan membuka `0.0.0.0` atau menggunakan HTTP melalui LAN.
- Sebelum PC Windows/HP lain dihubungkan, siapkan HTTPS tunnel/reverse proxy dan CORS/origin yang tepat. PC Billing menolak URL non-HTTPS selain loopback.
- Log tidak boleh merekam password, token, bootstrap secret atau body request.
- Blynk/WoL relay tidak dikelola oleh API database ini.

## Verifikasi dan batas hasil
CI berjalan pada PostgreSQL disposable dengan data sintetis. CI sukses membuktikan skema, API dan installer staging lulus pengujian otomatis; tidak membuktikan Redmi telah diperbarui, akses HTTPS antar-perangkat tersedia, APK sudah diuji pada perangkat nyata, atau PC sudah dipairing ke Redmi.

Tidak ada data Supabase yang dipindahkan dan belum ada cutover produksi.

## Rollback
- Pekerjaan ada di `backend/db-android-core-v1`; master/Supabase tetap tidak berubah.
- Sebelum instalasi staging di Redmi, buat dan verifikasi backup PostgreSQL.
- Hentikan hanya proses Node staging jika perlu rollback. Jangan hentikan PostgreSQL atau relay Blynk/WoL.
- Jangan drop database lokal untuk rollback. Ekspor data staging sebelum tindakan yang menghapus.
\n\n## Izin PAUSE / STOP Billing\n\nPengaturan `billing_stop_pause_enabled` disimpan pada `private.admin_feature_settings` dan berlaku global untuk semua PC pada DB Android yang sama. Default OFF. Owner dapat membukanya dari Admin; PC membaca status ke server ketika penyewa menekan PAUSE/STOP atau tombol X. Koneksi gagal atau status tidak valid berarti aksi penyewa ditolak (fail-closed). Timer habis otomatis dan perintah kontrol jarak jauh dari Admin tidak memakai gate ini. Untuk database DB Android yang sudah ada, hentikan sementara server API, jalankan `schema/012_billing_stop_pause_policy.sql` sekali dengan akun PostgreSQL pemilik database, lalu jalankan kembali server terbaru. Migrasi ini hanya menambah pengaturan/fungsi/izin API; tidak mengubah sesi, rental, token, pairing, atau service WoL.\n

## Remote Play (Moonlight / Sunshine)
Remote Play menambah tabel dan RPC pada DB Android yang sama agar rental account dan device yang sudah ada dapat dipakai bersama. Migrasi 013–017 mencakup sesi Remote Play, host enrollment, tantangan pairing Sunshine, izin Admin per PC/per rental, alamat Cloudflare Mesh, dan status cooldown 10 menit. Fungsi Remote Play dipisahkan dari fungsi PC Billing, Admin dan Reseller yang sudah ada. Untuk database staging kosong, server/migrate-local.sh menerapkan urutan lengkap 000 dan 002–017. Jangan menjalankan installer database kosong pada DB aktif yang sudah berisi tabel; untuk DB aktif gunakan migrasi terpisah setelah backup dan review.
