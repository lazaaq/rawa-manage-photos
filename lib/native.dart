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
  ConvertResult({required this.newId, required this.inBytes, required this.outBytes});

  final String newId;
  final int inBytes;
  final int outBytes;
}

/// Jembatan ke converter native (iOS: Core Image, Android: Skia/MediaStore).
class RawNative {
  static const _ch = MethodChannel('raw_compressor/native');

  /// Untuk test: paksa perilaku Android/non-Android. null = pakai platform asli.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _isAndroid => debugIsAndroid ?? Platform.isAndroid;

  static Future<List<RawPhoto>> scanRaw() async {
    final list = await _ch.invokeListMethod<Map<dynamic, dynamic>>('scanRaw') ?? [];
    return list.map(RawPhoto.fromMap).toList();
  }

  /// Konversi RAW ke JPEG dan simpan sebagai foto baru. RAW asli tidak dihapus.
  /// [maxSide] 0 = resolusi asli.
  static Future<ConvertResult> convert(String id, {required int quality, required int maxSide}) async {
    final m = await _ch.invokeMapMethod<String, dynamic>(
      'convert',
      {'id': id, 'quality': quality, 'maxSide': maxSide},
    );
    return ConvertResult(
      newId: m?['newId'] as String? ?? '',
      inBytes: (m?['inBytes'] as num?)?.toInt() ?? 0,
      outBytes: (m?['outBytes'] as num?)?.toInt() ?? 0,
    );
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
