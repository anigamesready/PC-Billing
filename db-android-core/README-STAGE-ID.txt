ANI GAMES READY — DB ANDROID STAGING PACKAGE
==============================================

Tujuan paket:
- Memasang backend DB Android BARU sebagai STAGING di Redmi/Termux.
- Tidak mengganti server lama yang berjalan di port 8787.
- Tidak mengubah Supabase DB1/DB2, APK master, atau relay Blynk/WoL.
- Tidak mengimpor data Supabase; database staging awalnya kosong.

Komponen:
- Database staging: ani_games_ready_stage
- PostgreSQL runtime role: ani_api_stage_login
- API staging: 127.0.0.1:8788 (loopback-only)
- Skema: 000 dan 002–019; termasuk watchdog server dan timer stream terhubung; katalog snapshot 001 dikecualikan.
- Remote Play: login rental, dashboard host, sesi maksimum 3 jam, cooldown 10 menit, host enrollment, permission Admin dan pairing Sunshine otomatis.
- API: PC pairing/heartbeat/sync/sesi, Admin, Billing Control, Reseller.
- API secret, password runtime dan bootstrap token dibuat acak di perangkat dan hanya disimpan di .env lokal.

Pemeriksaan keamanan:
- Setup berhenti bila folder staging, database staging, role staging, atau port 8788 sudah ada.
- Tidak menimpa database lama.
- Tidak menghentikan proses pada port 8787.
- Tidak menyalakan atau mematikan relay Blynk/WoL.
- API staging hanya menerima koneksi dari localhost sampai HTTPS gateway/reverse proxy disiapkan.
- Remote Play belum dapat dipakai dari luar HP sampai API stage dan gateway HTTPS terdaftar aktif, serta HP/PC terdaftar pada jaringan media privat Cloudflare Mesh.

Langkah setelah paket diekstrak:
1. Pastikan PostgreSQL dan Node.js online di Termux.
2. Masuk ke folder hasil ekstrak paket.
3. Jalankan:
   bash setup-stage.sh
4. Jalankan:
   bash ~/ani-games-db-android-stage/start-stage.sh
5. Periksa:
   bash ~/ani-games-db-android-stage/status-stage.sh
6. Buka browser di Redmi:
   http://127.0.0.1:8788/setup
7. Buat Owner staging pertama.
8. Salin file privat `ani-games-db-android-stage-online-secrets.env` ke folder `cloudflare-gateway-stage/online-secrets.env` dalam paket. File rahasia ini diberikan terpisah dan tidak boleh dimasukkan ke GitHub.
9. Jalankan `bash cloudflare-gateway-stage/configure-online.sh`, lalu `bash cloudflare-gateway-stage/start-online.sh`. Biarkan Termux aktif dan tunggu sampai pemeriksaan `/health` publik menampilkan API serta database online.

Perintah berikutnya:
- Status: bash ~/ani-games-db-android-stage/status-stage.sh
- Hentikan API staging saja: bash ~/ani-games-db-android-stage/stop-stage.sh
- Lihat log: tail -n 80 ~/ani-games-db-android-stage/logs/stage-api.log

Uji koneksi PC (sementara saja):
- Pastikan API 8788 online.
- Jalankan: bash ~/ani-games-db-android-stage/start-quick-tunnel-test.sh
- Catat URL HTTPS `https://....trycloudflare.com` yang dicetak.
- Masukkan URL itu ke kolom Server Rental DB Android di PC Billing V12.4.8 DB Android.
- Hentikan tunnel dengan CTRL+C setelah tes.

Quick Tunnel bersifat sementara: hostname berubah saat proses dimulai ulang, tidak ada jaminan uptime, dan hanya untuk tes awal. Jangan gunakan sebagai jalur produksi rental 24 jam. Named Tunnel dengan hostname stabil memerlukan domain aktif pada akun Cloudflare.

PENTING:
- Jangan ubah URL PC ke alamat HTTP LAN. PC Billing hanya menerima HTTPS untuk server di luar PC itu sendiri.
- Kontrol Android memakai HTTPS Worker gateway staging; media game tetap lewat Cloudflare Mesh privat, bukan Worker.
- Admin APK V12.1.53 default ke port utama `8787`. Sebelum login untuk staging, ubah **Alamat API Lokal** di layar login ke `http://127.0.0.1:8788` lalu Simpan. Jangan lanjut jika health check belum menyatakan API dan database online.
- Jangan menaruh isi .env, password, token, private key, atau backup database ke GitHub/chat.
- Paket ini belum memindahkan data DB1/DB2 dan belum memodifikasi server lama.
- Gateway runner perlu tetap aktif; Quick Tunnel staging belum merupakan layanan produksi 24/7.
- Untuk pengulangan uji instalasi bersih, gunakan folder/database staging baru setelah mengekspor hasil uji yang perlu disimpan.
