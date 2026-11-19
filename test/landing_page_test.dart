import 'package:flutter_test/flutter_test.dart';
import 'package:raw_compressor/compress_page.dart';
import 'package:raw_compressor/landing_page.dart';
import 'package:raw_compressor/main.dart';
import 'package:raw_compressor/native.dart';
import 'package:raw_compressor/sort_page.dart';

import 'fakes.dart';

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
}
