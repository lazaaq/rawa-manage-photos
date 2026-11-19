import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/sort_page.dart';

class FakeSortSource implements SortSource {
  FakeSortSource(int n) : photos = [for (var i = 0; i < n; i++) 'p$i'];

  /// Gallery, newest first. Deleting removes from this list like a real library.
  final List<String> photos;
  bool access = true;
  int settingsOpened = 0;
  final List<(int, int)> ranges = [];
  final List<List<String>> deleteCalls = [];

  /// null -> delete everything requested.
  List<String>? deleteResult;
  Object? deleteError;

  @override
  Future<bool> requestAccess() async => access;

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<int> count() async => photos.length;

  @override
  Future<List<SortPhoto>> loadRange(int start, int count) async {
    ranges.add((start, count));
    final end = (start + count).clamp(0, photos.length);
    if (start >= end) return [];
    return [for (final id in photos.sublist(start, end)) SortPhoto(id: id, date: DateTime(2023, 3, 30))];
  }

  @override
  Future<List<String>> delete(List<String> ids) async {
    deleteCalls.add(ids);
    if (deleteError != null) throw deleteError!;
    final done = deleteResult ?? ids;
    photos.removeWhere(done.contains);
    return done;
  }

  @override
  Widget image(SortPhoto photo, {required bool large}) => Center(child: Text('img-${photo.id}'));
}

Future<FakeSortSource> _pump(WidgetTester tester, FakeSortSource src) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => SortPage(source: src))),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return src;
}

/// Top card shows its image text; the card behind it shows the next one.
void _expectTop(String id) => expect(find.text('img-$id'), findsWidgets);

Future<void> _swipe(WidgetTester tester, {required bool keep}) async {
  await tester.drag(find.byType(Stack).at(1), Offset(keep ? 250 : -250, 0));
  await tester.pumpAndSettle();
}

