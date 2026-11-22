/// Ekran ↔ PDF sayfa koordinatı dönüşümü (saf Dart).
///
/// Sayfa koordinatı: PDF birimi (1/72 inç), sayfa DÖNDÜRÜLMÜŞ (görünen) haliyle,
/// başlangıç sol-üst, y aşağı. `/Rotate 90` sayfada [pageWidth] ile [pageHeight]
/// görünen yöne göre verilir ([displayedSize]); çizgiler bu uzayda saklandığından
/// yakınlaştırma ve döndürme çizgiyi kaydırmaz.
///
/// Görünüm tarafı: sayfanın ekrandaki dikdörtgeni ([viewWidth] x [viewHeight]).
/// Yakınlaştırma görünüm boyutunu büyütür; sayfa koordinatı değişmez.
library;

import 'dart:ui' show Offset, Size;

class PageCoords {
  const PageCoords._(
    this.pageWidth,
    this.pageHeight,
    this.viewWidth,
    this.viewHeight,
  );

  final double pageWidth;
  final double pageHeight;
  final double viewWidth;
  final double viewHeight;

  /// Boyutlardan biri sıfır, negatif ya da sonlu değilse null.
  static PageCoords? tryCreate({
    required double pageWidth,
    required double pageHeight,
    required double viewWidth,
    required double viewHeight,
  }) {
    for (final v in [pageWidth, pageHeight, viewWidth, viewHeight]) {
      if (!v.isFinite || v <= 0) return null;
    }
    return PageCoords._(pageWidth, pageHeight, viewWidth, viewHeight);
  }

  /// Dönmemiş sayfa boyutu ve `/Rotate` (derece) → görünen boyut.
  /// 90 ve 270'te en-boy yer değiştirir. Geçersiz açı 360'a göre alınır.
  static Size displayedSize(
    double nativeWidth,
    double nativeHeight,
    int rotationDegrees,
  ) {
    final turns = ((rotationDegrees ~/ 90) % 4 + 4) % 4;
    return turns.isOdd
        ? Size(nativeHeight, nativeWidth)
        : Size(nativeWidth, nativeHeight);
  }

  /// Görünüm pikseli başına sayfa birimi (yatay).
  double get pageUnitsPerViewPx => pageWidth / viewWidth;

  /// Sayfa biriminin görünümdeki piksel karşılığı (yatay).
  double get viewPxPerPageUnit => viewWidth / pageWidth;

  /// Görünüm (sayfa dikdörtgenine göre yerel) noktası → sayfa noktası.
  Offset toPage(Offset view) => Offset(
    view.dx * pageWidth / viewWidth,
    view.dy * pageHeight / viewHeight,
  );

  /// Sayfa noktası → görünüm noktası.
  Offset toView(Offset page) => Offset(
    page.dx * viewWidth / pageWidth,
    page.dy * viewHeight / pageHeight,
  );

  /// Ekran noktası → sayfa noktası; [pageOrigin] sayfanın ekrandaki sol-üst köşesi.
  Offset screenToPage(Offset screen, Offset pageOrigin) =>
      toPage(screen - pageOrigin);

  Offset pageToScreen(Offset page, Offset pageOrigin) =>
      toView(page) + pageOrigin;
}
