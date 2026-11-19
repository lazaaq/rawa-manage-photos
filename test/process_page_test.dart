import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/native.dart';
import 'package:raw_compressor/process_page.dart';

import 'fakes.dart';

const _mb = 1024 * 1024;

final _items = [
  RawPhoto(id: '1', name: 'A.CR3', size: 30 * _mb),
  RawPhoto(id: '2', name: 'B.CR3', size: 31 * _mb),
  RawPhoto(id: '3', name: 'C.CR3', size: 32 * _mb),
];

/// Pushes ProcessPage on top of a root route, like the app does.
Future<void> _open(WidgetTester tester, {List<RawPhoto>? items, bool deleteOriginal = true}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProcessPage(
                items: items ?? _items,
                quality: 85,
                maxSide: 4096,
                deleteOriginal: deleteOriginal,
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _expectStat(String label, String value) {
  final row = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
  expect(find.descendant(of: row, matching: find.text(value)), findsOneWidget, reason: '$label = $value');
}

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

  testWidgets('converts all, deletes originals, shows savings', (tester) async {
    await _open(tester);
    await tester.pumpAndSettle();

    expect(find.text('Selesai'), findsOneWidget);
    expect(find.text('3 foto diproses'), findsOneWidget);
    expect(fake.callsOf('convert').map((c) => (c.arguments as Map)['id']), ['1', '2', '3']);
    expect(fake.callsOf('convert').first.arguments, {'id': '1', 'quality': 85, 'maxSide': 4096});
    _expectStat('Berhasil', '3');
    _expectStat('Gagal', '0');
    _expectStat('Ukuran RAW', '30.0 MB');
    _expectStat('Ukuran JPG', '6.0 MB');
    _expectStat('Hemat', '24.0 MB (80%)');
    _expectStat('RAW dihapus', '3');
    expect((fake.callsOf('deleteWithIds').single.arguments as Map)['ids'], ['1', '2', '3']);
  });

  testWidgets('failed photos are listed and never deleted', (tester) async {
    fake.convertResults['2'] = PlatformException(code: 'convert_failed', message: 'Format RAW tidak didukung');
    await _open(tester);
    await tester.pumpAndSettle();

    _expectStat('Berhasil', '2');
    _expectStat('Gagal', '1');
    expect(find.text('Gagal dikonversi'), findsOneWidget);
    expect(find.text('B.CR3'), findsOneWidget);
    expect(find.text('Format RAW tidak didukung'), findsOneWidget);
    expect((fake.callsOf('deleteWithIds').single.arguments as Map)['ids'], ['1', '3']);
  });

  testWidgets('failures with the same file name are all reported', (tester) async {
    final dupes = [
      RawPhoto(id: '1', name: 'IMG_0001.CR3', size: 10),
      RawPhoto(id: '2', name: 'IMG_0001.CR3', size: 10),
    ];
    fake.convertResults['1'] = PlatformException(code: 'x', message: 'err 1');
    fake.convertResults['2'] = PlatformException(code: 'x', message: 'err 2');
    await _open(tester, items: dupes);
    await tester.pumpAndSettle();

    _expectStat('Gagal', '2');
    expect(find.text('err 1'), findsOneWidget);
    expect(find.text('err 2'), findsOneWidget);
  });

  testWidgets('nothing is deleted when every conversion fails', (tester) async {
    for (final p in _items) {
      fake.convertResults[p.id] = PlatformException(code: 'x', message: 'no');
    }
    await _open(tester);
    await tester.pumpAndSettle();

    _expectStat('Berhasil', '0');
    _expectStat('Gagal', '3');
    expect(fake.callsOf('deleteWithIds'), isEmpty);
    expect(find.text('RAW dihapus'), findsOneWidget);
    _expectStat('RAW dihapus', '0');
  });

  testWidgets('keeps originals when deleteOriginal is off', (tester) async {
    await _open(tester, deleteOriginal: false);
    await tester.pumpAndSettle();

    _expectStat('Berhasil', '3');
    expect(fake.callsOf('deleteWithIds'), isEmpty);
    expect(fake.callsOf('deleteLegacy'), isEmpty);
    expect(find.text('RAW dihapus'), findsNothing);
  });

  testWidgets('reports originals kept when the user declines the system delete dialog', (tester) async {
    fake.deleteResult = [];
    await _open(tester);
    await tester.pumpAndSettle();

    _expectStat('RAW dihapus', '0');
    expect(find.textContaining('3 RAW tidak dihapus'), findsOneWidget);
    expect(find.textContaining('JPG hasil tetap tersimpan'), findsOneWidget);
  });

  testWidgets('reports partial delete', (tester) async {
    fake.deleteResult = ['1'];
    await _open(tester);
    await tester.pumpAndSettle();

    _expectStat('RAW dihapus', '1');
    expect(find.textContaining('2 RAW tidak dihapus'), findsOneWidget);
  });

  testWidgets('shows delete error', (tester) async {
    fake.deleteError = PlatformException(code: 'x', message: 'deleteWithIds failed');
    await _open(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Gagal menghapus RAW'), findsOneWidget);
    expect(find.text('Selesai'), findsOneWidget);
  });

  testWidgets('Android 9 uses native legacy delete instead of photo_manager', (tester) async {
    RawNative.debugIsAndroid = true;
    fake.legacyDeleteResult = ['1', '2', '3'];
    await _open(tester);
    await tester.pumpAndSettle();

    expect(fake.callsOf('deleteLegacy').single.arguments, {'ids': ['1', '2', '3']});
    expect(fake.callsOf('deleteWithIds'), isEmpty);
    _expectStat('RAW dihapus', '3');
  });

  testWidgets('Android 10+ falls back to photo_manager delete', (tester) async {
    RawNative.debugIsAndroid = true;
    fake.legacyDeleteResult = null;
    await _open(tester);
    await tester.pumpAndSettle();

    expect(fake.callsOf('deleteLegacy'), hasLength(1));
    expect(fake.callsOf('deleteWithIds'), hasLength(1));
  });

  testWidgets('falls back to listed size when native reports 0 input bytes', (tester) async {
    for (final p in _items) {
      fake.convertResults[p.id] = {'newId': 'n', 'inBytes': 0, 'outBytes': _mb};
    }
    await _open(tester);
    await tester.pumpAndSettle();

    _expectStat('Ukuran RAW', '93.0 MB');
  });

  testWidgets('progress, stop button and back-blocking while converting', (tester) async {
    final gate = ConvertGate();
    fake.convertGate = gate.call;
    await _open(tester);
    await tester.pump();

    expect(find.text('Mengompres…'), findsOneWidget);
    expect(find.text('Foto 1 dari 3: A.CR3'), findsOneWidget);
    expect(find.text('Tutup'), findsNothing);

    // System back is ignored while working.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ProcessPage), findsOneWidget);

    gate.release('1');
    await tester.pump();
    await tester.pump();
    expect(find.text('Foto 2 dari 3: B.CR3'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(1 / 3, 1e-9));

    await tester.tap(find.text('Hentikan'));
    await tester.pump();
    expect(find.text('Menghentikan…'), findsOneWidget);

    gate.release('2');
    await tester.pumpAndSettle();

    expect(fake.callsOf('convert'), hasLength(2), reason: 'third photo must not start');
    expect(find.text('Dihentikan: 2 dari 3 foto diproses'), findsOneWidget);
    _expectStat('Berhasil', '2');
    expect((fake.callsOf('deleteWithIds').single.arguments as Map)['ids'], ['1', '2']);

    await tester.tap(find.text('Tutup'));
    await tester.pumpAndSettle();
    expect(find.byType(ProcessPage), findsNothing);
  });
}
