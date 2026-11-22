import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'duplicates.dart';
import 'gallery_cache.dart';
import 'native.dart';
import 'settings.dart';
import 'sort_page.dart' show deleteNote;

/// Akses galeri untuk Cari Duplikat; diganti versi palsu di test.
abstract class DuplicateSource {
  Future<bool> requestAccess();
  Future<void> openSettings();

  /// Semua foto di galeri, tanpa hash.
  Future<List<DupPhoto>> list();

  /// dHash foto, atau null bila tidak bisa dibaca.
  Future<int?> hash(DupPhoto photo);

  /// Id yang benar-benar terhapus.
  Future<List<String>> delete(List<String> ids);

  Widget image(DupPhoto photo, {required bool large});
}

class DeviceDuplicateSource implements DuplicateSource {
  final Map<String, AssetEntity> _entities = {};

  @override
  Future<bool> requestAccess() async {
    final p = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(type: RequestType.image, mediaLocation: false),
      ),
    );
    return p.hasAccess;
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  Future<List<DupPhoto>> list() async {
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (paths.isEmpty) return [];
    final all = paths.first;
    final total = await all.assetCountAsync;
    // Ukuran file dari scan native (dipakai juga oleh Kompres Foto); RAW tidak termasuk.
    final sizes = <String, (int, String)>{};
    try {
      final images = await RawNative.scanImages();
      GalleryCache.write('images', images); // Kompres Foto/Ubah Format langsung kebagian daftar baru
      for (final p in images) {
        sizes[p.id] = (p.size, p.name);
      }
    } catch (_) {}
    final out = <DupPhoto>[];
    for (var start = 0; start < total; start += 500) {
      final page = await all.getAssetListRange(start: start, end: start + 500 > total ? total : start + 500);
      for (final e in page) {
        if (e.type != AssetType.image) continue;
        _entities[e.id] = e;
        final s = sizes[e.id];
        out.add(DupPhoto(
          id: e.id,
          takenAt: e.createDateTime,
          width: e.orientatedWidth,
          height: e.orientatedHeight,
          bytes: s?.$1 ?? 0,
          name: s?.$2 ?? e.title ?? '',
          favorite: e.isFavorite,
          modified: e.modifiedDateSecond ?? 0,
        ));
      }
    }
    return out;
  }

  @override
  Future<int?> hash(DupPhoto photo) async {
    final e = _entities[photo.id];
    if (e == null) return null;
    try {
      final bytes = await e.thumbnailDataWithSize(const ThumbnailSize(32, 32), quality: 90);
      if (bytes == null) return null;
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 9, targetHeight: 8);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      return data == null ? null : dHash(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> delete(List<String> ids) async {
    final deleted = await RawNative.deleteLegacy(ids) ?? await PhotoManager.editor.deleteWithIds(ids);
    await GalleryCache.remove(deleted);
    return deleted;
  }

  @override
  Widget image(DupPhoto photo, {required bool large}) {
    final e = _entities[photo.id];
    if (e == null) return const Center(child: Icon(Icons.broken_image_outlined));
    return AssetEntityImage(
      e,
      isOriginal: false,
      thumbnailSize: ThumbnailSize.square(large ? 1440 : 250),
      fit: large ? BoxFit.contain : BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}

enum _Phase { loading, denied, scanning, done, error }

String _kindLabel(DupKind k) => k == DupKind.duplicate ? 'Duplikat' : 'Mirip';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

String _date(DateTime d) =>
    '${d.day} ${_months[d.month - 1]} ${d.year}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Cari foto duplikat dan mirip, tinjau per grup, lalu hapus yang ditandai.
/// Tidak ada yang terhapus sebelum pengguna menekan "Hapus" dan mengonfirmasi.
class DuplicatePage extends StatefulWidget {
  const DuplicatePage({super.key, this.source, this.rules = const DupRules()});

  final DuplicateSource? source;
  final DupRules rules;

  @override
  State<DuplicatePage> createState() => _DuplicatePageState();
}

class _DuplicatePageState extends State<DuplicatePage> {
  late final DuplicateSource _src = widget.source ?? DeviceDuplicateSource();

  _Phase _phase = _Phase.loading;
  String? _error;
  int _scanned = 0;
  int _toScan = 0;
  int _total = 0;
  bool _disposed = false;

  List<DupGroup> _groups = [];
  final Set<String> _keep = {};
  DupKind? _filter;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      if (!await _src.requestAccess()) {
        if (mounted) setState(() => _phase = _Phase.denied);
        return;
      }
      final photos = await _src.list();
      final cache = await DupHashCache.load();
      final todo = <DupPhoto>[];
      for (final p in photos) {
        final c = cache[p.id];
        if (c != null && c.$2 == p.modified) {
          p.hash = c.$1;
        } else {
          todo.add(p);
        }
      }
      if (!mounted) return;
      setState(() {
        _phase = _Phase.scanning;
        _total = photos.length;
        _toScan = todo.length;
        _scanned = 0;
      });

      // Beberapa sekaligus: thumbnail kecil cepat, tapi tiap permintaan menunggu galeri.
      for (var i = 0; i < todo.length && !_disposed; i += 4) {
        final chunk = todo.sublist(i, i + 4 > todo.length ? todo.length : i + 4);
        await Future.wait(chunk.map((p) async => p.hash = await _src.hash(p)));
        if (!mounted) return;
        setState(() => _scanned += chunk.length);
      }
      if (_disposed) return;

      await DupHashCache.save({
        for (final p in photos)
          if (p.hash != null) p.id: (p.hash!, p.modified),
      });
      final groups = findGroups(photos, rules: widget.rules);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _keep
          ..clear()
          ..addAll(groups.expand((g) => g.suggestedKeep));
        _phase = _Phase.done;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = '$e';
        });
      }
    }
  }

  List<DupGroup> get _visible => _filter == null ? _groups : _groups.where((g) => g.kind == _filter).toList();

  List<DupPhoto> get _marked => [
        for (final g in _groups)
          for (final p in g.photos)
            if (!_keep.contains(p.id)) p,
      ];

  /// Tandai/lepas hapus. Setiap grup harus menyisakan minimal satu foto; bila ditolak,
  /// pesan muncul di [messenger] (halaman yang sedang tampil).
  bool _toggle(DupGroup g, DupPhoto p, BuildContext messenger) {
    if (_keep.contains(p.id)) {
      if (g.photos.where((x) => _keep.contains(x.id)).length <= 1) {
        ScaffoldMessenger.of(messenger)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Sisakan minimal satu foto di setiap grup.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ));
        return false;
      }
      setState(() => _keep.remove(p.id));
    } else {
      setState(() => _keep.add(p.id));
    }
    return true;
  }

  Future<void> _delete() async {
    final marked = _marked;
    if (marked.isEmpty) return;
    final bytes = marked.fold(0, (a, p) => a + p.bytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus ${marked.length} foto?'),
        content: Text('${bytes > 0 ? 'Menghemat ${formatBytes(bytes)}. ' : ''}${deleteNote()}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    List<String> deleted;
    try {
      deleted = await _src.delete(marked.map((p) => p.id).toList());
    } catch (e) {
      deleted = [];
    }
    if (!mounted) return;
    final gone = deleted.toSet();
    setState(() {
      _deleting = false;
      _groups = [
        for (final g in _groups)
          if (g.photos.where((p) => !gone.contains(p.id)).length > 1)
            DupGroup(g.kind, g.photos.where((p) => !gone.contains(p.id)).toList()),
      ];
    });
    final missed = marked.length - gone.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(missed == 0
          ? '${gone.length} foto dihapus.'
          : '${gone.length} foto dihapus, $missed tidak (dibatalkan atau ditolak).'),
    ));
  }

  bool Function(DupPhoto, BuildContext) _toggler(DupGroup g) => (p, ctx) => _toggle(g, p, ctx);

  Future<void> _view(DupGroup g, int index) => Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _GroupViewer(
          group: g,
          initial: index,
          source: _src,
          isKept: _keep.contains,
          onToggle: _toggler(g),
        ),
      ));

  @override
  Widget build(BuildContext context) {
    final marked = _marked;
    final bytes = marked.fold(0, (a, p) => a + p.bytes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cari Duplikat'),
        actions: [
          if (_phase == _Phase.done)
            IconButton(tooltip: 'Pindai ulang', icon: const Icon(Icons.refresh), onPressed: _start),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _phase == _Phase.done && _groups.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: FilledButton.icon(
                  icon: _deleting
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.delete_outline),
                  onPressed: marked.isEmpty || _deleting ? null : _delete,
                  label: Text(marked.isEmpty
                      ? 'Tidak ada yang ditandai'
                      : 'Hapus ${marked.length} foto${bytes > 0 ? ' (${formatBytes(bytes)})' : ''}'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _body() {
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator());
      case _Phase.denied:
        return _message(Icons.lock_outline, 'Izin galeri dibutuhkan untuk mencari foto duplikat.',
            FilledButton(onPressed: _src.openSettings, child: const Text('Buka Pengaturan')));
      case _Phase.error:
        return _message(Icons.error_outline, _error ?? 'Gagal', FilledButton(onPressed: _start, child: const Text('Coba lagi')));
      case _Phase.scanning:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            LinearProgressIndicator(value: _toScan == 0 ? null : _scanned / _toScan, minHeight: 8),
            const SizedBox(height: 12),
            Text('Memeriksa foto $_scanned dari $_toScan', key: const ValueKey('scan-progress')),
            const SizedBox(height: 4),
            Text(
              _toScan < _total
                  ? '${_total - _toScan} foto lain sudah diperiksa sebelumnya.'
                  : 'Pemindaian pertama paling lama; berikutnya hanya foto baru.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]),
        );
      case _Phase.done:
        if (_groups.isEmpty) {
          return _message(Icons.check_circle_outline, 'Tidak ada foto duplikat atau mirip di $_total foto.',
              OutlinedButton(onPressed: _start, child: const Text('Pindai ulang')));
        }
        return _results();
    }
  }

  Widget _results() {
    final theme = Theme.of(context);
    final dup = _groups.where((g) => g.kind == DupKind.duplicate).length;
    final sim = _groups.length - dup;
    final groups = _visible;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: groups.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Foto bertanda centang disimpan, yang lain akan dihapus. Ketuk untuk mengubah, '
                'tahan untuk melihat besar.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SegmentedButton<DupKind?>(
                key: const ValueKey('dup-filter'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: null, label: Text('Semua (${_groups.length})')),
                  ButtonSegment(value: DupKind.duplicate, label: Text('Duplikat ($dup)')),
                  ButtonSegment(value: DupKind.similar, label: Text('Mirip ($sim)')),
                ],
                selected: {_filter},
                onSelectionChanged: (v) => setState(() => _filter = v.first),
              ),
            ]),
          );
        }
        final g = groups[i - 1];
        return _GroupCard(
          key: ValueKey('group-${g.photos.first.id}'),
          group: g,
          source: _src,
          isKept: _keep.contains,
          onTap: (p) => _toggle(g, p, context),
          onLongPress: (index) => _view(g, index),
        );
      },
    );
  }

  Widget _message(IconData icon, String text, Widget action) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            action,
          ]),
        ),
      );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    super.key,
    required this.group,
    required this.source,
    required this.isKept,
    required this.onTap,
    required this.onLongPress,
  });

  final DupGroup group;
  final DuplicateSource source;
  final bool Function(String id) isKept;
  final void Function(DupPhoto) onTap;
  final void Function(int index) onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = group;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_kindLabel(g.kind)} · ${g.photos.length} foto · ${_date(g.best.takenAt)}',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 16),
            itemCount: g.photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final p = g.photos[i];
              final kept = isKept(p.id);
              return GestureDetector(
                key: ValueKey('dup-${p.id}'),
                onTap: () => onTap(p),
                onLongPress: () => onLongPress(i),
                child: SizedBox(
                  width: 110,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(fit: StackFit.expand, children: [
                      ColoredBox(color: theme.colorScheme.surfaceContainerHighest, child: source.image(p, large: false)),
                      if (!kept) const ColoredBox(color: Color(0x99000000)),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(
                          kept ? Icons.check_circle : Icons.delete,
                          color: kept ? Colors.greenAccent : Colors.redAccent,
                          shadows: const [Shadow(blurRadius: 4)],
                        ),
                      ),
                      if (p.favorite)
                        const Positioned(
                          top: 4,
                          left: 4,
                          child: Icon(Icons.favorite, color: Colors.pinkAccent, size: 18, shadows: [Shadow(blurRadius: 4)]),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          color: Colors.black54,
                          child: Text(
                            p == g.best ? 'Terbaik · ${formatBytes(p.bytes)}' : formatBytes(p.bytes),
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// Lihat satu grup besar-besar, geser antar foto, pilih Simpan/Hapus.
class _GroupViewer extends StatefulWidget {
  const _GroupViewer({
    required this.group,
    required this.initial,
    required this.source,
    required this.isKept,
    required this.onToggle,
  });

  final DupGroup group;
  final int initial;
  final DuplicateSource source;
  final bool Function(String id) isKept;
  final bool Function(DupPhoto, BuildContext) onToggle;

  @override
  State<_GroupViewer> createState() => _GroupViewerState();
}

class _GroupViewerState extends State<_GroupViewer> {
  late int _page = widget.initial;
  late final _pc = PageController(initialPage: widget.initial);

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.group.photos;
    final p = photos[_page];
    final kept = widget.isKept(p.id);
    final theme = ThemeData(
      colorSchemeSeed: Theme.of(context).colorScheme.primary,
      brightness: Brightness.dark,
      useMaterial3: true,
    );
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, title: Text('${_page + 1} / ${photos.length}')),
        body: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: _pc,
              itemCount: photos.length,
              onPageChanged: (i) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                setState(() => _page = i);
              },
              itemBuilder: (_, i) => widget.source.image(photos[i], large: true),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(children: [
                Text(
                  [
                    if (p.name.isNotEmpty) p.name,
                    if (p.pixels > 0) '${p.width} × ${p.height}',
                    if (p.bytes > 0) formatBytes(p.bytes),
                    _date(p.takenAt),
                    if (p == widget.group.best) 'terbaik',
                  ].join(' · '),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  key: const ValueKey('viewer-keep'),
                  segments: const [
                    ButtonSegment(value: true, icon: Icon(Icons.check), label: Text('Simpan')),
                    ButtonSegment(value: false, icon: Icon(Icons.delete_outline), label: Text('Hapus')),
                  ],
                  selected: {kept},
                  onSelectionChanged: (v) {
                    if (v.first != kept && widget.onToggle(p, context)) setState(() {});
                  },
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
