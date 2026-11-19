import 'package:flutter/material.dart';

import 'compress_page.dart';
import 'jobs.dart';
import 'sort_page.dart';

/// Satu fitur di beranda.
class Feature {
  const Feature(this.title, this.icon, this.color, this.page);

  final String title;
  final IconData icon;
  final Color color;
  final Widget Function() page;
}

final kFeatures = <Feature>[
  Feature('Kompres RAW', Icons.raw_on, Colors.teal, () => const CompressPage()),
  Feature('Kompres Foto', Icons.photo_size_select_large, Colors.indigo,
      () => const CompressPage(job: PhotoJob.compress)),
  Feature('Ubah Format', Icons.transform, Colors.purple, () => const CompressPage(job: PhotoJob.convert)),
  Feature('Sortir Foto', Icons.swipe, Colors.deepOrange, () => const SortPage()),
];

/// Beranda: ikon kecil berjajar untuk setiap fitur.
class LandingPage extends StatelessWidget {
  const LandingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 24), children: [
          Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset('assets/branding/icon_source.jpg', width: 64, height: 64, fit: BoxFit.cover),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('rawa', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text('Rapikan galeri foto Anda', style: theme.textTheme.bodyMedium),
              ]),
            ),
          ]),
          const SizedBox(height: 32),
          Text('Fitur', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, box) {
            // 4 ikon per baris di HP; lebih banyak di layar lebar.
            final perRow = (box.maxWidth / 88).floor().clamp(4, 8);
            final w = box.maxWidth / perRow;
            return Wrap(
              runSpacing: 16,
              children: [for (final f in kFeatures) SizedBox(width: w, child: FeatureIcon(feature: f))],
            );
          }),
          const SizedBox(height: 32),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Flexible(
              child: Text('Semua diproses di perangkat, tanpa internet.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class FeatureIcon extends StatelessWidget {
  const FeatureIcon({super.key, required this.feature});

  final Feature feature;

  @override
  Widget build(BuildContext context) {
    final f = feature;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => f.page())),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: f.color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
            child: Icon(f.icon, size: 28, color: f.color),
          ),
          const SizedBox(height: 6),
          Text(
            f.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ]),
      ),
    );
  }
}
