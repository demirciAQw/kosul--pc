import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_input.dart';
import 'package:kocum/features/pdf/presentation/pdf_page_ink_layer.dart';

final _doc = 'b' * 64;

/// Dikey kaydıran bir liste (pdfrx görünümünün yerine): sayfa katmanı 400x600
/// (sayfa 612x792 → ölçek 0,654). Kaydırma konumunu görmek için ScrollController.
Future<(PdfInkSession, InkStrokeRepository, ScrollController)> _host(
  WidgetTester t,
) async {
  late AppDatabase db;
  late InkStrokeRepository repo;
  await t.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = InkStrokeRepository(db);
  });
  addTearDown(() => t.runAsync(db.close));
  final session = PdfInkSession(documentId: _doc, repository: repo);
  addTearDown(session.dispose);
  final sc = ScrollController();
  addTearDown(sc.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PdfInkInput(
          session: session,
          stylusOnlyOverride: true,
          // pdfrx'in panEnabled'ı gibi: kilitliyken görünüm kaymaz.
          child: ValueListenableBuilder<bool>(
            valueListenable: session.viewerLocked,
            builder: (_, locked, _) => ListView(
            controller: sc,
            physics: locked ? const NeverScrollableScrollPhysics() : null,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 600,
                  child: PdfPageInkLayer(
                    session: session,
                    page: 0,
                    pageWidth: 612,
                    pageHeight: 792,
                  ),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
          ),
        ),
      ),
    ),
  );
  return (session, repo, sc);
}

Future<void> _drag(
  WidgetTester t,
  Offset from,
  PointerDeviceKind kind, {
  Offset by = const Offset(0, -120),
}) async {
  final g = await t.startGesture(from, kind: kind);
  for (var i = 0; i < 6; i++) {
    await g.moveBy(by / 6);
  }
  await g.up();
  await t.pump();
}

Future<List<InkStroke>> _saved(
  WidgetTester t,
  PdfInkSession s,
  InkStrokeRepository repo,
) async {
  late List<InkStroke> rows;
  await t.runAsync(() async {
    await s.flush();
    rows = await repo.forPage(PdfPageOwner(_doc, 0), attemptNo: 1, layer: 0);
  });
  return rows;
}

