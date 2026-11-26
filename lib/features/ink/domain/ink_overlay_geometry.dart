/// Ink katmanı geometrisi (saf Dart): pencere pikseli -> sayfa/görünüm koordinatı, bölge seçimi,
/// fırça eşleme. Birimler: "px" fiziksel piksel (yerel katman), "mantıksal" Flutter pikseli
/// (px / devicePixelRatio), "görünüm" sayfa katmanına göre yerel mantıksal piksel.
library;

import 'dart:ui' show Offset, Rect;

import '../data/ink_overlay_codec.dart';
import 'ink_models.dart';
import 'pen_profiles.dart';

// --- KALİBRASYON (tabletle kalibre edilecek) ---
//
// Flutter kuru çizgisi (perfect_freehand, `inkOutlinePath`) ile Ink ıslak çizgisi (`pressurePen`)
// kalınlık eğrisi farklıdır; tam eşleşme beklenmez. Aşağıdaki sabitler Ink boyutunu Flutter'ınkine
// yaklaştırmak içindir. Başlangıç değerleri 1.0 (ölçüm yok); gerçek tabletle ıslak -> kuru geçişte
// kalınlık sıçraması gözlenirse yalnız bunlar ayarlanır.

/// Ink `pressurePen` boyutuna genel çarpan (kalem türlerinde).
const double kInkOverlayPenSizeScale = 1.0;

/// Ink `marker` (baskıya duyarsız) boyutuna çarpan.
const double kInkOverlayMarkerSizeScale = 1.0;

/// Ink `highlighter` boyutuna çarpan (Flutter fosforlu dikdörtgen uçlu, Ink yuvarlak/yatay uçlu).
const double kInkOverlayHighlighterSizeScale = 1.0;

/// Ink için kullanılacak fırça (ARGB, piksel boyutu ve ailesi).
class OverlayBrush {
  const OverlayBrush({required this.mode, required this.family, required this.argb, required this.sizePx});
  final InkOverlayMode mode;
  final InkOverlayFamily family;
  final int argb;
  final double sizePx;

  @override
  bool operator ==(Object other) =>
      other is OverlayBrush &&
      other.mode == mode &&
      other.family == family &&
      other.argb == argb &&
      other.sizePx == sizePx;

  @override
  int get hashCode => Object.hash(mode, family, argb, sizePx);
}

/// Oturum fırçasını (genişlik GÖRÜNÜM mantıksal pikseli) Ink fırçasına çevirir. Silgi için null:
/// silgi Flutter'da kalır. Fosforlu: renk alfası Flutter'daki saydamlıkla (profil ya da 0,35) çarpılır.
OverlayBrush? overlayBrushFor(InkBrush b, double dpr) {
  if (b.tool == InkTool.eraser) return null;
  final profile = b.kind == null ? null : penProfiles[b.kind];
  final highlighter = b.tool == InkTool.highlighter || b.kind == PenKind.highlighter;
  final base = b.width * dpr;
  if (highlighter) {
    final opacity = profile?.opacity ?? 0.35;
    final a = (((b.color >> 24) & 0xFF) * opacity).round().clamp(0, 255);
    return OverlayBrush(
      mode: InkOverlayMode.highlighter,
      family: InkOverlayFamily.highlighter,
      argb: (a << 24) | (b.color & 0x00FFFFFF),
      sizePx: base * kInkOverlayHighlighterSizeScale,
    );
  }
  final pressure = profile?.pressureSensitive ?? true;
  // Flutter kalınlığı baskıyla (minFactor..maxFactor) değişir; Ink baskıyı kendisi işler,
  // bu yüzden ortalama çarpan taban boyuta uygulanır.
  final factor = profile == null ? 1.0 : (profile.minFactor + profile.maxFactor) / 2;
  final opacity = profile?.opacity ?? 1.0;
  final a = (((b.color >> 24) & 0xFF) * opacity).round().clamp(0, 255);
  return OverlayBrush(
    mode: InkOverlayMode.pen,
    family: pressure ? InkOverlayFamily.pressurePen : InkOverlayFamily.marker,
    argb: (a << 24) | (b.color & 0x00FFFFFF),
    sizePx: base * factor * (pressure ? kInkOverlayPenSizeScale : kInkOverlayMarkerSizeScale),
  );
}

/// [point] (px) hangi dikdörtgenin içinde: birden fazlaysa SON olanı (üstte çizilen) seçer;
/// hiçbirinde değilse null.
int? pickRegionIndex(List<Rect> regionsPx, Offset pointPx) {
  for (var i = regionsPx.length - 1; i >= 0; i--) {
    if (regionsPx[i].contains(pointPx)) return i;
  }
  return null;
}

/// Pencere pikselini sayfa katmanına göre yerel mantıksal piksele çevirir.
/// [layerOriginLogical]: katmanın sol-üst köşesinin pencere mantıksal koordinatı (kaydırma ve
/// yakınlaştırma dahil, çizgi bittiği andaki).
Offset overlayPxToView(Offset px, {required double dpr, required Offset layerOriginLogical}) =>
    Offset(px.dx / dpr, px.dy / dpr) - layerOriginLogical;

/// Yerel noktaları görünüm noktalarına çevirir ([InkPoint]: x/y görünüm mantıksal piksel, baskı
/// [shapePressure]'dan geçer, tilt radyan, tMs ms). Sayfa birimine çeviri `PdfInkSession.addStroke`ta.
List<InkPoint> overlayPointsToView(
  List<OverlayPoint> points, {
  required double dpr,
  required Offset layerOriginLogical,
  double Function(double raw)? shapePressure,
}) {
  return [
    for (final p in points)
      () {
        final v = overlayPxToView(Offset(p.x, p.y), dpr: dpr, layerOriginLogical: layerOriginLogical);
        return InkPoint(
          x: v.dx,
          y: v.dy,
          pressure: shapePressure == null ? p.pressure : shapePressure(p.pressure),
          tilt: p.tilt,
          tMs: p.tMs,
        );
      }(),
  ];
}
