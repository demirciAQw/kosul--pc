import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../ink/domain/ink_stroke_record.dart';
import '../domain/pdf_engine.dart';
import '../domain/solve.dart';

/// Çözüm ekranının arka planı: PDF sayfası mı, görüntü mü. Çizgiler her zaman
/// [region] içindeki koordinat uzayında saklanır; arka plan yalnızca resmi verir.
abstract class SolveBackground {
  /// Ekranda gösterilen bölge (çizgi koordinat uzayında).
  PdfBox get region;

  /// Katmana verilen sayfa numarası (PDF'li kartta PDF sayfası, fotoğrafta 0).
  int get page;

  /// Oturumun belge anahtarı.
  String get documentId;

  /// Çizgi sahibi: null ise PDF sayfası (`PdfPageOwner(documentId, page)`).
  StrokeOwner Function(int page)? get ownerOf;

  /// Çizgi kalınlığı çarpanı (koordinat uzayı birimine göre).
  double get brushScale;

  CustomPainter painter();

  void dispose();
}

/// PDF sayfasının bir bölgesi (PDF bu cihazda).
class PdfPageBackground extends SolveBackground {
  PdfPageBackground({
    required this.documentId,
    required this.page,
    required this.region,
    required this.box,
    required this.pageSize,
    required this.image,
    required this.imageScale,
  });

  @override
  final String documentId;
  @override
  final int page;
  @override
  final PdfBox region;
  final PdfBox box;
  final PdfPageSize pageSize;
  final ui.Image image;
  final double imageScale;

  @override
  StrokeOwner Function(int page)? get ownerOf => null;
  @override
  double get brushScale => 1;

  @override
  CustomPainter painter() => _RegionPainter(image, imageScale, region, pageSize, box);

  @override
  void dispose() => image.dispose();
}

/// Bir görüntü (soru fotoğrafı ya da PDF kartının önizlemesi) çizim uzayında
/// [imageRect] alanına oturur; [region] onu ve altındaki yazı payını kapsar.
class ImageBackground extends SolveBackground {
  ImageBackground({
    required this.documentId,
    required this.page,
    required this.region,
    required this.imageRect,
    required this.image,
    this.ownerOf,
    this.brushScale = 1,
    this.outline = false,
  });

  /// Fotoğraflı kart: görüntü genişliği [photoUnitWidth] birim, sahibi `QuestionImageOwner`.
  /// Boyut geçersizse null.
  static ImageBackground? photo({
    required String questionId,
    required ui.Image image,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    final u = photoUnitSize(pixelWidth, pixelHeight);
    final region = photoSolveRegion(pixelWidth, pixelHeight);
    if (u == null || region == null) return null;
    return ImageBackground(
      documentId: 'q:$questionId',
      page: 0,
      region: region,
      imageRect: PdfBox(0, 0, u.width, u.height),
      image: image,
      ownerOf: (_) => QuestionImageOwner(questionId),
      brushScale: photoBrushScale,
    );
  }

  /// PDF'li kart, PDF bu cihazda yok: önizleme kutunun yerine oturur; koordinat PDF birimi.
  static ImageBackground? pdfPreview({
    required String documentId,
    required int page,
    required PdfBox box,
    required ui.Image image,
  }) {
    final region = previewSolveRegion(box);
    if (region == null) return null;
    return ImageBackground(
      documentId: documentId,
      page: page,
      region: region,
      imageRect: box,
      image: image,
      outline: true,
    );
  }

  @override
  final String documentId;
  @override
  final int page;
  @override
  final PdfBox region;
  final PdfBox imageRect;
  final ui.Image image;
  @override
  final StrokeOwner Function(int page)? ownerOf;
  @override
  final double brushScale;
  final bool outline;

  @override
  CustomPainter painter() => _ImagePainter(image, region, imageRect, outline);

  @override
  void dispose() => image.dispose();
}

/// Görüntü dosyasını çözer: özgün boyut (çizim uzayı için) ve en çok [maxWidth]
/// genişlikte ekran resmi. Dosya yok/bozuksa istisna (çağıran ekranda gösterir).
Future<({ui.Image image, int width, int height})> decodeSolveImage(File file, {int maxWidth = 2048}) async {
  if (!await file.exists()) throw const FileSystemException('Görüntü dosyası yok');
  final buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
  ui.ImageDescriptor? desc;
  ui.Codec? codec;
  try {
    desc = await ui.ImageDescriptor.encoded(buffer);
    final w = desc.width, h = desc.height;
    if (w <= 0 || h <= 0) throw const FormatException('Görüntü boyutu geçersiz');
    codec = await desc.instantiateCodec(targetWidth: math.min<int>(w, maxWidth));
    final frame = await codec.getNextFrame();
    return (image: frame.image, width: w, height: h);
  } finally {
    codec?.dispose();
    desc?.dispose();
    buffer.dispose();
  }
}

/// Sayfa resminin bölgeye düşen kısmını çizer; bölge sayfanın altından taşarsa
/// taşan yer beyazdır. Soru kutusu ince bir çerçeveyle işaretlenir.
class _RegionPainter extends CustomPainter {
  _RegionPainter(this.image, this.scale, this.region, this.page, this.box);
  final ui.Image image;
  final double scale;
  final PdfBox region;
  final PdfPageSize page;
  final PdfBox box;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final sx = size.width / region.width, sy = size.height / region.height;
    final r = math.min<double>(region.right, page.width);
    final b = math.min<double>(region.bottom, page.height);
    if (r > region.left && b > region.top) {
      canvas.drawImageRect(
        image,
        Rect.fromLTRB(region.left * scale, region.top * scale, r * scale, b * scale),
        Rect.fromLTRB(0, 0, (r - region.left) * sx, (b - region.top) * sy),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    _drawOutline(canvas, region, box, sx, sy);
  }

  @override
  bool shouldRepaint(_RegionPainter o) => o.image != image || o.region != region;
}

class _ImagePainter extends CustomPainter {
  _ImagePainter(this.image, this.region, this.imageRect, this.outline);
  final ui.Image image;
  final PdfBox region;
  final PdfBox imageRect;
  final bool outline;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final sx = size.width / region.width, sy = size.height / region.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTRB(
        (imageRect.left - region.left) * sx,
        (imageRect.top - region.top) * sy,
        (imageRect.right - region.left) * sx,
        (imageRect.bottom - region.top) * sy,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (outline) _drawOutline(canvas, region, imageRect, sx, sy);
  }

  @override
  bool shouldRepaint(_ImagePainter o) => o.image != image || o.region != region || o.imageRect != imageRect;
}

void _drawOutline(Canvas canvas, PdfBox region, PdfBox box, double sx, double sy) {
  canvas.drawRect(
    Rect.fromLTRB(
      (box.left - region.left) * sx,
      (box.top - region.top) * sy,
      (box.right - region.left) * sx,
      (box.bottom - region.top) * sy,
    ),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x991565C0),
  );
}
