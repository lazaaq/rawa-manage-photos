# Testing

Semua test otomatis berjalan di Mac tanpa simulator/emulator.

## Test otomatis

| Lapisan | Perintah | Isi |
|---|---|---|
| Dart (logika + UI) | `flutter test` | 128 test: jalur hapus Android 9 vs 10+ untuk foto biasa, error memori, opsi di lembar bawah setelah memilih foto (Batal mempertahankan pilihan, foto berformat sama dilewati), beranda (5 ikon, 4 per baris, navigasi tiap fitur), Kompres RAW (izin, kosong, error, pilih/pilih semua, dialog, kualitas/ukuran, switch hapus, rescan, lokasi simpan, pilihan diingat & nilai rusak → default), Kompres Foto (scan non-RAW, format sama + `onlyIfSmaller`, dilewati tidak dihapus, teks iOS/Android), Ubah Format (default JPG, foto berformat sama disembunyikan, target iOS JPG/HEIC/PNG vs Android JPG/PNG/WEBP, PNG tanpa slider, hasil lebih besar, format diingat per fitur), Cari Duplikat (dHash, duplikat lintas waktu via blok 16-bit, mirip hanya dalam 10 menit, rasio sisi & foto polos disaring, favorit/resolusi terbesar disimpan, minimal satu per grup, konfirmasi & hapus sebagian, cache hash hanya hitung foto baru/berubah, viewer), cache daftar galeri (daftar lama langsung tampil lalu diperbarui di latar belakang, Kompres Foto & Ubah Format berbagi daftar, gagal perbarui tetap tampil, foto terhapus dibuang dari cache), Sortir Foto (geser, tombol, urungkan, tinjau sebelum hapus, hapus sebagian/gagal, konfirmasi keluar, paging setelah hapus, progres diingat & lewati, ulangi dari awal, tombol favorit), ProcessPage (sukses, gagal sebagian, Hentikan, back diblokir, jalur Android 9 vs 10+), parsing channel |
| Android (JUnit) | `cd android && ./gradlew :app:testDebugUnitTest` | 15 test parser CR3 (co64/stco, box 64-bit, TIFF II/MM, format EXIF, GPS, file rusak/terpotong) + 9 test `ImageFormats` (format sama/eksplisit, HEIC → JPG, ekstensi, MIME, nama file hasil, deteksi RAW, path dokumen internal/kartu SD, nama unik "(1)", pesan error memori) |
| Encoder iOS | `tool/test_ios_encoder.sh` | RAW: DNG sintetis (ukuran asli, maxSide, tanpa upscale, orientasi 6, kualitas, file rusak). Foto biasa: JPEG→JPEG (GPS/TIFF/tanggal tersalin), orientasi 6, maxSide, kualitas, JPEG→PNG, PNG→JPEG, JPEG↔HEIC, aturan format, file rusak |
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
- [ ] **A13 Simpan ke**: default "Galeri internal" → JPG di `Pictures/rawa`, tampil di galeri. "Folder yang sama dengan RAW" → di samping RAW (Android 10+: hanya bila RAW di DCIM/Pictures). "Pilih folder…" (mis. kartu SD) → JPG di folder itu; folder diingat setelah aplikasi ditutup.

### iOS

- [ ] **I1 Izin**: "Akses penuh" dan "Foto terpilih" sama-sama menampilkan RAW yang boleh diakses.
- [ ] **I2 Konversi** CR3/DNG di Photos (hapus OFF): JPG muncul di Photos dengan tanggal & lokasi sama; panel Info menunjukkan kamera, lensa, ISO.
- [ ] **I3 Potret** tegak.
- [ ] **I4 Hapus ON**: satu dialog sistem untuk semua foto; RAW masuk "Baru Dihapus".
- [ ] **I5 Tolak dialog hapus**: muncul "N RAW tidak dihapus… JPG hasil tetap tersimpan".
- [ ] **I6 iCloud**: RAW yang hanya ada di iCloud diunduh lalu dikonversi.
- [ ] **I7 Pasangan RAW+JPEG** di satu aset: hapus menghapus keduanya (perilaku Photos) — pastikan dapat diterima.
- [ ] **I8 Simpan ke folder**: "Pilih folder…" → pilih folder di app Files (On My iPhone/iCloud Drive); JPG muncul di sana, tidak di Photos; nama kembar jadi `… (1).jpg`.

### Sortir Foto (iOS & Android)

