import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/pdf_import_rules.dart';

void main() {
  test('PdfBox: köşeler sırasız, kesişim ve kapsama', () {
    final b = PdfBox.fromCorners(100, 200, 10, 20);
    expect((b.left, b.top, b.right, b.bottom), (10, 20, 100, 200));
    expect(b.width, 90);
    expect(b.overlaps(const PdfBox(90, 190, 150, 250)), isTrue);
    expect(b.overlaps(const PdfBox(100, 0, 150, 250)), isFalse); // yalnız kenar değer
    expect(const PdfBox(0, 0, 10, 10).coverageBy(const PdfBox(0, 0, 5, 10)), 0.5);
    expect(const PdfBox(0, 0, 10, 10).coverageBy(const PdfBox(20, 20, 30, 30)), 0);
    expect(const PdfBox(0, 0, 0, 0).coverageBy(const PdfBox(0, 0, 5, 5)), 0);
  });

  test('sayfa eşleme: kitap sayfası = pdf sayfası (0\'dan) + 1 + ofset', () {
    const d = PdfDocumentRecord(id: 'a', sha256: 'a', title: 't', pageCount: 10, fileName: 'f.pdf', pageOffset: -2);
    expect(d.bookPageOf(2), 1); // PDF'in 3. sayfası kitabın 1. sayfası
    expect(d.pdfPageOf(1), 2);
    expect(d.pdfPageOf(d.bookPageOf(9)), 9);
    expect(d.pdfPageOf(-5), isNull);
    expect(d.pdfPageOf(100), isNull);
    const z = PdfDocumentRecord(id: 'a', sha256: 'a', title: 't', pageCount: 3, fileName: 'f');
    expect(z.bookPageOf(0), 1);
  });

  test('dosya adından başlık', () {
    expect(titleFromFileName('Tonguç_TYT  Matematik.pdf'), 'Tonguç TYT Matematik');
    expect(titleFromFileName('/a/b/Kitap.PDF'), 'Kitap');
    expect(titleFromFileName('.pdf'), 'PDF');
    final h = 'ab' * 32;
    expect(storedFileName(h), '$h.pdf');
  });

  group('kitap önerisi', () {
    const books = [
      BookCandidate(id: '1', title: 'TYT Matematik Soru Bankası'),
      BookCandidate(id: '2', title: 'AYT Fizik Konu Anlatımı'),
      BookCandidate(id: '3', title: 'TYT Türkçe'),
    ];
    test('aynı ad (büyük harf, Türkçe karakter farkı) en üstte', () {
      final s = suggestBooks('TYT MATEMATİK SORU BANKASI', books);
      expect(s.first.bookId, '1');
      expect(s.first.score, 1);
    });
    test('kitap adı PDF başlığının içinde geçiyorsa önerilir', () {
      final s = suggestBooks('Tonguç AYT Fizik Konu Anlatımı 2026 baskı', books);
      expect(s.first.bookId, '2');
      expect(s.first.score, greaterThanOrEqualTo(0.85));
    });
    test('alakasız başlık öneri çıkarmaz; boş başlık da', () {
      expect(suggestBooks('Yemek tarifleri', books), isEmpty);
      expect(suggestBooks('   ', books), isEmpty);
      expect(suggestBooks('TYT Matematik', const []), isEmpty);
    });
    test('en fazla limit kadar, puana göre sıralı', () {
      final s = suggestBooks('TYT', books, minScore: 0.1, limit: 2);
      expect(s.length, lessThanOrEqualTo(2));
      for (var i = 1; i < s.length; i++) {
        expect(s[i - 1].score, greaterThanOrEqualTo(s[i].score));
      }
    });
  });
}
