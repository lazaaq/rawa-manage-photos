import 'package:shared_preferences/shared_preferences.dart';

import 'jobs.dart';
import 'native.dart';

/// Pilihan terakhir per fitur (Kompres RAW, Kompres Foto, Ubah Format), disimpan di perangkat.
class CompressSettings {
  const CompressSettings({
    required this.quality,
    required this.maxSide,
    required this.deleteOriginal,
    this.target = SaveTarget.gallery,
    this.format = OutputFormat.same,
  });

  CompressSettings.defaults(PhotoJob job)
      : quality = job.defaultQuality,
        maxSide = job.defaultMaxSide,
        deleteOriginal = job.defaultDeleteOriginal,
        target = SaveTarget.gallery,
        format = job.defaultFormat;

  final int quality;
  final int maxSide;
  final bool deleteOriginal;
  final SaveTarget target;
  final OutputFormat format;

  /// Nilai tersimpan; nilai rusak atau tidak dikenal kembali ke default fitur.
  static Future<CompressSettings> load(PhotoJob job, {required Set<int> sizes, Set<OutputFormat>? formats}) async {
    final d = CompressSettings.defaults(job);
    final k = job.prefsPrefix;
    try {
      final p = await SharedPreferences.getInstance();
      final q = p.getInt('${k}quality');
      final m = p.getInt('${k}maxSide');
      final t = p.getString('${k}target');
      final f = OutputFormat.values.where((v) => v.name == p.getString('${k}format')).firstOrNull;
      return CompressSettings(
        quality: q != null && q >= 50 && q <= 100 ? q : d.quality,
        maxSide: m != null && sizes.contains(m) ? m : d.maxSide,
        deleteOriginal: p.getBool('${k}deleteOriginal') ?? d.deleteOriginal,
        target: SaveTarget.values.where((v) => v.name == t).firstOrNull ?? d.target,
        format: f != null && (formats == null || formats.contains(f)) ? f : d.format,
      );
    } catch (_) {
      return d;
    }
  }

  Future<void> save(PhotoJob job) async {
    final k = job.prefsPrefix;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('${k}quality', quality);
      await p.setInt('${k}maxSide', maxSide);
      await p.setBool('${k}deleteOriginal', deleteOriginal);
      await p.setString('${k}target', target.name);
      if (job == PhotoJob.convert) await p.setString('${k}format', format.name);
    } catch (_) {
      // Gagal menyimpan pilihan tidak boleh mengganggu kompresi.
    }
  }
}

/// Id foto yang sudah disimpan di Sortir Foto, supaya tidak ditampilkan lagi.
class SortProgress {
  static const _key = 'sort.keptIds';

  static Future<Set<String>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(_key) ?? const []).toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Set<String> ids) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_key, ids.toList());
    } catch (_) {}
  }
}
