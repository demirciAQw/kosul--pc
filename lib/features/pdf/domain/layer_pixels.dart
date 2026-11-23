/// Katmanları piksellere uygular (saf Dart): filigran temizleme ve örtü.
/// Katmanlar z sırasıyla verilir (görünür olanlar); sonuç yeni dizidir.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'page_layer.dart';
import 'watermark.dart';

/// [px] (w x h), sayfanın [originX],[originY] noktasından (PDF birimi) başlayan
/// bölgedir; her piksel [pxPerUnitX] x [pxPerUnitY] PDF birimine denk gelir.
/// Tüm sayfa için origin 0,0 ve pxPerUnit = w / sayfa genişliği.
Uint8List applyLayersToPixels(
  Uint8List px,
  int w,
  int h,
  double pxPerUnitX,
  double pxPerUnitY,
  List<PdfPageLayer> layers, {
  double originX = 0,
  double originY = 0,
  PixelOrder order = PixelOrder.rgba,
}) {
  if (layers.isEmpty) return px;
  var cur = px;
  var copied = false;
  for (final l in layers) {
    PixelRect? rect;
    final b = l.box;
    if (b != null) {
      rect = PixelRect(
        ((b.left - originX) * pxPerUnitX).floor().clamp(0, w),
        ((b.top - originY) * pxPerUnitY).floor().clamp(0, h),
        ((b.right - originX) * pxPerUnitX).ceil().clamp(0, w),
        ((b.bottom - originY) * pxPerUnitY).ceil().clamp(0, h),
      );
      if (rect.width <= 0 || rect.height <= 0) continue;
    }
    switch (l.kind) {
      case PdfLayerKind.watermark:
        cur = removeWatermark(cur, w, h, l.watermark, region: rect, order: order);
        copied = true;
      case PdfLayerKind.cover:
        if (!copied) {
          cur = Uint8List.fromList(cur);
          copied = true;
        }
        _cover(cur, w, h, l.cover, rect, order);
    }
  }
  return cur;
}

void _cover(Uint8List px, int w, int h, CoverParams c, PixelRect? r, PixelOrder order) {
  final rc = r ?? PixelRect(0, 0, w, h);
  final a = c.opacity.clamp(0.0, 1.0);
  if (a <= 0) return;
  final cr = (c.color >> 16) & 0xFF, cg = (c.color >> 8) & 0xFF, cb = c.color & 0xFF;
  final ri = order == PixelOrder.rgba ? 0 : 2, bi = order == PixelOrder.rgba ? 2 : 0;
  for (var y = rc.top; y < rc.bottom; y++) {
    var i = (y * w + rc.left) * 4;
    for (var x = rc.left; x < rc.right; x++, i += 4) {
      px[i + ri] = (px[i + ri] + (cr - px[i + ri]) * a).round();
      px[i + 1] = (px[i + 1] + (cg - px[i + 1]) * a).round();
      px[i + bi] = (px[i + bi] + (cb - px[i + bi]) * a).round();
    }
  }
}

/// [applyLayersToPixels] ayrı iş parçacığında.
Future<Uint8List> applyLayersInIsolate(
  Uint8List px,
  int w,
  int h,
  double pxPerUnitX,
  double pxPerUnitY,
  List<PdfPageLayer> layers, {
  double originX = 0,
  double originY = 0,
  PixelOrder order = PixelOrder.rgba,
}) {
  if (layers.isEmpty) return Future.value(px);
  return Isolate.run(() => applyLayersToPixels(px, w, h, pxPerUnitX, pxPerUnitY, layers,
      originX: originX, originY: originY, order: order));
}
