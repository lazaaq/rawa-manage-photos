import 'package:flutter/material.dart';

/// Kartu yang bisa digeser: kanan = simpan, kiri = hapus.
/// Posisi direset setiap [id] berganti (foto berikutnya).
class SwipeCard extends StatefulWidget {
  const SwipeCard({super.key, required this.id, required this.child, required this.onSwiped});

  final String id;
  final Widget child;
  final void Function(bool keep) onSwiped;

  @override
  State<SwipeCard> createState() => SwipeCardState();
}

class SwipeCardState extends State<SwipeCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(_tick);

  Offset _offset = Offset.zero;
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  bool _flying = false;

  /// Lebar kartu dari layout terakhir.
  double _width = 300;
  double get _threshold => _width * 0.3;

  void _tick() => setState(() => _offset = Offset.lerp(_from, _to, Curves.easeOut.transform(_c.value))!);

  Future<void> _animateTo(Offset target) {
    _from = _offset;
    _to = target;
    return _c.forward(from: 0).orCancel.catchError((_) {});
  }

  /// Lempar kartu keluar layar lalu laporkan keputusannya.
  Future<void> swipe({required bool keep}) async {
    if (_flying) return;
    _flying = true;
    await _animateTo(Offset((keep ? 1 : -1) * _width * 1.5, _offset.dy));
    if (mounted) widget.onSwiped(keep);
  }

  @override
  void didUpdateWidget(SwipeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _c.stop();
      _offset = Offset.zero;
      _flying = false;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onEnd(DragEndDetails d) {
    if (_flying) return;
    final vx = d.velocity.pixelsPerSecond.dx;
    if (_offset.dx > _threshold || vx > 1000) {
      swipe(keep: true);
    } else if (_offset.dx < -_threshold || vx < -1000) {
      swipe(keep: false);
    } else {
      _animateTo(Offset.zero);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (box.maxWidth.isFinite && box.maxWidth > 0) _width = box.maxWidth;
        return _card();
      });

  Widget _card() {
    final progress = (_offset.dx / _threshold).clamp(-1.0, 1.0);
    return GestureDetector(
      onPanUpdate: (d) {
        if (!_flying) setState(() => _offset += d.delta);
      },
      onPanEnd: _onEnd,
      child: Transform.translate(
        offset: _offset,
        child: Transform.rotate(
          angle: _offset.dx / _width * 0.3,
          child: Stack(fit: StackFit.expand, children: [
            widget.child,
            Positioned(
              top: 24,
              left: 20,
              child: Opacity(opacity: progress > 0 ? progress : 0, child: const _Stamp('SIMPAN', Colors.green, -0.25)),
            ),
            Positioned(
              top: 24,
              right: 20,
              child: Opacity(opacity: progress < 0 ? -progress : 0, child: const _Stamp('HAPUS', Colors.red, 0.25)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp(this.text, this.color, this.angle);

  final String text;
  final Color color;
  final double angle;

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: angle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black26,
            border: Border.all(color: color, width: 4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(text, style: TextStyle(color: color, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 2)),
          ),
        ),
      );
}
