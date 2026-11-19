import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/compress_page.dart';
import 'package:raw_compressor/jobs.dart';
import 'package:raw_compressor/native.dart';
import 'package:raw_compressor/process_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _mb = 1024 * 1024;

Future<void> _pump(WidgetTester tester, PhotoJob job) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: CompressPage(job: job)));
  await tester.pumpAndSettle();
}

/// Select [tiles] and open the options sheet (the only button in the bottom bar).
Future<void> _openSheet(WidgetTester tester, List<String> tiles) async {
  for (final t in tiles) {
    await tester.tap(find.text(t));
  }
  await tester.pump();
  await tester.tap(find.byType(FilledButton).last);
  await tester.pumpAndSettle();
}

String _summary(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('summary'))).data!;

Future<String> _mulai(WidgetTester tester) async {
  final text = _summary(tester);
  await tester.tap(find.text('Mulai'));
  await tester.pumpAndSettle();
  return text;
}

Future<String> _start(WidgetTester tester, List<String> tiles) async {
  await _openSheet(tester, tiles);
  return _mulai(tester);
}

void _expectStat(String label, String value) {
  final row = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
  expect(find.descendant(of: row, matching: find.text(value)), findsOneWidget, reason: label);
}

Future<void> _choose(WidgetTester tester, Key key, String item) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
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

  group('Kompres Foto', () {
    setUp(() {
      fake.images = [photo('1', 'IMG_1.HEIC', 3 * _mb), photo('2', 'IMG_2.JPG', 5 * _mb), photo('3', 'S.PNG', 1 * _mb)];
    });

    testWidgets('lists gallery photos (not RAW) with compress defaults', (tester) async {
      await _pump(tester, PhotoJob.compress);
      expect(fake.callsOf('scanImages'), hasLength(1));
      expect(fake.callsOf('scanRaw'), isEmpty);
      expect(find.text('Kompres Foto (3)'), findsOneWidget);
      expect(find.text('HEIC · 3.0 MB'), findsOneWidget);
      expect(find.byType(Slider), findsNothing, reason: 'options only in the sheet');
      await _openSheet(tester, ['HEIC · 3.0 MB']);
      expect(find.byKey(const ValueKey('format')), findsNothing);
      expect(find.text('3000 px'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
      expect(find.text('Hapus foto asli setelah kompres'), findsOneWidget);
    });

    testWidgets('sends same-format, only-if-smaller convert and replaces originals', (tester) async {
      await _pump(tester, PhotoJob.compress);
      final dialog = await _start(tester, ['HEIC · 3.0 MB', 'JPG · 5.0 MB']);
      expect(dialog, contains('dikompres ulang dengan format yang sama'));
      expect(dialog, contains('Foto yang hasilnya tidak lebih kecil dilewati'));
      expect(dialog, contains('Live Photo menjadi foto biasa.'));
      expect(dialog, isNot(contains('HEIC menjadi JPG')));

      expect(find.byType(ProcessPage), findsOneWidget);
      expect(fake.callsOf('convert').map((c) => c.arguments), [
        for (final id in ['1', '2'])
          {
            'id': id, 'quality': 80, 'maxSide': 3000, 'target': 'gallery',
            'source': 'image', 'format': 'same', 'onlyIfSmaller': true,
          },
      ]);
      expect((fake.callsOf('deleteWithIds').single.arguments as Map)['ids'], ['1', '2']);
      _expectStat('Ukuran asli', '20.0 MB');
      _expectStat('Asli dihapus', '2');
    });

    testWidgets('photo whose result is not smaller is skipped and kept', (tester) async {
      fake.convertResults['3'] = {'newId': '', 'inBytes': _mb, 'outBytes': _mb, 'skipped': true};
      await _pump(tester, PhotoJob.compress);
      await _start(tester, ['PNG · 1.0 MB', 'HEIC · 3.0 MB']);
      _expectStat('Dilewati (hasil tidak lebih kecil)', '1');
      _expectStat('Berhasil', '1');
      expect((fake.callsOf('deleteWithIds').single.arguments as Map)['ids'], ['1']);
    });

    testWidgets('all skipped: nothing deleted, no savings row', (tester) async {
      fake.convertResults['3'] = {'newId': '', 'inBytes': _mb, 'outBytes': _mb, 'skipped': true};
      await _pump(tester, PhotoJob.compress);
      await _start(tester, ['PNG · 1.0 MB']);
      expect(fake.callsOf('deleteWithIds'), isEmpty);
      expect(find.text('Hemat'), findsNothing);
    });

    testWidgets('Android: dialog says HEIC becomes JPG, no Live Photo note', (tester) async {
      RawNative.debugIsAndroid = true;
      fake.legacyDeleteResult = null;
      await _pump(tester, PhotoJob.compress);
      final dialog = await _start(tester, ['HEIC · 3.0 MB']);
      expect(dialog, contains('HEIC menjadi JPG'));
      expect(dialog, isNot(contains('Live Photo')));
    });

    testWidgets('delete failure names photos, not RAW', (tester) async {
      fake.deleteResult = [];
      await _pump(tester, PhotoJob.compress);
      await _start(tester, ['HEIC · 3.0 MB']);
      expect(find.textContaining('1 foto tidak dihapus'), findsOneWidget);
      expect(find.textContaining('Foto hasil tetap tersimpan'), findsOneWidget);
    });

    testWidgets('empty gallery message', (tester) async {
      fake.images = [];
      await _pump(tester, PhotoJob.compress);
      expect(find.text('Tidak ada foto di galeri.'), findsOneWidget);
    });

    testWidgets('permission denied message', (tester) async {
      fake.permission = 2;
      await _pump(tester, PhotoJob.compress);
      expect(find.text('Izin galeri dibutuhkan untuk memilih foto.'), findsOneWidget);
    });
  });

  group('Ubah Format', () {
    setUp(() {
      fake.images = [
        photo('1', 'IMG_1.HEIC', 3 * _mb),
        photo('2', 'IMG_2.JPG', 5 * _mb),
        photo('3', 'S.PNG', 1 * _mb),
        photo('4', 'IMG_4.heif', 2 * _mb),
      ];
    });

    testWidgets('grid shows every photo; options only after selecting', (tester) async {
      await _pump(tester, PhotoJob.convert);
      expect(find.text('Ubah Format (4)'), findsOneWidget);
      expect(find.byKey(const ValueKey('format')), findsNothing);
      expect(find.text('Pilih foto untuk diubah'), findsOneWidget);
      await tester.tap(find.text('HEIC · 3.0 MB'));
      await tester.pump();
      expect(find.text('Ubah 1 foto (3.0 MB)'), findsOneWidget);
    });

    testWidgets('defaults to JPG at original size and keeps originals', (tester) async {
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['HEIC · 3.0 MB', 'HEIF · 2.0 MB']);
      expect(find.text('Ubah 2 foto ke JPG?'), findsOneWidget);
      expect(find.text('Asli'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);

      final summary = await _mulai(tester);
      expect(summary, contains('diubah ke JPG (kualitas 90, ukuran Asli)'));
      expect(summary, contains('Foto asli tetap disimpan.'));
      expect(fake.callsOf('convert').map((c) => c.arguments), [
        for (final id in ['1', '4'])
          {
            'id': id, 'quality': 90, 'maxSide': 0, 'target': 'gallery',
            'source': 'image', 'format': 'jpeg', 'onlyIfSmaller': false,
          },
      ]);
      expect(fake.callsOf('deleteWithIds'), isEmpty);
      expect(find.text('Asli dihapus'), findsNothing);
    });

    testWidgets('selected photos already in the target format are skipped', (tester) async {
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['HEIC · 3.0 MB', 'JPG · 5.0 MB']);
      expect(find.text('Ubah 1 foto ke JPG?'), findsOneWidget);
      expect(_summary(tester), contains('1 foto sudah berformat JPG dan dilewati.'));
      await _mulai(tester);
      expect(fake.callsOf('convert').map((c) => (c.arguments as Map)['id']), ['1']);
    });

    testWidgets('only same-format photos selected: Mulai disabled until format changes', (tester) async {
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['JPG · 5.0 MB']);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Mulai')).onPressed, isNull);
      await _choose(tester, const ValueKey('format'), 'PNG');
      expect(find.text('Ubah 1 foto ke PNG?'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Mulai')).onPressed, isNotNull);
    });

    testWidgets('iOS targets: JPG, HEIC, PNG; PNG hides quality', (tester) async {
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['JPG · 5.0 MB', 'PNG · 1.0 MB']);
      await tester.tap(find.byKey(const ValueKey('format')));
      await tester.pumpAndSettle();
      expect(find.text('HEIC'), findsOneWidget);
      expect(find.text('WEBP'), findsNothing);
      await tester.tap(find.text('PNG').last);
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsNothing);
      expect(find.text('Ubah 1 foto ke PNG?'), findsOneWidget, reason: 'PNG photo skipped');
      final summary = await _mulai(tester);
      expect(summary, contains('diubah ke PNG (ukuran Asli)'));
      expect(fake.callsOf('convert').single.arguments, containsPair('format', 'png'));
      expect(fake.callsOf('convert').single.arguments, containsPair('id', '2'));
    });

    testWidgets('Android targets: JPG, PNG, WEBP (no HEIC)', (tester) async {
      RawNative.debugIsAndroid = true;
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['HEIC · 3.0 MB']);
      await tester.tap(find.byKey(const ValueKey('format')));
      await tester.pumpAndSettle();
      expect(find.text('WEBP'), findsOneWidget);
      expect(find.text('HEIC'), findsNothing);
    });

    testWidgets('bigger result is reported, not shown as savings', (tester) async {
      fake.convertResults['1'] = {'newId': 'n', 'inBytes': 3 * _mb, 'outBytes': 9 * _mb};
      await _pump(tester, PhotoJob.convert);
      await _start(tester, ['HEIC · 3.0 MB']);
      expect(find.text('Hemat'), findsNothing);
      _expectStat('Bertambah', '6.0 MB');
    });

    testWidgets('format choice is remembered separately from other features', (tester) async {
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['PNG · 1.0 MB']);
      await _choose(tester, const ValueKey('format'), 'HEIC');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('convert.format'), 'heic');
      expect(p.getInt('convert.maxSide'), 0);
      expect(p.getInt('compress.maxSide'), isNull, reason: 'RAW settings untouched');
    });

    testWidgets('restores saved format; unsupported saved format falls back to JPG', (tester) async {
      SharedPreferences.setMockInitialValues({'convert.format': 'png'});
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['HEIC · 3.0 MB']);
      expect(find.text('Ubah 1 foto ke PNG?'), findsOneWidget);

      RawNative.debugIsAndroid = true;
      SharedPreferences.setMockInitialValues({'convert.format': 'heic'});
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, PhotoJob.convert);
      await _openSheet(tester, ['HEIC · 3.0 MB']);
      expect(find.text('Ubah 1 foto ke JPG?'), findsOneWidget);
    });

    testWidgets('scan error shows retry', (tester) async {
      fake.scanError = PlatformException(code: 'x', message: 'boom');
      await _pump(tester, PhotoJob.convert);
      expect(find.textContaining('boom'), findsOneWidget);
    });
  });
}
