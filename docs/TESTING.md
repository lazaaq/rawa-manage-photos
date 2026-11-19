# Testing

Semua test otomatis berjalan di Mac tanpa simulator/emulator.

## Test otomatis

| Lapisan | Perintah | Isi |
|---|---|---|
| Dart (logika + UI) | `flutter test` | 54 test: beranda (navigasi ke 2 fitur), SortPage (izin, kosong, error, geser kanan/kiri, tombol, urungkan, tinjau sebelum hapus, batal hapus per foto, hapus sebagian/gagal, konfirmasi keluar, paging tanpa lompat setelah hapus), format ukuran, parsing channel, alur CompressPage (izin, kosong, error, pilih/pilih semua, dialog, opsi kualitas & ukuran, switch hapus, rescan) dan ProcessPage (sukses, gagal sebagian, nama file kembar, semua gagal, hapus dibatalkan/sebagian/error, jalur Android 9 vs 10+, tombol Hentikan, tombol back diblokir) |
| Parser CR3 (Android) | `cd android && ./gradlew :app:testDebugUnitTest` | 15 JUnit: CR3 sintetis (co64/stco, ukuran sampel seragam, header box 64-bit, TIFF II/MM, format nilai EXIF untuk ExifInterface, GPS, trak pertama saja, file rusak/terpotong/bukan CR3) |
| Encoder iOS | `tool/test_ios_encoder.sh` | DNG sintetis: ukuran asli, maxSide, tanpa upscale, orientasi 6 diterapkan ke pixel, kualitas vs ukuran file, quality di luar rentang, file rusak |
| Static | `flutter analyze` | tanpa issue |

Tambahkan file kamera asli dengan `CR3_SAMPLES_DIR`:

```bash
CR3_SAMPLES_DIR=~/Downloads/Landscape tool/test_ios_encoder.sh
cd android && CR3_SAMPLES_DIR=~/Downloads/Landscape ./gradlew :app:testDebugUnitTest
```

Dengan 4 file Canon EOS R6 Mark II (salah satunya potret, Orientation 8):
JPG 6000×4000 + EXIF lengkap terbaca di Android; di iOS hasil 4096 px tegak dengan
EXIF (f/, shutter, ISO, lensa, tanggal) tersalin, 30 MB → 3,6–4,1 MB.

## Yang tidak bisa diotomasi (butuh HP asli)

MediaStore/PhotoKit, dialog izin & hapus sistem, dan decoder Android hanya ada di perangkat.
Pakai 1–2 foto dulu dengan **"Hapus RAW asli" OFF**.

### Android (uji di Android 9; ulangi di Android 10+ bila ada)

- [ ] **A1 Update** APK di atas versi lama: aplikasi terbuka, izin tidak diminta ulang.
- [ ] **A2 Izin ditolak**: muncul "Izin galeri dibutuhkan…" + tombol *Buka Pengaturan* membuka pengaturan aplikasi.
- [ ] **A3 Daftar**: 4 CR3 di Download muncul dengan thumbnail; `3U2A6786` thumbnail **tegak** (potret).
- [ ] **A4 Konversi 1 foto** (hapus OFF, 4096 px, kualitas 85): JPG ±3–4 MB di folder yang sama, tampil di galeri, detail menunjukkan kamera/ISO/aperture, tanggal 30 Mar 2023.
- [ ] **A5 Potret**: hasil `3U2A6786` tegak di galeri dan di aplikasi lain (WhatsApp/Files).
- [ ] **A6 Ukuran**: "Asli" → 6000×4000; "2048 px" → sisi panjang 2048.
- [ ] **A7 Kualitas**: 50 menghasilkan file lebih kecil dari 95.
- [ ] **A8 Nama kembar**: konversi foto yang sama dua kali → `…(1).jpg`, tidak menimpa.
- [ ] **A9 Hapus ON**: RAW hilang dari Download, JPG tetap, daftar diperbarui. (Android 9: tanpa dialog sistem, permanen. Android 10+: satu dialog konfirmasi.)
- [ ] **A10 Hentikan**: pilih 4, tekan *Hentikan* setelah foto pertama → hanya yang sudah jadi JPG yang RAW-nya dihapus.
- [ ] **A11 Putar layar / pindah aplikasi** saat proses: proses tetap berjalan sampai selesai.
- [ ] **A12 Format lain** (DNG dari HP, CR2/NEF/ARW bila ada): terkonversi atau muncul pesan gagal yang jelas, RAW tidak dihapus.

### iOS

- [ ] **I1 Izin**: "Akses penuh" dan "Foto terpilih" sama-sama menampilkan RAW yang boleh diakses.
- [ ] **I2 Konversi** CR3/DNG di Photos (hapus OFF): JPG muncul di Photos dengan tanggal & lokasi sama; panel Info menunjukkan kamera, lensa, ISO.
- [ ] **I3 Potret** tegak.
- [ ] **I4 Hapus ON**: satu dialog sistem untuk semua foto; RAW masuk "Baru Dihapus".
- [ ] **I5 Tolak dialog hapus**: muncul "N RAW tidak dihapus… JPG hasil tetap tersimpan".
- [ ] **I6 iCloud**: RAW yang hanya ada di iCloud diunduh lalu dikonversi.
- [ ] **I7 Pasangan RAW+JPEG** di satu aset: hapus menghapus keduanya (perilaku Photos) — pastikan dapat diterima.

### Sortir Foto (iOS & Android)

- [ ] **S1 Beranda**: aplikasi terbuka di beranda tanpa meminta izin; dua kartu membuka Kompres RAW dan Sortir Foto.
- [ ] **S2 Geser**: kanan = SIMPAN (hijau), kiri = HAPUS (merah); geser pendek kembali ke tengah; foto potret/lanskap tampil utuh.
- [ ] **S3 Urungkan** mengembalikan foto terakhir.
- [ ] **S4 Tinjau**: ketuk foto untuk batal hapus; hanya sisanya yang dihapus. iOS: satu dialog sistem, masuk "Baru Dihapus".
- [ ] **S5 Tolak dialog sistem**: foto tetap ditandai, tidak ada yang hilang.
- [ ] **S6 Keluar** dengan foto bertanda: muncul "Keluar tanpa menghapus?".
- [ ] **S7 Galeri besar** (>100 foto): urutan terbaru dulu, tidak ada foto terlewat setelah menghapus.

## Batasan yang diketahui

- Android 10+: CR3 di folder Download yang tidak terindeks sebagai foto tidak terlihat aplikasi
  (scoped storage). Perlu tombol "Pilih file" (Storage Access Framework).
- Android: CR3 memakai JPG olahan kamera di dalam file, bukan decode RAW penuh.
- iOS: build butuh komponen "iOS platform" di Xcode › Settings › Components (berisi juga runtime
  simulator), walau hanya untuk deploy ke iPhone fisik.
- Sortir Foto belum mengingat foto yang sudah disimpan; sesi berikutnya mulai lagi dari foto terbaru.
