import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ink/data/ink_surface_b.dart' show inkPointerDraws;
import '../../../app/platform.dart';
import '../../../core/pen_diag.dart';
import '../domain/palm_rejector.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

// Avuç koruması: boyut + MESAFE. Kalem aşağıdayken tüm dokunmalar yutulur;
// havadayken yalnız kalem konumuna [PdfInkSession.palmNearDistance] içindeki
// dokunma yutulur (görünüm kilidi yok), uzak parmak ve iki parmak zum geçer.

/// Bu yarıçaptan (`PointerEvent.radiusMajor`) büyük dokunuş avuçtur: görünüme
/// gitmez, yutulur. Casper PAD H10'da ölçüm: parmak ~75-143 (birimi cihaz
/// bildirir, mantıksal pikselle uyuşmaz). Bu yüzden eşik parmağın çok üstünde
/// (260). Asıl avuç koruması boyut değil KALEM YAKINLIĞIDIR (havada ya da
/// çizerken her temas yutulur); boyut yalnız çok büyük temaslar içindir.
/// Gerçek avuç boyutu ölçülünce ayarlanır. Cihaz bildirmezse 0 gelir (işlemez).
const double palmRadiusMajor = palmBigRadius;

/// Görünümü (PDF kaydırıcıyı) saran kalem girişi.
///
/// Sayfa katmanları dokunuş almaz; kalem olaylarını burası ilgili sayfaya
/// yollar. Kalem bir sayfanın üstündeyken hareket arenasını hemen kazanır
/// (görünüm kalemle kaymaz), kalem çizerken ikinci temas (avuç) yutulur;
/// kalem yokken parmak görünüme gider.
///
/// Avuç kalemden ÖNCE değerse görünüm onu zaten izliyordur: bunu iki katman
/// önler. (1) Büyük temas (`radiusMajor`) baştan yutulur. (2) Kalem bir sayfanın
/// çizerken [PdfInkSession.viewerLocked] açılır (havadayken kilit yok; yakın
/// temas tek tek yutulur).
///
/// Kalem sayfalar ARASI boşluktayken (sayfa dışı) bilinçli olarak arenayı
/// ALMAZ ve çizmez: kalem/parmak görünümü kaydırır; kilit de açıktır.
///
/// [stylusOnly]: telefon/tablette yalnızca kalem çizer; masaüstünde (fare)
/// fare de çizer. Varsayılan `!isDesktop`.
class PdfInkInput extends StatefulWidget {
  const PdfInkInput({super.key, required this.session, required this.child, this.stylusOnlyOverride});
  final PdfInkSession session;
  final Widget child;
  final bool? stylusOnlyOverride;

  bool get stylusOnly => stylusOnlyOverride ?? !isDesktop;

  @override
  State<PdfInkInput> createState() => _PdfInkInputState();
}

class _PdfInkInputState extends State<PdfInkInput> {
  /// Çizen işaretçi → sayfa katmanı (katman sonradan ekrandan çıksa bile
  /// olaylar ona gider; `containsGlobal` yalnızca başlangıçta bakar).
  final Map<int, PdfPageInkLayerState> _routes = {};

  /// Tanı günlüğü kararı (yalnız [PenDiag.enabled] iken çağrılır).
  String _decision(PointerEvent e) {
    final s = widget.session;
    if (e.kind == PointerDeviceKind.touch) {
      return s.palm.isPalm(e.pointer) || !s.passedTouches.contains(e.pointer)
          ? PenDecision.swallowed
          : PenDecision.toView;
    }
    return _routes.containsKey(e.pointer) ? PenDecision.penTook : PenDecision.noLayer;
  }

  void _diag(String name, PointerEvent e, [String? decision]) {
    if (!PenDiag.enabled) return;
    PenDiag.log(
      name,
      tMs: e.timeStamp.inMilliseconds,
      kind: e.kind.name,
      device: e.device,
      pointer: e.pointer,
      x: e.position.dx,
      y: e.position.dy,
      pressure: e.pressure,
      radiusMajor: e.radiusMajor,
      decision: decision ?? _decision(e),
    );
  }

  void _down(PointerDownEvent e) {
    if (!inkPointerDraws(e.kind, stylusOnly: widget.stylusOnly)) {
      _diag('down', e);
      return;
    }
    final layer = widget.session.layerAt(e.position);
    if (layer != null) _routes[e.pointer] = layer;
    _diag('down', e);
    if (layer == null) return;
    layer.pointerDown(e);
  }

  void _hover(PointerHoverEvent e) {
    if (e.kind != PointerDeviceKind.stylus && e.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    final layer = widget.session.layerAt(e.position);
    widget.session.penHover(
      overPage: layer != null,
      position: e.position,
      tMs: e.timeStamp.inMicroseconds / 1000,
    );
    _diag('hover', e, layer == null ? PenDecision.noLayer : PenDecision.penTook);
    layer?.pointerHover(e);
  }

  void _move(PointerMoveEvent e) {
    _diag('move', e);
    _routes[e.pointer]?.pointerMove(e);
  }

  void _up(PointerUpEvent e) {
    _diag('up', e);
    widget.session.passedTouches.remove(e.pointer);
    if (e.kind == PointerDeviceKind.touch) widget.session.palmTouchUp(e.pointer);
    _routes.remove(e.pointer)?.pointerUp(e);
  }

  void _cancel(PointerCancelEvent e) {
    final pen = e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;
    _diag('cancel', e, pen && _routes.containsKey(e.pointer) ? PenDecision.cancelSaved : null);
    widget.session.passedTouches.remove(e.pointer);
    if (e.kind == PointerDeviceKind.touch) widget.session.palmTouchUp(e.pointer);
    _routes.remove(e.pointer)?.pointerCancel(e);
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        InkPointerClaim: GestureRecognizerFactoryWithHandlers<InkPointerClaim>(
          () => InkPointerClaim(widget.session, stylusOnly: widget.stylusOnly),
          (r) {
            r.session = widget.session;
            r.stylusOnly = widget.stylusOnly;
          },
        ),
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _down,
        onPointerHover: _hover,
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
  InkPointerClaim(this.session, {this.stylusOnly = true});

  PdfInkSession session;
  bool stylusOnly;
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
    if (event.kind == PointerDeviceKind.touch) {
      // Avuç: kalem aşağıdayken her temas; havadayken yalnız kalem konumuna
      // yakın temas (yazan elin avucu); ya da temas çok büyükse. Uzak temas
      // ve görünümde süren bir temasa eşlik eden ikinci parmak (zum) geçer.
      var swallow = session.penActive ||
          event.radiusMajor >= palmRadiusMajor ||
          (session.passedTouches.isEmpty && session.isPalmNearPen(event.position));
      // Geriye dönük avuç reddi: kayıt (dönüşüm anlık görüntüsü) + ≥3 temas.
      final palm = session.palmTouchDown(
        pointer: event.pointer,
        tMs: event.timeStamp.inMicroseconds / 1000,
        position: event.position,
        radius: event.radiusMajor,
        swallowed: swallow,
      );
      swallow = swallow || palm;
      if (!swallow) session.passedTouches.add(event.pointer);
      return swallow;
    }
    if (!inkPointerDraws(event.kind, stylusOnly: stylusOnly)) return false;
    // Sayfa dışında (sayfalar arası boşluk) arenayı alma: görünüm kayabilsin.
    return session.layerAt(event.position) != null;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    if (event.kind != PointerDeviceKind.touch) {
      _mine.add(event.pointer);
      session.penDown(event.pointer, event.position, event.timeStamp.inMicroseconds / 1000);
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
