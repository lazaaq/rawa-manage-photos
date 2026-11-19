import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/native.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('formatBytes', () {
    test('non-positive values render as dash', () {
      expect(formatBytes(0), '-');
      expect(formatBytes(-5), '-');
    });

    test('bytes have no decimals', () {
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('KB / MB / GB use one decimal below 100', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(30177426), '28.8 MB');
      expect(formatBytes(1024 * 1024 * 1024 * 3 ~/ 2), '1.5 GB');
    });

    test('values of 100 or more have no decimals', () {
      expect(formatBytes(150 * 1024 * 1024), '150 MB');
    });

    test('caps at TB', () {
      expect(formatBytes(5 * 1024 * 1024 * 1024 * 1024 * 1024), '5120 TB');
    });
  });

  group('RawPhoto.fromMap', () {
    test('reads all fields', () {
      final p = RawPhoto.fromMap({'id': '7', 'name': 'A.CR3', 'size': 42});
      expect((p.id, p.name, p.size), ('7', 'A.CR3', 42));
    });

    test('defaults missing name and size, accepts double size', () {
      expect(RawPhoto.fromMap({'id': '1'}).name, '');
      expect(RawPhoto.fromMap({'id': '1'}).size, 0);
      expect(RawPhoto.fromMap({'id': '1', 'size': 12.0}).size, 12);
    });
  });

  group('RawNative', () {
    late FakePlatform fake;

    setUp(() {
      fake = FakePlatform()..install();
      RawNative.debugIsAndroid = null;
    });

    tearDown(() {
      fake.uninstall();
      RawNative.debugIsAndroid = null;
    });

    test('scanRaw parses native list', () async {
      fake.photos = [photo('1', 'A.CR3', 10), photo('2', 'B.DNG', 20)];
      final list = await RawNative.scanRaw();
      expect(list.map((p) => p.name), ['A.CR3', 'B.DNG']);
    });

    test('scanRaw propagates native errors', () {
      fake.scanError = PlatformException(code: 'x', message: 'boom');
      expect(RawNative.scanRaw(), throwsA(isA<PlatformException>()));
    });

    test('convert sends id, quality, maxSide and parses result', () async {
      fake.convertResults['9'] = {'newId': 'n9', 'inBytes': 100, 'outBytes': 30};
      final r = await RawNative.convert('9', quality: 77, maxSide: 2048);
      expect((r.newId, r.inBytes, r.outBytes), ('n9', 100, 30));
      expect(fake.callsOf('convert').single.arguments,
          {'id': '9', 'quality': 77, 'maxSide': 2048, 'target': 'gallery'});
    });

    test('convert sends the chosen save target', () async {
      for (final t in SaveTarget.values) {
        await RawNative.convert('1', quality: 85, maxSide: 0, target: t);
      }
      expect(fake.callsOf('convert').map((c) => (c.arguments as Map)['target']), ['gallery', 'sameFolder', 'folder']);
    });

    test('pickFolder returns name or null; savedFolder swallows errors', () async {
      fake.pickFolderResult = 'Kompres';
      expect(await RawNative.pickFolder(), 'Kompres');
      fake.pickFolderResult = null;
      expect(await RawNative.pickFolder(), isNull);
      expect(await RawNative.savedFolder(), 'Kompres');

      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(nativeChannel, (_) async => throw PlatformException(code: 'x'));
      expect(await RawNative.savedFolder(), isNull);
    });

    test('convert tolerates missing fields', () async {
      fake.convertResults['1'] = <String, Object?>{};
      final r = await RawNative.convert('1', quality: 85, maxSide: 0);
      expect((r.newId, r.inBytes, r.outBytes), ('', 0, 0));
    });

    test('convert surfaces native error message', () async {
      fake.convertResults['1'] = PlatformException(code: 'convert_failed', message: 'Bukan file RAW');
      await expectLater(
        RawNative.convert('1', quality: 85, maxSide: 0),
        throwsA(isA<PlatformException>().having((e) => e.message, 'message', 'Bukan file RAW')),
      );
    });

    test('thumbnail and deleteLegacy are skipped off Android', () async {
      RawNative.debugIsAndroid = false;
      expect(await RawNative.thumbnail('1'), isNull);
      expect(await RawNative.deleteLegacy(['1']), isNull);
      expect(fake.calls, isEmpty);
    });

    test('thumbnail on Android returns bytes and swallows errors', () async {
      RawNative.debugIsAndroid = true;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        if ((call.arguments as Map)['id'] == 'bad') throw PlatformException(code: 'x');
        return Uint8List.fromList([1, 2, 3]);
      });
      expect(await RawNative.thumbnail('ok'), [1, 2, 3]);
      expect(await RawNative.thumbnail('bad'), isNull);
    });

    test('deleteLegacy on Android returns native result (null on Android 10+)', () async {
      RawNative.debugIsAndroid = true;
      fake.legacyDeleteResult = ['1'];
      expect(await RawNative.deleteLegacy(['1', '2']), ['1']);
      fake.legacyDeleteResult = null;
      expect(await RawNative.deleteLegacy(['1']), isNull);
    });
  });
}
