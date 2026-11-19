import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'jobs.dart';
import 'native.dart';
import 'process_page.dart';
import 'settings.dart';

/// Pilihan ukuran sisi terpanjang. 0 = resolusi asli.
const kSizeOptions = <int, String>{
  0: 'Asli',
  6000: '6000 px',
  4096: '4096 px',
  3000: '3000 px',
  2048: '2048 px',
};

/// Pilih foto, atur opsi, lalu proses. Dipakai untuk Kompres RAW, Kompres Foto, dan Ubah Format.
class CompressPage extends StatefulWidget {
  const CompressPage({super.key, this.job = PhotoJob.raw});

  final PhotoJob job;

  @override
  State<CompressPage> createState() => _CompressPageState();
}

class _CompressPageState extends State<CompressPage> {
  PhotoJob get _job => widget.job;

  PermissionState? _perm;
  bool _loading = true;
  String? _error;

  List<RawPhoto> _photos = [];
  final Set<String> _selected = {};

  late int _quality = _job.defaultQuality;
  late int _maxSide = _job.defaultMaxSide;
  late bool _deleteOriginal = _job.defaultDeleteOriginal;
  late OutputFormat _format = _job.defaultFormat;
  SaveTarget _target = SaveTarget.gallery;
  String? _folderName;

  List<OutputFormat> get _formats => OutputFormat.convertTargets(android: RawNative.isAndroid);

  String? _folderError;

  /// Ubah Format: foto yang sudah berformat tujuan dilewati.
  bool _alreadyTarget(RawPhoto p) => _job == PhotoJob.convert && _format.extensions.contains(extensionOf(p.name));

  @override
  void initState() {
    super.initState();
    _restore().whenComplete(_init);
  }

  /// Pulihkan pilihan terakhir. Folder yang tidak bisa diakses lagi kembali ke galeri.
  Future<void> _restore() async {
    final s = await CompressSettings.load(
      _job,
      sizes: kSizeOptions.keys.toSet(),
      formats: _job == PhotoJob.convert ? _formats.toSet() : {OutputFormat.same},
    );
    final folder = await RawNative.savedFolder();
    var target = s.target;
    if (target == SaveTarget.folder && folder == null) target = SaveTarget.gallery;
    if (target == SaveTarget.sameFolder && !RawNative.isAndroid) target = SaveTarget.gallery;
    if (!mounted) return;
    setState(() {
      _quality = s.quality;
      _maxSide = s.maxSide;
      _deleteOriginal = s.deleteOriginal;
      _format = s.format;
      _target = target;
      _folderName = folder;
    });
  }

  void _saveSettings() => CompressSettings(
        quality: _quality,
        maxSide: _maxSide,
        deleteOriginal: _deleteOriginal,
        target: _target,
        format: _format,
      ).save(_job);

  String _targetLabel(SaveTarget t) => switch (t) {
        SaveTarget.gallery => 'Galeri internal',
        SaveTarget.sameFolder => 'Folder yang sama dengan ${_job == PhotoJob.raw ? 'RAW' : 'foto asli'}',
        SaveTarget.folder => _folderName != null
            ? 'Folder: $_folderName'
            : RawNative.isAndroid
                ? 'Pilih folder / kartu SD…'
                : 'Pilih folder…',
      };

