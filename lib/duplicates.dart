import 'dart:typed_data';

/// Satu foto untuk pencarian duplikat.
class DupPhoto {
  DupPhoto({
    required this.id,
    required this.takenAt,
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
    this.favorite = false,
    this.modified = 0,
    this.name = '',
    this.hash,
  });

  final String id;
  final DateTime takenAt;

  /// Ukuran setelah orientasi (0 = tidak diketahui).
  final int width;
  final int height;

  /// Ukuran file (0 = tidak diketahui).
  final int bytes;
  final bool favorite;

  /// Detik terakhir diubah; hash di cache dipakai ulang selama nilai ini sama.
  final int modified;
  final String name;

  /// dHash 64-bit, null bila belum dihitung atau foto tidak bisa dibaca.
  int? hash;

  int get pixels => width * height;
}

/// dHash 64-bit dari gambar RGBA [w]×[h] (biasanya 9×8): tiap bit = piksel lebih terang
/// daripada tetangga kanannya. Tahan terhadap ubah ukuran dan kompresi ulang.
int dHash(Uint8List rgba, {int w = 9, int h = 8}) {
  assert(rgba.length >= w * h * 4);
  var hash = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w - 1; x++) {
      final i = (y * w + x) * 4;
      final j = i + 4;
      final a = rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114;
      final b = rgba[j] * 299 + rgba[j + 1] * 587 + rgba[j + 2] * 114;
      hash = (hash << 1) | (a > b ? 1 : 0);
    }
  }
  return hash;
}

int _popcount(int v) {
  var n = 0;
  while (v != 0) {
    v &= v - 1;
    n++;
  }
  return n;
}

/// Jumlah bit berbeda antara dua hash.
int hamming(int a, int b) => _popcount(a ^ b);

enum DupKind {
  /// Hampir identik (kiriman ulang, salinan, versi yang diperkecil).
  duplicate,

  /// Mirip dan diambil berdekatan (foto beruntun, beberapa jepretan pose yang sama).
  similar,
}

class DupGroup {
  DupGroup(this.kind, this.photos) : best = photos.first;

  final DupKind kind;

  /// Urut dari yang paling layak disimpan.
  final List<DupPhoto> photos;
  final DupPhoto best;

  /// Saran awal: simpan foto terbaik dan semua favorit, sisanya hapus.
  Set<String> get suggestedKeep => {best.id, for (final p in photos) if (p.favorite) p.id};
}

/// Batas pencarian. Nilai bawaan dipilih agar salah tebak jarang.
class DupRules {
  const DupRules({
    this.duplicateDistance = 3,
    this.similarDistance = 10,
    this.similarWindow = const Duration(minutes: 10),
    this.aspectTolerance = 0.03,
  });

  /// Selisih bit maksimum untuk "Duplikat" (dicari di seluruh galeri).
  final int duplicateDistance;

  /// Selisih bit maksimum untuk "Mirip" (hanya foto yang diambil berdekatan).
  final int similarDistance;
  final Duration similarWindow;

  /// Selisih rasio sisi maksimum (relatif).
  final double aspectTolerance;
}

bool _sameAspect(DupPhoto a, DupPhoto b, double tol) {
  if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) return true;
  final ra = a.width / a.height;
  final rb = b.width / b.height;
  return (ra - rb).abs() / (ra > rb ? ra : rb) <= tol;
}

/// Hash hampir rata (foto hitam, putih polos): terlalu sedikit informasi untuk dicocokkan
/// di seluruh galeri.
bool _lowInfo(int h) {
  final n = _popcount(h);
  return n < 4 || n > 52;
}

/// Urutan "paling layak disimpan": favorit, resolusi terbesar, file terbesar, paling awal.
int compareBest(DupPhoto a, DupPhoto b) {
  if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
  if (a.pixels != b.pixels) return b.pixels.compareTo(a.pixels);
  if (a.bytes != b.bytes) return b.bytes.compareTo(a.bytes);
  return a.takenAt.compareTo(b.takenAt);
}

/// Kelompokkan foto yang hash-nya sudah dihitung. Grup "Duplikat" didahulukan, lalu terbaru.
List<DupGroup> findGroups(List<DupPhoto> photos, {DupRules rules = const DupRules()}) {
  final list = [for (final p in photos) if (p.hash != null) p];
  final n = list.length;
  final parent = List<int>.generate(n, (i) => i);
  final similarEdge = List<bool>.filled(n, false); // root -> grup memakai sambungan "mirip"
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void union(int a, int b, {required bool similar}) {
    final ra = find(a);
    final rb = find(b);
    if (ra == rb) {
      if (similar) similarEdge[ra] = true;
      return;
    }
    parent[rb] = ra;
    similarEdge[ra] = similarEdge[ra] || similarEdge[rb] || similar;
  }

  // 1) Duplikat di seluruh galeri. Bila selisih ≤ 3 bit, salah satu dari 4 blok 16-bit pasti
  //    sama persis: cukup bandingkan foto yang berbagi blok (tanpa O(n²)).
  final blocks = List.generate(4, (_) => <int, List<int>>{});
  for (var i = 0; i < n; i++) {
    final h = list[i].hash!;
    if (_lowInfo(h)) continue;
    final seen = <int>{};
    for (var b = 0; b < 4; b++) {
      final key = (h >> (16 * b)) & 0xFFFF;
      final bucket = blocks[b].putIfAbsent(key, () => []);
      for (final j in bucket) {
        if (!seen.add(j)) continue;
        if (hamming(h, list[j].hash!) <= rules.duplicateDistance &&
            _sameAspect(list[i], list[j], rules.aspectTolerance)) {
          union(j, i, similar: false);
        }
      }
      bucket.add(i);
    }
  }

  // 2) Mirip: hanya foto yang diambil berdekatan.
  final byTime = List<int>.generate(n, (i) => i)..sort((a, b) => list[a].takenAt.compareTo(list[b].takenAt));
  for (var x = 0; x < n; x++) {
    final a = list[byTime[x]];
    for (var y = x + 1; y < n; y++) {
      final b = list[byTime[y]];
      if (b.takenAt.difference(a.takenAt) > rules.similarWindow) break;
      final d = hamming(a.hash!, b.hash!);
      if (d <= rules.similarDistance && _sameAspect(a, b, rules.aspectTolerance)) {
        union(byTime[x], byTime[y], similar: d > rules.duplicateDistance);
      }
    }
  }

  final members = <int, List<DupPhoto>>{};
  for (var i = 0; i < n; i++) {
    members.putIfAbsent(find(i), () => []).add(list[i]);
  }
  final groups = [
    for (final e in members.entries)
      if (e.value.length > 1)
        DupGroup(similarEdge[e.key] ? DupKind.similar : DupKind.duplicate, e.value..sort(compareBest)),
  ];
  groups.sort((a, b) {
    if (a.kind != b.kind) return a.kind.index.compareTo(b.kind.index);
    final ta = a.photos.map((p) => p.takenAt).reduce((x, y) => x.isAfter(y) ? x : y);
    final tb = b.photos.map((p) => p.takenAt).reduce((x, y) => x.isAfter(y) ? x : y);
    return tb.compareTo(ta);
  });
  return groups;
}
