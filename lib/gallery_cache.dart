import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'native.dart';

/// Hasil pindai galeri terakhir, supaya daftar foto langsung tampil saat fitur dibuka.
/// Disimpan di memori (selama app terbuka) dan di file (setelah app ditutup).
/// Daftar tetap diperbarui di latar belakang; cache hanya untuk tampilan awal.
class GalleryCache {
  static final Map<String, List<RawPhoto>> _memory = {};

  /// Folder file cache. Diganti di test.
  @visibleForTesting
  static Future<Directory> Function() directory = getApplicationSupportDirectory;

  @visibleForTesting
  static void reset() => _memory.clear();

  static Future<File?> _file(String key) async {
    try {
      return File('${(await directory()).path}/gallery-$key.json');
    } catch (_) {
      return null; // tanpa folder (mis. test tanpa plugin): cache memori saja
    }
  }

  /// Daftar tersimpan untuk [key] ("raw" / "images"), atau null bila belum ada.
  static Future<List<RawPhoto>?> read(String key) async {
    final mem = _memory[key];
    if (mem != null) return mem;
    try {
      final f = await _file(key);
      if (f == null || !await f.exists()) return null;
      final data = jsonDecode(await f.readAsString()) as List<dynamic>;
      final list = [
        for (final e in data)
          if (e is List && e.length == 3)
            RawPhoto(id: e[0] as String, name: e[1] as String, size: (e[2] as num).toInt()),
      ];
      return _memory[key] = list;
    } catch (_) {
      return null; // file rusak: anggap belum ada
    }
  }

  /// Buang foto yang baru dihapus dari semua daftar tersimpan.
  static Future<void> remove(Iterable<String> ids) async {
    final gone = ids.toSet();
    if (gone.isEmpty) return;
    for (final key in const ['raw', 'images']) {
      final list = await read(key);
      if (list == null || !list.any((p) => gone.contains(p.id))) continue;
      await write(key, [for (final p in list) if (!gone.contains(p.id)) p]);
    }
  }

  static Future<void> write(String key, List<RawPhoto> photos) async {
    _memory[key] = List.unmodifiable(photos);
    try {
      final f = await _file(key);
      if (f == null) return;
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode([
        for (final p in photos) [p.id, p.name, p.size],
      ]));
      await tmp.rename(f.path); // tidak pernah setengah tertulis
    } catch (_) {}
  }
}
