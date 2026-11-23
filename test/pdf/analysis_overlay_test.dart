import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/pdf/domain/book_analysis.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/presentation/analysis_overlay.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';

QuestionCard _c(String id, QuestionStatus st, {String? node, int? no}) => QuestionCard(
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
    roots: const [ContentNode(id: 't1', level: NodeLevel.unit, title: 'Test 1', pageStart: 1, pageEnd: 5, questionCount: 5)],
  );
  final doc = PdfDocumentRecord(id: 'd' * 64, sha256: 'd' * 64, title: 'K', pageCount: 10, fileName: 'k.pdf', bookId: 'b');
  final a = buildBookAnalysis(book: book, doc: doc, cards: [_c('c1', QuestionStatus.wrong, node: 't1', no: 4)]);

  Future<(int, int)> pump(WidgetTester t, {required void Function() onOpen}) async {
    var down = 0, tapped = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: Stack(
            children: [
              // Kalem katmanı yerine geçen: şeridin ALTINDAki dokunuş alıcı.
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => down++,
                  child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => tapped++),
                ),
              ),
              Positioned.fill(
                child: AnalysisPageOverlay(page: 0, pageWidth: 400, pageHeight: 600, analysis: ValueNotifier(a), onOpenPanel: onOpen),
              ),
            ],
          ),
        ),
      ),
    ));
    await t.pump();
    return (down, tapped);
  }

  testWidgets('şerit ince (<= 24 px) ve kalem/dokunuşu YUTMAZ: altındaki katman olayı alır', (t) async {
    var opened = 0;
    var down = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: Stack(
            children: [
              Positioned.fill(child: Listener(behavior: HitTestBehavior.opaque, onPointerDown: (_) => down++)),
              Positioned.fill(
                child: AnalysisPageOverlay(page: 0, pageWidth: 400, pageHeight: 600, analysis: ValueNotifier(a), onOpenPanel: () => opened++),
              ),
            ],
          ),
        ),
      ),
    ));
    await t.pump();
    final banner = find.byKey(Key('analysis-banner-${a.bannersOn(0).single.nodeId}'));
    expect(banner, findsOneWidget);
    expect(t.getSize(banner).height, lessThanOrEqualTo(24));
    // Şeridin gövdesine (sol) basış alttaki katmana ulaşır; "Aç" çağrılmaz.
    final p = t.getTopLeft(banner) + const Offset(20, 10);
    final g = await t.startGesture(p);
    await g.moveBy(const Offset(30, 0)); // kalem çizgisi gibi sürükleme
    await g.up();
    expect(down, 1);
    expect(opened, 0);
    // Yalnız "Aç" düğmesi dokunuş alır ve alttakine geçmez.
    await t.tap(find.byKey(Key('analysis-banner-open-${a.bannersOn(0).single.nodeId}')));
    expect(opened, 1);
    expect(down, 1);
  });

  testWidgets('şerit sayfa içeriğinin çoğunu örtmez (ince bant)', (t) async {
    final r = await pump(t, onOpen: () {});
    expect(r, (0, 0));
    final banner = find.byKey(Key('analysis-banner-${a.bannersOn(0).single.nodeId}'));
    expect(t.getRect(banner).height / 600, lessThan(0.05));
  });
}
