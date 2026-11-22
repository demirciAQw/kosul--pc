/// PDF motoru arayüzü (saf Dart). Gerçek uygulama `data/pdfrx_engine.dart`;
/// testlerde sahte motor kullanılır. Bu dosya pdfrx'i bilmez.
///
/// Kurallar:
/// - Sayfa numarası 0'dan başlar (`ink_strokes.pdfPage` ile aynı).
/// - Boyutlar ve kutular PDF birimidir (1/72 inç), sayfa DÖNDÜRÜLMÜŞ haliyle,
///   başlangıç sol-üst, y aşağı (ekran gibi). Motor kendi koordinatını çevirir.
library;

import 'dart:typed_data';

/// Sayfa boyutu (PDF birimi, döndürme uygulanmış).
class PdfPageSize {
  const PdfPageSize(this.width, this.height);
  final double width;
  final double height;

  @override
  bool operator ==(Object other) => other is PdfPageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'PdfPageSize($width x $height)';
}

/// Sayfa üzerinde dikdörtgen (PDF birimi, sol-üst başlangıç, y aşağı).
class PdfBox {
  const PdfBox(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// İki köşeden, sırası fark etmeden (kalemle çizilen kutu için).
  factory PdfBox.fromCorners(double x1, double y1, double x2, double y2) => PdfBox(
        x1 < x2 ? x1 : x2,
        y1 < y2 ? y1 : y2,
        x1 < x2 ? x2 : x1,
        y1 < y2 ? y2 : y1,
      );

  bool overlaps(PdfBox o) => left < o.right && o.left < right && top < o.bottom && o.top < bottom;

  /// Kutunun [o] ile kesişen alanının kendi alanına oranı (0..1).
  double coverageBy(PdfBox o) {
    final w = (right < o.right ? right : o.right) - (left > o.left ? left : o.left);
    final h = (bottom < o.bottom ? bottom : o.bottom) - (top > o.top ? top : o.top);
    final area = width * height;
    if (w <= 0 || h <= 0 || area <= 0) return 0;
    return (w * h) / area;
  }

  @override
  bool operator ==(Object other) =>
      other is PdfBox && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PdfBox($left, $top, $right, $bottom)';
}

/// Piksel bayt sırası.
enum PdfPixelFormat { rgba, bgra }

/// Çizilmiş sayfa: piksel başına 4 bayt, [format] sırasıyla (dart:ui'den bağımsız).
/// PDFium BGRA verir; dönüşüm çağırana kalır (kopya yok). Android/Skia için
/// BGRA doğrudan `ui.decodeImageFromPixels(..., PixelFormat.bgra8888)` ile açılır.
class PdfRenderedImage {
  const PdfRenderedImage({
    required this.width,
    required this.height,
    required this.bytes,
    this.format = PdfPixelFormat.rgba,
  });
  final int width;
  final int height;
  final Uint8List bytes;
  final PdfPixelFormat format;

  /// Verilen pikselin (x, y) R, G, B, A değerleri (biçimden bağımsız).
  List<int> rgbaAt(int x, int y) {
    final i = (y * width + x) * 4;
    return format == PdfPixelFormat.rgba
        ? [bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]
        : [bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3]];
  }
}

/// Bir sayfa çiziminin piksel üst sınırı (16 MP ≈ 64 MB). Aşılırsa [ArgumentError];
/// çağıran ölçeği kendisi küçültür (sessiz küçültme yok: ink eşlemesi boyuta bağlı).
const int maxRenderPixels = 16 * 1000 * 1000;

/// PDF açılamadı (bozuk, şifreli, PDF değil).
class PdfOpenException implements Exception {
  const PdfOpenException(this.message);
  final String message;
  @override
  String toString() => 'PdfOpenException: $message';
}

/// Açık bir belge. İşi bitince [close] çağrılmalı.
abstract interface class PdfEngineDocument {
  int get pageCount;

  Future<PdfPageSize> pageSize(int page);

  /// Sayfayı tam olarak [width] x [height] piksele çizer (beyaz zemin).
  /// Boyut <= 0 ya da `width*height > maxRenderPixels` ise [ArgumentError].
  Future<PdfRenderedImage> renderPage(int page, {required int width, required int height});

  /// [box] içindeki metin (okuma sırasıyla, satırlar `\n`). Metin katmanı
  /// yoksa ya da kutu boşsa `''`.
  Future<String> textInBox(int page, PdfBox box);

  Future<void> close();
}

abstract interface class PdfEngine {
  /// Açılamazsa [PdfOpenException] fırlatır.
  Future<PdfEngineDocument> openFile(String path);
  Future<PdfEngineDocument> openBytes(Uint8List bytes);
}
