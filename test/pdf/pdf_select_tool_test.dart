import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/routes.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/features/ocr/data/ocr_repository_impl.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';
import 'package:kocum/features/pdf/data/pdf_import_service.dart';
import 'package:kocum/features/pdf/data/pdf_question_service.dart';
import 'package:kocum/features/pdf/data/pdfrx_engine.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/pdf_page_ink_layer.dart';
import 'package:kocum/features/pdf/presentation/pdf_question_panel.dart';
import 'package:kocum/features/pdf/presentation/pdf_reader_page.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:kocum/features/question_bank/presentation/widgets/question_tile.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

import 'pdf_test_support.dart';

final _id = 'd' * 64;

class _Ids implements IdGenerator {
  var n = 0;
  @override
  String next() => 'k${n++}';
}

class _DirMedia implements MediaStorage {
  _DirMedia(this.root);
  final Directory root;
  var n = 0;
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async {
    final rel = '$bucket/${n++}.${sourcePath.split('.').last}';
    final t = resolve(rel);
    t.parent.createSync(recursive: true);
    File(sourcePath).copySync(t.path);
    return rel;
  }

  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');
  @override
  Future<void> delete(String relativePath) async {}
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late String path;
  late _DirMedia media;
  late ProviderContainer container;

  Future<void> settle(WidgetTester t, [int ms = 500]) async {
    await t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  Future<void> open(WidgetTester t, {int? initialPage, PdfBox? highlight}) async {
    tmp = await t.runAsync(() => Directory.systemTemp.createTemp('soru_sec')) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    path = '${tmp.path}/a.pdf';
    media = _DirMedia(Directory('${tmp.path}/media'));
    late TopicLexicon lexicon;
    await t.runAsync(() async {
      await File(path).writeAsBytes(minimalPdf([
        [('turev ve turev teget hangisi dogrudur', 72, 700)],
        [('Ikinci', 72, 700)],
      ]));
      await pdfrxInitialize();
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      lexicon = TopicLexicon.fromJson(
          jsonDecode(await File('assets/meb/konu_sozlugu.json').readAsString()) as Map<String, dynamic>);
    });
    addTearDown(() => t.runAsync(db.close));
    t.view.physicalSize = const Size(900, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final info = PdfOpenInfo(
      PdfDocumentRecord(id: _id, sha256: _id, title: 'Sınav PDF', pageCount: 2, fileName: 'a.pdf'),
      path,
    );
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      mediaStorageProvider.overrideWithValue(media),
      pdfOpenInfoProvider(_id).overrideWith((ref) async => info),
      pdfQuestionServiceProvider.overrideWith((ref) async => PdfQuestionService(
            engine: const PdfrxEngine(initialize: pdfrxInitialize),
            cards: DriftQuestionCardRepository(db),
            media: media,
            ids: _Ids(),
            clock: () => DateTime(2026, 11, 1),
            tempDir: tmp,
            lexicon: () async => lexicon,
            ocrRepository: DriftOcrRepository(db),
          )),
    ]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: PdfReaderPage(documentId: _id, initialPage: initialPage, highlight: highlight)),
    ));
    for (var i = 0; i < 6; i++) {
      await settle(t, 400);
    }
  }

  /// Sayfa 1'de (sayfa birimi) iki köşe arasında kalemle sürükler.
  Future<void> dragBox(WidgetTester t, double x1, double y1, double x2, double y2) async {
    final r = t.getRect(find.byType(PdfPageInkLayer).first);
    Offset at(double x, double y) => Offset(r.left + x * r.width / 612, r.top + y * r.height / 792);
    final pen = await t.startGesture(at(x1, y1), kind: PointerDeviceKind.stylus);
    await pen.moveTo(at((x1 + x2) / 2, (y1 + y2) / 2));
    await pen.moveTo(at(x2, y2));
    await pen.up();
    await settle(t, 200);
  }

  testWidgets('Soru seç: kutu çiz, panel açılır, ders/konu önerilir, Kaydet kart yazar', (t) async {
    await open(t);
    expect(find.byKey(const Key('pdf-tool-select')), findsOneWidget);
    expect(find.byKey(const Key('pdf-question-panel')), findsNothing);

    await t.tap(find.byKey(const Key('pdf-tool-select')));
    await t.pump();
    // Sürüklerken görünür çerçeve çizilir.
    final r = t.getRect(find.byType(PdfPageInkLayer).first);
    Offset at(double x, double y) => Offset(r.left + x * r.width / 612, r.top + y * r.height / 792);
    final pen = await t.startGesture(at(40, 60), kind: PointerDeviceKind.stylus);
    await pen.moveTo(at(300, 150));
    await t.pump();
    expect(find.byKey(const Key('pdf-select-drag')), findsOneWidget);
    await pen.moveTo(at(580, 200));
    await pen.up();
    for (var i = 0; i < 20; i++) {
      await settle(t, 300);
      if (t.widget<TextField>(find.byKey(const Key('pdf-q-topic'))).controller!.text.isNotEmpty) break;
    }

    expect(find.byKey(const Key('pdf-question-panel')), findsOneWidget);
    expect(find.byKey(const Key('pdf-box-mark-0')), findsOneWidget); // bekleyen kutu sayfada kalır
    expect(find.byKey(const Key('pdf-select-drag')), findsNothing);
    // Kalem çizgisi yazılmadı: araç seçmeydi.
    final strokes = await t.runAsync(() => db.select(db.inkStrokes).get());
    expect(strokes, isEmpty);
    // Analiz bitti: konu metni önerildi.
    expect(t.widget<TextField>(find.byKey(const Key('pdf-q-topic'))).controller!.text, 'Türev');
    // Durum seçilmeden Kaydet kapalı.
    expect(t.widget<FilledButton>(find.byKey(const Key('pdf-q-save'))).onPressed, isNull);
    await t.tap(find.byKey(const Key('pdf-q-status-wrong')));
    await t.pump();
    expect(t.widget<FilledButton>(find.byKey(const Key('pdf-q-save'))).onPressed, isNotNull);
    await t.tap(find.byKey(const Key('pdf-q-save')));
    for (var i = 0; i < 30 && find.byKey(const Key('pdf-question-panel')).evaluate().isNotEmpty; i++) {
      await settle(t, 300);
    }

    expect(find.byKey(const Key('pdf-question-panel')), findsNothing);
    expect(find.text('Soru kaydedildi.'), findsOneWidget);
    final cards = (await t.runAsync(() => DriftQuestionCardRepository(db).watch(const QuestionFilter()).first))!;
    expect(cards, hasLength(1));
    final c = cards.single;
    expect([c.pdfDocumentId, c.pdfPage, c.status, c.subject, c.topicText], [_id, 0, QuestionStatus.wrong, 'TYT Matematik', 'Türev']);
    final b = c.pdfBox!;
    expect([b.left, b.top, b.right, b.bottom], [closeTo(40, 3), closeTo(60, 3), closeTo(580, 3), closeTo(200, 3)]);
    expect(File('${tmp.path}/media/${c.questionImage}').existsSync(), isTrue);

    // Defterdeki kart fotoğraflı kartla aynı görünür: aynı QuestionTile, önizleme MediaImage.
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: SizedBox(width: 200, height: 260, child: QuestionTile(card: c))),
      ),
      GoRoute(path: '/pdf/:id', builder: (_, s) => Scaffold(body: Text('PDF ${s.uri}'))),
      GoRoute(path: '/questions/:id', builder: (_, s) => const Scaffold(body: Text('AYRINTI'))),
    ]);
    addTearDown(router.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: ProviderContainer(parent: container, overrides: [
        pdfAvailableProvider(_id).overrideWith((ref) async => true),
      ]),
      child: MaterialApp.router(routerConfig: router),
    ));
    await settle(t, 200);
    expect(find.byType(Image), findsOneWidget);
    // PDF bu cihazdaysa köşede PDF simgesi çıkar; simge sayfaya/kutuya götürür.
    await t.tap(find.byKey(const Key('tile-open-pdf')));
    await settle(t, 200);
    expect(find.textContaining('PDF /pdf/$_id?page=0&box='), findsOneWidget);
    // autoDispose sağlayıcının zamanlayıcısı bitsin.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('PDF kartı: dokunuş onOpen çağırır (geçmiş yazılır), simge PDF açar', (t) async {
    final card = QuestionCard(
      id: 'y',
      status: QuestionStatus.wrong,
      origin: QuestionOrigin.independent,
      sourceName: 'y',
      subject: 'TYT Matematik',
      difficulty: 5,
      createdAt: DateTime(2026),
      pdfDocumentId: _id,
      pdfPage: 0,
      pdfBox: const PdfBox(10, 10, 100, 100),
    );
    var opened = 0;
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SizedBox(width: 200, height: 260, child: QuestionTile(card: card, onOpen: () => opened++)),
        ),
      ),
      GoRoute(path: '/pdf/:id', builder: (_, s) => Scaffold(body: Text('PDF ${s.uri}'))),
    ]);
    addTearDown(router.dispose);
    await t.pumpWidget(ProviderScope(
      overrides: [pdfAvailableProvider(_id).overrideWith((ref) async => true)],
      child: MaterialApp.router(routerConfig: router),
    ));
    await settle(t, 100);
    await t.tap(find.byType(QuestionTile));
    await settle(t, 100);
    expect(opened, 1);
    expect(find.textContaining('PDF /pdf/'), findsNothing);
    await t.tap(find.byKey(const Key('tile-open-pdf')));
    await settle(t, 100);
    expect(opened, 1);
    expect(find.textContaining('PDF /pdf/$_id?page=0&box='), findsOneWidget);
  });

  test('pdfAvailableProvider: PDF eklenince/silinince güncellenir', () async {
    final dir = await Directory.systemTemp.createTemp('avail');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pdfs = Directory('${dir.path}/pdfs')..createSync();
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      pdfImportServiceProvider.overrideWith((ref) async => PdfImportService(
            engine: const PdfrxEngine(initialize: pdfrxInitialize),
            repository: ref.watch(pdfDocumentRepositoryProvider),
            pdfDir: pdfs,
          )),
    ]);
    addTearDown(c.dispose);
    final seen = <bool>[];
    c.listen(pdfAvailableProvider(_id), (_, n) {
      if (n.hasValue && !n.isLoading) seen.add(n.value!);
    }, fireImmediately: true);
    final repo = c.read(pdfDocumentRepositoryProvider);
    await Future.delayed(const Duration(milliseconds: 200));
    File('${pdfs.path}/$_id.pdf').writeAsBytesSync([1]);
    await repo.add(sha256: _id, title: 'x', pageCount: 1, fileName: 'a.pdf');
    await Future.delayed(const Duration(milliseconds: 300));
    await repo.softDelete(_id);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(seen, [false, true, false]);
  });

  testWidgets('analiz sürerken Kaydet kapalı', (t) async {
    final never = Completer<PdfQuestionService>();
    final db = await t.runAsync(() async {
      final d = AppDatabase(NativeDatabase.memory());
      await d.customSelect('SELECT 1').get();
      return d;
    }) as AppDatabase;
    addTearDown(() => t.runAsync(db.close));
    t.view.physicalSize = const Size(900, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        pdfQuestionServiceProvider.overrideWith((ref) => never.future),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: PdfQuestionPanel(
            info: PdfOpenInfo(
              PdfDocumentRecord(id: _id, sha256: _id, title: 'x', pageCount: 1, fileName: 'a.pdf'),
              '/yok.pdf',
            ),
            page: 0,
            box: const PdfBox(0, 0, 100, 100),
            onSaved: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    ));
    await settle(t, 100);
    await t.tap(find.byKey(const Key('pdf-q-status-wrong')));
    await t.tap(find.byType(DropdownMenu<String>));
    await t.pump();
    await t.tap(find.text('TYT Matematik').last);
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const Key('pdf-q-save'))).onPressed, isNull);
    await t.pumpWidget(const SizedBox());
    await settle(t, 100);
  });

  testWidgets('PDF bu cihazda yoksa dokunuş ayrıntıyı açar (yalnız önizleme)', (t) async {
    final card = QuestionCard(
      id: 'x',
      status: QuestionStatus.wrong,
      origin: QuestionOrigin.independent,
      sourceName: 'x',
      subject: 'TYT Matematik',
      difficulty: 5,
      createdAt: DateTime(2026),
      questionImage: 'questions/yok.png',
      pdfDocumentId: _id,
      pdfPage: 0,
      pdfBox: const PdfBox(10, 10, 100, 100),
    );
    final dir = await t.runAsync(() => Directory.systemTemp.createTemp('tile')) as Directory;
    addTearDown(() => t.runAsync(() => dir.delete(recursive: true)));
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: SizedBox(width: 200, height: 260, child: QuestionTile(card: card))),
      ),
      GoRoute(path: '/questions/:id', builder: (_, s) => const Scaffold(body: Text('AYRINTI'))),
    ]);
    addTearDown(router.dispose);
    await t.pumpWidget(ProviderScope(
      overrides: [
        mediaStorageProvider.overrideWithValue(_DirMedia(dir)),
        pdfAvailableProvider(_id).overrideWith((ref) async => false),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await settle(t, 100);
    await t.tap(find.byType(QuestionTile));
    await settle(t, 100);
    expect(find.text('AYRINTI'), findsOneWidget);
    expect(AppRoutes.pdfReaderAt('a', 2, 1, 2, 3, 4), '/pdf/a?page=2&box=1.0,2.0,3.0,4.0');
  });

  testWidgets('çok küçük kutu reddedilir: panel açılmaz, uyarı çıkar', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('pdf-tool-select')));
    await t.pump();
    await dragBox(t, 100, 100, 108, 106);
    expect(find.byKey(const Key('pdf-question-panel')), findsNothing);
    expect(find.textContaining('Kutu çok küçük'), findsOneWidget);
  });

  testWidgets('ters sürükleme: kutu düzelir; İptal paneli ve kutuyu kaldırır, kayıt yok', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('pdf-tool-select')));
    await t.pump();
    await dragBox(t, 500, 300, 100, 120);
    await settle(t, 600);
    expect(find.byKey(const Key('pdf-question-panel')), findsOneWidget);
    await t.tap(find.byKey(const Key('pdf-q-cancel')));
    await t.pump();
    expect(find.byKey(const Key('pdf-question-panel')), findsNothing);
    expect(find.byKey(const Key('pdf-box-mark-0')), findsNothing);
    final n = await t.runAsync(() => DriftQuestionCardRepository(db).watch(const QuestionFilter()).first);
    expect(n, isEmpty);
  });

  testWidgets('kalem araca geçince seçim kapanır ve kalem yine çizer', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('pdf-tool-select')));
    await t.pump();
    await t.tap(find.byKey(const Key('pdf-tool-pen')));
    await t.pump();
    final pen = await t.startGesture(const Offset(450, 500), kind: PointerDeviceKind.stylus);
    for (var i = 0; i < 6; i++) {
      await pen.moveBy(const Offset(10, 0));
    }
    await pen.up();
    await settle(t, 300);
    expect(find.byKey(const Key('pdf-question-panel')), findsNothing);
    final strokes = await t.runAsync(() => db.select(db.inkStrokes).get());
    expect(strokes, hasLength(1));
  });

  testWidgets('bağlantıdaki sayfa belgede yoksa başa açılır, kutu yok sayılır', (t) async {
    await open(t, initialPage: 9, highlight: const PdfBox(50, 50, 300, 200));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byKey(const Key('pdf-box-mark-9')), findsNothing);
    expect(find.byKey(const Key('pdf-box-mark-0')), findsNothing);
  });

  testWidgets('karttan açılış: sayfaya atlar ve kutuyu vurgular', (t) async {
    await open(t, initialPage: 1, highlight: const PdfBox(50, 50, 300, 200));
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byKey(const Key('pdf-box-mark-1')), findsOneWidget);
    expect(find.byKey(const Key('pdf-box-mark-0')), findsNothing);
    final top = t.getRect(find.byKey(const Key('pdf-box-mark-1'))).top;
    expect(top, inInclusiveRange(0, 1200)); // sayfa 2 görünür bölgede
  });
}
