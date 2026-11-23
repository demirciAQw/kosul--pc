import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/app/platform.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/library/data/library_data.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/notes/data/note_tool_prefs_store.dart';
import 'package:kocum/features/notes/presentation/note_tool_dock.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart' show PdfBox;
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/pdf_reader_page.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

import 'pdf_test_support.dart';

final _id = 'e' * 64;

QuestionCard _card(String id, QuestionStatus st, String node, int no, {int? page, PdfBox? box}) => QuestionCard(
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
  pdfDocumentId: page == null ? null : _id,
  pdfPage: page,
  pdfBox: box,
);

/// Gerçek PdfViewer + PDFium. Kitap: Test 1 (kitap sayfası 1-1 → pdf 0, ofset 0),
/// Test 2 (kitap sayfası 3 → pdf 2). Sayfa 1 (pdf 1) kutulu bir yanlış taşır.
void main() {
  late Directory tmp;
  late AppDatabase db;

  Future<void> settle(WidgetTester t, [int ms = 500]) async {
    await t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  /// Sayfaya gitme animasyonu sahte zamanla ilerler: birkaç kare daha.
  Future<void> glide(WidgetTester t) async {
    await settle(t, 300);
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t, 300);
  }

  Future<void> open(WidgetTester t, {bool analysis = false, int? bookless, DockPosition? dock}) async {
    tmp = await t.runAsync(() => Directory.systemTemp.createTemp('analiz')) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    final path = '${tmp.path}/a.pdf';
    await t.runAsync(() async {
      await File(path).writeAsBytes(minimalPdf([
        [('Bir', 72, 700)],
        [('Iki', 72, 700)],
        [('Uc', 72, 700)],
      ]));
      await pdfrxInitialize();
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      await DriftLibraryRepository(db).save(Book(
        id: 'b',
        title: 'K',
        examType: 'TYT',
        subject: 'Fizik',
        pageCount: 3,
        avgQuestionsPerPage: 1,
        createdAt: DateTime(2026),
        roots: const [
          ContentNode(id: 't1', level: NodeLevel.unit, title: 'Test 1', pageStart: 1, pageEnd: 2, questionCount: 5),
          ContentNode(id: 't2', level: NodeLevel.unit, title: 'Test 2', pageStart: 3, pageEnd: 3, questionCount: 5),
        ],
      ));
        final cards = DriftQuestionCardRepository(db);
      await cards.insert(_card('k1', QuestionStatus.wrong, 't1', 3));
      await cards.insert(_card('k2', QuestionStatus.blank, 't1', 5, page: 1, box: const PdfBox(50, 50, 300, 300)));
      await cards.insert(_card('k3', QuestionStatus.wrong, 't2', 2));
      await cards.insert(_card('k4', QuestionStatus.correct, 't2', 4));
      if (dock != null) await NoteToolPrefsStore(db, key: isDesktop ? NoteToolPrefsStore.desktopKey : NoteToolPrefsStore.phoneKey).save({'dock.pos': dock.name});
    });
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.runAsync(db.close);
    });
    t.view.physicalSize = const Size(1000, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final info = PdfOpenInfo(
      PdfDocumentRecord(
        id: _id,
        sha256: _id,
        title: 'K PDF',
        pageCount: 3,
        fileName: 'a.pdf',
        bookId: bookless == null ? 'b' : null,
      ),
      path,
    );
    await t.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        pdfOpenInfoProvider(_id).overrideWith((ref) async => info),
      ],
      child: MaterialApp(home: PdfReaderPage(documentId: _id, analysis: analysis)),
    ));
    for (var i = 0; i < 6; i++) {
      await settle(t, 400);
    }
  }

  testWidgets('analiz kapalıyken işaret, panel ve düğme yok; anahtar var', (t) async {
    await open(t);
    expect(find.byKey(const Key('pdf-analysis-toggle')), findsOneWidget);
    expect(find.byKey(const Key('analysis-bar')), findsNothing);
    expect(find.byKey(const Key('analysis-panel')), findsNothing);
    expect(find.byKey(const Key('analysis-box-k2')), findsNothing);
    expect(find.textContaining('yanlışlar'), findsNothing);
  });

  testWidgets('kitapsız PDF: analiz anahtarı yok (telefon/eski akış aynı)', (t) async {
    await open(t, bookless: 1, analysis: true);
    expect(find.byKey(const Key('pdf-analysis-toggle')), findsNothing);
    expect(find.byKey(const Key('analysis-bar')), findsNothing);
  });

  testWidgets('anahtar açınca: panel, test grupları, süzgeç, şerit, rozet; kapanınca gizlenir', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('pdf-analysis-toggle')));
    await settle(t, 600);
    expect(find.byKey(const Key('analysis-panel')), findsOneWidget);
    // Varsayılan süzgeç Yanlış: k1 (Test 1), k3 (Test 2); blank k2 yok.
    expect(find.byKey(const Key('analysis-item-k1')), findsOneWidget);
    expect(find.byKey(const Key('analysis-item-k3')), findsOneWidget);
    expect(find.byKey(const Key('analysis-item-k2')), findsNothing);
    expect(find.byKey(const Key('analysis-item-k4')), findsNothing);
    // Boş süzgeci.
    await t.tap(find.text('Boş'));
    await settle(t, 200);
    expect(find.byKey(const Key('analysis-item-k2')), findsOneWidget);
    expect(find.byKey(const Key('analysis-item-k1')), findsNothing);
    // Hepsi: doğru da görünür.
    await t.tap(find.text('Hepsi'));
    await settle(t, 200);
    expect(find.byKey(const Key('analysis-item-k4')), findsOneWidget);
    // Test 1'in başlık şeridi (ilk sayfa, kutusuz yanlış 3).
    expect(find.textContaining('Test 1: yanlışlar 3'), findsOneWidget);
    // Sayfa göstergesinde rozet metni (sayfa 1: 1 yanlış).
    expect(find.textContaining('1 / 3 · 1 yanlış'), findsOneWidget);
    // Küçük resim şeridi: rozetler (sayfa 0: 1, sayfa 1: 1 [boş kutulu], sayfa 2: 1).
    await t.tap(find.byKey(const Key('pdf-thumbs-toggle')));
    await settle(t, 400);
    for (final i in [0, 1, 2]) {
      expect(find.byKey(Key('analysis-badge-$i')), findsOneWidget, reason: 'sayfa $i');
    }
    // Kapat: her şey gizlenir.
    await t.tap(find.byKey(const Key('pdf-analysis-toggle')));
    await settle(t, 300);
    expect(find.byKey(const Key('analysis-panel')), findsNothing);
    expect(find.byKey(const Key('analysis-bar')), findsNothing);
    expect(find.textContaining('yanlışlar'), findsNothing);
    expect(find.byKey(const Key('analysis-badge-0')), findsNothing);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('analiz=1 ile açılır; panelden dokununca sayfaya gider; sonraki/önceki yanlış', (t) async {
    await open(t, analysis: true);
    await settle(t, 400);
    expect(find.byKey(const Key('analysis-panel')), findsOneWidget);
    // Kutulu boş soru: çerçeve çizilir (sayfa 2'de, bu yüzden Boş süzgeciyle ona gidilir).
    await t.tap(find.text('Boş'));
    await settle(t, 200);
    await t.tap(find.byKey(const Key('analysis-item-k2')));
    await glide(t);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(find.byKey(const Key('analysis-box-k2')), findsOneWidget);
    // Yanlış süzgecine dön; sayfa 2'den (pdf 1) sonraki yanlış pdf 2, önceki pdf 0.
    await t.tap(find.text('Yanlış'));
    await settle(t, 200);
    await t.tap(find.byKey(const Key('analysis-next')));
    await glide(t);
    expect(find.textContaining('3 / 3'), findsOneWidget);
    await t.tap(find.byKey(const Key('analysis-next')));
    await settle(t, 300);
    expect(find.text('Sonrası yok.'), findsOneWidget);
    // Yanlışlar pdf 0 ve 2'de (pdf 1 boş): önceki yanlış başa gider.
    await t.tap(find.byKey(const Key('analysis-prev')));
    await glide(t);
    expect(find.textContaining('1 / 3'), findsOneWidget);
    await t.tap(find.byKey(const Key('analysis-prev')));
    await glide(t);
    expect(find.text('Öncesi yok.'), findsOneWidget);
  });

  for (final pos in DockPosition.values) {
    testWidgets('analiz paneli açıkken araç yuvası (${pos.name}) panelin altında kalmaz', (t) async {
      await open(t, analysis: true, dock: pos);
      await settle(t, 400);
      expect(find.byKey(const Key('analysis-panel')), findsOneWidget);
      final panel = t.getRect(find.byKey(const Key('analysis-panel')));
      final dock = t.getRect(find.byType(NoteToolDock));
      expect(dock.overlaps(panel), isFalse, reason: 'yuva $dock panel $panel');
      // Yuva gerçekten istenen kenarda mı (ayar yüklendi mi)?
      expect(switch (pos) {
        DockPosition.top => dock.top < 100,
        DockPosition.bottom => dock.bottom > 1200,
        DockPosition.left => dock.left < 100,
        DockPosition.right => dock.right > 600,
      }, isTrue, reason: '$pos: $dock');
      // Panel kapanınca yuva yerine döner (sağdaysa ekranın sağ kenarına yaslanır).
      await t.tap(find.byKey(const Key('analysis-panel-close')));
      await settle(t, 300);
      expect(find.byKey(const Key('analysis-panel')), findsNothing);
      if (pos == DockPosition.right) {
        await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
        expect(t.getRect(find.byType(NoteToolDock)).right, greaterThan(900));
      }
    });
  }

  test('toolDockRightInset: panel kapalı 0; sağ yuva panel genişliği; dar ekranda üst/alt değişmez', () {
    for (final p in DockPosition.values) {
      expect(toolDockRightInset(panelOpen: false, screenWidth: 1000, position: p), 0);
    }
    expect(toolDockRightInset(panelOpen: true, screenWidth: 1000, position: DockPosition.right), 320);
    expect(toolDockRightInset(panelOpen: true, screenWidth: 400, position: DockPosition.right), 320);
    expect(toolDockRightInset(panelOpen: true, screenWidth: 1000, position: DockPosition.bottom), 320);
    expect(toolDockRightInset(panelOpen: true, screenWidth: 700, position: DockPosition.bottom), 0);
  });
}
