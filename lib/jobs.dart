import 'native.dart';

/// Fitur yang memakai alur pilih foto → proses → (opsional) hapus asli.
enum PhotoJob {
  /// RAW → JPG.
  raw,

  /// Foto galeri biasa dikompres ulang dengan format yang sama.
  compress,

  /// Foto galeri biasa diubah ke format lain (mis. HEIC → JPG).
  convert,
}

/// Format hasil untuk foto biasa.
enum OutputFormat {
  /// Sama dengan foto asli (bila tidak bisa ditulis perangkat: JPG).
  same,
  jpeg,
  heic,
  png,
  webp;

  String get label => switch (this) {
        OutputFormat.same => 'Sama dengan asli',
        OutputFormat.jpeg => 'JPG',
        OutputFormat.heic => 'HEIC',
        OutputFormat.png => 'PNG',
        OutputFormat.webp => 'WEBP',
      };

  /// Ekstensi file yang sudah berformat ini.
  Set<String> get extensions => switch (this) {
        OutputFormat.same => const {},
        OutputFormat.jpeg => const {'jpg', 'jpeg'},
        OutputFormat.heic => const {'heic', 'heif', 'hif'},
        OutputFormat.png => const {'png'},
        OutputFormat.webp => const {'webp'},
      };

  /// PNG tanpa kompresi lossy: slider kualitas tidak berlaku.
  bool get lossy => this != OutputFormat.png;

  /// Format tujuan yang bisa ditulis perangkat. iOS: HEIC. Android: WEBP.
  static List<OutputFormat> convertTargets({required bool android}) => android
      ? const [OutputFormat.jpeg, OutputFormat.png, OutputFormat.webp]
      : const [OutputFormat.jpeg, OutputFormat.heic, OutputFormat.png];
}

String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Teks dan nilai awal per fitur.
extension PhotoJobText on PhotoJob {
  String get title => switch (this) {
        PhotoJob.raw => 'Kompres RAW',
        PhotoJob.compress => 'Kompres Foto',
        PhotoJob.convert => 'Ubah Format',
      };

  /// Sebutan file asli dalam kalimat: "RAW" / "foto".
  String get originalWord => this == PhotoJob.raw ? 'RAW' : 'foto';

  bool get isImage => this != PhotoJob.raw;

  /// Prefix kunci SharedPreferences. RAW memakai "compress." sejak versi pertama.
  String get prefsPrefix => switch (this) {
        PhotoJob.raw => 'compress.',
        PhotoJob.compress => 'gallery.',
        PhotoJob.convert => 'convert.',
      };

  int get defaultQuality => switch (this) {
        PhotoJob.raw => 85,
        PhotoJob.compress => 80,
        PhotoJob.convert => 90,
      };

  int get defaultMaxSide => switch (this) {
        PhotoJob.raw => 4096,
        PhotoJob.compress => 3000,
        PhotoJob.convert => 0,
      };

  bool get defaultDeleteOriginal => this != PhotoJob.convert;

  OutputFormat get defaultFormat => this == PhotoJob.convert ? OutputFormat.jpeg : OutputFormat.same;

  Future<List<RawPhoto>> scan() => this == PhotoJob.raw ? RawNative.scanRaw() : RawNative.scanImages();

  /// Kunci [GalleryCache]: Kompres Foto dan Ubah Format memakai daftar yang sama.
  String get cacheKey => this == PhotoJob.raw ? 'raw' : 'images';
}
