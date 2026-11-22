import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;
import 'package:kocum/features/pdf/data/pdfrx_engine.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';

import 'pdf_test_support.dart';

/// Gerçek PDFium. İlk çalıştırmada ikili indirilmiş olmalı (derleme kancası).
void main() {
  test('gerçek motor: aç, boyut, çiz, kutudaki metin, bozuk dosya', () async {
    // path_provider eklentisi testte yok: Dart başlatması (PDFium aynı).
    final engine = PdfrxEngine(initialize: () => pdfrxInitialize());
    final bytes = minimalPdf([
      [('Birinci sayfa', 72, 700), ('Altta', 72, 100)],
      [('Ikinci', 72, 700)],
    ]);
    final doc = await engine.openBytes(bytes);
    addTearDown(doc.close);
    expect(doc.pageCount, 2);
    expect(await doc.pageSize(0), const PdfPageSize(612, 792));

    final img = await doc.renderPage(0, width: 306, height: 396);
    expect((img.width, img.height), (306, 396));
    expect(img.rgbaBytes.length, 306 * 396 * 4);
    expect(img.rgbaBytes.sublist(0, 4), [255, 255, 255, 255]); // sol-üst beyaz, RGBA sırası
    expect(img.rgbaBytes.any((b) => b != 255), isTrue); // yazı çizilmiş

    // Üst yazı: alttan y=700 → üstten ~92. Alt yazı: üstten ~692.
    expect(await doc.textInBox(0, const PdfBox(0, 60, 612, 120)), 'Birinci sayfa');
    expect(await doc.textInBox(0, const PdfBox(0, 660, 612, 720)), 'Altta');
    expect(await doc.textInBox(0, const PdfBox(0, 300, 612, 400)), '');
    expect(await doc.textInBox(1, const PdfBox(0, 0, 612, 792)), 'Ikinci');
    await expectLater(doc.pageSize(2), throwsRangeError);

    await expectLater(engine.openBytes(minimalPdf([]).sublist(0, 20)), throwsA(isA<PdfOpenException>()));
  });
}
