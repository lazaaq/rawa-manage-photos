import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'jobs.dart';
import 'native.dart';

enum _Phase { converting, deleting, done }

/// Proses bulk: konversi satu per satu (hemat memori), lalu hapus RAW yang berhasil
/// dalam satu permintaan konfirmasi sistem.
class ProcessPage extends StatefulWidget {
  const ProcessPage({
    super.key,
    required this.items,
    required this.quality,
    required this.maxSide,
    required this.deleteOriginal,
    this.target = SaveTarget.gallery,
    this.job = PhotoJob.raw,
    this.format = OutputFormat.same,
  });

  final List<RawPhoto> items;
  final int quality;
  final int maxSide;
  final bool deleteOriginal;
  final SaveTarget target;
  final PhotoJob job;

  /// Format hasil untuk foto biasa (diabaikan untuk RAW).
  final OutputFormat format;

  @override
  State<ProcessPage> createState() => _ProcessPageState();
}

class _ProcessPageState extends State<ProcessPage> {
  _Phase _phase = _Phase.converting;
  int _index = 0;
  bool _cancel = false;

  final List<RawPhoto> _ok = [];
  int _skipped = 0;
  final List<({String name, String error})> _failed = [];
  int _inBytes = 0;
  int _outBytes = 0;
  int _deleted = 0;
  String? _deleteError;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    for (final p in widget.items) {
      if (_cancel) break;
      try {
        final r = await RawNative.convert(
          p.id,
          quality: widget.quality,
          maxSide: widget.maxSide,
          target: widget.target,
          imageFormat: widget.job.isImage ? widget.format.name : null,
          onlyIfSmaller: widget.job == PhotoJob.compress,
        );
        if (r.skipped) {
          // Tidak ada file baru: asli dibiarkan, tidak dihitung hemat.
          _skipped++;
        } else {
          _ok.add(p);
          _inBytes += r.inBytes > 0 ? r.inBytes : p.size;
          _outBytes += r.outBytes;
        }
      } on PlatformException catch (e) {
        _failed.add((name: p.name, error: e.message ?? e.code));
      } catch (e) {
        _failed.add((name: p.name, error: '$e'));
      }
      if (!mounted) return;
      setState(() => _index++);
    }

    if (widget.deleteOriginal && _ok.isNotEmpty) {
      setState(() => _phase = _Phase.deleting);
      try {
        final ids = _ok.map((p) => p.id).toList();
        final deleted = await RawNative.deleteLegacy(ids) ?? await PhotoManager.editor.deleteWithIds(ids);
        _deleted = deleted.length;
        if (_deleted < ids.length) {
          _deleteError = '${ids.length - _deleted} ${widget.job.originalWord} tidak dihapus '
              '(dibatalkan atau ditolak). $_resultWord hasil tetap tersimpan.';
        }
      } catch (e) {
        _deleteError = 'Gagal menghapus ${widget.job.originalWord}: $e';
      }
    }
    if (mounted) setState(() => _phase = _Phase.done);
  }

  /// Sebutan file hasil: "JPG" untuk RAW, "Foto" untuk lainnya.
  String get _resultWord => widget.job == PhotoJob.raw ? 'JPG' : 'Foto';

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;
    final raw = widget.job == PhotoJob.raw;
    final done = _phase == _Phase.done;
    return PopScope(
      canPop: done,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(done ? 'Selesai' : (widget.job == PhotoJob.convert ? 'Mengubah…' : 'Mengompres…')),
        ),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          LinearProgressIndicator(value: total == 0 ? 1 : _index / total, minHeight: 8),
          const SizedBox(height: 12),
          Text(
            switch (_phase) {
              _Phase.converting => _index < total
                  ? 'Foto ${_index + 1} dari $total: ${widget.items[_index].name}'
                  : 'Menyelesaikan…',
              _Phase.deleting => 'Menghapus ${widget.job.originalWord} asli… (konfirmasi di dialog sistem)',
              _Phase.done => _cancel && _index < total
                  ? 'Dihentikan: $_index dari $total foto diproses'
                  : '$total foto diproses',
            },
          ),
          const SizedBox(height: 24),
          _stat('Berhasil', '${_ok.length}'),
          _stat('Gagal', '${_failed.length}'),
          if (_skipped > 0) _stat('Dilewati (hasil tidak lebih kecil)', '$_skipped'),
          _stat(raw ? 'Ukuran RAW' : 'Ukuran asli', formatBytes(_inBytes)),
          _stat(raw ? 'Ukuran JPG' : 'Ukuran hasil', formatBytes(_outBytes)),
          if (_inBytes > 0 && _outBytes <= _inBytes)
            _stat('Hemat', '${formatBytes(_inBytes - _outBytes)} '
                '(${((1 - _outBytes / _inBytes) * 100).toStringAsFixed(0)}%)'),
          if (_inBytes > 0 && _outBytes > _inBytes) _stat('Bertambah', formatBytes(_outBytes - _inBytes)),
          if (widget.deleteOriginal && done) _stat(raw ? 'RAW dihapus' : 'Asli dihapus', '$_deleted'),
          if (_deleteError != null) ...[
            const SizedBox(height: 12),
            Text(_deleteError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_failed.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(raw ? 'Gagal dikonversi' : 'Gagal diproses', style: Theme.of(context).textTheme.titleSmall),
            for (final f in _failed)
              ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(f.name), subtitle: Text(f.error)),
          ],
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: done
                ? FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))
                : OutlinedButton(
                    onPressed: _phase == _Phase.converting && !_cancel ? () => setState(() => _cancel = true) : null,
                    child: Text(_cancel ? 'Menghentikan…' : 'Hentikan'),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(k)), Text(v, style: const TextStyle(fontWeight: FontWeight.w600))]),
      );
}