  /// Pilih folder tujuan; target pindah ke folder hanya bila pengguna memilih.
  Future<void> _pickFolder() async {
    setState(() => _folderError = null);
    try {
      final name = await RawNative.pickFolder();
      if (name == null || !mounted) return;
      setState(() {
        _folderName = name;
        _target = SaveTarget.folder;
      });
      _saveSettings();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _folderError = e.message ?? 'Gagal memilih folder');
    }
  }

  Future<void> _onTargetChanged(SaveTarget? t) async {
    if (t == null || t == _target) return;
    if (t == SaveTarget.folder && _folderName == null) return _pickFolder();
    setState(() {
      _target = t;
      _folderError = null;
    });
    _saveSettings();
  }

  void _onFormatChanged(OutputFormat? f) {
    if (f == null || f == _format) return;
    setState(() => _format = f);
    _saveSettings();
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
      final list = await _job.scan();
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

  List<RawPhoto> get _selectedPhotos => _photos.where((p) => _selected.contains(p.id)).toList();

  int get _selectedBytes => _selectedPhotos.fold(0, (a, p) => a + p.size);

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

  String get _sizeText => kSizeOptions[_maxSide]!;

  String _describe(int n) => switch (_job) {
        PhotoJob.raw => 'Setiap foto RAW akan dikonversi ke JPG (kualitas $_quality, ukuran $_sizeText).',
        PhotoJob.compress => 'Setiap foto dikompres ulang dengan format yang sama '
            '(kualitas $_quality, ukuran $_sizeText). '
            '${RawNative.isAndroid ? 'HEIC menjadi JPG. ' : ''}'
            'Foto yang hasilnya tidak lebih kecil dilewati dan tidak dihapus.',
        PhotoJob.convert => 'Setiap foto diubah ke ${_format.label}'
            '${_format.lossy ? ' (kualitas $_quality, ukuran $_sizeText)' : ' (ukuran $_sizeText)'}.',
      };

  String get _deleteText {
    final what = _job == PhotoJob.raw ? 'file RAW asli' : 'foto asli';
    if (!_deleteOriginal) return '${what[0].toUpperCase()}${what.substring(1)} tetap disimpan.';
    return 'Setelah selesai, $what akan DIHAPUS. '
        'iOS: konfirmasi sekali, lalu masuk album "Baru Dihapus" (30 hari).\n'
        'Android 10+: konfirmasi sekali, lalu terhapus permanen.\n'
        'Android 9: langsung terhapus permanen tanpa konfirmasi tambahan.'
        '${_job.isImage && !RawNative.isAndroid ? '\nLive Photo menjadi foto biasa.' : ''}';
  }

  /// Setelah memilih foto: semua opsi + ringkasan di satu lembar bawah, lalu "Mulai".
  Future<void> _start() async {
    if (_selected.isEmpty) return;
    setState(() => _folderError = null);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => _optionsSheet(ctx, setSheet)),
    );
    final items = _selectedPhotos.where((p) => !_alreadyTarget(p)).toList();
    if (ok != true || items.isEmpty || !mounted) return;

    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ProcessPage(
        items: items,
        quality: _quality,
        maxSide: _maxSide,
        deleteOriginal: _deleteOriginal,
        target: _target,
        job: _job,
        format: _format,
      ),
    ));
    _selected.clear();
    await _scan();
  }

  Widget _optionsSheet(BuildContext ctx, StateSetter setSheet) {
    // Ubah state halaman dan gambar ulang lembar ini.
    void up(VoidCallback f) {
      setState(f);
      setSheet(() {});
    }

    Future<void> upAsync(Future<void> Function() f) async {
      await f();
      if (ctx.mounted) setSheet(() {});
    }

    final theme = Theme.of(ctx);
    final selected = _selectedPhotos;
    final items = selected.where((p) => !_alreadyTarget(p)).toList();
    final skippedSame = selected.length - items.length;
    final showQuality = _job != PhotoJob.convert || _format.lossy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _job == PhotoJob.convert ? 'Ubah ${items.length} foto ke ${_format.label}?' : 'Kompres ${items.length} foto?',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (_job == PhotoJob.convert)
            Row(children: [
              const Text('Ubah ke'),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<OutputFormat>(
                  key: const ValueKey('format'),
                  isExpanded: true,
                  value: _format,
                  items: [for (final f in _formats) DropdownMenuItem(value: f, child: Text(f.label))],
                  onChanged: (f) => up(() => _onFormatChanged(f)),
                ),
              ),
            ]),
          if (showQuality)
            Row(children: [
              const Text('Kualitas'),
              Expanded(
                child: Slider(
                  value: _quality.toDouble(),
                  min: 50,
                  max: 100,
                  divisions: 50,
                  label: '$_quality',
                  onChanged: (v) => up(() => _quality = v.round()),
                  onChangeEnd: (_) => _saveSettings(),
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
                items: kSizeOptions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) {
                  up(() => _maxSide = v ?? _maxSide);
                  _saveSettings();
                },
              ),
            ),
          ]),
          Row(children: [
            const Text('Simpan ke'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<SaveTarget>(
                key: const ValueKey('save-target'),
                isExpanded: true,
                value: _target,
                items: [
                  for (final t in SaveTarget.values)
                    if (t != SaveTarget.sameFolder || RawNative.isAndroid)
                      DropdownMenuItem(value: t, child: Text(_targetLabel(t), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (t) => upAsync(() => _onTargetChanged(t)),
              ),
            ),
            if (_target == SaveTarget.folder)
              IconButton(
                tooltip: 'Ganti folder',
                icon: const Icon(Icons.folder_open),
                onPressed: () => upAsync(_pickFolder),
              ),
          ]),
          if (_folderError != null)
            Text(_folderError!, style: TextStyle(color: theme.colorScheme.error)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(switch (_job) {
              PhotoJob.raw => 'Hapus RAW asli setelah konversi',
              PhotoJob.compress => 'Hapus foto asli setelah kompres',
              PhotoJob.convert => 'Hapus foto asli setelah diubah',
            }),
            value: _deleteOriginal,
            onChanged: (v) {
              up(() => _deleteOriginal = v);
              _saveSettings();
            },
          ),
          const SizedBox(height: 4),
          Text(
            '${_describe(items.length)}\nDisimpan ke: ${_targetLabel(_target)}.\n\n$_deleteText'
            '${skippedSame > 0 ? '\n\n$skippedSame foto sudah berformat ${_format.label} dan dilewati.' : ''}',
            key: const ValueKey('summary'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: items.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: const Text('Mulai'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  String get _listTitle => switch (_job) {
        PhotoJob.raw => 'Foto RAW',
        PhotoJob.compress => 'Kompres Foto',
        PhotoJob.convert => 'Ubah Format',
      };

  @override
  Widget build(BuildContext context) {
    final photos = _photos;
    final allSelected = photos.isNotEmpty && _selected.length == photos.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? '$_listTitle (${photos.length})' : '${_selected.length} dipilih'),
        actions: [
          if (photos.isNotEmpty)
            IconButton(
              tooltip: allSelected ? 'Batalkan semua' : 'Pilih semua',
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
              onPressed: _toggleAll,
            ),
          IconButton(tooltip: 'Muat ulang', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _scan),
        ],
      ),
      body: _body(photos),
      bottomNavigationBar: _loading || photos.isEmpty ? null : _bottomBar(),
    );
  }

  Widget _body(List<RawPhoto> photos) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_perm != null && !_perm!.hasAccess) {
      return _message(
        Icons.lock_outline,
        _job == PhotoJob.raw
            ? 'Izin galeri dibutuhkan untuk menemukan foto RAW.'
            : 'Izin galeri dibutuhkan untuk memilih foto.',
        action: FilledButton(onPressed: PhotoManager.openSetting, child: const Text('Buka Pengaturan')),
      );
    }
    if (_error != null) {
      return _message(Icons.error_outline, _error!, action: FilledButton(onPressed: _scan, child: const Text('Coba lagi')));
    }
    if (photos.isEmpty) {
      final text = _job == PhotoJob.raw ? 'Tidak ada foto RAW di galeri.' : 'Tidak ada foto di galeri.';
      return _message(Icons.photo_library_outlined, text,
          action: OutlinedButton(onPressed: _scan, child: const Text('Muat ulang')));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: photos.length,
      itemBuilder: (_, i) {
        final p = photos[i];
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

  /// Hanya satu tombol supaya grid foto tidak tertutup; opsi muncul setelah ditekan.
  Widget _bottomBar() => SafeArea(
        child: Material(
          elevation: 8,
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: Icon(_job == PhotoJob.convert ? Icons.transform : Icons.compress),
                onPressed: _selected.isEmpty ? null : _start,
                label: Text(_buttonText),
              ),
            ),
          ),
        ),
      );

  String get _buttonText {
    final n = _selected.length;
    if (_job == PhotoJob.convert) {
      return n == 0 ? 'Pilih foto untuk diubah' : 'Ubah $n foto (${formatBytes(_selectedBytes)})';
    }
    return n == 0 ? 'Pilih foto untuk dikompres' : 'Kompres $n foto (${formatBytes(_selectedBytes)})';
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
