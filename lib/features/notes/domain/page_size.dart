/// Defter sayfa boyutu seçenekleri (saf Dart).
///
/// Not koordinatında genişlik SABİT [notePageWidth]; yalnızca yükseklik seçilir.
/// "Sınırsız" gerçek sonsuz tuval DEĞİLDİR (veri modeli sayfa boyutludur):
/// genişliğin 10 katı yüksekliğinde ([freePageHeight]) çok uzun bir sayfadır;
/// zum ve kaydırmayla gezilir. Sayfa boyutu `ink_note_pages.width/height`
/// sütunlarında tutulur (şema değişmez).
library;

import 'dart:math' as math;

/// Not koordinatında sayfa genişliği (tüm boyut türlerinde ortak).
const notePageWidth = 1404.0;

/// A4 dikey yüksekliği (genişlik 1404).
const a4PageHeight = 1984.0;

/// "Sınırsız (serbest tuval)" yüksekliği: genişliğin 10 katı (1404 x 14040).
const freePageHeight = 14040.0;

enum PageSizeKind {
  a4('a4', 'A4 dikey'),
  screen('screen', 'Ekrana tam (cihaz oranı)'),
  free('free', 'Sınırsız (serbest tuval)');

  const PageSizeKind(this.key, this.label);
  final String key;
  final String label;
}

/// Cihaz oranı (uzun kenar / kısa kenar, hep >= 1). Geçersiz boyutta A4 oranı.
double screenAspect(double width, double height) {
  if (!(width > 0) || !(height > 0)) return a4PageHeight / notePageWidth;
  return math.max(width, height) / math.min(width, height);
}

/// [kind] için (genişlik, yükseklik). [aspect] yalnızca `screen` için; makul
/// aralığa (1.2..3) kırpılır.
({double width, double height}) pageDimensions(
  PageSizeKind kind, {
  double? aspect,
}) {
  switch (kind) {
    case PageSizeKind.a4:
      return (width: notePageWidth, height: a4PageHeight);
    case PageSizeKind.screen:
      final a = (aspect ?? a4PageHeight / notePageWidth).clamp(1.2, 3.0);
      return (
        width: notePageWidth,
        height: (notePageWidth * a).roundToDouble(),
      );
    case PageSizeKind.free:
      return (width: notePageWidth, height: freePageHeight);
  }
}

/// Kayıtlı boyuttan tür tahmini (diyalogta ilk seçim için).
PageSizeKind pageSizeKindOf(double width, double height) {
  if (height >= freePageHeight) return PageSizeKind.free;
  if ((height - a4PageHeight).abs() < 1) return PageSizeKind.a4;
  return PageSizeKind.screen;
}