Future<void> _tapTooltip(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

String _counts(int kept, int marked) => 'Disimpan $kept · Ditandai hapus $marked';

void main() {
  testWidgets('denied permission shows settings button', (tester) async {
    final src = await _pump(tester, FakeSortSource(3)..access = false);
    expect(find.text('Izin galeri dibutuhkan untuk menyortir foto.'), findsOneWidget);
    expect(src.ranges, isEmpty);
    await tester.tap(find.text('Buka Pengaturan'));
    expect(src.settingsOpened, 1);
  });

  testWidgets('empty gallery', (tester) async {
    await _pump(tester, FakeSortSource(0));
    expect(find.text('Tidak ada foto di galeri.'), findsOneWidget);
  });

  testWidgets('load error shows retry', (tester) async {
    final src = _ThrowingSource();
    await _pump(tester, src);
    expect(find.textContaining('boom'), findsOneWidget);
    src.fail = false;
    await tester.tap(find.text('Coba lagi'));
    await tester.pumpAndSettle();
    _expectTop('p0');
  });

  testWidgets('drag right keeps, drag left marks, short drag snaps back', (tester) async {
    await _pump(tester, FakeSortSource(5));
    _expectTop('p0');
    expect(find.text('1 / 5'), findsOneWidget);

    await tester.drag(find.byType(Stack).at(1), const Offset(40, 0)); // below threshold
    await tester.pumpAndSettle();
    expect(find.text(_counts(0, 0)), findsOneWidget);

    await _swipe(tester, keep: true);
    expect(find.text(_counts(1, 0)), findsOneWidget);
    expect(find.text('2 / 5'), findsOneWidget);

    await _swipe(tester, keep: false);
    expect(find.text(_counts(1, 1)), findsOneWidget);
    expect(find.text('img-p0'), findsNothing);
    expect(find.text('img-p1'), findsNothing);
    _expectTop('p2');
  });

  testWidgets('buttons swipe and undo restores previous photo', (tester) async {
    await _pump(tester, FakeSortSource(5));
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Simpan');
    expect(find.text(_counts(1, 1)), findsOneWidget);
    _expectTop('p2');

    await _tapTooltip(tester, 'Urungkan');
    expect(find.text(_counts(0, 1)), findsOneWidget);
    _expectTop('p1');
    await _tapTooltip(tester, 'Urungkan');
    expect(find.text(_counts(0, 0)), findsOneWidget);
    _expectTop('p0');

    // Undo disabled when nothing to undo; review disabled when nothing marked.
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo)).onPressed, isNull);
    expect(
      tester.widget<IconButton>(find.ancestor(of: find.byType(Badge), matching: find.byType(IconButton))).onPressed,
      isNull,
    );
  });

  testWidgets('nothing is deleted until review is confirmed', (tester) async {
    final src = await _pump(tester, FakeSortSource(4));
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Hapus');
    expect(src.deleteCalls, isEmpty);

    await _tapTooltip(tester, 'Tinjau & hapus');
    expect(find.text('Hapus 3 foto?'), findsOneWidget);

    // Back from review: still marked, nothing deleted.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(src.deleteCalls, isEmpty);
    expect(find.text(_counts(0, 3)), findsOneWidget);
  });

  testWidgets('review: untapped photo is kept, rest deleted', (tester) async {
    final src = await _pump(tester, FakeSortSource(4));
    for (var i = 0; i < 3; i++) {
      await _tapTooltip(tester, 'Hapus');
    }
    await _tapTooltip(tester, 'Tinjau & hapus');
    await tester.tap(find.byKey(const ValueKey('review-p1')));
    await tester.pump();
    expect(find.text('Hapus 2 foto?'), findsOneWidget);

    await tester.tap(find.text('Hapus 2 foto'));
    await tester.pumpAndSettle();
    expect(src.deleteCalls.single, ['p0', 'p2']);
    expect(find.text('2 foto dihapus'), findsOneWidget);
    expect(find.text(_counts(1, 0)), findsOneWidget);
    expect(find.text('4 / 4'), findsOneWidget);
    _expectTop('p3');
  });

  testWidgets('review with everything untapped deletes nothing', (tester) async {
    final src = await _pump(tester, FakeSortSource(3));
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Tinjau & hapus');
    await tester.tap(find.byKey(const ValueKey('review-p0')));
    await tester.pump();
    await tester.tap(find.text('Simpan semua'));
    await tester.pumpAndSettle();
    expect(src.deleteCalls, isEmpty);
    expect(find.text(_counts(1, 0)), findsOneWidget);
  });

  testWidgets('partially refused delete keeps the rest marked', (tester) async {
    final src = FakeSortSource(3)..deleteResult = ['p0'];
    await _pump(tester, src);
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Tinjau & hapus');
    await tester.tap(find.text('Hapus 2 foto'));
    await tester.pumpAndSettle();
    expect(find.text('1 foto dihapus, 1 tidak dihapus (masih ditandai).'), findsOneWidget);
    expect(find.text(_counts(0, 1)), findsOneWidget);
  });

  testWidgets('delete error keeps everything marked', (tester) async {
    final src = FakeSortSource(3)..deleteError = Exception('nope');
    await _pump(tester, src);
    await _tapTooltip(tester, 'Hapus');
    await _tapTooltip(tester, 'Tinjau & hapus');
    await tester.tap(find.text('Hapus 1 foto'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Gagal menghapus'), findsOneWidget);
    expect(find.text(_counts(0, 1)), findsOneWidget);
  });

  testWidgets('finished view: review button, then back to home', (tester) async {
    await _pump(tester, FakeSortSource(2));
    await _tapTooltip(tester, 'Simpan');
    await _tapTooltip(tester, 'Hapus');
    expect(find.text('Semua foto sudah disortir.\nDisimpan 1 · Dihapus 0 · Menunggu dihapus 1'), findsOneWidget);

    await tester.tap(find.text('Tinjau & hapus 1 foto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hapus 1 foto'));
    await tester.pumpAndSettle();
    expect(find.text('Semua foto sudah disortir.\nDisimpan 1 · Dihapus 1'), findsOneWidget);

    await tester.tap(find.text('Kembali ke beranda'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('leaving with marked photos asks first', (tester) async {
    await _pump(tester, FakeSortSource(3));
    await _tapTooltip(tester, 'Hapus');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Keluar tanpa menghapus?'), findsOneWidget);
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();
    expect(find.byType(SortPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keluar'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('leaving without marks needs no confirmation', (tester) async {
    await _pump(tester, FakeSortSource(3));
    await _tapTooltip(tester, 'Simpan');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('pages through a large gallery without skipping after deletes', (tester) async {
    final src = await _pump(tester, FakeSortSource(100));
    expect(src.ranges, [(0, 40)]);

    // Mark 31 -> 9 pending left -> next batch loads.
    for (var i = 0; i < 31; i++) {
      await _tapTooltip(tester, 'Hapus');
    }
    expect(src.ranges.last, (40, 40));

    await _tapTooltip(tester, 'Tinjau & hapus');
    await tester.tap(find.text('Hapus 31 foto'));
    await tester.pumpAndSettle();
    expect(src.photos, hasLength(69));
    await tester.pump(const Duration(seconds: 3)); // let the snackbar leave the buttons
    await tester.pumpAndSettle();

    // 31 earlier items vanished from the gallery, so the next read starts at 80 - 31.
    for (var i = 0; i < 40; i++) {
      await _tapTooltip(tester, 'Simpan');
    }
    expect(src.ranges.last, (49, 40));
    _expectTop('p71');
    expect(find.text('72 / 100'), findsOneWidget);
  });
}

class _ThrowingSource extends FakeSortSource {
  _ThrowingSource() : super(2);
  bool fail = true;

  @override
  Future<int> count() async {
    if (fail) throw Exception('boom');
    return super.count();
  }
}
