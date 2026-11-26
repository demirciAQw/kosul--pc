
import 'package:flutter/widgets.dart';

/// Yerel Ink katmanının "kalem burada çizmesin" bölgeleri (araç çubuğu, yüzen düğmeler).
/// [InkMask] ile sarılan her Flutter öğesi kayda girer; `PdfInkOverlay` her karede
/// dikdörtgenleri okuyup `setMask` ile yerele bildirir (geometri değişince, ör. döndürme ya da
/// açılır pencere, bir sonraki karede kendiliğinden güncellenir).
class InkMaskRegistry {
  InkMaskRegistry._();

  static final Set<RenderBox Function()> _sources = {};

  static void add(RenderBox Function() source) => _sources.add(source);
  static void remove(RenderBox Function() source) => _sources.remove(source);

  /// Kayıtlı öğelerin pencere koordinatındaki dikdörtgenleri (fiziksel piksel).
  static List<Rect> rectsPx(double dpr) {
    final out = <Rect>[];
    for (final s in _sources) {
      final box = s();
      if (!box.attached || !box.hasSize) continue;
      final r = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      if (r.isEmpty) continue;
      out.add(
        Rect.fromLTRB(r.left * dpr, r.top * dpr, r.right * dpr, r.bottom * dpr),
      );
    }
    return out;
  }

  @visibleForTesting
  static int get count => _sources.length;
}

/// [child] alanında yerel kalem çizmez (çubuk/düğme üstüne yazılmasın).
class InkMask extends StatefulWidget {
  const InkMask({super.key, required this.child});
  final Widget child;

  @override
  State<InkMask> createState() => _InkMaskState();
}

class _InkMaskState extends State<InkMask> {
  late final RenderBox Function() _source = _box;

  RenderBox _box() {
    if (!mounted) return _Detached.instance;
    try {
      final o = context.findRenderObject();
      return o is RenderBox ? o : _Detached.instance;
    } catch (_) {
      return _Detached.instance; // etkin olmayan öğe: bu karede atla
    }
  }

  @override
  void initState() {
    super.initState();
    InkMaskRegistry.add(_source);
  }

  @override
  void dispose() {
    InkMaskRegistry.remove(_source);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Bağlı olmayan öğe için yer tutucu (attached=false: atlanır).
class _Detached extends RenderBox {
  static final _Detached instance = _Detached();
}
