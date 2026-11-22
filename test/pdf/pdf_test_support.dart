import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kocum/features/pdf/domain/pdf_engine.dart';

/// Elle yazılmış minimal PDF: her sayfa 612x792, verilen metinler (x, y alttan).
Uint8List minimalPdf(List<List<(String, double, double)>> pages) {
  final objs = <String>[];
  // 1 katalog, 2 sayfa ağacı, 3 yazı tipi, sonra her sayfa için (sayfa, içerik).
  objs.add('<< /Type /Catalog /Pages 2 0 R >>');
  final kids = [for (var i = 0; i < pages.length; i++) '${4 + i * 2} 0 R'].join(' ');
  objs.add('<< /Type /Pages /Kids [$kids] /Count ${pages.length} >>');
  objs.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  for (var i = 0; i < pages.length; i++) {
    final content = StringBuffer();
    for (final (t, x, y) in pages[i]) {
      content.write('BT /F1 18 Tf $x $y Td ($t) Tj ET\n');
    }
    objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents ${5 + i * 2} 0 R '
        '/Resources << /Font << /F1 3 0 R >> >> >>');
    objs.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final b = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(b.length);
    b.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = b.length;
  b.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    b.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  b.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(b.toString()));
}

/// Sahte motor: baytlardan `SAHTE:sayfa sayısı` okur; başka şey bozuk sayılır.
class FakePdfEngine implements PdfEngine {
  int opened = 0;
  int closed = 0;

  static Uint8List bytes(int pages, [String pad = '']) => Uint8List.fromList(utf8.encode('SAHTE:$pages:$pad'));

  @override
  Future<PdfEngineDocument> openBytes(Uint8List b) async {
    final s = utf8.decode(b, allowMalformed: true);
    if (!s.startsWith('SAHTE:')) throw const PdfOpenException('PDF değil');
    opened++;
    return _FakeDoc(int.parse(s.split(':')[1]), () => closed++);
  }

  @override
  Future<PdfEngineDocument> openFile(String path) async => openBytes(await File(path).readAsBytes());
}

class _FakeDoc implements PdfEngineDocument {
  _FakeDoc(this.pageCount, this._onClose);
  @override
  final int pageCount;
  final void Function() _onClose;

  @override
  Future<void> close() async => _onClose();
  @override
  Future<PdfPageSize> pageSize(int page) async => const PdfPageSize(612, 792);
  @override
  Future<PdfRenderedImage> renderPage(int page, {required int width, required int height}) async =>
      PdfRenderedImage(width: width, height: height, rgbaBytes: Uint8List(width * height * 4));
  @override
  Future<String> textInBox(int page, PdfBox box) async => '';
}
