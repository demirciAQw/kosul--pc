import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/question_box.dart';

const _page = PdfPageSize(612, 792);

void main() {
  group('normalizeQuestionBox', () {
    test('ters sürükleme düzelir', () {
      final b = normalizeQuestionBox(300, 400, 100, 100, _page)!;
      expect([b.left, b.top, b.right, b.bottom], [100, 100, 300, 400]);
    });

    test('sayfa sınırına kırpılır', () {
      final b = normalizeQuestionBox(-50, -10, 700, 900, _page)!;
      expect([b.left, b.top, b.right, b.bottom], [0, 0, 612, 792]);
    });

    test('çok küçük kutu reddedilir (eşik sınırı dahil)', () {
      expect(normalizeQuestionBox(100, 100, 110, 300, _page), isNull); // dar
      expect(normalizeQuestionBox(100, 100, 300, 105, _page), isNull); // basık
      expect(normalizeQuestionBox(100, 100, 100 + minQuestionBoxSide - 0.1, 300, _page), isNull);
      expect(normalizeQuestionBox(100, 100, 100 + minQuestionBoxSide, 100 + minQuestionBoxSide, _page), isNotNull);
    });

    test('kırpma sonrası küçülen kutu da reddedilir', () {
      expect(normalizeQuestionBox(600, 100, 700, 300, _page), isNull); // yalnız 12 birim içeride
    });

    test('sayfa dışında kalan, NaN ve sonsuz değerler reddedilir', () {
      expect(normalizeQuestionBox(700, 100, 800, 300, _page), isNull);
      expect(normalizeQuestionBox(double.nan, 0, 100, 100, _page), isNull);
      expect(normalizeQuestionBox(0, 0, double.infinity, 100, _page), isNull);
      expect(normalizeQuestionBox(0, 0, 100, 100, const PdfPageSize(0, 0)), isNull);
    });
  });

  group('kutu metni kararı', () {
    test('yeterli metin: metin katmanı', () {
      const t = 'f(x) = x^2 fonksiyonunun türevi nedir?';
      expect(hasEnoughBoxText(t), isTrue);
      expect(decideBoxTextSource(t, ocrAvailable: true), BoxTextSource.textLayer);
      expect(decideBoxTextSource(t, ocrAvailable: false), BoxTextSource.textLayer);
    });

    test('metin yok: Android ML Kit okur, Linux metinsiz kaydeder', () {
      expect(decideBoxTextSource('', ocrAvailable: true), BoxTextSource.ocr);
      expect(decideBoxTextSource('  \n ', ocrAvailable: false), BoxTextSource.none);
    });

    test('süs/sayfa numarası metin sayılmaz; eşikler', () {
      expect(hasEnoughBoxText('12'), isFalse);
      expect(hasEnoughBoxText('— 12 —'), isFalse);
      expect(hasEnoughBoxText('abcdefghijklmnopqrstuvwxyz'), isFalse); // tek sözcük
      expect(hasEnoughBoxText('bir iki üç dört beş altı yedi sekiz'), isTrue);
      expect(hasEnoughBoxText('bir iki üç'), isFalse); // 9 harf
    });
  });

  group('öneri', () {
    late TopicLexicon lexicon;
    setUpAll(() {
      lexicon = TopicLexicon.fromJson(jsonDecode(File('assets/meb/konu_sozlugu.json').readAsStringSync()) as Map<String, dynamic>);
    });

    test('kitap dersi verilmişse ders sabit, konu ve tür metinden gelir', () {
      final s = suggestFromBoxText(
        '7. Bir fonksiyonun türevi alınırken türev ve teğet doğrusu kullanılır. Buna göre aşağıdakilerden hangisi doğrudur?\n'
        'A) 1\nB) 2\nC) 3\nD) 4\nE) 5',
        lexicon: lexicon,
        subject: 'AYT Matematik',
      );
      expect(s.subject, 'AYT Matematik');
      expect(s.topic, 'Türev');
      expect(s.questionNo, 7);
      expect(s.types, isNot(contains('Şekilli')));
    });

    test('ders bilinmiyorsa metinden çıkarılır ve sınav türüyle birleşir', () {
      final s = suggestFromBoxText(
        'Türev ve limit: f fonksiyonunun türevi x noktasında limit ile hesaplanır. İntegral de kullanılır.',
        lexicon: lexicon,
        examType: 'AYT',
      );
      expect(s.subject, 'AYT Matematik');
    });

    test('boş metin boş öneri', () {
      expect(suggestFromBoxText('  ', lexicon: lexicon).isEmpty, isTrue);
    });

    test('konusu belirsiz metinde ders boş kalır (uydurmaz)', () {
      final s = suggestFromBoxText('bugün hava çok güzel ve herkes dışarıda yürüyüş yapıyor', lexicon: lexicon);
      expect(s.subject, isNull);
      expect(s.topic, isNull);
    });
  });

  group('kitap haritası', () {
    final book = Book(
      id: 'k1',
      title: 'Kitap',
      examType: 'TYT',
      subject: 'Matematik',
      pageCount: 100,
      avgQuestionsPerPage: 2,
      createdAt: DateTime(2026),
      roots: const [
        ContentNode(id: 'u1', level: NodeLevel.unit, title: 'Ünite', pageStart: 1, pageEnd: 50, mebNodeId: 'meb-u', children: [
          ContentNode(id: 't1', level: NodeLevel.topic, title: 'Test 1', pageStart: 10, pageEnd: 20),
        ]),
      ],
    );

    test('sayfayı kapsayan en derin düğüm ve MEB konusu (ataya düşer)', () {
      final c = bookContextForPage(book, 15);
      expect([c.bookId, c.subject, c.contentNodeId, c.mebNodeId], ['k1', 'TYT Matematik', 't1', 'meb-u']);
      expect(c.testLabel, 'Ünite › Test 1');
      expect(bookContextForPage(book, 30).contentNodeId, 'u1');
      expect(bookContextForPage(book, 80).contentNodeId, isNull);
    });
  });

  group('kırpma planı', () {
    test('kutu hedef genişliğe ölçeklenir', () {
      final p = planBoxRender(_page, const PdfBox(72, 72, 312, 312), 480);
      expect(p.cropWidth, closeTo(480, 2));
      expect(p.renderWidth, closeTo(612 * 2, 2));
      expect(p.cropX + p.cropWidth, lessThanOrEqualTo(p.renderWidth));
    });

    test('küçük kutuda sayfa çizim sınırı aşılmaz', () {
      final p = planBoxRender(_page, const PdfBox(0, 0, 24, 24), 1400);
      expect(p.renderWidth * p.renderHeight, lessThanOrEqualTo(maxRenderPixels));
      expect(p.cropWidth, lessThan(1400));
    });

    test('kutu sayfanın sağ-alt köşesindeyse kırpma taşmaz', () {
      final p = planBoxRender(_page, const PdfBox(500, 700, 612, 792), 480);
      expect(p.cropX + p.cropWidth, lessThanOrEqualTo(p.renderWidth));
      expect(p.cropY + p.cropHeight, lessThanOrEqualTo(p.renderHeight));
    });
  });

  group('okuyucu bağlantısı', () {
    test('validReaderPage: sayfa sayısı dışı geçersiz', () {
      expect(validReaderPage(0, 3), 0);
      expect(validReaderPage(2, 3), 2);
      expect(validReaderPage(3, 3), isNull);
      expect(validReaderPage(-1, 3), isNull);
      expect(validReaderPage(null, 3), isNull);
    });

    test('clipBoxToPage: sınıra kırpar, dışarıdaki ve geçersiz kutu null', () {
      const page = PdfPageSize(612, 792);
      final c = clipBoxToPage(const PdfBox(-10, 50, 9000, 9000), page)!;
      expect([c.left, c.top, c.right, c.bottom], [0, 50, 612, 792]);
      expect(clipBoxToPage(const PdfBox(700, 10, 800, 100), page), isNull);
      expect(clipBoxToPage(const PdfBox(0, 0, double.infinity, 10), page), isNull);
      expect(clipBoxToPage(const PdfBox(0, 0, double.nan, 10), page), isNull);
    });
  });
}
