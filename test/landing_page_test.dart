import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/compress_page.dart';
import 'package:raw_compressor/jobs.dart';
import 'package:raw_compressor/landing_page.dart';
import 'package:raw_compressor/main.dart';
import 'package:raw_compressor/native.dart';
import 'package:raw_compressor/sort_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

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

  testWidgets('app opens on the landing page without touching the gallery', (tester) async {
    await tester.pumpWidget(const RawCompressorApp());
    await tester.pumpAndSettle();
    expect(find.byType(LandingPage), findsOneWidget);
    expect(find.text('Kompres RAW'), findsOneWidget);
    expect(find.text('Sortir Foto'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });

  testWidgets('Kompres RAW opens the compress page and back returns', (tester) async {
    await tester.pumpWidget(const RawCompressorApp());
    await tester.tap(find.text('Kompres RAW'));
    await tester.pumpAndSettle();
    expect(find.byType(CompressPage), findsOneWidget);
    expect(fake.callsOf('scanRaw'), hasLength(1));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(LandingPage), findsOneWidget);
  });

  testWidgets('Sortir Foto opens the sort page', (tester) async {
    await tester.pumpWidget(const RawCompressorApp());
    await tester.tap(find.text('Sortir Foto'));
    await tester.pumpAndSettle();
    expect(find.byType(SortPage), findsOneWidget);
    expect(fake.callsOf('requestPermissionExtend'), hasLength(1));
  });

  testWidgets('four feature icons sit side by side in one row', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const RawCompressorApp());
    final names = ['Kompres RAW', 'Kompres Foto', 'Ubah Format', 'Sortir Foto'];
    final ys = {for (final n in names) tester.getCenter(find.text(n)).dy};
    expect(ys, hasLength(1), reason: 'same row');
    final xs = [for (final n in names) tester.getCenter(find.text(n)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(find.byType(FeatureIcon), findsNWidgets(4));
  });

  for (final (label, job) in [('Kompres Foto', PhotoJob.compress), ('Ubah Format', PhotoJob.convert)]) {
    testWidgets('$label opens the image page for $job', (tester) async {
      await tester.pumpWidget(const RawCompressorApp());
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.widget<CompressPage>(find.byType(CompressPage)).job, job);
      expect(fake.callsOf('scanImages'), hasLength(1));
    });
  }
}
