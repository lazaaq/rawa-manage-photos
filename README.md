# rawa

Aplikasi Android dan iOS untuk merapikan galeri foto. Semua diproses di perangkat, tanpa internet.

## Fitur

- **Kompres RAW**: ubah foto RAW (CR3, CR2, NEF, ARW, DNG, …) menjadi JPG yang jauh lebih kecil.
- **Kompres Foto**: kompres ulang foto galeri biasa (JPG, HEIC, PNG, …).
- **Ubah Format**: ubah format foto, misalnya HEIC ke JPG.
- **Sortir Foto**: geser kanan untuk simpan, geser kiri untuk hapus. Ada tombol favorit, dan progres diingat.

Hasil bisa disimpan ke galeri, folder yang sama dengan aslinya (Android), atau folder pilihan.
Pilihan kualitas, ukuran, dan lokasi simpan diingat per fitur.

## Download (Android)

1. Buka halaman [Releases](../../releases/latest) dan download `rawa.apk` (untuk hampir semua HP sejak 2017).
   Bila muncul "Aplikasi tidak terpasang" di HP lama, pakai `rawa-32bit.apk`.
2. Buka file tersebut di HP. Bila diminta, izinkan "Instal aplikasi tidak dikenal" untuk browser atau file manager.
3. Bila Play Protect memberi peringatan, pilih **Tetap instal**. Peringatan ini muncul karena aplikasi tidak berasal dari Play Store.

Butuh Android 9 atau lebih baru. Versi baru bisa dipasang langsung di atas versi lama.

## iOS

Belum ada file siap pasang untuk iOS. Build sendiri dengan Xcode (lihat di bawah).

## Privasi

Aplikasi tidak meminta izin internet dan tidak mengirim data ke server mana pun.
Foto hanya dibaca dan ditulis di perangkat Anda.

## Build sendiri

Butuh Flutter 3.47 atau lebih baru, JDK 17, dan Xcode untuk iOS.

```bash
flutter pub get
flutter test
flutter build apk --release
```

Tanpa `android/key.properties`, build release ditandatangani dengan debug key.
Detail pengujian ada di [docs/TESTING.md](docs/TESTING.md).

## Lisensi

[MIT](LICENSE)
