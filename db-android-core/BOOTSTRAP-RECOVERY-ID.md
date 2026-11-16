# Pemulihan `ADMIN_BOOTSTRAP_DENIED` — DB Android staging

Helper ini hanya untuk instalasi staging lokal Redmi di `~/ani-games-db-android-stage`.

## Cara pakai di Termux

Pastikan API staging sudah online, lalu unduh dan jalankan helper:

```bash
bash ~/ani-games-db-android-stage/start-stage.sh
curl -fL 'https://raw.githubusercontent.com/anigamesready/PC-Billing/fix/db-android-stage-bootstrap-recovery-20261116/db-android-core/repair-stage-bootstrap.sh' -o ~/repair-stage-bootstrap.sh
bash ~/repair-stage-bootstrap.sh
```

Bila helper menyatakan berhasil, buka Chrome di Redmi sendiri:

`http://127.0.0.1:8788/setup`

Buat Owner pertama dengan username/email dan password milik sendiri (minimal 12 karakter), lalu login melalui Admin APK menggunakan akun tersebut.

## Apa yang diperiksa/diperbaiki

- Memastikan PID, working directory, bind localhost, port 8788, dan health API sesuai staging.
- Mengamankan permission `.env` menjadi mode 600, lalu membaca token secara lokal tanpa mencetak token atau password.
- Menolak tindakan jika Owner aktif sudah ada atau bootstrap sudah pernah dikonsumsi.
- Menambahkan atau menyelaraskan hanya `private.admin_bootstrap_control.token_hash` bila bootstrap masih belum digunakan.
- Menguji POST dengan input sengaja tidak valid. Respons `ADMIN_BOOTSTRAP_INPUT_INVALID` berarti pemeriksaan token dan jalur POST berhasil; probe ini tidak membuat akun.
- Bila environment proses API berbeda dari `.env`, hanya API staging 8788 yang direstart menggunakan `stop-stage.sh`/`start-stage.sh`.

Tidak menjalankan installer awal, tidak menjalankan migrasi, tidak menghapus data, tidak membuat Owner, tidak mengganti secret, tidak menghentikan PostgreSQL/port 8787, dan tidak menyentuh Supabase DB1/DB2 atau relay Blynk/WoL.

Jika helper berhenti karena bootstrap sudah dikonsumsi atau Owner sudah ada, jangan reset database. Periksa akun Admin yang sudah dibuat atau lakukan audit manual terlebih dahulu.
