# ANI GAMES READY — AI Skill System

Dokumentasi kerja permanen lintas proyek Ani Games Ready. Tujuan: menjaga konteks, mencegah salah sumber, membuat audit wajib sebelum perubahan, dan memastikan setiap pekerjaan memiliki catatan handover.

## Cara mulai
1. Baca `AGENTS.md` dan `docs/ai-skill-system/MASTER_SKILL.md`.
2. Baca `PROJECT_REGISTRY.md`, `PROJECT_STATE.md`, `DECISIONS.md`, dan `NEXT_TASKS.md`.
3. Pilih Skill turunan di `.agents/skills/` sesuai jenis tugas.
4. Audit repository/branch/commit terbaru pada saat tugas dimulai. Registry adalah snapshot, bukan izin untuk menganggapnya selalu terbaru.
5. Sebelum berhenti, perbarui state, changelog, dan handover.

## Struktur
- `.agents/skills/`: Skill modular dengan format `SKILL.md`.
- `docs/ai-skill-system/`: aturan induk, registry, state, keputusan, changelog, backlog, template handover.
- `AGENTS.md`: entry point agar agen membaca aturan sebelum bekerja.

## Batas penting
Folder ini adalah dokumentasi dan Skill saja. Tidak mengubah source runtime, database, Supabase, workflow build, APK, atau EXE. Perubahan kode harus dilakukan di branch proyek yang benar setelah audit dan persetujuan lingkupnya.

## Status awal
Skill System dibuat pada 2026-11-14 di branch `docs/ani-games-ready-ai-skill-system`, diturunkan dari branch DB Android PC Billing agar terisolasi dari `main` dan baseline produksi.
