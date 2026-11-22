/// Defter sayfa boyutu seçenekleri (saf Dart).
///
/// Not koordinatında genişlik SABİT [notePageWidth]; yalnızca yükseklik seçilir.
/// "Sonsuz (aşağı kayan)" sayfa: ayrı bayrak YOK (şema değişmez); yüksekliği
/// [infiniteMinHeight] ve üstü olan her sayfa sonsuz sayılır (eski 1404x14040
/// "Sınırsız" sayfalar da). Çizim alt kenara [infiniteTriggerMargin] kadar
/// yaklaşınca yükseklik [infiniteGrowStep] artar ([infiniteGrownHeight]);
/// üst sınır [infiniteMaxHeight]. "Ekrana tam" en çok genişliğin 3 katı
/// (4212) olduğundan eşik onun üstünde seçildi. Sayfa boyutu
/// `ink_note_pages.width/height` sütunlarında tutulur.
library;

import 'dart:math' as math;

/// Not koordinatında sayfa genişliği (tüm boyut türlerinde ortak).
const notePageWidth = 1404.0;

/// A4 dikey yüksekliği (genişlik 1404).
const a4PageHeight = 1984.0;

/// Bu yükseklik ve üstü "sonsuz" sayılır ("ekrana tam" en çok 4212).
const infiniteMinHeight = 4300.0;

/// Yeni sonsuz sayfanın başlangıç yüksekliği.
const infiniteStartHeight = 4400.0;

/// Her uzamada eklenen yükseklik.
const infiniteGrowStep = 2000.0;

/// Çizim alt kenara bu kadar yaklaşınca sayfa uzar.
const infiniteTriggerMargin = 600.0;

/// Sonsuz sayfanın üst sınırı (dolunca kullanıcı uyarılır).
const infiniteMaxHeight = 200000.0;

enum PageSizeKind {
  a4('a4', 'A4 dikey'),
  screen('screen', 'Ekrana tam (cihaz oranı)'),
  infinite('infinite', 'Sonsuz (aşağı kayan)');

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
    case PageSizeKind.infinite:
      return (width: notePageWidth, height: infiniteStartHeight);
  }
}

/// Kayıtlı boyuttan tür tahmini (diyalogta ilk seçim için).
PageSizeKind pageSizeKindOf(double width, double height) {
  if (isInfinitePage(height)) return PageSizeKind.infinite;
  if ((height - a4PageHeight).abs() < 1) return PageSizeKind.a4;
  return PageSizeKind.screen;
}

/// Yüksekliğe göre sayfa sonsuz mu (bayrak yok; bkz. dosya başı).
bool isInfinitePage(double height) => height >= infiniteMinHeight;

/// Çizgilerin en alt noktası [maxStrokeY] için gereken yeni yükseklik. Sonsuz
/// olmayan sayfada ya da uzama gerekmiyorsa [height] aynen döner. Üst sınırı
/// aşmaz ([infiniteMaxHeight]); sınırda kalındıysa [height] döner.
double infiniteGrownHeight(double height, double maxStrokeY) {
  if (!isInfinitePage(height) || !maxStrokeY.isFinite) return height;
  var h = height;
  while (maxStrokeY > h - infiniteTriggerMargin && h < infiniteMaxHeight) {
    h = math.min(h + infiniteGrowStep, infiniteMaxHeight);
  }
  return h;
}

/// Sonsuz sayfa üst sınıra yaklaştı/vardı mı (uyarı için).
bool infiniteAtLimit(double height, double maxStrokeY) =>
    isInfinitePage(height) &&
    height >= infiniteMaxHeight &&
    maxStrokeY > height - infiniteTriggerMargin;
