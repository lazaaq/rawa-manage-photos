import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Satu foto RAW di galeri.
class RawPhoto {
  RawPhoto({required this.id, required this.name, required this.size});

  factory RawPhoto.fromMap(Map<dynamic, dynamic> m) => RawPhoto(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        size: (m['size'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String name;
  final int size;
}

class ConvertResult {
  ConvertResult({required this.newId, required this.inBytes, required this.outBytes, this.skipped = false});

  final String newId;
  final int inBytes;
  final int outBytes;

  /// Hasil tidak lebih kecil dari asli, jadi tidak disimpan (hanya dengan `onlyIfSmaller`).
  final bool skipped;
}

/// Jembatan ke converter native (iOS: Core Image, Android: Skia/MediaStore).
/// Tujuan penyimpanan JPG hasil kompresi.
enum SaveTarget {
  /// iOS: Photos. Android: Pictures/rawa di penyimpanan internal.
  gallery,

  /// Android saja: folder yang sama dengan RAW (Android 10+: hanya bila di DCIM/ atau Pictures/).
  sameFolder,

  /// Folder pilihan pengguna (app Files di iOS; folder mana pun termasuk kartu SD di Android).
  folder,
}

class RawNative {
  static const _ch = MethodChannel('raw_compressor/native');

  /// Untuk test: paksa perilaku Android/non-Android. null = pakai platform asli.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _isAndroid => debugIsAndroid ?? Platform.isAndroid;

  static bool get isAndroid => _isAndroid;

  static Future<List<RawPhoto>> scanRaw() async {
    final list = await _ch.invokeListMethod<Map<dynamic, dynamic>>('scanRaw') ?? [];
    return list.map(RawPhoto.fromMap).toList();
  }

  /// Semua foto non-RAW (JPEG, HEIC, PNG, …) di galeri, terbaru dulu.
  static Future<List<RawPhoto>> scanImages() async {
    final list = await _ch.invokeListMethod<Map<dynamic, dynamic>>('scanImages') ?? [];
    return list.map(RawPhoto.fromMap).toList();
  }

  /// Konversi lalu simpan di [target]. File asli tidak dihapus. [maxSide] 0 = resolusi asli.
  ///
  /// [imageFormat] null: sumber RAW → JPG. Selain itu: foto biasa → format itu
  /// (`same` = format asli). [onlyIfSmaller]: hasil yang tidak lebih kecil tidak disimpan.
  static Future<ConvertResult> convert(
    String id, {
    required int quality,
    required int maxSide,
    SaveTarget target = SaveTarget.gallery,
    String? imageFormat,
    bool onlyIfSmaller = false,
  }) async {
    final m = await _ch.invokeMapMethod<String, dynamic>('convert', {
      'id': id,
      'quality': quality,
      'maxSide': maxSide,
      'target': target.name,
      if (imageFormat != null) ...{'source': 'image', 'format': imageFormat, 'onlyIfSmaller': onlyIfSmaller},
    });
    return ConvertResult(
      newId: m?['newId'] as String? ?? '',
      inBytes: (m?['inBytes'] as num?)?.toInt() ?? 0,
      outBytes: (m?['outBytes'] as num?)?.toInt() ?? 0,
      skipped: m?['skipped'] == true,
    );
  }

  /// Versi API Android (mis. 28 = Android 9), atau null di platform lain.
  static Future<int?> androidSdk() async {
    if (!_isAndroid) return null;
    try {
      return await _ch.invokeMethod<int>('androidSdk');
    } catch (_) {
      return null;
    }
  }

  /// Buka pemilih folder sistem. Mengembalikan nama folder, atau null bila dibatalkan.
  /// Folder diingat native untuk [SaveTarget.folder].
  static Future<String?> pickFolder() => _ch.invokeMethod<String>('pickFolder');

  /// Nama folder tersimpan yang masih bisa ditulis, atau null.
  static Future<String?> savedFolder() async {
    try {
      return await _ch.invokeMethod<String>('savedFolder');
    } catch (_) {
      return null;
    }
  }

  /// Thumbnail dari native (Android), untuk file yang tidak dikenali galeri, mis. CR3.
  static Future<Uint8List?> thumbnail(String id, {int size = 300}) async {
    if (!_isAndroid) return null;
    try {
      return await _ch.invokeMethod<Uint8List>('thumbnail', {'id': id, 'size': size});
    } catch (_) {
      return null;
    }
  }

  /// Android 9: hapus langsung di native dan kembalikan id yang benar-benar terhapus.
  /// null = pakai photo_manager (iOS & Android 10+, dengan dialog konfirmasi sistem).
  static Future<List<String>?> deleteLegacy(List<String> ids) async {
    if (!_isAndroid) return null;
    return _ch.invokeListMethod<String>('deleteLegacy', {'ids': ids});
  }
}

String formatBytes(int b) {
  if (b <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}
