import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'gallery_cache.dart';
import 'native.dart';
import 'settings.dart';
import 'swipe_card.dart';

/// Satu foto galeri yang disortir.
class SortPhoto {
  const SortPhoto({required this.id, this.date, this.entity, this.favorite = false});

  final String id;
  final DateTime? date;
  final AssetEntity? entity;

  /// Status favorit di galeri saat dimuat.
  final bool favorite;
}

/// Akses galeri untuk [SortPage]; diganti fake di test.
abstract class SortSource {
  Future<bool> requestAccess();
  Future<void> openSettings();

  /// Jumlah foto di galeri.
  Future<int> count();

  /// Foto urut terbaru dulu, mulai dari posisi [start]. Hasil kosong = habis.
  Future<List<SortPhoto>> loadRange(int start, int count);

  /// Menghapus foto; mengembalikan id yang benar-benar terhapus.
  Future<List<String>> delete(List<String> ids);

  /// Id foto yang sudah disimpan di sesi sebelumnya.
  Future<Set<String>> loadSorted();
  Future<void> saveSorted(Set<String> ids);

  /// Apakah galeri perangkat punya status favorit yang bisa diubah aplikasi.
  Future<bool> canFavorite();

  /// Ubah status favorit di galeri; true bila berhasil.
  Future<bool> setFavorite(SortPhoto photo, bool favorite);

  Widget image(SortPhoto photo, {required bool large});
}

/// Semua foto (bukan video) di galeri perangkat lewat photo_manager.
class GallerySortSource implements SortSource {
  AssetPathEntity? _all;
  bool _loaded = false;

  Future<AssetPathEntity?> _path() async {
    if (_loaded) return _all;
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    _loaded = true;
    return _all = paths.isEmpty ? null : paths.first;
  }

