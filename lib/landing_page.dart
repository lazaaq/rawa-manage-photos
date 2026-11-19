import 'package:flutter/material.dart';

import 'compress_page.dart';
import 'sort_page.dart';

/// Beranda: pintu masuk ke setiap fitur.
class LandingPage extends StatelessWidget {
  const LandingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
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
          const SizedBox(height: 28),
          FeatureCard(
            icon: Icons.compress,
            color: Colors.teal,
            title: 'Kompres RAW',
            description: 'Ubah foto RAW (CR3, DNG, NEF, ARW, …) jadi JPG berukuran normal. '
                'RAW asli bisa langsung dihapus untuk menghemat ruang.',
            onTap: () => open(const CompressPage()),
          ),
          const SizedBox(height: 16),
          FeatureCard(
            icon: Icons.swipe,
            color: Colors.deepOrange,
            title: 'Sortir Foto',
            description: 'Geser kanan untuk simpan, geser kiri untuk hapus. '
                'Semua yang ditandai ditinjau dulu sebelum benar-benar dihapus.',
            onTap: () => open(const SortPage()),
          ),
          const SizedBox(height: 28),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Text('Semua diproses di perangkat, tanpa internet.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          ]),
        ]),
      ),
    );
  }
}

class FeatureCard extends StatelessWidget {
  const FeatureCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(18)),
              child: Icon(icon, size: 34, color: color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(description, style: theme.textTheme.bodySmall),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
