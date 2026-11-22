import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ink/data/ink_surface_b.dart' show inkPointerDraws;
import '../../../app/platform.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

/// Bu yarıçaptan (`PointerEvent.radiusMajor`) büyük dokunuş avuçtur: görünüme
/// gitmez, yutulur. Casper PAD H10'da ölçüm: parmak ~75-143 (birimi cihaz
/// bildirir, mantıksal pikselle uyuşmaz). Bu yüzden eşik parmağın çok üstünde
/// (260). Asıl avuç koruması boyut değil KALEM YAKINLIĞIDIR (havada ya da
/// çizerken her temas yutulur); boyut yalnız çok büyük temaslar içindir.
/// Gerçek avuç boyutu ölçülünce ayarlanır. Cihaz bildirmezse 0 gelir (işlemez).
const double palmRadiusMajor = 260;

/// Görünümü (PDF kaydırıcıyı) saran kalem girişi.
///
/// Sayfa katmanları dokunuş almaz; kalem olaylarını burası ilgili sayfaya
/// yollar. Kalem bir sayfanın üstündeyken hareket arenasını hemen kazanır
/// (görünüm kalemle kaymaz), kalem çizerken ikinci temas (avuç) yutulur;
/// kalem yokken parmak görünüme gider.
///
/// Avuç kalemden ÖNCE değerse görünüm onu zaten izliyordur: bunu iki katman
/// önler. (1) Büyük temas (`radiusMajor`) baştan yutulur. (2) Kalem bir sayfanın
/// üstüne yaklaşınca (havada) ya da çizerken [PdfInkSession.viewerLocked]
/// açılır; okuyucu görünümün kaydırma/yakınlaştırmasını kapatır.
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

  void _down(PointerDownEvent e) {
    if (!inkPointerDraws(e.kind, stylusOnly: widget.stylusOnly)) return;
    final layer = widget.session.layerAt(e.position);
    if (layer == null) return;
    _routes[e.pointer] = layer;
    layer.pointerDown(e);
  }

  void _hover(PointerHoverEvent e) {
    if (e.kind != PointerDeviceKind.stylus && e.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    final layer = widget.session.layerAt(e.position);
    widget.session.penHover(overPage: layer != null);
    layer?.pointerHover(e);
  }

  void _move(PointerMoveEvent e) => _routes[e.pointer]?.pointerMove(e);

  void _up(PointerUpEvent e) => _routes.remove(e.pointer)?.pointerUp(e);

  void _cancel(PointerCancelEvent e) => _routes.remove(e.pointer)?.pointerCancel(e);

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
      // Avuç: kalem çiziyorsa ya da temas büyükse yut.
      return session.penActive || session.penNear || event.radiusMajor >= palmRadiusMajor;
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