  @override
  Future<bool> requestAccess() async {
    final perm = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(type: RequestType.image, mediaLocation: false),
      ),
    );
    return perm.hasAccess;
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  Future<int> count() async => await (await _path())?.assetCountAsync ?? 0;

  @override
  Future<List<SortPhoto>> loadRange(int start, int count) async {
    final path = await _path();
    if (path == null) return [];
    final list = await path.getAssetListRange(start: start, end: start + count);
    return [
      for (final e in list) SortPhoto(id: e.id, date: e.createDateTime, entity: e, favorite: e.isFavorite),
    ];
  }

  @override
  Future<Set<String>> loadSorted() => SortProgress.load();

  @override
  Future<void> saveSorted(Set<String> ids) => SortProgress.save(ids);

  /// iOS: PHAsset.isFavorite. Android 11+: MediaStore IS_FAVORITE (dengan dialog izin sistem).
  /// Android 9–10 tidak punya favorit tingkat sistem.
  @override
  Future<bool> canFavorite() async {
    if (Platform.isIOS) return true;
    if (!Platform.isAndroid) return false;
    return (await RawNative.androidSdk() ?? 0) >= 30;
  }

  @override
  Future<bool> setFavorite(SortPhoto photo, bool favorite) async {
    final e = photo.entity;
    if (e == null) return false;
    try {
      if (Platform.isIOS) {
        await PhotoManager.editor.darwin.favoriteAsset(entity: e, favorite: favorite);
      } else {
        await PhotoManager.editor.android.favoriteAsset(entity: e, favorite: favorite);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> delete(List<String> ids) async {
    final deleted = await RawNative.deleteLegacy(ids) ?? await PhotoManager.editor.deleteWithIds(ids);
    await GalleryCache.remove(deleted);
    return deleted;
  }

  @override
  Widget image(SortPhoto photo, {required bool large}) {
    final e = photo.entity;
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

/// Teks penjelasan hapus per platform.
String deleteNote() {
  if (Platform.isIOS) return 'Foto masuk album "Baru Dihapus" dan bisa dipulihkan selama 30 hari.';
  return 'Foto terhapus permanen dari perangkat.';
}

/// Sortir ala kartu: geser kanan simpan, geser kiri tandai hapus.
/// Tidak ada yang terhapus sebelum pengguna meninjau dan menekan "Hapus".
class SortPage extends StatefulWidget {
  const SortPage({super.key, this.source});

  final SortSource? source;

  @override
  State<SortPage> createState() => _SortPageState();
}

class _SortPageState extends State<SortPage> {
  static const _batch = 40;

  late final SortSource _src = widget.source ?? GallerySortSource();
  final _cardKey = GlobalKey<SwipeCardState>();

  bool _loading = true;
  bool? _access;
  String? _error;
  int _total = 0;

  /// Foto yang belum diputuskan; elemen pertama = kartu teratas.
  final List<SortPhoto> _pending = [];

  /// Keputusan berurutan (untuk urungkan). `keep == false` = ditandai hapus.
  final List<({SortPhoto photo, bool keep})> _history = [];
  final Set<String> _seen = {};

  /// Id yang sudah disimpan (sesi ini dan sebelumnya); dilewati saat memuat.
  Set<String> _sorted = {};
  int _skipped = 0;
  Future<void> _saving = Future.value();

  /// Posisi asli foto di galeri (terbaru = 0), untuk penghitung "N / total".
  final Map<String, int> _pos = {};

  bool _canFavorite = false;
  final Map<String, bool> _fav = {};
  bool _favBusy = false;

  /// Posisi berikutnya di galeri yang belum dimuat.
  int _offset = 0;
  bool _exhausted = false;
  bool _loadingMore = false;
  bool _deleting = false;
  int _deletedCount = 0;

  List<SortPhoto> get _marked => [for (final h in _history) if (!h.keep) h.photo];
  int get _keptCount => _history.where((h) => h.keep).length;

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
    try {
      final ok = await _src.requestAccess();
      _access = ok;
      if (ok) {
        _sorted = await _src.loadSorted();
        _total = await _src.count();
        _canFavorite = await _src.canFavorite().catchError((_) => false);
        await _loadMore();
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    try {
      // Lanjut memuat selama batch hanya berisi foto yang sudah disortir/tampil.
      while (mounted && !_exhausted && _pending.length < 10) {
        final start = _offset;
        final list = await _src.loadRange(start, _batch);
        _offset += list.length;
        if (list.isEmpty) _exhausted = true;
        final fresh = <SortPhoto>[];
        for (var i = 0; i < list.length; i++) {
          final p = list[i];
          if (!_seen.add(p.id)) continue;
          if (_sorted.contains(p.id)) {
            _skipped++;
            continue;
          }
          // Semua foto yang sudah terhapus berada sebelum posisi ini.
          _pos[p.id] = start + i + _deletedCount;
          fresh.add(p);
        }
        if (mounted) setState(() => _pending.addAll(fresh));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _loadingMore = false;
    }
  }

  void _persistSorted() {
    final snapshot = Set.of(_sorted);
    _saving = _saving.then((_) => _src.saveSorted(snapshot)).catchError((_) {});
  }

  void _decide(bool keep) {
    if (_pending.isEmpty) return;
    final p = _pending.removeAt(0);
    setState(() => _history.add((photo: p, keep: keep)));
    if (keep && _sorted.add(p.id)) _persistSorted();
    if (_pending.length < 10) _loadMore();
  }

  void _undo() {
    if (_history.isEmpty) return;
    final h = _history.removeLast();
    setState(() => _pending.insert(0, h.photo));
    if (h.keep && _sorted.remove(h.photo.id)) _persistSorted();
  }

  bool _isFav(SortPhoto p) => _fav[p.id] ?? p.favorite;

  Future<void> _toggleFavorite() async {
    if (_pending.isEmpty || _favBusy) return;
    final p = _pending.first;
    final next = !_isFav(p);
    setState(() => _favBusy = true);
    final ok = await _src.setFavorite(p, next).catchError((_) => false);
    if (!mounted) return;
    setState(() {
      _favBusy = false;
      if (ok) _fav[p.id] = next;
    });
    // Berhasil: bintang di tombol & kartu sudah cukup sebagai tanda (snackbar akan menutupi tombol).
    if (!ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Gagal mengubah favorit'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
    }
  }

  Future<void> _reset() async {
    final marked = _marked.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ulangi dari awal?'),
        content: Text('Semua foto akan ditampilkan lagi, termasuk yang sudah disimpan sebelumnya.'
            '${marked > 0 ? '\n$marked tanda hapus di sesi ini juga dibatalkan.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ulangi')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _sorted = {};
    _persistSorted();
    setState(() {
      _pending.clear();
      _history.clear();
      _seen.clear();
      _pos.clear();
      _offset = 0;
      _skipped = 0;
      _deletedCount = 0;
      _exhausted = false;
    });
    await _init();
  }

  Future<void> _review() async {
    final marked = _marked;
    if (marked.isEmpty || _deleting) return;
    final ids = await Navigator.of(context).push<List<String>>(MaterialPageRoute(
      builder: (_) => SortReviewPage(photos: marked, source: _src),
    ));
    if (ids == null || !mounted) return;

    // Foto yang batal dihapus di halaman tinjau dianggap disimpan.
    final chosen = ids.toSet();
    setState(() {
      for (var i = 0; i < _history.length; i++) {
        final h = _history[i];
        if (!h.keep && !chosen.contains(h.photo.id)) {
          _history[i] = (photo: h.photo, keep: true);
          _sorted.add(h.photo.id);
        }
      }
    });
    _persistSorted();
    if (ids.isEmpty) return;

    setState(() => _deleting = true);
    String? message;
    try {
      final deleted = (await _src.delete(ids)).toSet();
      setState(() {
        _history.removeWhere((h) => !h.keep && deleted.contains(h.photo.id));
        _deletedCount += deleted.length;
        _total -= deleted.length;
        // Foto yang terhapus sudah dimuat, jadi posisi galeri berikutnya bergeser maju.
        _offset = (_offset - deleted.length).clamp(0, _offset);
      });
      final missed = ids.length - deleted.length;
      message = missed == 0
          ? '${deleted.length} foto dihapus'
          : '${deleted.length} foto dihapus, $missed tidak dihapus (masih ditandai).';
    } catch (e) {
      message = 'Gagal menghapus: $e';
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar tanpa menghapus?'),
        content: Text('${_marked.length} foto yang ditandai hapus belum dihapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Keluar')),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final marked = _marked.length;
    return PopScope(
      canPop: marked == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sortir Foto'),
          actions: [
            IconButton(
              tooltip: 'Urungkan',
              icon: const Icon(Icons.undo),
              onPressed: _history.isEmpty || _deleting ? null : _undo,
            ),
            IconButton(
              tooltip: 'Tinjau & hapus',
              onPressed: marked == 0 || _deleting ? null : _review,
              icon: Badge(
                isLabelVisible: marked > 0,
                label: Text('$marked'),
                child: const Icon(Icons.delete_outline),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Menu',
              enabled: !_loading && !_deleting && _access == true,
              onSelected: (_) => _reset(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reset', child: Text('Ulangi dari awal')),
              ],
            ),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_access == false) {
      return _message(
        Icons.lock_outline,
        'Izin galeri dibutuhkan untuk menyortir foto.',
        action: FilledButton(onPressed: _src.openSettings, child: const Text('Buka Pengaturan')),
      );
    }
    if (_error != null && _pending.isEmpty) {
      return _message(Icons.error_outline, _error!, action: FilledButton(onPressed: _init, child: const Text('Coba lagi')));
    }
    if (_pending.isEmpty && _history.isEmpty && _deletedCount == 0) {
      if (_skipped > 0) {
        return _message(
          Icons.task_alt,
          'Semua foto sudah disortir sebelumnya.\n$_skipped foto disimpan.',
          action: OutlinedButton(onPressed: _reset, child: const Text('Ulangi dari awal')),
        );
      }
      return _message(Icons.photo_library_outlined, 'Tidak ada foto di galeri.');
    }
    if (_pending.isEmpty) return _done();

    final scheme = Theme.of(context).colorScheme;
    final current = _pending.first;
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            Expanded(
              child: Text(
                'Disimpan $_keptCount · Ditandai hapus ${_marked.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_total > 0 && _pos[current.id] != null)
              Text('${_pos[current.id]! + 1} / ${_total + _deletedCount}',
                  style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(fit: StackFit.expand, children: [
              if (_pending.length > 1)
                Transform.scale(
                  scale: 0.94,
                  child: _frame(_pending[1], scheme),
                ),
              SwipeCard(
                key: _cardKey,
                id: current.id,
                onSwiped: _decide,
                child: _frame(current, scheme),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _roundButton(Icons.close, 'Hapus', scheme.error, () => _cardKey.currentState?.swipe(keep: false)),
            if (_canFavorite)
              _roundButton(
                _isFav(current) ? Icons.star : Icons.star_border,
                _isFav(current) ? 'Hapus dari Favorit' : 'Tambah ke Favorit',
                Colors.amber.shade700,
                _favBusy ? null : _toggleFavorite,
                small: true,
              ),
            _roundButton(Icons.check, 'Simpan', Colors.green, () => _cardKey.currentState?.swipe(keep: true)),
          ]),
        ),
      ]),
    );
  }

  Widget _frame(SortPhoto p, ColorScheme scheme) => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Stack(fit: StackFit.expand, children: [
            _src.image(p, large: true),
            if (_isFav(p))
              const Positioned(
                right: 12,
                bottom: 12,
                child: Icon(Icons.star, color: Colors.amber, size: 28, shadows: [Shadow(blurRadius: 6)]),
              ),
            if (p.date != null)
              Positioned(
                left: 12,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(_formatDate(p.date!), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ),
              ),
          ]),
        ),
      );

  Widget _roundButton(IconData icon, String tooltip, Color color, VoidCallback? onPressed, {bool small = false}) =>
      IconButton.outlined(
        tooltip: tooltip,
        iconSize: small ? 26 : 32,
        padding: EdgeInsets.all(small ? 12 : 16),
        style: IconButton.styleFrom(foregroundColor: color, side: BorderSide(color: color, width: 2)),
        onPressed: _deleting ? null : onPressed,
        icon: Icon(icon),
      );

  Widget _done() {
    final marked = _marked.length;
    return _message(
      Icons.task_alt,
      'Semua foto sudah disortir.\nDisimpan $_keptCount · Dihapus $_deletedCount'
      '${marked > 0 ? ' · Menunggu dihapus $marked' : ''}'
      '${_skipped > 0 ? '\n$_skipped foto dilewati karena sudah disortir sebelumnya.' : ''}',
      action: marked > 0
          ? FilledButton.icon(
              onPressed: _deleting ? null : _review,
              icon: const Icon(Icons.delete_outline),
              label: Text('Tinjau & hapus $marked foto'),
            )
          : FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Kembali ke beranda')),
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
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

String _formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// Tinjau foto yang ditandai hapus. Ketuk foto untuk membatalkan hapusnya.
/// Pop dengan daftar id yang jadi dihapus, atau null bila kembali.
class SortReviewPage extends StatefulWidget {
  const SortReviewPage({super.key, required this.photos, required this.source});

  final List<SortPhoto> photos;
  final SortSource source;

  @override
  State<SortReviewPage> createState() => _SortReviewPageState();
}

class _SortReviewPageState extends State<SortReviewPage> {
  late final Set<String> _chosen = {for (final p in widget.photos) p.id};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ids = [for (final p in widget.photos) if (_chosen.contains(p.id)) p.id];
    return Scaffold(
      appBar: AppBar(title: Text('Hapus ${ids.length} foto?')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('Ketuk foto untuk batal menghapusnya. ${deleteNote()}',
              style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: widget.photos.length,
            itemBuilder: (_, i) {
              final p = widget.photos[i];
              final on = _chosen.contains(p.id);
              return GestureDetector(
                key: ValueKey('review-${p.id}'),
                onTap: () => setState(() => on ? _chosen.remove(p.id) : _chosen.add(p.id)),
                child: Stack(fit: StackFit.expand, children: [
                  ColoredBox(color: scheme.surfaceContainerHighest, child: widget.source.image(p, large: false)),
                  if (!on) const ColoredBox(color: Colors.white54),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Icon(
                      on ? Icons.delete : Icons.undo,
                      color: on ? scheme.error : scheme.primary,
                      shadows: const [Shadow(blurRadius: 4, color: Colors.white)],
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.of(context).pop(ids),
            icon: const Icon(Icons.delete_forever),
            label: Text(ids.isEmpty ? 'Simpan semua' : 'Hapus ${ids.length} foto'),
          ),
        ),
      ),
    );
  }
}
