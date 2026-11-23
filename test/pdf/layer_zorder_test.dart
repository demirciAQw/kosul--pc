import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/pdf/domain/layer_pixels.dart';
import 'package:kocum/features/pdf/domain/page_layer.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart' show PdfBox;
import 'package:kocum/features/pdf/domain/watermark.dart';

PdfPageLayer _wm(String id, int z) => PdfPageLayer(
      id: id,
      documentId: 'd',
      page: allPdfPages,
      kind: PdfLayerKind.watermark,
      z: z,
      params: const WatermarkParams().toJson(),
    );

PdfPageLayer _cover(String id, int z, PdfBox box) => PdfPageLayer(
      id: id,
      documentId: 'd',
      page: allPdfPages,
      kind: PdfLayerKind.cover,
      box: box,
      z: z,
      params: const CoverParams(color: 0xFF0000FF).toJson(),
    );

/// 200x100: beyaz zemin, yatay açık gri şeritler (filigran), sol yarıda.
Uint8List _page() {
  final px = Uint8List(200 * 100 * 4)..fillRange(0, 200 * 100 * 4, 255);
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 200; x++) {
      if (y % 10 < 4) {
        final i = (y * 200 + x) * 4;
        px[i] = px[i + 1] = px[i + 2] = 215;
      }
    }
  }
  return px;
}

/// Okuyucunun çizim modeli: z sırasıyla her katmanı çizer; filigran katmanı kendi
/// görüntüsüyle (zincir uygulanmış ham sayfa) bölgesini ÖRTER, örtü düz boyar.
Uint8List _readerComposite(Uint8List raw, List<PdfPageLayer> ordered) {
  final canvas = Uint8List.fromList(raw);
  for (var i = 0; i < ordered.length; i++) {
    final l = ordered[i];
    if (l.kind == PdfLayerKind.cover) {
      canvas.setAll(0, applyLayersToPixels(canvas, 200, 100, 1, 1, [l]));
    } else {
      final img = applyLayersToPixels(raw, 200, 100, 1, 1, layerChainUpTo(ordered, i));
      canvas.setAll(0, img); // opak tam sayfa görüntü: altındakini örter
    }
  }
  return canvas;
}

void main() {
  const box = PdfBox(50, 20, 120, 60);

  test('layerChainUpTo: alttaki örtüleri ve filigranları z sırasıyla içerir', () {
    final ord = visibleLayersFor([_wm('w2', 5), _cover('c', 1, box), _wm('w1', 3)], 0);
    expect(ord.map((l) => l.id), ['c', 'w1', 'w2']);
    expect(layerChainUpTo(ord, 1).map((l) => l.id), ['c', 'w1']);
    expect(layerChainUpTo(ord, 2).map((l) => l.id), ['c', 'w1', 'w2']);
  });

  test('örtü filigranın ALTINDA (z küçük): okuyucu = çözüm/önizleme (hepsi tek sıra)', () {
    final raw = _page();
    final ord = visibleLayersFor([_cover('c', 1, box), _wm('w', 2)], 0);
    final solve = applyLayersToPixels(raw, 200, 100, 1, 1, ord); // çözüm ekranı / önizleme
    final reader = _readerComposite(raw, ord);
    expect(reader, solve);
    // Mavi örtü filigran temizlemeden geçer ama koyu/renkli olduğu için aynen kalır.
    final i = (30 * 200 + 80) * 4;
    expect(solve.sublist(i, i + 3), [0, 0, 255]);
  });

  test('örtü filigranın ÜSTÜNDE (z büyük): örtü okuyucuda da görünür', () {
    final raw = _page();
    final ord = visibleLayersFor([_wm('w', 1), _cover('c', 2, box)], 0);
    final solve = applyLayersToPixels(raw, 200, 100, 1, 1, ord);
    final reader = _readerComposite(raw, ord);
    expect(reader, solve);
    final i = (30 * 200 + 80) * 4;
    expect(reader.sublist(i, i + 3), [0, 0, 255]);
  });

  test('eski davranış (yalnız filigran zinciri) örtüyü kaybederdi: zincir tüm katmanları içermeli', () {
    final raw = _page();
    final ord = visibleLayersFor([_cover('c', 1, box), _wm('w', 2)], 0);
    final onlyWm = applyLayersToPixels(raw, 200, 100, 1, 1, [ord[1]]);
    final full = applyLayersToPixels(raw, 200, 100, 1, 1, layerChainUpTo(ord, 1));
    expect(onlyWm, isNot(full));
  });
}
