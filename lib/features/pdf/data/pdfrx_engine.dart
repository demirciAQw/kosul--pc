import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart' as r;

import '../domain/pdf_engine.dart';

/// `pdfrx` (PDFium, MIT) ile [PdfEngine]. Uygulamanın tek pdfrx içe aktarması.
class PdfrxEngine implements PdfEngine {
  /// [initialize]: varsayılan Flutter başlatması; saf Dart testinde `pdfrxInitialize`.
  const PdfrxEngine({Future<void> Function() initialize = r.pdfrxFlutterInitialize}) : _init = initialize;

  final Future<void> Function() _init;

  @override
  Future<PdfEngineDocument> openFile(String path) => _open(() => r.PdfDocument.openFile(path));

  @override
  Future<PdfEngineDocument> openBytes(Uint8List bytes) => _open(() => r.PdfDocument.openData(bytes));

  Future<PdfEngineDocument> _open(Future<r.PdfDocument> Function() open) async {
    await _init();
    try {
      return _PdfrxDocument(await open());
    } on r.PdfException catch (e) {
      throw PdfOpenException(e.toString());
    }
  }
}

class _PdfrxDocument implements PdfEngineDocument {
  _PdfrxDocument(this._doc);
  final r.PdfDocument _doc;

  @override
  int get pageCount => _doc.pages.length;

  r.PdfPage _page(int i) {
    if (i < 0 || i >= _doc.pages.length) throw RangeError.index(i, _doc.pages, 'page');
    return _doc.pages[i];
  }

  @override
  Future<PdfPageSize> pageSize(int page) async {
    final p = _page(page);
    return PdfPageSize(p.width, p.height);
  }

  @override
  Future<PdfRenderedImage> renderPage(int page, {required int width, required int height}) async {
    if (width <= 0 || height <= 0 || width * height > maxRenderPixels) {
      throw ArgumentError('Geçersiz çizim boyutu: ${width}x$height (üst sınır $maxRenderPixels piksel)');
    }
    final p = _page(page);
    final img = await p.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
      backgroundColor: 0xFFFFFFFF,
    );
    if (img == null) throw StateError('Sayfa çizilemedi: $page');
    try {
      // Tamponu yerel belleğe bağlı; dispose'tan önce kopyala. Renk sırası DEĞİŞMEZ (BGRA).
      return PdfRenderedImage(
          width: img.width, height: img.height, bytes: Uint8List.fromList(img.pixels), format: PdfPixelFormat.bgra);
    } finally {
      img.dispose();
    }
  }

  @override
  Future<String> textInBox(int page, PdfBox box) async {
    final p = _page(page);
    final text = await p.loadStructuredText();
    if (text.fullText.isEmpty) return '';
    // pdfrx kutuları PDF'in kendi koordinatında (sol-alt başlangıç, y yukarı).
    // Döndürülmüş sayfalarda rotate() sayfanın görünür yönüne çevirir; sonra
    // y'yi sol-üst başlangıca çeviririz.
    final rot = p.rotation.index;
    final hits = <(double, double, r.PdfPageTextFragment)>[];
    for (final f in text.fragments) {
      final b = f.bounds.rotate(rot, p);
      final fb = PdfBox(b.left, p.height - b.top, b.right, p.height - b.bottom);
      if (fb.width <= 0 || fb.height <= 0) continue;
      // Parçanın yarıdan fazlası kutudaysa alınır (yan satırlar karışmasın).
      if (fb.coverageBy(box) >= 0.5) hits.add((fb.top, fb.left, f));
    }
    // Okuma sırası: önce yukarıdan aşağı sırala, sonra satırlara kümele
    // (satırın ilk parçasına 3 birimden yakın olanlar aynı satır), her satırı
    // soldan sağa sırala. Karşılaştırıcılar geçişli: kararsız sıra yok.
    hits.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    final lines = <List<(double, double, r.PdfPageTextFragment)>>[];
    for (final h in hits) {
      if (lines.isNotEmpty && h.$1 - lines.last.first.$1 <= 3) {
        lines.last.add(h);
      } else {
        lines.add([h]);
      }
    }
    final buf = StringBuffer();
    var firstLine = true;
    for (final line in lines) {
      line.sort((a, b) => a.$2.compareTo(b.$2));
      final words = [for (final h in line) if (h.$3.text.trim().isNotEmpty) h.$3.text.trim()];
      if (words.isEmpty) continue;
      if (!firstLine) buf.write('\n');
      firstLine = false;
      buf.write(words.join(' '));
    }
    return buf.toString().trim();
  }

  @override
  Future<void> close() => _doc.dispose();
}
