import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'native.dart';
import 'process_page.dart';

/// Pilihan ukuran sisi terpanjang. 0 = resolusi asli.
const kSizeOptions = <int, String>{
  0: 'Asli',
  6000: '6000 px',
  4096: '4096 px',
  3000: '3000 px',
  2048: '2048 px',
};

class CompressPage extends StatefulWidget {
  const CompressPage({super.key});

  @override
  State<CompressPage> createState() => _CompressPageState();
}

class _CompressPageState extends State<CompressPage> {
  PermissionState? _perm;
  bool _loading = true;
  String? _error;
  List<RawPhoto> _photos = [];
  final Set<String> _selected = {};

  int _quality = 85;
  int _maxSide = 4096;
  bool _deleteOriginal = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final perm = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(type: RequestType.image, mediaLocation: true),
      ),
    );
    _perm = perm;
    if (!perm.hasAccess) {
      setState(() => _loading = false);
      return;
    }
    await _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await RawNative.scanRaw();
      setState(() {
        _photos = list;
        _selected.removeWhere((id) => !list.any((p) => p.id == id));
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  int get _selectedBytes =>
      _photos.where((p) => _selected.contains(p.id)).fold(0, (a, p) => a + p.size);

  void _toggleAll() {
    setState(() {
      if (_selected.length == _photos.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_photos.map((p) => p.id));
      }
    });
  }

  Future<void> _start() async {
    final items = _photos.where((p) => _selected.contains(p.id)).toList();
    if (items.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Kompres ${items.length} foto?'),
        content: Text(
          'Setiap foto RAW akan dikonversi ke JPG '
          '(kualitas $_quality, ukuran ${kSizeOptions[_maxSide]}).\n\n'
          '${_deleteOriginal ? 'Setelah selesai, file RAW asli akan DIHAPUS. '
              'iOS: konfirmasi sekali, lalu masuk album "Baru Dihapus" (30 hari).\n'
              'Android 10+: konfirmasi sekali, lalu terhapus permanen.\n'
              'Android 9: langsung terhapus permanen tanpa konfirmasi tambahan.' : 'File RAW asli tetap disimpan.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mulai')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ProcessPage(
        items: items,
        quality: _quality,
        maxSide: _maxSide,
        deleteOriginal: _deleteOriginal,
      ),
    ));
    _selected.clear();
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _photos.isNotEmpty && _selected.length == _photos.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Foto RAW (${_photos.length})' : '${_selected.length} dipilih'),
        actions: [
          if (_photos.isNotEmpty)
            IconButton(
              tooltip: allSelected ? 'Batalkan semua' : 'Pilih semua',
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
              onPressed: _toggleAll,
            ),
          IconButton(tooltip: 'Muat ulang', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _scan),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _photos.isEmpty ? null : _bottomBar(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_perm != null && !_perm!.hasAccess) {
      return _message(
        Icons.lock_outline,
        'Izin galeri dibutuhkan untuk menemukan foto RAW.',
        action: FilledButton(onPressed: PhotoManager.openSetting, child: const Text('Buka Pengaturan')),
      );
    }
    if (_error != null) {
      return _message(Icons.error_outline, _error!, action: FilledButton(onPressed: _scan, child: const Text('Coba lagi')));
    }
    if (_photos.isEmpty) {
      return _message(Icons.photo_library_outlined, 'Tidak ada foto RAW di galeri.',
          action: OutlinedButton(onPressed: _scan, child: const Text('Muat ulang')));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _photos.length,
      itemBuilder: (_, i) {
        final p = _photos[i];
        final sel = _selected.contains(p.id);
        return _Tile(
          key: ValueKey(p.id),
          photo: p,
          selected: sel,
          onTap: () => setState(() => sel ? _selected.remove(p.id) : _selected.add(p.id)),
        );
      },
    );
  }

  Widget _message(IconData icon, String text, {Widget? action}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action],
          ]),
        ),
      );

  Widget _bottomBar() {
    final theme = Theme.of(context);
    return SafeArea(
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Text('Kualitas'),
              Expanded(
                child: Slider(
                  value: _quality.toDouble(),
                  min: 50,
                  max: 100,
                  divisions: 50,
                  label: '$_quality',
                  onChanged: (v) => setState(() => _quality = v.round()),
                ),
              ),
              SizedBox(width: 32, child: Text('$_quality', textAlign: TextAlign.end)),
            ]),
            Row(children: [
              const Text('Ukuran'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _maxSide,
                  items: kSizeOptions.entries
                      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setState(() => _maxSide = v ?? _maxSide),
                ),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Hapus RAW asli setelah konversi'),
              value: _deleteOriginal,
              onChanged: (v) => setState(() => _deleteOriginal = v),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.compress),
                onPressed: _selected.isEmpty ? null : _start,
                label: Text(_selected.isEmpty
                    ? 'Pilih foto untuk dikompres'
                    : 'Kompres ${_selected.length} foto (${formatBytes(_selectedBytes)})'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Tile extends StatefulWidget {
  const _Tile({super.key, required this.photo, required this.selected, required this.onTap});

  final RawPhoto photo;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  late final Future<AssetEntity?> _entity = AssetEntity.fromId(widget.photo.id);

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    final selected = widget.selected;
    final onTap = widget.onTap;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Stack(fit: StackFit.expand, children: [
        ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: FutureBuilder<AssetEntity?>(
            future: _entity,
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
              final e = snap.data;
              // File yang tidak dikenali galeri (mis. CR3 di Download): thumbnail dari native.
              if (e == null) return _NativeThumb(id: photo.id);
              return AssetEntityImage(
                e,
                isOriginal: false,
                thumbnailSize: const ThumbnailSize.square(250),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _NativeThumb(id: photo.id),
              );
            },
          ),
        ),
        AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.all(selected ? 6 : 0),
          child: selected ? DecoratedBox(decoration: BoxDecoration(border: Border.all(color: scheme.primary, width: 3))) : null,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            color: Colors.black54,
            child: Text(
              '${photo.name.split('.').last.toUpperCase()} · ${formatBytes(photo.size)}',
              style: const TextStyle(color: Colors.white, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: selected ? scheme.primary : Colors.white,
            shadows: const [Shadow(blurRadius: 4)],
          ),
        ),
      ]),
    );
  }
}

class _NativeThumb extends StatefulWidget {
  const _NativeThumb({required this.id});

  final String id;

  @override
  State<_NativeThumb> createState() => _NativeThumbState();
}

class _NativeThumbState extends State<_NativeThumb> {
  late final Future<Uint8List?> _bytes = RawNative.thumbnail(widget.id);

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (_, snap) {
          final b = snap.data;
          if (b == null) {
            return snap.connectionState == ConnectionState.done
                ? const Icon(Icons.raw_on)
                : const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
        },
      );
}
