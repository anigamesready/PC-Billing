ANI GAMES READY — PERBAIKAN PAUSE / STOP BILLING (STAGE API)
Build: 2026-11-24
Target: DB Android staging Redmi/Termux, database ani_games_ready_stage, API 127.0.0.1:8788

KENAPA ERROR
Admin V12.1.58 sudah mengirim nama RPC yang benar. Source server.mjs lama pada paket WebSocket relay belum mendaftarkan:
- admin_get_billing_stop_pause_policy
- admin_set_billing_stop_pause_policy
Server mengembalikan RPC_NOT_ALLOWED sebelum query database dijalankan.

Selain itu paket stage lama baru membawa skema 000–011. Fitur Stop/Pause memerlukan migrasi 012 dan endpoint device/session-control-policy untuk PC Billing.

CARA PAKAI
1. Download ZIP dan ekstrak foldernya ke Download di Redmi.
2. Buka Termux.
3. Jalankan:
   cd /sdcard/Download/ANI-GAMES-READY-STOP-PAUSE-RPC-FIX
   bash APPLY-STOP-PAUSE-FIX.sh
4. Tunggu sampai tertulis:
   [ANI STOP/PAUSE FIX] SELESAI.
   PASS admin_get_billing_stop_pause_policy
   PASS admin_set_billing_stop_pause_policy

Apabila Termux belum dapat membuka folder Download, jalankan termux-setup-storage satu kali, izinkan akses, lalu ulangi cd di atas.

APA YANG DILAKUKAN SCRIPT
- Memastikan target tepat DB ani_games_ready_stage dan port 8788.
- Memastikan API/Database staging sedang online dan PID adalah server.mjs dari folder stage yang benar.
- Memeriksa prasyarat skema, role, dan fungsi actor Admin sebelum menyentuh database.
- Membuat backup PostgreSQL format custom dan backup server.mjs sebelum perubahan.
- Menerapkan migrasi SQL 012 secara transaksional hanya jika fungsi belum ada.
- Menambahkan hanya 2 entri allowlist Admin dan 1 route device pada server.mjs. Tidak membuka wildcard RPC.
- Menjalankan node --check, restart API stage port 8788 saja, health check, serta probe kedua RPC tanpa token.
- Probe harus menjawab HTTP 401 AUTH_REQUIRED. Ini membuktikan nama RPC sudah dikenali API dan proteksi token tetap aktif.

BATASAN DAN KEAMANAN
- Default izin penyewa tetap OFF. Script tidak pernah mengaktifkan izin.
- Master/Owner harus mengaktifkan checkbox dan menekan Simpan dari Admin.
- Migrasi 012 hanya menambah setting billing_stop_pause_enabled (default false), helper dan tiga fungsi policy. Tidak mengubah data rental, sesi berjalan, token perangkat, pairing, Remote Play, atau WoL.
- Tidak mengubah APK, Worker Cloudflare, Agent WebSocket, Blynk/WoL relay, API utama port 8787, atau database utama.
- Hanya API staging port 8788 yang direstart. WebSocket relay dan PostgreSQL tetap hidup.
- Jika preflight, backup, sintaks, health check, atau smoke test gagal, script berhenti. Jika API gagal setelah restart, server.mjs lama dipulihkan dari backup. Migrasi SQL yang berhasil tetap additive dengan default OFF.
- File .env, password, token, dan rahasia tidak dicetak atau dikirim.

BACKUP
Script menyimpan dump database dan salinan server.mjs ke folder backups di lokasi stage. Backup tidak diunggah ke GitHub/chat.

SETELAH SELESAI
1. Buka Admin Ani Games Ready V12.1.58.
2. Masuk menu Izin PAUSE / STOP BILLING.
3. Tekan Muat Status.
4. Status awal seharusnya OFF (karena default aman).
5. Master/Owner dapat memilih Izinkan penyewa menggunakan PAUSE / STOP lalu Simpan Pengaturan.
6. Tutup dan buka Muat Status lagi untuk memastikan nilai tersimpan.

Bila Muat Status masih gagal, kirim teks lengkap output terakhir dari script dan pesan error Admin. Jangan kirim file .env atau backup database.
