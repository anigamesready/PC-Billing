ANI GAMES READY — DB ANDROID STAGING PACKAGE
==============================================

Tujuan:
- Membuat instalasi STAGING terpisah pada Redmi/Termux.
- Database staging: ani_games_ready_stage
- PostgreSQL runtime role: ani_api_stage_login
- API staging: 127.0.0.1:8788
- Server lama yang menggunakan port 8787 tidak disentuh.
- Blynk/WoL relay tidak disentuh.

Jangan jalankan pada database produksi atau menghapus folder ani-games-server.
Setup akan berhenti bila folder staging, database staging, role staging, atau port 8788 sudah ada.

Langkah setelah paket diekstrak:
1. Pastikan PostgreSQL dan Node.js online pada Termux.
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

Perintah berikutnya:
- Status: bash ~/ani-games-db-android-stage/status-stage.sh
- Hentikan API staging saja: bash ~/ani-games-db-android-stage/stop-stage.sh
- Lihat log: tail -n 80 ~/ani-games-db-android-stage/logs/stage-api.log

PENTING:
- Server staging masih hanya localhost. PC Windows atau HP lain belum dapat mengaksesnya.
- Akses antar-perangkat baru boleh diaktifkan setelah jalur HTTPS/tunnel dan origin/CORS dikonfigurasi. Jangan mengubah URL client ke HTTP LAN karena login dan token akan terkirim tanpa enkripsi.
- Jangan menaruh isi .env, password, token, private key, atau backup database ke GitHub/chat.
- Paket ini belum mengimpor data Supabase dan belum memodifikasi server lama.
- Untuk mengulang uji instalasi bersih, gunakan database/folder staging baru hanya setelah meninjau dan mengekspor data uji yang perlu disimpan.
