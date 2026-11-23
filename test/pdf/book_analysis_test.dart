import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/pdf/domain/book_analysis.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart' show PdfBox;
import 'package:kocum/features/question_bank/domain/question_card.dart';

QuestionCard card(
  String id,
  QuestionStatus st, {
  String? node,
  int? no,
  String? doc,
  int? page,
  PdfBox? box,
}) => QuestionCard(
  id: id,
  status: st,
  origin: QuestionOrigin.book,
  sourceName: 'K',
  subject: 'fizik',
  difficulty: 5,
  createdAt: DateTime(2026),
  bookId: 'b',
  contentNodeId: node,
  questionNo: no,
  pdfDocumentId: doc,
  pdfPage: page,
  pdfBox: box,
);

void main() {
  final book = Book(
    id: 'b',
    title: 'K',
    examType: 'TYT',
    subject: 'Fizik',
    pageCount: 100,
    avgQuestionsPerPage: 1,
    createdAt: DateTime(2026),
    roots: [
      ContentNode(
        id: 'u',
        level: NodeLevel.unit,
        title: 'Ünite 1',
        pageStart: 10,
        pageEnd: 39,
        children: [
          ContentNode(id: 't1', level: NodeLevel.topic, title: 'Test 1', pageStart: 10, pageEnd: 19, questionCount: 10),
          ContentNode(id: 't2', level: NodeLevel.topic, title: 'Test 2', pageStart: 20, pageEnd: 29, questionCount: 10),
          const ContentNode(id: 't3', level: NodeLevel.topic, title: 'Test 3'), // sayfası yok: ünitenin başı
        ],
      ),
    ],
  );
  // PDF sayfası (0'dan) = kitap sayfası - 1 - ofset; ofset 2.
  final doc = PdfDocumentRecord(
    id: 'd' * 64,
    sha256: 'd' * 64,
    title: 'K',
    pageCount: 60,
    fileName: 'k.pdf',
    bookId: 'b',
    pageOffset: 2,
  );

  test('sayfa eşleme: ofsetli, aralık dışı null', () {
    expect(doc.pdfPageOf(10), 7);
    expect(doc.bookPageOf(7), 10);
    expect(doc.pdfPageOf(3), 0);
    expect(doc.pdfPageOf(2), isNull);
    expect(doc.pdfPageOf(63), isNull);
    expect(testStartPdfPage(book, doc, 't1'), 7);
    expect(testStartPdfPage(book, doc, 't2'), 17);
    expect(testStartPdfPage(book, doc, 't3'), 7); // atanın başlangıcı
    expect(testStartPdfPage(book, doc, 'yok'), isNull);
  });

  final box = const PdfBox(10, 20, 100, 200);
  final cards = [
    card('c1', QuestionStatus.wrong, node: 't1', no: 4),
    card('c2', QuestionStatus.blank, node: 't1', no: 7, doc: doc.id, page: 8, box: box),
    card('c3', QuestionStatus.correct, node: 't2', no: 2),
    card('c4', QuestionStatus.wrong, node: 't2', no: 5, doc: 'x' * 64, page: 40, box: box), // başka PDF
    card('c5', QuestionStatus.wrong, no: 1),
    card('c6', QuestionStatus.wrong, node: 't1', no: 12, doc: doc.id, page: 99, box: box), // aralık dışı
  ];
  final a = buildBookAnalysis(book: book, doc: doc, cards: cards);

  test('testler kitap sırasıyla, sorular numarayla; düğümsüz "Diğer" sonda', () {
    expect([for (final t in a.tests) t.title], ['Test 1', 'Test 2', 'Diğer']);
    expect([for (final i in a.tests[0].items) i.questionNo], [4, 7, 12]);
    expect(a.tests[0].path, 'Ünite 1');
  });

  test('kutulu kart kendi sayfasında; kutusuz ve yabancı/aralık dışı kart testin başında', () {
    final byId = {for (final i in a.items) i.cardId: i};
    expect(byId['c2']!.pdfPage, 8);
    expect(byId['c2']!.box, box);
    expect(byId['c1']!.pdfPage, 7);
    expect(byId['c1']!.box, isNull);
    expect(byId['c4']!.pdfPage, 17);
    expect(byId['c4']!.box, isNull);
    expect(byId['c6']!.pdfPage, 7);
    expect(byId['c5']!.pdfPage, isNull);
  });

  test('rozetler: sayfa başına yanlış+boş (doğru sayılmaz)', () {
    expect(a.mistakeBadges, {7: 2, 8: 1, 17: 1});
  });

  test('başlık şeridi: testin ilk sayfasında, kutusuz yanlışlar listelenir', () {
    final b = a.bannersOn(7);
    expect(b, hasLength(1));
    expect(b.single.bannerText(), 'Test 1: yanlışlar 4, 12');
    expect(a.bannersOn(8), isEmpty);
    expect(a.bannersOn(17).single.bannerText(), 'Test 2: yanlışlar 5');
  });

  test('süzgeç ve sonraki/önceki yanlış', () {
    expect([for (final t in a.filtered(AnalysisFilter.blank)) t.items.length], [1]);
    expect(a.filtered(AnalysisFilter.all).expand((t) => t.items), hasLength(6));
    expect(a.mistakePages(AnalysisFilter.wrong), [7, 17]);
    expect(a.mistakePages(AnalysisFilter.blank), [8]);
    expect(a.nextMistakePage(0, AnalysisFilter.wrong), 7);
    expect(a.nextMistakePage(7, AnalysisFilter.wrong), 17);
    expect(a.nextMistakePage(17, AnalysisFilter.wrong), isNull);
    expect(a.previousMistakePage(17, AnalysisFilter.wrong), 7);
    expect(a.previousMistakePage(7, AnalysisFilter.wrong), isNull);
    expect(a.nextMistakePage(7, AnalysisFilter.all), 8); // doğru kart (c3) sayılmaz
  });

  test('adres: yalın page, kutu, analiz; geçersiz yok sayılır', () {
    expect(pdfPageRoute('a'), '/pdf/a');
    expect(pdfPageRoute('a', page: 3), '/pdf/a?page=3');
    expect(pdfPageRoute('a', page: 3, analysis: true), '/pdf/a?page=3&analiz=1');
    expect(pdfPageRoute('a', analysis: true), '/pdf/a?analiz=1');
    var l = ReaderLink.parse({'page': '4'});
    expect((l.page, l.box, l.analysis), (4, null, false));
    l = ReaderLink.parse({'page': '4', 'box': '1,2,3,4', 'q': 'k', 'analiz': '1'});
    expect((l.page, l.box, l.questionId, l.analysis), (4, const PdfBox(1, 2, 3, 4), 'k', true));
    l = ReaderLink.parse({'page': '-1', 'box': '1,2,3,4'});
    expect((l.page, l.box), (null, null));
    l = ReaderLink.parse({'page': 'x'});
    expect(l.page, isNull);
    l = ReaderLink.parse({'page': '1', 'box': '3,2,1,4'});
    expect((l.page, l.box), (1, null)); // bozuk kutu: yalnız sayfa
    expect(ReaderLink.parse({}).page, isNull);
  });
}
