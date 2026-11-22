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
    expect(img.bytes.length, 306 * 396 * 4);
    expect(img.rgbaAt(0, 0), [255, 255, 255, 255]); // sol-üst beyaz
    expect(img.bytes.any((b) => b != 255), isTrue); // yazı çizilmiş

    // Üst yazı: alttan y=700 → üstten ~92. Alt yazı: üstten ~692.
    expect(await doc.textInBox(0, const PdfBox(0, 60, 612, 120)), 'Birinci sayfa');
    expect(await doc.textInBox(0, const PdfBox(0, 660, 612, 720)), 'Altta');
    expect(await doc.textInBox(0, const PdfBox(0, 300, 612, 400)), '');
    expect(await doc.textInBox(1, const PdfBox(0, 0, 612, 792)), 'Ikinci');
    await expectLater(doc.pageSize(2), throwsRangeError);

    await expectLater(engine.openBytes(minimalPdf([]).sublist(0, 20)), throwsA(isA<PdfOpenException>()));
  });

  test('gerçek motor: kırmızı dikdörtgen R=255,B=0 (piksel biçimi bildirilir); boyut sınırı', () async {
    final engine = PdfrxEngine(initialize: () => pdfrxInitialize());
    // Sayfanın sol-alt köşesi: x 0..306, y(alttan) 0..396 = çizimin sol-alt çeyreği.
    final doc = await engine.openBytes(minimalPdf([[]], rawContent: '1 0 0 rg 0 0 306 396 re f'));
    addTearDown(doc.close);
    final img = await doc.renderPage(0, width: 306, height: 396);
    expect(img.format, PdfPixelFormat.bgra);
    final red = img.rgbaAt(50, 300); // sol-alt çeyrek
    expect((red[0], red[1], red[2], red[3]), (255, 0, 0, 255));
    expect(img.rgbaAt(250, 50), [255, 255, 255, 255]); // sağ-üst beyaz
    await expectLater(doc.renderPage(0, width: 5000, height: 5000), throwsArgumentError);
    await expectLater(doc.renderPage(0, width: 0, height: 10), throwsArgumentError);
  });

  test('gerçek motor: /Rotate 90 sayfada boyut ve kutudaki metin', () async {
    final engine = PdfrxEngine(initialize: () => pdfrxInitialize());
    final doc = await engine.openBytes(minimalPdf([
      [('Dondu', 72, 700)],
    ], rotate: 90));
    addTearDown(doc.close);
    expect(await doc.pageSize(0), const PdfPageSize(792, 612)); // en-boy yer değiştirir
    // 90° saat yönü: dönmemiş (x=72, y=700 alttan) -> görünür (x=700, üstten 72).
    expect(await doc.textInBox(0, const PdfBox(650, 40, 792, 200)), 'Dondu');
    expect(await doc.textInBox(0, const PdfBox(0, 300, 400, 612)), '');
  });
}
