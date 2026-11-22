import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ink/data/ink_surface_b.dart' show inkPointerDraws;
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

/// Görünümü (PDF kaydırıcıyı) saran kalem girişi.
///
/// Sayfa katmanları dokunuş almaz; kalem olaylarını burası ilgili sayfaya
/// yollar. Kalem hareket arenasını hemen kazanır (görünüm kalemle kaymaz),
/// kalem çizerken ikinci temas (avuç) yutulur; kalem yokken parmak görünüme gider.
class PdfInkInput extends StatefulWidget {
  const PdfInkInput({super.key, required this.session, required this.child});
  final PdfInkSession session;
  final Widget child;

  @override
  State<PdfInkInput> createState() => _PdfInkInputState();
}

class _PdfInkInputState extends State<PdfInkInput> {
  /// Çizen işaretçi → sayfa katmanı (katman sonradan ekrandan çıksa bile
  /// olaylar ona gider; `containsGlobal` yalnızca başlangıçta bakar).
  final Map<int, PdfPageInkLayerState> _routes = {};

  void _down(PointerDownEvent e) {
    if (!inkPointerDraws(e.kind, stylusOnly: true)) return;
    final layer = widget.session.layerAt(e.position);
    if (layer == null) return;
    _routes[e.pointer] = layer;
    layer.pointerDown(e);
  }

  void _move(PointerMoveEvent e) => _routes[e.pointer]?.pointerMove(e);

  void _up(PointerUpEvent e) => _routes.remove(e.pointer)?.pointerUp(e);

  void _cancel(PointerCancelEvent e) =>
      _routes.remove(e.pointer)?.pointerCancel(e);

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        InkPointerClaim: GestureRecognizerFactoryWithHandlers<InkPointerClaim>(
          () => InkPointerClaim(widget.session),
          (r) => r.session = widget.session,
        ),
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: widget.child,
      ),
    );
  }
}

/// Kalem temasını görünümün kaydırma/yakınlaştırma hareketinden önce alır
/// (hareket arenasında hemen kazanır). Kalem çizerken gelen parmak/avuç
/// teması da burada yutulur. Parmak (kalem yokken) alınmaz: görünüme gider.
class InkPointerClaim extends OneSequenceGestureRecognizer {
  InkPointerClaim(this.session);

  PdfInkSession session;
  final Set<int> _mine = {};

  @override
  void dispose() {
    // Sayfa ekrandan çıkarken tutulan kalem temasları oturumda takılı kalmasın.
    for (final p in _mine) {
      session.penUp(p);
    }
    _mine.clear();
    super.dispose();
  }

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    final stylus =
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    final palm = session.penActive && event.kind == PointerDeviceKind.touch;
    return stylus || palm;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    if (event.kind != PointerDeviceKind.touch) {
      _mine.add(event.pointer);
      session.penDown(event.pointer);
    }
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_mine.remove(event.pointer)) session.penUp(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'InkPointerClaim';
}
