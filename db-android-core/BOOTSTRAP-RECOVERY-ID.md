# Pemulihan `ADMIN_BOOTSTRAP_DENIED` — DB Android staging

Helper ini hanya untuk instalasi staging lokal Redmi di `~/ani-games-db-android-stage`.

## Cara pakai di Termux

Pastikan API staging sudah online, lalu unduh dan jalankan helper:

```bash
bash ~/ani-games-db-android-stage/start-stage.sh
curl -fL 'https://raw.githubusercontent.com/anigamesready/PC-Billing/fix/db-android-stage-bootstrap-tcp-fix-20261117/db-android-core/repair-stage-bootstrap.sh' -o ~/repair-stage-bootstrap.sh
bash ~/repair-stage-bootstrap.sh
```

Bila helper menyatakan berhasil, buka Chrome di Redmi sendiri:

`http://127.0.0.1:8788/setup`

Buat Owner pertama dengan username/email dan password milik sendiri (minimal 12 karakter), lalu login melalui Admin APK menggunakan akun tersebut.

## Catatan koneksi PostgreSQL TCP

Helper recovery awal memanggil psql tanpa host, sehingga libpq mencari Unix socket
`$PREFIX/tmp/.s.PGSQL.5432`. Pada perangkat ini pemeriksaan menunjukkan PostgreSQL
menerima TCP di `127.0.0.1:5432`, tetapi socket yang dicari helper tidak tersedia.

Versi TCP-fix mengunci seluruh query helper ke `127.0.0.1:5432` dan lebih dulu
memastikan akun Termux lokal adalah PostgreSQL superuser. Akun `ani_api_stage_login`
tetap least-privilege dan tidak diberi akses langsung ke schema `private`. Jika koneksi
TCP admin atau pemeriksaan superuser gagal, helper berhenti tanpa perubahan database.

## Apa yang diperiksa/diperbaiki

- Memastikan PID, working directory, bind localhost, port 8788, dan health API sesuai staging.
- Memastikan koneksi TCP loopback 127.0.0.1:5432 dan hak superuser PostgreSQL sebelum membaca atau menulis kontrol bootstrap.
- Mengamankan permission `.env` menjadi mode 600, lalu membaca token secara lokal tanpa mencetak token atau password.
- Menolak tindakan jika Owner aktif sudah ada atau bootstrap sudah pernah dikonsumsi.
- Menambahkan atau menyelaraskan hanya `private.admin_bootstrap_control.token_hash` bila bootstrap masih belum digunakan.
- Menguji POST dengan input sengaja tidak valid. Respons `ADMIN_BOOTSTRAP_INPUT_INVALID` berarti pemeriksaan token dan jalur POST berhasil; probe ini tidak membuat akun.
- Bila environment proses API berbeda dari `.env`, hanya API staging 8788 yang direstart menggunakan `stop-stage.sh`/`start-stage.sh`.

Tidak menjalankan installer awal, tidak menjalankan migrasi, tidak menghapus data, tidak membuat Owner, tidak mengganti secret, tidak menghentikan PostgreSQL/port 8787, dan tidak menyentuh Supabase DB1/DB2 atau relay Blynk/WoL.

Jika helper berhenti karena bootstrap sudah dikonsumsi atau Owner sudah ada, jangan reset database. Periksa akun Admin yang sudah dibuat atau lakukan audit manual terlebih dahulu.
