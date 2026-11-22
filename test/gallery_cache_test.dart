import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/compress_page.dart';
import 'package:raw_compressor/gallery_cache.dart';
import 'package:raw_compressor/jobs.dart';
import 'package:raw_compressor/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Let the page's async start-up run without waiting for the (gated) scan; pumpAndSettle would
/// never return while the progress bar animates.
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakePlatform fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fake = FakePlatform()..install();
    RawNative.debugIsAndroid = false;
  });

  tearDown(() {
    fake.uninstall();
    RawNative.debugIsAndroid = null;
  });

  group('file cache', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('rawa-cache');
      GalleryCache.directory = () async => dir;
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('survives an app restart (memory cleared)', () async {
      await GalleryCache.write('images', [RawPhoto(id: '1', name: 'A.JPG', size: 10)]);
      GalleryCache.reset();
      final back = await GalleryCache.read('images');
      expect(back!.single.id, '1');
      expect(back.single.name, 'A.JPG');
      expect(back.single.size, 10);
      expect(await GalleryCache.read('raw'), isNull);
    });

    test('corrupt file is ignored', () async {
      File('${dir.path}/gallery-raw.json').writeAsStringSync('{not json');
      expect(await GalleryCache.read('raw'), isNull);
    });

    test('remove drops deleted photos from every list', () async {
      await GalleryCache.write('images', [RawPhoto(id: '1', name: 'a', size: 1), RawPhoto(id: '2', name: 'b', size: 1)]);
      await GalleryCache.write('raw', [RawPhoto(id: '3', name: 'c.CR3', size: 1)]);
      await GalleryCache.remove(['2', '3']);
      GalleryCache.reset();
      expect((await GalleryCache.read('images'))!.map((p) => p.id), ['1']);
      expect(await GalleryCache.read('raw'), isEmpty);
    });
  });

  group('CompressPage', () {
    Future<void> open(WidgetTester tester, PhotoJob job) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: CompressPage(key: UniqueKey(), job: job)));
    }

    testWidgets('second open shows the last list at once, then refreshes in the background', (tester) async {
      fake.images = [photo('1', 'A.JPG', 1024)];
      await open(tester, PhotoJob.compress);
      await tester.pumpAndSettle();
      expect(find.text('JPG · 1.0 KB'), findsOneWidget);

      final gate = Completer<void>();
      fake.scanGate = () => gate.future;
      fake.images = [photo('2', 'B.JPG', 2048), photo('1', 'A.JPG', 1024)];
      await open(tester, PhotoJob.compress);
      await _settleAsync(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'no full-screen loading');
      expect(find.text('JPG · 1.0 KB'), findsOneWidget, reason: 'cached list shown while scanning');
      expect(find.byKey(const ValueKey('refreshing')), findsOneWidget);
      await tester.tap(find.text('JPG · 1.0 KB'));
      await tester.pump();
      expect(find.text('1 dipilih'), findsOneWidget, reason: 'usable while refreshing');

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('JPG · 2.0 KB'), findsOneWidget, reason: 'new photo appears');
      expect(find.byKey(const ValueKey('refreshing')), findsNothing);
      expect(find.text('1 dipilih'), findsOneWidget, reason: 'selection kept');
    });

    testWidgets('Kompres Foto and Ubah Format share the list; RAW has its own', (tester) async {
      fake.images = [photo('1', 'A.JPG', 1024)];
      fake.photos = [photo('r', 'R.CR3', 4096)];
      await open(tester, PhotoJob.compress);
      await tester.pumpAndSettle();

      fake.scanGate = () => Completer<void>().future; // never finishes
      await open(tester, PhotoJob.convert);
      await _settleAsync(tester);
      expect(find.text('JPG · 1.0 KB'), findsOneWidget);

      await open(tester, PhotoJob.raw);
      await _settleAsync(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'no RAW list cached yet');
    });

    testWidgets('failed background refresh keeps the list and says so', (tester) async {
      fake.images = [photo('1', 'A.JPG', 1024)];
      await open(tester, PhotoJob.compress);
      await tester.pumpAndSettle();

      fake.scanError = PlatformException(code: 'x', message: 'boom');
      await open(tester, PhotoJob.compress);
      await tester.pumpAndSettle();
      expect(find.text('JPG · 1.0 KB'), findsOneWidget);
      expect(find.textContaining('Gagal memperbarui daftar foto'), findsOneWidget);
    });
  });
}
