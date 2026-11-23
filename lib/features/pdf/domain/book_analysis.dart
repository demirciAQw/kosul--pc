/// Kitaba bağlı PDF'te analiz modu: yanlış/boş soruların PDF sayfasına eşlenmesi.
/// Saf Dart; Flutter ve veritabanı yok.
library;

import '../../library/domain/library.dart';
import '../../library/domain/progress.dart' show pathTo;
import '../../question_bank/domain/question_card.dart';
import 'pdf_document_record.dart';
import 'pdf_engine.dart' show PdfBox;

/// Okuyucu adresi: yalın sayfa (0'dan) ve isteğe bağlı analiz modu.
String pdfPageRoute(String documentId, {int? page, bool analysis = false}) {
  final q = [
    if (page != null && page >= 0) 'page=$page',
    if (analysis) 'analiz=1',
  ];
  return '/pdf/$documentId${q.isEmpty ? '' : '?${q.join('&')}'}';
}

/// `/pdf/:id` adresinin sorgusu: sayfa (0'dan), isteğe bağlı kutu ve analiz modu.
/// Yalın `?page=N` geçerlidir; kutu ancak geçerli sayfayla ve dört sayıyla
/// (sağ > sol, alt > üst) kabul edilir; geçersizse yok sayılır.
class ReaderLink {
  const ReaderLink({this.page, this.box, this.questionId, this.analysis = false});
  final int? page;
  final PdfBox? box;
  final String? questionId;
  final bool analysis;

  factory ReaderLink.parse(Map<String, String> q) {
    final p = int.tryParse(q['page'] ?? '');
    final page = p != null && p >= 0 ? p : null;
    final parts = (q['box'] ?? '').split(',').map(double.tryParse).toList();
    final boxOk = page != null &&
        parts.length == 4 &&
        parts.every((v) => v != null && v.isFinite) &&
        parts[2]! > parts[0]! &&
        parts[3]! > parts[1]!;
    return ReaderLink(
      page: page,
      box: boxOk ? PdfBox(parts[0]!, parts[1]!, parts[2]!, parts[3]!) : null,
      questionId: boxOk ? q['q'] : null,
      analysis: q['analiz'] == '1',
    );
  }
}

/// Panel süzgeci. "Hepsi" doğruları da listeler.
enum AnalysisFilter {
  wrong('Yanlış'),
  blank('Boş'),
  all('Hepsi');

  const AnalysisFilter(this.label);
  final String label;

  bool matches(QuestionStatus s) => switch (this) {
    AnalysisFilter.wrong => s == QuestionStatus.wrong,
    AnalysisFilter.blank => s == QuestionStatus.blank,
    AnalysisFilter.all => true,
  };
}

/// Kitaptaki tek bir soru (kart) ve PDF'teki yeri.
class AnalysisItem {
  const AnalysisItem({
    required this.cardId,
    required this.nodeId,
    required this.status,
    this.questionNo,
    this.pdfPage,
    this.box,
  });

  final String cardId;

  /// Kitap haritası düğümü (test); yoksa null.
  final String? nodeId;
  final QuestionStatus status;
  final int? questionNo;

  /// PDF sayfası (0'dan); bulunamadıysa null (listede görünür, gidilemez).
  final int? pdfPage;

  /// Yalnız kartın kendi PDF kutusu varsa (testin başlangıç sayfası değil).
  final PdfBox? box;

  bool get isMistake => status != QuestionStatus.correct;
}

/// Bir test (ya da konu) ve içindeki sorular.
class AnalysisTest {
  const AnalysisTest({
    required this.nodeId,
    required this.title,
    required this.path,
    required this.startPage,
    required this.items,
  });

  /// Düğüm yoksa null ("Diğer").
  final String? nodeId;
  final String title;

  /// "Ünite › Konu" (testin kendi adı olmadan).
  final String path;

  /// Testin PDF'teki ilk sayfası (0'dan); sayfa aralığı bilinmiyorsa null.
  final int? startPage;
  final List<AnalysisItem> items;

  /// Başlık şeridi için: kutusu olmayan yanlış/boşlar.
  List<AnalysisItem> get unboxedMistakes => [
    for (final i in items)
      if (i.isMistake && i.box == null) i,
  ];

  /// "Test 3: yanlışlar 4, 7, 12" metni.
  String bannerText() {
    final nos = [for (final i in unboxedMistakes) i.questionNo?.toString() ?? '?'];
    return '$title: yanlışlar ${nos.join(', ')}';
  }
}

class BookAnalysis {
  const BookAnalysis({required this.documentId, required this.tests});

  final String documentId;
  final List<AnalysisTest> tests;

  Iterable<AnalysisItem> get items sync* {
    for (final t in tests) {
      yield* t.items;
    }
  }

