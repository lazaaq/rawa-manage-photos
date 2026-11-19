import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const nativeChannel = MethodChannel('raw_compressor/native');
const photoManagerChannel = MethodChannel('com.fluttercandies/photo_manager');

/// Fake for both platform channels the app talks to.
class FakePlatform {
  final List<MethodCall> calls = [];

  /// photo_manager PermissionState index: 0 notDetermined, 2 denied, 3 authorized, 4 limited.
  int permission = 3;

  List<Map<String, Object?>> photos = [];

  /// Non-RAW gallery photos returned by `scanImages`.
  List<Map<String, Object?>> images = [];
  PlatformException? scanError;

  /// Per-id convert result. Missing id -> default success map. A [PlatformException] value is thrown.
  final Map<String, Object> convertResults = {};

  /// Optional gate: convert(id) waits for this future before answering.
  Future<void> Function(String id)? convertGate;

  /// photo_manager deleteWithIds result. null -> echo all requested ids.
  List<String>? deleteResult;
  PlatformException? deleteError;

  /// Native deleteLegacy result (Android 9 path).
  List<String>? legacyDeleteResult;

  /// Name returned by `savedFolder` (folder remembered from an earlier pick).
  String? savedFolder;

  /// `pickFolder` answer: a folder name, null (cancelled) or a [PlatformException].
  Object? pickFolderResult;

  List<MethodCall> callsOf(String method) => calls.where((c) => c.method == method).toList();

  void install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, _native);
    messenger.setMockMethodCallHandler(photoManagerChannel, _photoManager);
  }

  void uninstall() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(photoManagerChannel, null);
  }

  Future<Object?> _native(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'scanRaw':
        if (scanError != null) throw scanError!;
        return photos;
      case 'scanImages':
        if (scanError != null) throw scanError!;
        return images;
      case 'convert':
        final id = (call.arguments as Map)['id'] as String;
        if (convertGate != null) await convertGate!(id);
        final r = convertResults[id];
        if (r is PlatformException) throw r;
        return r ?? {'newId': 'new-$id', 'inBytes': 10 * 1024 * 1024, 'outBytes': 2 * 1024 * 1024};
      case 'thumbnail':
        return null;
      case 'deleteLegacy':
        return legacyDeleteResult;
      case 'savedFolder':
        return savedFolder;
      case 'pickFolder':
        final r = pickFolderResult;
        if (r is PlatformException) throw r;
        if (r is String) savedFolder = r;
        return r;
    }
    throw MissingPluginException(call.method);
  }

  Future<Object?> _photoManager(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'requestPermissionExtend':
        return permission;
      case 'fetchEntityProperties':
        return null; // -> AssetEntity.fromId == null -> native thumbnail fallback
      case 'openSetting':
        return null;
      case 'deleteWithIds':
        if (deleteError != null) throw deleteError!;
        return deleteResult ?? List<String>.from((call.arguments as Map)['ids'] as List);
    }
    return null;
  }
}

Map<String, Object?> photo(String id, String name, int size) => {'id': id, 'name': name, 'size': size};

/// Completer-based gate so a test can release conversions one at a time.
class ConvertGate {
  final Map<String, Completer<void>> _pending = {};

  Future<void> call(String id) => (_pending[id] ??= Completer<void>()).future;

  void release(String id) => (_pending[id] ??= Completer<void>()).complete();
}
