import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/compress_page.dart';
import 'package:raw_compressor/native.dart';
import 'package:raw_compressor/process_page.dart';

import 'fakes.dart';

const _mb = 1024 * 1024;

Future<void> _pumpCompress(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: CompressPage()));
  await tester.pumpAndSettle();
}

/// Tile label is `EXT · size`; sizes in tests are unique so labels are too.
Finder _tile(String label) => find.text(label);

FilledButton _compressButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byWidgetPredicate((w) => w is FilledButton).last);

void main() {
  late FakePlatform fake;

  setUp(() {
    fake = FakePlatform()..install();
    RawNative.debugIsAndroid = false;
  });

  tearDown(() {
    fake.uninstall();
    RawNative.debugIsAndroid = null;
  });

  testWidgets('asks for permission and shows settings button when denied', (tester) async {
    fake.permission = 2; // denied
    await _pumpCompress(tester);

    expect(find.text('Izin galeri dibutuhkan untuk menemukan foto RAW.'), findsOneWidget);
    expect(fake.callsOf('scanRaw'), isEmpty);
    final req = fake.callsOf('requestPermissionExtend').single.arguments as Map;
    expect((req['androidPermission'] as Map)['mediaLocation'], isTrue);

    await tester.tap(find.text('Buka Pengaturan'));
    await tester.pump();
    expect(fake.callsOf('openSetting'), hasLength(1));
  });

  testWidgets('limited access still scans', (tester) async {
    fake.permission = 4; // limited (iOS)
    fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
    await _pumpCompress(tester);
    expect(find.text('Foto RAW (1)'), findsOneWidget);
  });

  testWidgets('empty library', (tester) async {
    await _pumpCompress(tester);
    expect(find.text('Tidak ada foto RAW di galeri.'), findsOneWidget);
    expect(find.text('Foto RAW (0)'), findsOneWidget);
    expect(find.byType(Slider), findsNothing, reason: 'no bottom bar without photos');
  });

  testWidgets('scan error shows message and retry works', (tester) async {
    fake.scanError = PlatformException(code: 'x', message: 'scan rusak');
    await _pumpCompress(tester);
    expect(find.textContaining('scan rusak'), findsOneWidget);

    fake.scanError = null;
    fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
    await tester.tap(find.text('Coba lagi'));
    await tester.pumpAndSettle();
    expect(find.text('Foto RAW (1)'), findsOneWidget);
  });

  testWidgets('lists photos with extension and size; non-gallery files fall back to icon', (tester) async {
    fake.photos = [
      photo('1', '3U2A6708.CR3', 30177426),
      photo('2', 'IMG_1.dng', 25 * _mb),
    ];
    await _pumpCompress(tester);

    expect(find.text('Foto RAW (2)'), findsOneWidget);
    expect(_tile('CR3 · 28.8 MB'), findsOneWidget);
    expect(_tile('DNG · 25.0 MB'), findsOneWidget);
    expect(find.byIcon(Icons.raw_on), findsNWidgets(2));
  });

  testWidgets('selection, select-all and button state', (tester) async {
    fake.photos = [photo('1', 'A.CR3', 10 * _mb), photo('2', 'B.CR3', 20 * _mb), photo('3', 'C.NEF', 30 * _mb)];
    await _pumpCompress(tester);

    expect(_compressButton(tester).onPressed, isNull);
    expect(find.text('Pilih foto untuk dikompres'), findsOneWidget);

    await tester.tap(_tile('CR3 · 10.0 MB'));
    await tester.pump();
    expect(find.text('1 dipilih'), findsOneWidget);
    expect(find.text('Kompres 1 foto (10.0 MB)'), findsOneWidget);
    expect(_compressButton(tester).onPressed, isNotNull);

    await tester.tap(_tile('NEF · 30.0 MB'));
    await tester.pump();
    expect(find.text('Kompres 2 foto (40.0 MB)'), findsOneWidget);

    await tester.tap(_tile('CR3 · 10.0 MB'));
    await tester.pump();
    expect(find.text('Kompres 1 foto (30.0 MB)'), findsOneWidget);

    await tester.tap(find.byTooltip('Pilih semua'));
    await tester.pump();
    expect(find.text('3 dipilih'), findsOneWidget);
    expect(find.text('Kompres 3 foto (60.0 MB)'), findsOneWidget);

    await tester.tap(find.byTooltip('Batalkan semua'));
    await tester.pump();
    expect(find.text('Foto RAW (3)'), findsOneWidget);
    expect(_compressButton(tester).onPressed, isNull);
  });

  testWidgets('cancel in confirm dialog converts nothing', (tester) async {
    fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
    await _pumpCompress(tester);
    await tester.tap(_tile('CR3 · 10.0 MB'));
    await tester.pump();
    await tester.tap(find.text('Kompres 1 foto (10.0 MB)'));
    await tester.pumpAndSettle();

    expect(find.text('Kompres 1 foto?'), findsOneWidget);
    expect(find.textContaining('kualitas 85, ukuran 4096 px'), findsOneWidget);
    expect(find.textContaining('file RAW asli akan DIHAPUS'), findsOneWidget);

    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();
    expect(fake.callsOf('convert'), isEmpty);
    expect(find.text('1 dipilih'), findsOneWidget);
  });

  testWidgets('full flow: options, convert selected only, delete, rescan', (tester) async {
    fake.photos = [photo('1', 'A.CR3', 10 * _mb), photo('2', 'B.CR3', 20 * _mb), photo('3', 'C.CR3', 30 * _mb)];
    await _pumpCompress(tester);

    // Size option -> "Asli" (maxSide 0).
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Asli').last);
    await tester.pumpAndSettle();

    await tester.tap(_tile('CR3 · 30.0 MB'));
    await tester.tap(_tile('CR3 · 10.0 MB'));
    await tester.pump();
    await tester.tap(find.text('Kompres 2 foto (40.0 MB)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ukuran Asli'), findsOneWidget);
    await tester.tap(find.text('Mulai'));
    await tester.pumpAndSettle();

    expect(find.byType(ProcessPage), findsOneWidget);
    // Order follows the library list, not the tap order.
    expect(fake.callsOf('convert').map((c) => c.arguments),
        [
          {'id': '1', 'quality': 85, 'maxSide': 0, 'target': 'gallery'},
          {'id': '3', 'quality': 85, 'maxSide': 0, 'target': 'gallery'},
        ]);
    expect((fake.callsOf('deleteWithIds').single.arguments as Map)['ids'], ['1', '3']);

    fake.photos = [photo('2', 'B.CR3', 20 * _mb)];
    await tester.tap(find.text('Tutup'));
    await tester.pumpAndSettle();

    expect(fake.callsOf('scanRaw'), hasLength(2), reason: 'rescan after processing');
    expect(find.text('Foto RAW (1)'), findsOneWidget, reason: 'selection cleared, list refreshed');
  });

  testWidgets('quality slider value is sent to native', (tester) async {
    fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
    await _pumpCompress(tester);

    final slider = find.byType(Slider);
    await tester.tap(slider, warnIfMissed: false); // centre of 50..100 -> 75
    await tester.pump();
    final q = tester.widget<Slider>(slider).value.round();
    expect(q, inInclusiveRange(70, 80));

    await tester.tap(_tile('CR3 · 10.0 MB'));
    await tester.pump();
    await tester.tap(find.text('Kompres 1 foto (10.0 MB)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mulai'));
    await tester.pumpAndSettle();

    expect((fake.callsOf('convert').single.arguments as Map)['quality'], q);
  });

  testWidgets('delete switch off keeps originals', (tester) async {
    fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
    await _pumpCompress(tester);

    await tester.tap(find.text('Hapus RAW asli setelah konversi'));
    await tester.pump();
    await tester.tap(_tile('CR3 · 10.0 MB'));
    await tester.pump();
    await tester.tap(find.text('Kompres 1 foto (10.0 MB)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('File RAW asli tetap disimpan.'), findsOneWidget);

    await tester.tap(find.text('Mulai'));
    await tester.pumpAndSettle();
    expect(fake.callsOf('convert'), hasLength(1));
    expect(fake.callsOf('deleteWithIds'), isEmpty);
  });

  group('save location', () {
    Future<void> openTargets(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('save-target')));
      await tester.pumpAndSettle();
    }

    Future<Map> convertOne(WidgetTester tester) async {
      await tester.tap(_tile('CR3 · 10.0 MB'));
      await tester.pump();
      await tester.tap(find.text('Kompres 1 foto (10.0 MB)'));
      await tester.pumpAndSettle();
      final dialog = tester.widget<Text>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)).at(1));
      await tester.tap(find.text('Mulai'));
      await tester.pumpAndSettle();
      return {'dialog': dialog.data, 'args': fake.callsOf('convert').single.arguments};
    }

    testWidgets('defaults to internal gallery', (tester) async {
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      await _pumpCompress(tester);
      expect(find.text('Galeri internal'), findsOneWidget);
      final r = await convertOne(tester);
      expect(r['dialog'], contains('Disimpan ke: Galeri internal.'));
      expect((r['args'] as Map)['target'], 'gallery');
    });

    testWidgets('same-folder option only on Android', (tester) async {
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      await _pumpCompress(tester);
      await openTargets(tester);
      expect(find.text('Folder yang sama dengan RAW'), findsNothing);
      expect(find.text('Pilih folder…'), findsOneWidget);
    });

    testWidgets('Android: same folder is sent to native', (tester) async {
      RawNative.debugIsAndroid = true;
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      await _pumpCompress(tester);
      await openTargets(tester);
      await tester.tap(find.text('Folder yang sama dengan RAW').last);
      await tester.pumpAndSettle();
      final r = await convertOne(tester);
      expect((r['args'] as Map)['target'], 'sameFolder');
    });

    testWidgets('cancelled folder picker keeps gallery', (tester) async {
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      await _pumpCompress(tester);
      await openTargets(tester);
      await tester.tap(find.text('Pilih folder…').last);
      await tester.pumpAndSettle();
      expect(fake.callsOf('pickFolder'), hasLength(1));
      expect(find.text('Galeri internal'), findsOneWidget);
      expect(find.byTooltip('Ganti folder'), findsNothing);
    });

    testWidgets('picked folder is used and can be changed', (tester) async {
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      fake.pickFolderResult = 'Kompres';
      await _pumpCompress(tester);
      await openTargets(tester);
      await tester.tap(find.text('Pilih folder…').last);
      await tester.pumpAndSettle();
      expect(find.text('Folder: Kompres'), findsOneWidget);

      fake.pickFolderResult = 'Arsip';
      await tester.tap(find.byTooltip('Ganti folder'));
      await tester.pumpAndSettle();
      expect(find.text('Folder: Arsip'), findsOneWidget);

      final r = await convertOne(tester);
      expect(r['dialog'], contains('Disimpan ke: Folder: Arsip.'));
      expect((r['args'] as Map)['target'], 'folder');
    });

    testWidgets('remembered folder is offered without opening the picker', (tester) async {
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      fake.savedFolder = 'Lama';
      await _pumpCompress(tester);
      expect(find.text('Galeri internal'), findsOneWidget, reason: 'default stays gallery');
      await openTargets(tester);
      await tester.tap(find.text('Folder: Lama').last);
      await tester.pumpAndSettle();
      expect(fake.callsOf('pickFolder'), isEmpty);
      final r = await convertOne(tester);
      expect((r['args'] as Map)['target'], 'folder');
    });

    testWidgets('picker error shows message and keeps gallery', (tester) async {
      fake.photos = [photo('1', 'A.CR3', 10 * _mb)];
      fake.pickFolderResult = PlatformException(code: 'no_picker', message: 'Pemilih folder tidak tersedia');
      await _pumpCompress(tester);
      await openTargets(tester);
      await tester.tap(find.text('Pilih folder…').last);
      await tester.pumpAndSettle();
      expect(find.text('Pemilih folder tidak tersedia'), findsOneWidget);
      expect(find.text('Galeri internal'), findsOneWidget);
    });
  });
}