  /// Süzgece uyan öğeler, test ve soru sırasıyla.
  List<AnalysisTest> filtered(AnalysisFilter f) => [
    for (final t in tests)
      if (t.items.any((i) => f.matches(i.status)))
        AnalysisTest(
          nodeId: t.nodeId,
          title: t.title,
          path: t.path,
          startPage: t.startPage,
          items: [
            for (final i in t.items)
              if (f.matches(i.status)) i,
          ],
        ),
  ];

  /// Sayfadaki öğeler (analiz modunda çerçeve çizilenler).
  List<AnalysisItem> onPage(int page) => [
    for (final i in items)
      if (i.pdfPage == page) i,
  ];

  /// Sayfa → yanlış + boş sayısı (rozetler).
  Map<int, int> get mistakeBadges {
    final out = <int, int>{};
    for (final i in items) {
      final p = i.pdfPage;
      if (p != null && i.isMistake) out[p] = (out[p] ?? 0) + 1;
    }
    return out;
  }

  /// Bu sayfada başlık şeridi gereken testler: testin ilk sayfası ve kutusuz
  /// yanlışı olanlar.
  List<AnalysisTest> bannersOn(int page) => [
    for (final t in tests)
      if (t.startPage == page && t.unboxedMistakes.isNotEmpty) t,
  ];

  /// Süzgece uyan yanlış/boş sayfaları, artan ve tekrarsız.
  List<int> mistakePages(AnalysisFilter f) =>
      ({
        for (final i in items)
          if (i.isMistake && i.pdfPage != null && f.matches(i.status)) i.pdfPage!,
      }.toList()..sort());

  /// [from] sayfasından sonraki yanlış sayfası (yoksa null).
  int? nextMistakePage(int from, AnalysisFilter f) {
    for (final p in mistakePages(f)) {
      if (p > from) return p;
    }
    return null;
  }

  /// [from] sayfasından önceki yanlış sayfası (yoksa null).
  int? previousMistakePage(int from, AnalysisFilter f) {
    int? best;
    for (final p in mistakePages(f)) {
      if (p < from) best = p;
    }
    return best;
  }
}

/// Testin PDF'teki ilk sayfası: düğümün ya da en yakın atasının başlangıç
/// kitap sayfası → PDF sayfası (ofsetli, 0'dan). Bilinmiyorsa null.
int? testStartPdfPage(Book book, PdfDocumentRecord doc, String nodeId) {
  for (final n in pathTo(book, nodeId).reversed) {
    if (n.hasPages) return doc.pdfPageOf(n.pageStart!);
  }
  return null;
}

/// Kitabın kartlarından PDF analizi kurar. [cards] bu kitaba ait kartlardır.
BookAnalysis buildBookAnalysis({
  required Book book,
  required PdfDocumentRecord doc,
  required Iterable<QuestionCard> cards,
}) {
  // Test sırası: kitap haritasının sırası.
  final order = <String, int>{};
  var k = 0;
  for (final n in book.allNodes) {
    order[n.id] = k++;
  }

  final byNode = <String?, List<AnalysisItem>>{};
  for (final c in cards) {
    if (c.bookId != null && c.bookId != book.id) continue;
    final nodeId = c.contentNodeId != null && order.containsKey(c.contentNodeId) ? c.contentNodeId : null;
    final anchored = c.hasPdfAnchor && c.pdfDocumentId == doc.id;
    final start = nodeId == null ? null : testStartPdfPage(book, doc, nodeId);
    final anchorPage = anchored && c.pdfPage! >= 0 && c.pdfPage! < doc.pageCount ? c.pdfPage : null;
    (byNode[nodeId] ??= []).add(
      AnalysisItem(
        cardId: c.id,
        nodeId: nodeId,
        status: c.status,
        questionNo: c.questionNo,
        pdfPage: anchorPage ?? start,
        box: anchorPage != null ? c.pdfBox : null,
      ),
    );
  }

  int byNo(AnalysisItem a, AnalysisItem b) => (a.questionNo ?? 1 << 30).compareTo(b.questionNo ?? 1 << 30);

  final tests = <AnalysisTest>[];
  final ids = byNode.keys.toList()
    ..sort((a, b) => (a == null ? 1 << 30 : order[a]!).compareTo(b == null ? 1 << 30 : order[b]!));
  for (final id in ids) {
    final items = byNode[id]!..sort(byNo);
    if (id == null) {
      tests.add(AnalysisTest(nodeId: null, title: 'Diğer', path: '', startPage: null, items: items));
      continue;
    }
    final path = pathTo(book, id);
    tests.add(
      AnalysisTest(
        nodeId: id,
        title: path.last.title,
        path: path.take(path.length - 1).map((n) => n.title).join(' › '),
        startPage: testStartPdfPage(book, doc, id),
        items: items,
      ),
    );
  }
  return BookAnalysis(documentId: doc.id, tests: tests);
}
