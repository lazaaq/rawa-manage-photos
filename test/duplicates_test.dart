import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/duplicate_page.dart';
import 'package:raw_compressor/duplicates.dart';
import 'package:raw_compressor/native.dart';
import 'package:raw_compressor/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

final _t0 = DateTime(2026, 11, 1, 10);

DupPhoto _p(String id, int hash,
        {int minutes = 0, int w = 4000, int h = 3000, int bytes = 1000, bool fav = false, int modified = 1}) =>
    DupPhoto(
      id: id,
      takenAt: _t0.add(Duration(minutes: minutes)),
      width: w,
      height: h,
      bytes: bytes,
      favorite: fav,
      modified: modified,
      hash: hash,
    );

/// A hash with plenty of set bits (not "low information").
const _base = 0x0F0F_3C3C_55AA_F00F;

int _flip(int h, List<int> bits) => bits.fold(h, (v, b) => v ^ (1 << b));

/// Gallery whose photos and hashes the test controls.
class FakeDupSource implements DuplicateSource {
  FakeDupSource(this.photos, this.hashes);

  final List<DupPhoto> photos;
  final Map<String, int?> hashes;
  bool access = true;
  final List<String> hashed = [];
  final List<List<String>> deleteCalls = [];

  /// null: delete everything asked.
  List<String>? deleteResult;

  @override
  Future<bool> requestAccess() async => access;

  @override
  Future<void> openSettings() async {}

  @override
  Future<List<DupPhoto>> list() async => [
        for (final p in photos)
          DupPhoto(
            id: p.id,
            takenAt: p.takenAt,
            width: p.width,
            height: p.height,
            bytes: p.bytes,
            favorite: p.favorite,
            modified: p.modified,
            name: '${p.id}.JPG',
          ),
      ];

  @override
  Future<int?> hash(DupPhoto photo) async {
    hashed.add(photo.id);
    return hashes[photo.id];
  }

  @override
  Future<List<String>> delete(List<String> ids) async {
    deleteCalls.add(ids);
    return deleteResult ?? ids;
  }

  @override
  Widget image(DupPhoto photo, {required bool large}) => const ColoredBox(color: Colors.grey);
}

