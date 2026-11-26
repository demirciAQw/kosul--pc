import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';
import 'package:kocum/features/pdf/domain/book_autofill.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';

TopicLexicon _lex() => TopicLexicon(
      subjects: {
        'matematik': ['mat'],
        'fizik': ['fiz'],
      },
      families: {
        'mat': {
          'Türev': ['turev', 'teget', 'artan'],
          'İntegral': ['integral'],
        },
        'fiz': {
          'Kuvvet': ['kuvvet', 'ivme', 'newton'],
        },
      },
    );

void main() {
  group('cleanBookTitle', () {
    test('uzantı, alt çizgi, tire, sürüm ve kopya ekleri atılır', () {
      expect(cleanBookTitle('Tonguç_TYT-Matematik_v2 (1).pdf'), 'Tonguç TYT Matematik');
      expect(cleanBookTitle('Palme_AYT_Fizik_final.PDF'), 'Palme AYT Fizik');
      expect(cleanBookTitle('C:\\indirilenler\\Kitap - Copy.pdf'), 'Kitap');
      expect(cleanBookTitle('www.pdfindir.com - Bilgi Sarmal Fizik.pdf'), 'Bilgi Sarmal Fizik');
    });

    test('hepsi küçükse baş harfler büyür, TYT/AYT büyük kalır', () {
      expect(cleanBookTitle('tyt_matematik_soru_bankasi.pdf'), 'TYT Matematik Soru Bankasi');
      expect(cleanBookTitle('ilk asama fizik.pdf'), 'İlk Asama Fizik');
    });

    test('boş kalırsa dosya adından başlığa düşer', () {
      expect(cleanBookTitle('final.pdf'), 'Final');
      expect(cleanBookTitle('.pdf'), 'PDF');
    });
  });

  group('yayınevi, sınav, ders', () {
    test('bilinen yayınevi tam sözcük olarak bulunur; yanlış pozitif yok', () {
      expect(findPublisher('Bilgi Sarmal TYT Fizik'), 'Bilgi Sarmal');
      expect(findPublisher('tonguc akademi'), 'Tonguç');
      expect(findPublisher('Esenlik ve huzur'), isNull);
      expect(findPublisher(''), isNull);
    });

    test('sıradan sözcük olan yayınevi adları yalnız "yayın..." ile eşleşir (yanlış pozitif yok)', () {
      for (final t in [
        'Orijinal soru çözümü',
        'Nitelik kazandırma',
        'Antrenman programı',
        'Zafer Bayramı',
        'Aydın ilinde',
        'Zafer',
      ]) {
        expect(findPublisher(t), isNull, reason: t);
      }
      expect(findPublisher('Aydın Yayınları TYT'), 'Aydın');
      expect(findPublisher('Nitelik Yayınları'), 'Nitelik');
      expect(findPublisher('antrenman yayincilik'), 'Antrenman');
      expect(findPublisher('Zafer Yayınevi'), 'Zafer');
      expect(buildBookAutofill(fileName: 'Orijinal_TYT_Matematik.pdf', pageCount: 10).publisher, isNull);
    });

    test('sınav türü: başlıktan, yoksa metinde baskın olandan', () {
      expect(guessExamType('TYT Matematik', ''), 'TYT');
      expect(guessExamType('AYT Fizik', 'tyt'), 'AYT');
      expect(guessExamType('Soru Bankası', 'AYT AYT AYT matematik TYT'), 'AYT');
      expect(guessExamType('Soru Bankası', 'TYT AYT'), isNull);
      expect(guessExamType('TYT AYT Matematik', ''), isNull);
      expect(guessExamType('Soru Bankası', ''), isNull);
    });

    test('ders: başlıktaki ders adı; geometri matematiğe gider', () {
      expect(guessSubject('Palme Fizik Soru Bankası', '', null), 'Fizik');
      expect(guessSubject('Geometri Kitabı', '', null), 'Matematik');
      expect(guessSubject('Türkçe Paragraf', 'integral integral', _lex()), 'Türkçe');
    });

    test('ders: başlıkta yoksa metinden, yalnız güven yeterliyse', () {
      final lex = _lex();
      const physics = 'Net kuvvet ve ivme. Newton kuvvet ivme newton kuvvet ivme';
      expect(guessSubject('Soru Bankası', physics, lex), 'Fizik');
      // Karışık / zayıf metin: tahmin yok.
      expect(guessSubject('Soru Bankası', 'kuvvet integral', lex), isNull);
      expect(guessSubject('Soru Bankası', '', lex), isNull);
      expect(guessSubject('Soru Bankası', physics, null), isNull);
    });

    test('ders adı sınava çevrilir (Tarih + AYT = Tarih-1)', () {
      expect(resolveSubject('Tarih', 'AYT'), 'Tarih-1');
      expect(resolveSubject('Tarih', 'TYT'), 'Tarih');
      expect(resolveSubject('Matematik', null), 'Matematik');
      expect(resolveSubject('Edebiyat', 'TYT'), isNull);
      expect(resolveSubject(null, 'TYT'), isNull);
      expect(subjectsFor('YDT'), ['Yabancı Dil']);
    });
  });

  group('sayfa ofseti', () {
    test('1. sayfa PDF 1 ise ofset 0; 5. PDF sayfasındaysa -4', () {
      expect(offsetFromFirstPage(1), 0);
      expect(offsetFromFirstPage(5), -4);
      expect(firstPageFromOffset(-4), 5);
      expect(firstPageFromOffset(offsetFromFirstPage(9)), 9);
    });

    test('kayıttaki dönüşümle uyumlu: kitap 1. sayfası = PDF indeksi 4', () {
      final d = PdfDocumentRecord(
        id: 'a',
        sha256: 'a',
        title: 't',
        pageCount: 50,
        fileName: 'a.pdf',
        pageOffset: offsetFromFirstPage(5),
      );
      expect(d.bookPageOf(4), 1);
      expect(d.pdfPageOf(1), 4);
    });
  });

  group('buildBookAutofill', () {
    test('doldurabildiklerini doldurur, doldurulamayanı null bırakır', () {
      final a = buildBookAutofill(fileName: 'Bilgi_Sarmal-TYT-Fizik_v3.pdf', pageCount: 120);
      expect(a.title, 'Bilgi Sarmal TYT Fizik');
      expect(a.pageCount, 120);
      expect(a.publisher, 'Bilgi Sarmal');
      expect(a.exam, 'TYT');
      expect(a.subject, 'Fizik');
      expect(a.firstPdfPage, 1);
      expect(a.missingRequired, isFalse);

      final b = buildBookAutofill(fileName: 'kitap_001.pdf', pageCount: 30);
      expect(b.exam, isNull);
      expect(b.subject, isNull);
      expect(b.publisher, isNull);
      expect(b.missingRequired, isTrue);
    });

    test('üst veri başlığı dosya adından önce gelir; yayınevi yazardan ve metinden', () {
      final a = buildBookAutofill(
        fileName: 'x.pdf',
        pageCount: 10,
        metaTitle: 'AYT Matematik Soru Bankası',
        metaAuthor: 'Tonguç Akademi',
      );
      expect(a.title, 'AYT Matematik Soru Bankası');
      expect(a.publisher, 'Tonguç');
      expect(a.exam, 'AYT');
      expect(a.subject, 'Matematik');

      final c = buildBookAutofill(fileName: 'k.pdf', pageCount: 10, text: 'Palme Yayınevi 2026 baskı');
      expect(c.publisher, 'Palme');
    });

    test('sınav bilinmiyorsa ders yine tahmin edilir (TYT sırasıyla)', () {
      final a = buildBookAutofill(fileName: 'Matematik Soru Bankasi.pdf', pageCount: 10);
      expect(a.exam, isNull);
      expect(a.subject, 'Matematik');
      expect(a.missingRequired, isTrue);
    });
  });
}
