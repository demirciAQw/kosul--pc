import 'dart:typed_data';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/routes.dart';
import 'package:kocum/app/tablet.dart' show debugAndroidOverride;
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/pdf/data/pdf_preview_encoder.dart';
import 'package:kocum/features/pdf/data/pdfrx_engine.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/solve.dart';
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/pdf_solve_page.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:kocum/features/question_bank/presentation/screens/question_detail_screen.dart';
import 'package:kocum/features/question_bank/presentation/widgets/question_tile.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

import 'pdf_test_support.dart';

final _docId = 'd' * 64;
const _box = PdfBox(72, 100, 400, 300);

class _DirMedia implements MediaStorage {
  _DirMedia(this.root);
  final Directory root;
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async => throw UnimplementedError();
  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');
  @override
  Future<void> delete(String relativePath) async {}
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

QuestionCard _card(String id, {String? image, bool pdf = false}) => QuestionCard(
  id: id,
  status: QuestionStatus.wrong,
  origin: QuestionOrigin.independent,
  sourceName: 'kaynak',
  subject: 'TYT Matematik',
  difficulty: 5,
  createdAt: DateTime(2026),
  questionImage: image,
  pdfDocumentId: pdf ? _docId : null,
  pdfPage: pdf ? 0 : null,
  pdfBox: pdf ? _box : null,
);

void main() {
  late AppDatabase db;
  late Directory tmp;
  late ProviderContainer container;

  Future<void> settle(WidgetTester t, [int ms = 500]) async {
    await t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  Future<void> until(WidgetTester t, Finder f) async {
    for (var i = 0; i < 30 && f.evaluate().isEmpty; i++) {
      await settle(t, 200);
    }
  }

  /// Veritabanı + medya klasörü + (isteğe bağlı) 200x100 PNG fotoğraf ('foto.png').
  Future<void> setup(WidgetTester t, {bool writeImage = true}) async {
    tmp = await t.runAsync(() => Directory.systemTemp.createTemp('foto_cozum')) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    await t.runAsync(() async {
      await pdfrxInitialize();
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      if (writeImage) {
        final rgba = List<int>.filled(200 * 100 * 4, 255);
        final png = await encodePreview(Uint8List.fromList(rgba), 200, 100);
        await File('${tmp.path}/foto.png').writeAsBytes(png.bytes);
      }
    });
    addTearDown(() => t.runAsync(db.close));
    t.view.physicalSize = const Size(1000, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  Future<void> pumpSolve(
    WidgetTester t,
    String questionId, {
    PdfOpenInfo? pdfInfo,
    String? pdfDocId,
    bool waitCanvas = true,
  }) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          mediaStorageProvider.overrideWithValue(_DirMedia(tmp)),
          pdfEngineProvider.overrideWithValue(PdfrxEngine(initialize: pdfrxInitialize)),
          if (pdfDocId != null) pdfOpenInfoProvider(pdfDocId).overrideWith((ref) async => pdfInfo),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(home: QuestionSolvePage(questionId: questionId));
          },
        ),
      ),
    );
    for (var i = 0; waitCanvas && i < 40 && find.byKey(const Key('solve-canvas')).evaluate().isEmpty; i++) {
      await settle(t, 200);
    }
  }

  Future<void> closeApp(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
  }

  Future<void> insert(WidgetTester t, QuestionCard c) =>
      t.runAsync(() => DriftQuestionCardRepository(db).insert(c)).then((_) {});

  Future<void> penDraw(WidgetTester t, Offset start) async {
    final pen = await t.startGesture(start, kind: PointerDeviceKind.stylus);
    for (var i = 0; i < 6; i++) {
      await pen.moveBy(const Offset(12, 4));
    }
    await pen.up();
    await settle(t, 300);
  }

  Future<List<InkStrokeRow>> allRows(WidgetTester t) async {
    late List<InkStrokeRow> r;
    await t.runAsync(() async => r = await db.select(db.inkStrokes).get());
    return r;
  }

  /// Ekran noktası -> fotoğraf çizim uzayı (1000 birim genişlik; 200x100 görüntü, bölge 1000x900).
  Offset expectedUnit(WidgetTester t, Offset screen) {
    final f = find.byKey(const Key('solve-canvas'));
    final tl = t.getTopLeft(f), br = t.getBottomRight(f);
    final region = photoSolveRegion(200, 100)!;
    return Offset(
      (screen.dx - tl.dx) / (br.dx - tl.dx) * region.width,
      (screen.dy - tl.dy) / (br.dy - tl.dy) * region.height,
    );
  }

  group('saf mantık', () {
    test('fotoğraf uzayı: genişlik 1000 birim, yükseklik orantılı; altta yazı payı', () {
      final u = photoUnitSize(2000, 1000)!;
      expect((u.width, u.height), (1000, 500));
      // Aynı oran, başka çözünürlük: aynı uzay (çizgi yerinde kalır).
      final v = photoUnitSize(400, 200)!;
      expect((v.width, v.height), (1000, 500));
      final r = photoSolveRegion(2000, 1000)!;
      expect((r.left, r.top, r.right), (0, 0, 1000));
      expect(r.bottom, greaterThan(500 + 300 - 1));
      expect(photoUnitSize(0, 10), isNull);
      expect(photoSolveRegion(10, 0), isNull);
    });

    test('bağlam karttan türer', () {
      expect(solveSpaceOf(hasPdfAnchor: true, hasImage: true), SolveSpace.pdf);
      expect(solveSpaceOf(hasPdfAnchor: true, hasImage: false), SolveSpace.pdf);
      expect(solveSpaceOf(hasPdfAnchor: false, hasImage: true), SolveSpace.photo);
      expect(solveSpaceOf(hasPdfAnchor: false, hasImage: false), SolveSpace.none);
    });

    test('önizleme bölgesi sayfaya kırpılmaz ama kutuyu kapsar', () {
      final r = previewSolveRegion(_box)!;
      expect(r.left, lessThanOrEqualTo(_box.left));
      expect(r.right, greaterThan(_box.right));
      expect(r.bottom, greaterThan(_box.bottom));
    });

    test('çözüm özeti: deneme sayısı ve son deneme süresi', () {
      final m = solveSummaries({
        'a': [
          const StrokeTime(attemptNo: 1, startedAtMs: 1000, durationMs: 2000),
          const StrokeTime(attemptNo: 2, startedAtMs: 100000, durationMs: 5000),
        ],
        'b': [const StrokeTime(attemptNo: 0, startedAtMs: 1000, durationMs: 2000)],
      });
      expect(m.keys, ['a']);
      expect((m['a']!.attempts, m['a']!.lastDuration), (2, const Duration(seconds: 5)));
    });
  });

  testWidgets('fotoğraflı kart: kalemle çiz, görüntü uzayında kaydedilir, yeniden açılınca durur', (t) async {
    await setup(t);
    await insert(t, _card('q1', image: 'foto.png'));
    await pumpSolve(t, 'q1');
    expect(find.byKey(const Key('solve-canvas')), findsOneWidget);
    expect(find.byKey(const Key('solve-layer-1')), findsOneWidget);

    final c = t.getCenter(find.byKey(const Key('solve-canvas')));
    await penDraw(t, c);
    var rows = await allRows(t);
    expect(rows, hasLength(1));
    final r = rows.single;
    // Bağlam: PDF değil, not değil; yalnız soru ve deneme.
    expect((r.pdfDocumentId, r.pdfPage, r.noteId, r.questionId, r.attemptNo), (null, null, null, 'q1', 1));
    final pts = StrokeCodec.decode(r.points);
    final e = expectedUnit(t, c);
    expect(pts.first.x, closeTo(e.dx, 1));
    expect(pts.first.y, closeTo(e.dy, 1));
    // Depo da aynı çizgiyi QuestionImageOwner ile bulur.
    late List<InkStroke> viaRepo;
    await t.runAsync(() async {
      viaRepo = await container.read(inkStrokeRepositoryProvider).forPage(const QuestionImageOwner('q1'), attemptNo: 1);
    });
    expect(viaRepo, hasLength(1));
    expect(viaRepo.single.owner, isA<QuestionImageOwner>());

    // Kapat, yeniden aç: deneme 1 çizgileriyle gelir (yeniden çöz "zaten boş" demez).
    await closeApp(t);
    await pumpSolve(t, 'q1');
    expect(find.byKey(const Key('solve-layer-1')), findsOneWidget);
    await t.tap(find.byKey(const Key('solve-resolve')));
    await settle(t, 400);
    expect(find.text('Bu deneme zaten boş.'), findsNothing);
    expect(find.byKey(const Key('solve-layer-2')), findsOneWidget);
    await closeApp(t);
  });

  testWidgets('fotoğraf: yakınlaştırılmış görünümde de koordinat görüntü uzayında', (t) async {
    await setup(t);
    await insert(t, _card('q1', image: 'foto.png'));
    await pumpSolve(t, 'q1');
    final canvas = find.byKey(const Key('solve-canvas'));
    final c = t.getCenter(canvas);
    final a = await t.startGesture(c - const Offset(20, 0), pointer: 1);
    final b = await t.startGesture(c + const Offset(20, 0), pointer: 2);
    await t.pump();
    await a.moveBy(const Offset(-60, 0));
    await b.moveBy(const Offset(60, 0));
    await a.up();
    await b.up();
    await settle(t, 200);
    final big = t.getBottomRight(canvas) - t.getTopLeft(canvas);
    expect(big.dx, greaterThan(t.getSize(canvas).width * 1.5));
    final start = c + const Offset(-70, -50);
    await penDraw(t, start);
    final rows = await allRows(t);
    expect(rows, hasLength(1));
    final p = StrokeCodec.decode(rows.single.points).first;
    final e = expectedUnit(t, start);
    expect(p.x, closeTo(e.dx, 1));
    expect(p.y, closeTo(e.dy, 1));
    await closeApp(t);
  });

  testWidgets('fotoğraf: yeniden çöz yeni katman, eski çizgi yerinde; geri al yalnız o katmanı etkiler', (t) async {
    await setup(t);
    await insert(t, _card('q1', image: 'foto.png'));
    await pumpSolve(t, 'q1');
    final c = t.getCenter(find.byKey(const Key('solve-canvas')));
    await penDraw(t, c);
    await t.tap(find.byKey(const Key('solve-resolve')));
    await settle(t, 400);
    expect(find.byKey(const Key('solve-layer-2')), findsOneWidget);
    await penDraw(t, c);
    var rows = await allRows(t);
    expect(rows.map((r) => r.attemptNo).toList()..sort(), [1, 2]);
    expect(rows.every((r) => r.questionId == 'q1' && r.pdfDocumentId == null), isTrue);
    await t.tap(find.byKey(const Key('pdf-undo')));
    await settle(t, 400);
    rows = (await allRows(t)).where((r) => !r.deleted).toList();
    expect(rows.map((r) => r.attemptNo), [1]);
    // Eski çözümü göster / bindir çalışır.
    await t.tap(find.byKey(const Key('solve-show-old')));
    await settle(t, 200);
    expect(find.byKey(const Key('solve-layer-1')), findsOneWidget);
    await closeApp(t);
  });

  testWidgets('PDF kartı, PDF bu cihazda: PDF sayfası arka plan, PDF sayfa birimi, PDF sahibi', (t) async {
    await setup(t, writeImage: false);
    final pdfPath = '${tmp.path}/a.pdf';
    await t.runAsync(() => File(pdfPath).writeAsBytes(minimalPdf([
      [('Soru bir', 72, 700)],
    ])));
    await insert(t, _card('q1', pdf: true));
    final info = PdfOpenInfo(
      PdfDocumentRecord(id: _docId, sha256: _docId, title: 'D', pageCount: 1, fileName: 'a.pdf'),
      pdfPath,
    );
    await pumpSolve(t, 'q1', pdfInfo: info, pdfDocId: _docId);
    expect(find.byKey(const Key('solve-canvas')), findsOneWidget);
    final c = t.getCenter(find.byKey(const Key('solve-canvas')));
    await penDraw(t, c);
    final r = (await allRows(t)).single;
    expect((r.pdfDocumentId, r.pdfPage, r.questionId), (_docId, 0, 'q1'));
    final region = solveRegion(_box, const PdfPageSize(612, 792))!;
    final f = find.byKey(const Key('solve-canvas'));
    final tl = t.getTopLeft(f), br = t.getBottomRight(f);
    final p = StrokeCodec.decode(r.points).first;
    expect(p.x, closeTo(region.left + (c.dx - tl.dx) / (br.dx - tl.dx) * region.width, 1));
    await closeApp(t);
  });

  testWidgets('PDF kartı, PDF yok: kart önizlemesi açılır; çizgi yine PDF sahibi ve PDF birimi', (t) async {
    await setup(t);
    await insert(t, _card('q1', image: 'foto.png', pdf: true));
    await pumpSolve(t, 'q1', pdfInfo: null, pdfDocId: _docId);
    expect(find.byKey(const Key('solve-canvas')), findsOneWidget);
    final c = t.getCenter(find.byKey(const Key('solve-canvas')));
    await penDraw(t, c);
    final r = (await allRows(t)).single;
    expect((r.pdfDocumentId, r.pdfPage, r.questionId, r.attemptNo), (_docId, 0, 'q1', 1));
    final region = previewSolveRegion(_box)!;
    final f = find.byKey(const Key('solve-canvas'));
    final tl = t.getTopLeft(f), br = t.getBottomRight(f);
    final p = StrokeCodec.decode(r.points).first;
    expect(p.x, closeTo(region.left + (c.dx - tl.dx) / (br.dx - tl.dx) * region.width, 1));
    expect(p.y, closeTo(region.top + (c.dy - tl.dy) / (br.dy - tl.dy) * region.height, 1));
    await closeApp(t);
  });

  testWidgets('görüntü dosyası yoksa ya da kart resimsizse çökmez, ileti gösterir', (t) async {
    await setup(t, writeImage: false);
    await insert(t, _card('q1', image: 'yok.png'));
    await insert(t, _card('q2'));
    await pumpSolve(t, 'q1', waitCanvas: false);
    await until(t, find.textContaining('Soru açılamadı'));
    expect(find.textContaining('Soru açılamadı'), findsOneWidget);
    expect(tester(t), isNull);
    await closeApp(t);
    await pumpSolve(t, 'q2', waitCanvas: false);
    await until(t, find.textContaining('görüntüsü yok'));
    expect(find.textContaining('görüntüsü yok'), findsOneWidget);
    await closeApp(t);
    await pumpSolve(t, 'olmayan', waitCanvas: false);
    await until(t, find.text('Soru bulunamadı.'));
    expect(find.text('Soru bulunamadı.'), findsOneWidget);
    await closeApp(t);
  });

  testWidgets('kart silinince çizgiler yumuşak silinir (fotoğraflı kart dahil)', (t) async {
    await setup(t);
    await insert(t, _card('q1', image: 'foto.png'));
    await t.runAsync(() => db.into(db.inkStrokes).insert(InkStrokesCompanion.insert(
      id: 's1',
      questionId: const Value('q1'),
      attemptNo: const Value(1),
      startedAtMs: 1000,
      points: StrokeCodec.encode(const [StrokePoint(1, 2, t: 0), StrokePoint(3, 4, t: 10)]),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    )));
    await t.runAsync(() => DriftQuestionCardRepository(db).delete('q1'));
    final rows = await allRows(t);
    expect(rows, hasLength(1)); // veri silinmez
    expect(rows.single.deleted, isTrue); // yalnız görünmez
  });

  group('girişler', () {
    Future<void> pumpTile(WidgetTester t, QuestionCard card, Size size, {bool android = true}) async {
      debugAndroidOverride = android;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final router = GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: SizedBox(width: 200, height: 260, child: QuestionTile(card: card))),
        ),
        GoRoute(path: '/soru/:id/coz', builder: (_, s) => Scaffold(body: Text('COZ ${s.uri}'))),
      ]);
      addTearDown(router.dispose);
      await t.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          mediaStorageProvider.overrideWithValue(_DirMedia(tmp)),
          pdfAvailableProvider(_docId).overrideWith((ref) async => true),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await settle(t, 200);
    }

    testWidgets('kartta kalem simgesi yalnız tablette; dokununca çözüm rotası', (t) async {
      await setup(t);
      await pumpTile(t, _card('q1', image: 'foto.png'), const Size(1280, 800));
      expect(find.byKey(const Key('tile-open-solve')), findsOneWidget);
      await t.tap(find.byKey(const Key('tile-open-solve')));
      await settle(t, 200);
      expect(find.text('COZ ${AppRoutes.questionSolve('q1')}'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));

      await pumpTile(t, _card('q1', image: 'foto.png'), const Size(400, 800));
      expect(find.byKey(const Key('tile-open-solve')), findsNothing); // telefon
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('PDF simgesinin yanında; resimsiz ve PDF bağsız kartta yok', (t) async {
      await setup(t);
      await pumpTile(t, _card('q1', image: 'foto.png', pdf: true), const Size(1280, 800));
      expect(find.byKey(const Key('tile-open-pdf')), findsOneWidget);
      expect(find.byKey(const Key('tile-open-solve')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      await pumpTile(t, _card('q2'), const Size(1280, 800));
      expect(find.byKey(const Key('tile-open-solve')), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    Future<void> pumpDetail(WidgetTester t, QuestionCard card, Size size) async {
      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => QuestionDetailScreen(cardId: card.id)),
        GoRoute(path: '/soru/:id/coz', builder: (_, s) => Scaffold(body: Text('COZ ${s.uri}'))),
      ]);
      addTearDown(router.dispose);
      await t.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          mediaStorageProvider.overrideWithValue(_DirMedia(tmp)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await settle(t, 300);
    }

    testWidgets('ayrıntı: Çiz / Çöz düğmesi telefonda çubukta, tablette ayrıca büyük; resimsizde yok', (t) async {
      await setup(t);
      await insert(t, _card('q1', image: 'foto.png'));
      await insert(t, _card('q2'));
      await pumpDetail(t, _card('q1', image: 'foto.png'), const Size(400, 900));
      expect(find.byKey(const Key('detail-solve')), findsOneWidget);
      expect(find.byKey(const Key('detail-solve-big')), findsNothing);
      await t.tap(find.byKey(const Key('detail-solve')));
      await settle(t, 200);
      expect(find.text('COZ ${AppRoutes.questionSolve('q1')}'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));

      await pumpDetail(t, _card('q1', image: 'foto.png'), const Size(1280, 800));
      expect(find.byKey(const Key('detail-solve')), findsOneWidget);
      expect(find.byKey(const Key('detail-solve-big')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));

      await pumpDetail(t, _card('q2'), const Size(1280, 800));
      expect(find.byKey(const Key('detail-solve')), findsNothing);
      expect(find.byKey(const Key('detail-solve-big')), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('çizimi olan kartta işaret: deneme sayısı ve son süre (telefonda da)', (t) async {
      await setup(t);
      await t.runAsync(() async {
        for (final (id, no, start) in [('s1', 1, 1000), ('s2', 2, 900000)]) {
          await db.into(db.inkStrokes).insert(InkStrokesCompanion.insert(
            id: id,
            questionId: const Value('q1'),
            attemptNo: Value(no),
            startedAtMs: start,
            durationMs: const Value(4000),
            points: StrokeCodec.encode(const [StrokePoint(1, 2, t: 0), StrokePoint(3, 4, t: 4000)]),
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ));
        }
      });
      await pumpTile(t, _card('q1', image: 'foto.png'), const Size(400, 800));
      expect(find.byKey(const Key('tile-solved-mark')), findsOneWidget);
      expect(find.text('2 · 4 sn'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });
  });
}

Object? tester(WidgetTester t) => t.takeException();