void main() {
  group('dHash', () {
    Uint8List gray(List<int> values) => Uint8List.fromList([for (final v in values) ...[v, v, v, 255]]);

    test('bit is 1 where a pixel is brighter than its right neighbour', () {
      // 9x8: every row descending -> all 64 bits set; ascending -> none.
      final desc = gray([for (var y = 0; y < 8; y++) for (var x = 0; x < 9; x++) 200 - x * 10]);
      final asc = gray([for (var y = 0; y < 8; y++) for (var x = 0; x < 9; x++) 10 + x * 10]);
      expect(dHash(desc), -1, reason: 'all 64 bits');
      expect(dHash(asc), 0);
    });

    test('robust to uniform brightness change, hamming counts differing bits', () {
      final a = gray([for (var i = 0; i < 72; i++) (i * 37) % 200]);
      final b = gray([for (var i = 0; i < 72; i++) (i * 37) % 200 + 30]);
      expect(dHash(a), dHash(b));
      expect(hamming(0, -1), 64);
      expect(hamming(_base, _flip(_base, [0, 5, 63])), 3);
    });
  });

  group('findGroups', () {
    test('near-identical photos far apart in time are duplicates; best = largest', () {
      final groups = findGroups([
        _p('orig', _base, w: 4000, h: 3000, bytes: 5000),
        _p('wa', _flip(_base, [3, 40]), minutes: 60 * 24 * 30, w: 1600, h: 1200, bytes: 300),
        _p('other', ~_base, minutes: 5),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.kind, DupKind.duplicate);
      expect(groups.single.photos.map((p) => p.id), ['orig', 'wa']);
      expect(groups.single.suggestedKeep, {'orig'});
    });

    test('similar only when taken close together', () {
      final sim = _flip(_base, [1, 2, 3, 4, 5, 6, 7]); // 7 bits: similar, not duplicate
      final groups = findGroups([
        _p('a', _base),
        _p('b', sim, minutes: 2),
        // Close to a (8 bits) but taken 2 hours later, and far from b: not grouped.
        _p('far', _flip(_base, [20, 21, 22, 23, 24, 25, 26, 27]), minutes: 120),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.kind, DupKind.similar);
      expect(groups.single.photos.map((p) => p.id).toSet(), {'a', 'b'});
    });

    test('different aspect ratio, low-information and unhashed photos are not grouped', () {
      expect(findGroups([_p('land', _base), _p('crop', _base, w: 3000, h: 3000, minutes: 60 * 24)]), isEmpty);
      expect(findGroups([_p('black1', 0), _p('black2', 1, minutes: 60 * 24)]), isEmpty,
          reason: 'blank photos taken far apart are not duplicates');
      expect(findGroups([_p('a', _base), DupPhoto(id: 'b', takenAt: _t0)]), isEmpty);
    });

    test('favourites are kept and ranked first; duplicate groups come before similar', () {
      final groups = findGroups([
        _p('s1', ~_base, minutes: 500),
        _p('s2', _flip(~_base, [1, 2, 3, 4, 5, 6]), minutes: 501),
        _p('big', _base, bytes: 9000),
        _p('fav', _base, minutes: 60 * 24, w: 2000, h: 1500, fav: true),
      ]);
      expect(groups.map((g) => g.kind), [DupKind.duplicate, DupKind.similar]);
      expect(groups.first.best.id, 'fav');
      expect(groups.first.suggestedKeep, {'fav'});
    });
  });

  test('hash cache round trip keeps 64-bit values', () async {
    SharedPreferences.setMockInitialValues({});
    await DupHashCache.save({'a': (-1, 5), 'b': (_base, 7), 'c': (-0x7FFFFFFFFFFFFFFF - 1, 9)});
    expect(await DupHashCache.load(), {'a': (-1, 5), 'b': (_base, 7), 'c': (-0x7FFFFFFFFFFFFFFF - 1, 9)});
  });

  group('DuplicatePage', () {
    late FakeDupSource src;
    late FakePlatform fake;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      fake = FakePlatform()..install();
      RawNative.debugIsAndroid = false;
      src = FakeDupSource([
        _p('orig', 0, bytes: 5 * 1024 * 1024),
        _p('copy', 0, minutes: 60 * 24 * 10, w: 2000, h: 1500, bytes: 1024 * 1024),
        _p('burst1', 0, minutes: 300, bytes: 3 * 1024 * 1024),
        _p('burst2', 0, minutes: 301, bytes: 2 * 1024 * 1024),
        _p('burst3', 0, minutes: 302, bytes: 2 * 1024 * 1024, fav: true),
        _p('lonely', 0, minutes: 900),
      ], {
        'orig': _base,
        'copy': _flip(_base, [10]),
        'burst1': ~_base,
        'burst2': _flip(~_base, [1, 2, 3, 4, 5]),
        'burst3': _flip(~_base, [1, 2, 3, 4, 5, 6]),
        'lonely': 0x1234_5678_9ABC_DEF0,
      });
    });

    tearDown(() {
      fake.uninstall();
      RawNative.debugIsAndroid = null;
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DuplicatePage(source: src)));
      await tester.pumpAndSettle();
    }

    bool kept(WidgetTester tester, String id) =>
        find.descendant(of: find.byKey(ValueKey('dup-$id')), matching: find.byIcon(Icons.check_circle)).evaluate().isNotEmpty;

    testWidgets('groups duplicates and burst shots; suggests what to delete', (tester) async {
      await pump(tester);
      expect(find.text('Semua (2)'), findsOneWidget);
      expect(find.text('Duplikat (1)'), findsOneWidget);
      expect(find.text('Mirip (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('dup-lonely')), findsNothing);
      // orig kept (largest); copy marked. Burst: favourite kept and ranked best, plus nothing else.
      expect(kept(tester, 'orig'), isTrue);
      expect(kept(tester, 'copy'), isFalse);
      expect(kept(tester, 'burst3'), isTrue);
      expect(kept(tester, 'burst1'), isFalse);
      expect(kept(tester, 'burst2'), isFalse);
      expect(find.text('Hapus 3 foto (6.0 MB)'), findsOneWidget);

      await tester.tap(find.text('Mirip (1)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dup-orig')), findsNothing);
      expect(find.byKey(const ValueKey('dup-burst1')), findsOneWidget);
    });

    testWidgets('tap toggles; the last kept photo of a group cannot be marked', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('dup-copy')));
      await tester.pump();
      expect(kept(tester, 'copy'), isTrue);
      expect(find.text('Hapus 2 foto (5.0 MB)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dup-copy')));
      await tester.tap(find.byKey(const ValueKey('dup-orig')));
      await tester.pump();
      expect(kept(tester, 'orig'), isTrue);
      expect(find.text('Sisakan minimal satu foto di setiap grup.'), findsOneWidget);
    });

    testWidgets('delete asks first, removes deleted photos and finished groups', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Hapus 3 foto (6.0 MB)'));
      await tester.pumpAndSettle();
      expect(find.text('Hapus 3 foto?'), findsOneWidget);
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(src.deleteCalls, isEmpty);

      src.deleteResult = ['copy', 'burst1'];
      await tester.tap(find.text('Hapus 3 foto (6.0 MB)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Hapus'));
      await tester.pumpAndSettle();
      expect(src.deleteCalls.single.toSet(), {'copy', 'burst1', 'burst2'});
      expect(find.text('2 foto dihapus, 1 tidak (dibatalkan atau ditolak).'), findsOneWidget);
      expect(find.byKey(const ValueKey('dup-orig')), findsNothing, reason: 'group with one photo left is gone');
      expect(find.byKey(const ValueKey('dup-burst2')), findsOneWidget);
      expect(find.text('Hapus 1 foto (2.0 MB)'), findsOneWidget);
    });

    testWidgets('second scan only hashes new or changed photos', (tester) async {
      await pump(tester);
      expect(src.hashed, hasLength(6));
      src.hashed.clear();
      src.photos[0] = _p('orig', 0, bytes: 5 * 1024 * 1024, modified: 2);
      await tester.tap(find.byTooltip('Pindai ulang'));
      await tester.pumpAndSettle();
      expect(src.hashed, ['orig']);
      expect(find.text('Duplikat (1)'), findsOneWidget);
    });

    testWidgets('long press opens the viewer; Hapus there marks the photo', (tester) async {
      await pump(tester);
      await tester.longPress(find.byKey(const ValueKey('dup-orig')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.textContaining('4000 × 3000'), findsOneWidget);
      await tester.tap(find.text('Hapus').last);
      await tester.pumpAndSettle();
      expect(find.text('Sisakan minimal satu foto di setiap grup.'), findsOneWidget, reason: 'orig is the only kept');

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.text('Simpan').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(kept(tester, 'copy'), isTrue);
    });

    testWidgets('no groups and permission denied messages', (tester) async {
      src = FakeDupSource([_p('a', 0), _p('b', 0, minutes: 60 * 24)], {'a': _base, 'b': ~_base});
      await pump(tester);
      expect(find.text('Tidak ada foto duplikat atau mirip di 2 foto.'), findsOneWidget);

      src = FakeDupSource([], {})..access = false;
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(find.text('Izin galeri dibutuhkan untuk mencari foto duplikat.'), findsOneWidget);
    });
  });
}
