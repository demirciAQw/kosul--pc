import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Parmakla kaydırma ve yakınlaştırma. YALNIZCA parmak (touch) dinlenir:
/// kalem ve fare çizim içindir, görünümü oynatmaz. Çocuk, dönüşümün içinde
/// olduğundan çizim koordinatları (localPosition) dönüşümden bağımsızdır.
class InkViewport extends StatefulWidget {
  const InkViewport({
    super.key,
    required this.child,
    this.minScale = 0.5,
    this.maxScale = 8,
    this.drawingActive,
    this.transformChild = true,
    this.onMatrixChanged,
  });

  /// Kalem çizerken true döner: bu sırada ikinci temas/avuç görünümü
  /// oynatmaz.
  final bool Function()? drawingActive;

  final Widget child;

  /// false: çocuk Flutter dönüşümüyle ölçeklenmez (yerel görünüm bulanmasın);
  /// dönüşümü [onMatrixChanged] ile alan çocuk kendisi uygular (A yüzeyi).
  final bool transformChild;

  /// Görünüm matrisi (dünya -> görünüm; sol-üst kaynaklı) her değiştiğinde.
  final ValueChanged<Matrix4>? onMatrixChanged;
  final double minScale;
  final double maxScale;

  @override
  State<InkViewport> createState() => InkViewportState();
}

class InkViewportState extends State<InkViewport> {
  Matrix4 _m = Matrix4.identity();
  double _startScale = 1;

  Matrix4 get matrix => _m;

  void reset() {
    setState(() => _m = Matrix4.identity());
    widget.onMatrixChanged?.call(_m);
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        ScaleGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
              () => ScaleGestureRecognizer(
                supportedDevices: {PointerDeviceKind.touch},
              ),
              (r) {
                r.onStart = (d) {
                  _startScale = 1;
                };
                r.onUpdate = _update;
              },
            ),
      },
      child: ClipRect(
        child: widget.transformChild
            ? Transform(transform: _m, child: widget.child)
            : widget.child,
      ),
    );
  }

  void _update(ScaleUpdateDetails d) {
    if (widget.drawingActive?.call() ?? false) {
      _startScale = d.scale; // çizim bitince atlama olmasın
      return;
    }
    final current = _m.getMaxScaleOnAxis();
    var ds = d.scale / _startScale;
    _startScale = d.scale;
    final target = (current * ds).clamp(widget.minScale, widget.maxScale);
    ds = target / current;
    // Odak noktası çevresinde ölçekle, ardından parmak kadar kaydır.
    final local = _focalLocal(d);
    final m = Matrix4.identity()
      ..translateByDouble(d.focalPointDelta.dx, d.focalPointDelta.dy, 0, 1)
      ..translateByDouble(local.dx, local.dy, 0, 1)
      ..scaleByDouble(ds, ds, 1, 1)
      ..translateByDouble(-local.dx, -local.dy, 0, 1)
      ..multiply(_m);
    setState(() => _m = m);
    widget.onMatrixChanged?.call(m);
  }

  Offset _focalLocal(ScaleUpdateDetails d) {
    final box = context.findRenderObject() as RenderBox;
    return box.globalToLocal(d.focalPoint - d.focalPointDelta);
  }
}