void main() {
  testWidgets(
    'kalem çizer ve kaydeder; görünüm kaymaz; sayfa koordinatına çevrilir',
    (t) async {
      final (s, repo, sc) = await _host(t);
      await _drag(
        t,
        const Offset(100, 300),
        PointerDeviceKind.stylus,
        by: const Offset(0, -120),
      );
      expect(sc.offset, 0);
      final rows = await _saved(t, s, repo);
      expect(rows, hasLength(1));
      // Görünüm (100,300)-ish → sayfa: x * 612/400. (Başlangıç noktası dokunuş yeridir.)
      final p = rows.single.points;
      expect(p.first.x, closeTo(100 * 612 / 400, 0.1));
      expect(p.first.y, closeTo(300 * 792 / 600, 0.1));
      expect(p.last.y, lessThan(p.first.y));
      expect(rows.single.attemptNo, 1);
      expect(rows.single.layer, 0);
      expect(s.penActive, isFalse);
    },
  );

  testWidgets('parmak çizmez, görünümü kaydırır', (t) async {
    final (s, repo, sc) = await _host(t);
    await _drag(t, const Offset(100, 300), PointerDeviceKind.touch);
    await t.pumpAndSettle();
    expect(sc.offset, greaterThan(50));
    expect(await _saved(t, s, repo), isEmpty);
  });

  testWidgets(
    'kalem çizerken ikinci temas (avuç) görünümü kaydırmaz, çizgiyi bozmaz',
    (t) async {
      final (s, repo, sc) = await _host(t);
      final pen = await t.startGesture(
        const Offset(100, 300),
        kind: PointerDeviceKind.stylus,
      );
      expect(s.penActive, isTrue);
      final palm = await t.startGesture(
        const Offset(300, 450),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 6; i++) {
        await palm.moveBy(const Offset(0, -30));
        await pen.moveBy(const Offset(8, 0));
      }
      await palm.up();
      await pen.up();
      await t.pumpAndSettle();
      expect(sc.offset, 0);
      final rows = await _saved(t, s, repo);
      expect(rows, hasLength(1));
      expect(rows.single.points.length, greaterThan(3));
      expect(s.penActive, isFalse);
      // Kalem kalktıktan sonra parmak yine kaydırır.
      await _drag(t, const Offset(100, 300), PointerDeviceKind.touch);
      await t.pumpAndSettle();
      expect(sc.offset, greaterThan(50));
    },
  );

  testWidgets(
    'önce avuç sonra kalem: avuç kalem inince kaydırmayı bırakır, çizgi bozulmaz',
    (t) async {
      final (s, repo, sc) = await _host(t);
      // Avuç kalemden ÖNCE değer ve görünüm onu izlemeye başlar.
      final palm = await t.startGesture(
        const Offset(300, 450),
        kind: PointerDeviceKind.touch,
      );
      await palm.moveBy(const Offset(0, -20));
      await t.pump();
      final before = sc.offset;
      final pen = await t.startGesture(
        const Offset(100, 300),
        kind: PointerDeviceKind.stylus,
      );
      expect(s.viewerLocked.value, isTrue);
      for (var i = 0; i < 6; i++) {
        await palm.moveBy(const Offset(0, -30));
        await pen.moveBy(const Offset(8, 0));
      }
      await palm.up();
      await pen.up();
      await t.pumpAndSettle();
      expect(sc.offset, before); // sayfa kalemle birlikte kaymadı
      expect((await _saved(t, s, repo)), hasLength(1));
      expect(s.viewerLocked.value, isFalse);
    },
  );

  testWidgets('kalem havada sayfaya yaklaşınca önceki avuç da kilitlenir', (t) async {
    final (s, _, sc) = await _host(t);
    final palm = await t.startGesture(
      const Offset(300, 450),
      kind: PointerDeviceKind.touch,
    );
    await palm.moveBy(const Offset(0, -20));
    await t.pump();
    final before = sc.offset;
    final hover = await t.createGesture(kind: PointerDeviceKind.stylus);
    await hover.addPointer(location: const Offset(100, 300));
    await hover.moveTo(const Offset(110, 300));
    expect(s.viewerLocked.value, isTrue);
    await t.pump(); // kilit bir sonraki karede görünüme ulaşır
    await palm.moveBy(const Offset(0, -60));
    await palm.up();
    await t.pumpAndSettle();
    expect(sc.offset, before);
    await hover.removePointer();
    await t.pump(const Duration(seconds: 1)); // havada tutma süresi dolar
    expect(s.viewerLocked.value, isFalse);
  });

  testWidgets('büyük temas (avuç) baştan yutulur, görünümü kaydırmaz', (t) async {
    final (_, _, sc) = await _host(t);
    final p = TestPointer(77, PointerDeviceKind.touch);
    final b = GestureBinding.instance;
    b.handlePointerEvent(PointerDownEvent(
      pointer: 77, position: const Offset(300, 450), radiusMajor: 60,
    ));
    for (var i = 1; i <= 6; i++) {
      b.handlePointerEvent(PointerMoveEvent(
        pointer: 77, position: Offset(300, 450 - i * 20.0),
        delta: const Offset(0, -20), radiusMajor: 60,
      ));
    }
    b.handlePointerEvent(PointerUpEvent(pointer: 77, position: const Offset(300, 330)));
    expect(p.pointer, 77);
    await t.pumpAndSettle();
    expect(sc.offset, 0);
  });

  testWidgets('kalem sayfa dışındayken (boşluk) kilit yok, çizmez', (t) async {
    final (s, repo, _) = await _host(t);
    // Katman 400x600; (500, 300) sayfa dışı.
    final hover = await t.createGesture(kind: PointerDeviceKind.stylus);
    await hover.addPointer(location: const Offset(500, 300));
    await hover.moveTo(const Offset(510, 300));
    expect(s.viewerLocked.value, isFalse);
    await _drag(t, const Offset(500, 300), PointerDeviceKind.stylus);
    expect(await _saved(t, s, repo), isEmpty);
    await hover.removePointer();
  });

  testWidgets('silgi sürerken geri al/yinele kapalı', (t) async {
    final (s, repo, _) = await _host(t);
    await _drag(t, const Offset(100, 300), PointerDeviceKind.stylus,
        by: const Offset(120, 0));
    await _saved(t, s, repo);
    expect(s.canUndo, isTrue);
    s.setBrush(const InkBrush(tool: InkTool.eraser, width: 6));
    final g = await t.startGesture(const Offset(160, 300),
        kind: PointerDeviceKind.stylus);
    await g.moveBy(const Offset(0, 5));
    expect(s.erasing, isTrue);
    unawaited(s.undo()); // yutulur
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 150)));
    expect(s.canRedo, isFalse); // geri alma çalışsaydı yinele dolardı
    expect(s.canUndo, isTrue);
    await g.up();
    await t.pump();
    expect(s.erasing, isFalse);
    await _saved(t, s, repo);
  });

  testWidgets('sayfa katmanı kalkınca önbellek boşalır', (t) async {
    final (s, _, _) = await _host(t);
    expect(s.cachedPages, 1);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(s.cachedPages, 0);
  });

  testWidgets('silgi aracı çizgiyi siler ve kayıtta yumuşak siler', (t) async {
    final (s, repo, _) = await _host(t);
    await _drag(
      t,
      const Offset(100, 300),
      PointerDeviceKind.stylus,
      by: const Offset(120, 0),
    );
    expect(await _saved(t, s, repo), hasLength(1));
    s.setBrush(const InkBrush(tool: InkTool.eraser, width: 6));
    await _drag(
      t,
      const Offset(160, 310),
      PointerDeviceKind.stylus,
      by: const Offset(0, -30),
    );
    expect(await _saved(t, s, repo), isEmpty);
    expect(s.canUndo, isTrue);
    await t.runAsync(s.undo);
    expect(await _saved(t, s, repo), hasLength(1));
  });

  testWidgets(
    'yakınlaştırılmış (büyük) katmanda aynı sayfa noktası aynı kalır',
    (t) async {
      late AppDatabase db;
      late InkStrokeRepository repo;
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
        repo = InkStrokeRepository(db);
      });
      addTearDown(() => t.runAsync(db.close));
      final s = PdfInkSession(documentId: _doc, repository: repo);
      addTearDown(s.dispose);
      // Zum 3: katman 1224x1584 (sayfa 612x792 → 2 piksel/birim).
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfInkInput(
              session: s,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                maxWidth: 1224,
                maxHeight: 1584,
                child: SizedBox(
                  width: 1224,
                  height: 1584,
                  child: PdfPageInkLayer(
                    session: s,
                    page: 0,
                    pageWidth: 612,
                    pageHeight: 792,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _drag(
        t,
        const Offset(200, 400),
        PointerDeviceKind.stylus,
        by: const Offset(100, 0),
      );
      late List<InkStroke> rows;
      await t.runAsync(() async {
        await s.flush();
        rows = await repo.forPage(PdfPageOwner(_doc, 0));
      });
      expect(rows.single.points.first.x, closeTo(100, 0.1));
      expect(rows.single.points.first.y, closeTo(200, 0.1));
    },
  );
}
