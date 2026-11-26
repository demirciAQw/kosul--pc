import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/pdf/data/pdfrx_engine.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/solve.dart' show defaultOldOpacity, solveRegion;
import 'package:drift/drift.dart' show Value;
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/pdf_solve_page.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

import 'pdf_test_support.dart';

final _id = 'd' * 64;
const _box = PdfBox(72, 100, 400, 300);

/// Gerçek PDFium + gerçek veritabanı (Linux'ta çalışır).
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  Future<void> settle(WidgetTester t, [int ms = 500]) async {
    await t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  Future<void> open(WidgetTester t, {Future<void> Function()? seed}) async {
    final tmp = await t.runAsync(() => Directory.systemTemp.createTemp('cozum')) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    final path = '${tmp.path}/a.pdf';
    await t.runAsync(() async {
      await File(path).writeAsBytes(minimalPdf([
        [('Soru bir', 72, 700)],
      ]));
      await pdfrxInitialize();
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      await seed?.call();
    });
    addTearDown(() async {
      await t.runAsync(db.close);
    });
    t.view.physicalSize = const Size(1000, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final info = PdfOpenInfo(
      PdfDocumentRecord(id: _id, sha256: _id, title: 'Deneme', pageCount: 1, fileName: 'a.pdf'),
      path,
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          pdfEngineProvider.overrideWithValue(PdfrxEngine(initialize: pdfrxInitialize)),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(home: PdfSolveView(info: info, questionId: 'q1', page: 0, box: _box));
          },
        ),
      ),
    );
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    });
    for (var i = 0; i < 40 && find.byKey(const Key('solve-canvas')).evaluate().isEmpty; i++) {
      await settle(t, 300);
    }
  }

  /// Ekran noktası -> sayfa noktası (zum dahil: dönüşümlü kutudan oranla).
  Offset expectedPage(WidgetTester t, Offset screen) {
    final f = find.byKey(const Key('solve-canvas'));
    final tl = t.getTopLeft(f), br = t.getBottomRight(f);
    final region = solveRegion(_box, const PdfPageSize(612, 792))!;
    return Offset(
      region.left + (screen.dx - tl.dx) / (br.dx - tl.dx) * region.width,
      region.top + (screen.dy - tl.dy) / (br.dy - tl.dy) * region.height,
    );
  }

  Future<void> draw(WidgetTester t) async {
    final c = t.getCenter(find.byKey(const Key('solve-canvas')));
    final pen = await t.startGesture(c, kind: PointerDeviceKind.stylus);
    for (var i = 0; i < 6; i++) {
      await pen.moveBy(const Offset(12, 4));
    }
    await pen.up();
    await settle(t, 300);
  }

  Future<List<InkStroke>> rows(WidgetTester t, {int? attempt}) async {
    late List<InkStroke> r;
    await t.runAsync(() async {
      r = await container
          .read(inkStrokeRepositoryProvider)
          .forPage(PdfPageOwner(_id, 0), questionId: 'q1', attemptNo: attempt);
    });
    return r;
  }


  Future<void> seedDb(AppDatabase d, int attempt, int startMs) async {
    await d.into(d.inkStrokes).insert(InkStrokesCompanion.insert(
          id: 's$attempt',
          pdfDocumentId: Value(_id),
          pdfPage: Value(0),
          questionId: Value('q1'),
          attemptNo: Value(attempt),
          startedAtMs: startMs,
          durationMs: Value(2000),
          points: StrokeCodec.encode(const [StrokePoint(100, 120, t: 0), StrokePoint(200, 160, t: 2000)]),
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
  }

  testWidgets('temiz açılır; kalem çizer, çizgi soruya ve 1. denemeye kaydedilir', (t) async {
    await open(t);
    expect(find.byKey(const Key('solve-canvas')), findsOneWidget);
    expect(find.byKey(const Key('solve-layer-1')), findsOneWidget);
    expect(find.text('1. deneme · 0 sn'), findsOneWidget);
    expect(find.byKey(const Key('solve-old-1')), findsNothing);
    await draw(t);
    final r = await rows(t);
    expect(r, hasLength(1));
    expect((r.single.questionId, r.single.attemptNo), ('q1', 1));
    // Çizgi bölge koordinatından SAYFA koordinatına çevrilmiş (ekran -> bölge -> sayfa).
    final e = expectedPage(t, t.getCenter(find.byKey(const Key('solve-canvas'))));
    expect(r.single.points.first.x, closeTo(e.dx, 1));
    expect(r.single.points.first.y, closeTo(e.dy, 1));
    expect(find.byKey(const Key('note-undo')), findsOneWidget);
  });

  testWidgets('çözüm ekranında ortak araç yuvası: kalem türleri, silgi, kement, şekil, konum', (t) async {
    await open(t);
    for (final k in ['note-pen', 'note-pen-highlighter', 'note-eraser', 'note-lasso', 'note-shape', 'note-undo', 'note-redo', 'note-dock-move']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const Key('note-template')), findsNothing); // sayfa şablonu yok
    expect(find.byKey(const Key('pdf-tool-select')), findsNothing); // soru seç yalnız okuyucuda
    // Konum: sağ kenara al -> dikey sütun.
    await t.tap(find.byKey(const Key('note-dock-move')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-dock-pos-right')));
    await t.pumpAndSettle();
    final dock = t.getRect(find.byKey(const Key('note-dock')));
    expect(dock.right, greaterThan(t.view.physicalSize.width - 20));
    expect(dock.width, lessThan(90));
    // Silgi: varsayılan kısmi.
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
  });

  testWidgets('yakınlaştırılmış görünümde de çizgi doğru SAYFA koordinatına düşer', (t) async {
    await open(t);
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
    expect(big.dx, greaterThan(t.getSize(canvas).width * 1.5)); // gerçekten yakınlaştı
    // Çizim: tuvalin görünen kısmında, merkezden kaymış bir noktadan.
    final start = c + const Offset(-70, -50);
    final pen = await t.startGesture(start, kind: PointerDeviceKind.stylus);
    for (var i = 0; i < 6; i++) {
      await pen.moveBy(const Offset(12, 4));
    }
    await pen.up();
    await settle(t, 300);
    final r = await rows(t);
    expect(r, hasLength(1));
    final e = expectedPage(t, start);
    expect(r.single.points.first.x, closeTo(e.dx, 1));
    expect(r.single.points.first.y, closeTo(e.dy, 1));
  });

  testWidgets('yeniden çöz: yeni boş katman, eski çizgiler yerinde; boş denemede uyarır', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('solve-resolve')));
    await settle(t, 200);
    expect(find.text('Bu deneme zaten boş.'), findsOneWidget);
    expect(find.text('1. deneme · 0 sn'), findsOneWidget);

    await draw(t);
    await t.tap(find.byKey(const Key('solve-resolve')));
    await settle(t, 400);
    expect(find.byKey(const Key('solve-layer-2')), findsOneWidget);
    expect(find.byKey(const Key('solve-layer-1')), findsNothing); // eski gizli, temiz sayfa
    await draw(t);
    expect(await rows(t, attempt: 1), hasLength(1));
    expect(await rows(t, attempt: 2), hasLength(1));
    // Katmanlar karışmadı: 2. denemeyi geri alınca yalnız o gider.
    await t.pump(const Duration(seconds: 6)); // alttaki ileti çubuğu yuvayı örtmesin
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.byKey(const Key('note-undo')));
    await settle(t, 400);
    expect(await rows(t, attempt: 1), hasLength(1));
    expect(await rows(t, attempt: 2), isEmpty);
  });

  testWidgets('eski çözümü göster: açılıp kapanır, deneme seçilir, saydamlık kaydırıcısı çalışır', (t) async {
    await open(t, seed: () async {
      await seedDb(db, 1, 1000);
      await seedDb(db, 2, 600000);
      await seedDb(db, 3, 1200000);
    });
    // Son denemede açılır (kaybolmasın); eskiler gizli.
    expect(find.text('3. deneme · 2 sn'), findsOneWidget);
    expect(find.byKey(const Key('solve-layer-2')), findsNothing);
    await t.tap(find.byKey(const Key('solve-show-old')));
    await settle(t, 300);
    Opacity op(int n) => t.widget<Opacity>(find.descendant(of: find.byKey(Key('solve-layer-$n')), matching: find.byType(Opacity)));
    expect(op(2).opacity, defaultOldOpacity);
    expect(find.byKey(const Key('solve-layer-3')), findsOneWidget);
    expect(find.byKey(const Key('solve-old-1')), findsOneWidget);
    // Başka deneme seç.
    await t.tap(find.byKey(const Key('solve-old-1')));
    await settle(t, 300);
    expect(find.byKey(const Key('solve-layer-2')), findsNothing);
    expect(find.byKey(const Key('solve-layer-1')), findsOneWidget);
    // Saydamlık.
    await t.drag(find.byKey(const Key('solve-opacity')), const Offset(40, 0));
    await t.pump();
    expect(op(1).opacity, greaterThan(defaultOldOpacity));
    // Kapat.
    await t.tap(find.byKey(const Key('solve-show-old')));
    await settle(t, 200);
    expect(find.byKey(const Key('solve-layer-1')), findsNothing);
  });

  testWidgets('iki denemeyi üst üste bindir: iki katman, salt okunur; çizim eklenmez', (t) async {
    await open(t, seed: () async {
      await seedDb(db, 1, 1000);
      await seedDb(db, 2, 600000);
    });
    expect(find.byKey(const Key('solve-layer-1')), findsNothing);
    await t.tap(find.byKey(const Key('solve-compare')));
    await settle(t, 300);
    expect(find.byKey(const Key('solve-layer-1')), findsOneWidget);
    expect(find.byKey(const Key('solve-layer-2')), findsOneWidget);
    expect(find.byType(ColorFiltered), findsNWidgets(2)); // iki farklı renk
    final ops = t.widgetList<Opacity>(find.descendant(of: find.byKey(const Key('solve-canvas')), matching: find.byType(Opacity)));
    expect(ops.every((o) => o.opacity < 1), isTrue);
    await draw(t);
    expect(await rows(t), hasLength(2)); // yeni çizgi yok
    // Kapatınca yazılabilir katman döner.
    await t.tap(find.byKey(const Key('solve-compare')));
    await settle(t, 300);
    await draw(t);
    expect(await rows(t, attempt: 2), hasLength(2));
  });

  testWidgets('çizgisiz soruda eski çözüm ve bindirme kapalı', (t) async {
    await open(t);
    expect(t.widget<FilterChip>(find.byKey(const Key('solve-show-old'))).onSelected, isNull);
    expect(t.widget<FilterChip>(find.byKey(const Key('solve-compare'))).onSelected, isNull);
  });
}