- [ ] **S1 Beranda**: aplikasi terbuka di beranda tanpa meminta izin; dua kartu membuka Kompres RAW dan Sortir Foto.
- [ ] **S2 Geser**: kanan = SIMPAN (hijau), kiri = HAPUS (merah); geser pendek kembali ke tengah; foto potret/lanskap tampil utuh.
- [ ] **S3 Urungkan** mengembalikan foto terakhir.
- [ ] **S4 Tinjau**: ketuk foto untuk batal hapus; hanya sisanya yang dihapus. iOS: satu dialog sistem, masuk "Baru Dihapus".
- [ ] **S5 Tolak dialog sistem**: foto tetap ditandai, tidak ada yang hilang.
- [ ] **S6 Keluar** dengan foto bertanda: muncul "Keluar tanpa menghapus?".
- [ ] **S7 Galeri besar** (>100 foto): urutan terbaru dulu, tidak ada foto terlewat setelah menghapus.

### Kompres Foto & Ubah Format (iOS & Android)

- [ ] **F1 Kompres Foto**: pilih 2–3 foto HP (hapus OFF) → hasil format sama, lebih kecil, tanggal/lokasi sama; foto yang sudah kecil "Dilewati".
- [ ] **F2 Ganti asli**: hapus ON → asli masuk "Baru Dihapus" (iOS) / terhapus (Android); yang dilewati tetap ada.
- [ ] **F3 HEIC → JPG** (iPhone): hasil `IMG_xxxx.JPG` di Photos, tegak, info kamera tetap.
- [ ] **F4 JPG → HEIC / PNG** (iOS), **JPG → WEBP / PNG** (Android): file terbuka di galeri & app lain.
- [ ] **F5 Foto editan** (iOS, crop/filter): hasil memakai versi editan.
- [ ] **F6 Live Photo**: hasil berupa foto biasa (sesuai peringatan dialog).
- [ ] **F8 Cari Duplikat**: kirim foto ke diri sendiri lewat WhatsApp lalu simpan (harus jadi Duplikat), jepret 3 foto beruntun (harus jadi Mirip); catat lama pemindaian pertama dan kedua untuk galeri besar; pastikan tidak ada grup salah tebak yang mencolok.
- [ ] **F7 Galeri besar**: daftar Kompres Foto termuat dalam waktu wajar (catat lama untuk ±5.000 foto).

### Beranda & pengaturan

- [ ] **B1** 4 ikon sebaris; tiap ikon membuka fiturnya.
- [ ] **B1b** Saat memilih foto, bagian bawah hanya berisi satu tombol; semua opsi (format, kualitas, ukuran, lokasi, hapus asli) muncul di lembar bawah setelah tombol ditekan; Batal mempertahankan pilihan foto.
- [ ] **B2** Ubah kualitas/ukuran/lokasi di satu fitur, tutup & buka app → pilihan tetap; fitur lain tidak ikut berubah.
- [ ] **B3 Sortir**: simpan beberapa foto, keluar, buka lagi → foto itu tidak muncul; menu "Ulangi dari awal" menampilkannya lagi.
- [ ] **B4 Favorit** (iOS / Android 11+): tombol ⭐ menandai favorit di galeri; tidak pindah ke foto berikutnya. Android 9–10: tombol tidak tampil.
- [ ] **B5 Kartu SD** (Android): "Pilih folder / kartu SD…" → pilih/buat folder di kartu SD → JPG tersimpan & tampil di galeri.

## Batasan yang diketahui

- Android 10+: CR3 di folder Download yang tidak terindeks sebagai foto tidak terlihat aplikasi
  (scoped storage). Perlu tombol "Pilih file" (Storage Access Framework).
- Android: CR3 memakai JPG olahan kamera di dalam file, bukan decode RAW penuh.
- iOS: build butuh komponen "iOS platform" di Xcode › Settings › Components (berisi juga runtime
  simulator), walau hanya untuk deploy ke iPhone fisik.
- Android tidak bisa menulis HEIC: Kompres Foto mengubah HEIC menjadi JPG; Ubah Format tanpa HEIC.
- Android 11+: root kartu SD/memori internal dan folder Download tidak bisa dipilih langsung di pemilih folder; buat atau pilih subfolder.
- Favorit di Android hanya ada di Android 11+ (setiap perubahan memunculkan dialog izin sistem).
- Kompres/Ubah Format menulis ulang piksel: HDR gain map dan Live Photo tidak ikut tersalin.
