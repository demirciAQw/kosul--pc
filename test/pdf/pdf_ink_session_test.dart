import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/pdf/domain/page_coords.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';

final _doc = 'a' * 64;

Future<(AppDatabase, InkStrokeRepository)> _open() async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return (db, InkStrokeRepository(db));
}

List<InkPoint> _line(double x0, double y0) => [
  for (var i = 0; i < 5; i++)
    InkPoint(x: x0 + i * 10, y: y0 + i * 2, pressure: 0.6, tMs: 1000.0 + i * 8),
];

PageCoords _coords(double zoom) => PageCoords.tryCreate(
  pageWidth: 612,
  pageHeight: 792,
  viewWidth: 306 * zoom,
  viewHeight: 396 * zoom,
)!;

void main() {
  test(
    'çizgi sayfa birimine çevrilip kaydedilir, yeni oturum aynı çizgiyi yükler',
    () async {
      final (_, repo) = await _open();
      final s = PdfInkSession(documentId: _doc, repository: repo);
      addTearDown(s.dispose);
      // Zum 2: görünüm 612 px geniş; görünümde (100,40) = sayfada (100,40).
      s.addStroke(
        3,
        const InkBrush(width: 4, color: 0xFF1565C0),
        _line(100, 40),
        _coords(2),
      );
      await s.flush();

      final rows = await repo.forPage(
        PdfPageOwner(_doc, 3),
        attemptNo: 1,
        layer: 0,
      );
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.points.first.x, closeTo(100, 0.06));
      expect(r.points.first.y, closeTo(40, 0.06));
      expect(r.points.last.x, closeTo(140, 0.06));
      expect(r.width, closeTo(4, 1e-9)); // zum 2: 1 px = 1 birim
      expect(r.color, 0xFF1565C0);
      expect(r.points.last.t, 32);
      expect(await repo.forPage(PdfPageOwner(_doc, 2)), isEmpty);

      final s2 = PdfInkSession(documentId: _doc, repository: repo);
      addTearDown(s2.dispose);
      final pen = s2.penFor(3);
      await s2.flush();
      expect(pen.strokes, hasLength(1));
      expect(pen.strokes.single.id, r.id);
      expect(pen.strokes.single.points.first.x, closeTo(100, 0.06));
    },
  );

  test('aynı çizgi farklı zumda çizilse sayfada aynı yere düşer', () async {
    final (_, repo) = await _open();
    final s = PdfInkSession(documentId: _doc, repository: repo);
    addTearDown(s.dispose);
    s.addStroke(0, const InkBrush(width: 3), [
      InkPoint(x: 50, y: 20, tMs: 0),
      InkPoint(x: 60, y: 30, tMs: 5),
    ], _coords(1));
    s.addStroke(1, const InkBrush(width: 3), [
      InkPoint(x: 150, y: 60, tMs: 0),
      InkPoint(x: 180, y: 90, tMs: 5),
    ], _coords(3));
    await s.flush();
    final a = (await repo.forPage(PdfPageOwner(_doc, 0))).single;
    final b = (await repo.forPage(PdfPageOwner(_doc, 1))).single;
    expect(a.points.first.x, closeTo(100, 0.06));
    expect(b.points.first.x, closeTo(100, 0.06));
    expect(b.points.first.y, closeTo(40, 0.06));
    expect(a.width, closeTo(6, 1e-9));
    expect(b.width, closeTo(2, 1e-9));
  });

  test(
    'silgi: kayıt yumuşak silinir; geri al geri getirir, yinele yine siler',
    () async {
      final (db, repo) = await _open();
      final s = PdfInkSession(documentId: _doc, repository: repo);
      addTearDown(s.dispose);
      final pen = s.penFor(0);
      s.addStroke(0, const InkBrush(width: 3), _line(100, 100), _coords(2));
      await s.flush();
      expect(pen.strokes, hasLength(1));
      expect(s.canUndo, isTrue);

      final hit = s.eraseAt(0, 120, 104, 10);
      expect(hit, hasLength(1));
      expect(pen.strokes, isEmpty);
      s.commitErase(0, hit);
      await s.flush();
      expect(await repo.forPage(PdfPageOwner(_doc, 0)), isEmpty);
      expect(
        await db.select(db.inkStrokes).get(),
        hasLength(1),
      ); // satır durur (yumuşak silme)

      await s.undo(); // silmeyi geri al
      expect(pen.strokes, hasLength(1));
      expect(await repo.forPage(PdfPageOwner(_doc, 0)), hasLength(1));
      await s.redo();
      expect(pen.strokes, isEmpty);
      expect(await repo.forPage(PdfPageOwner(_doc, 0)), isEmpty);
      await s.undo();
      await s.undo(); // çizgiyi geri al
      expect(pen.strokes, isEmpty);
      expect(s.canUndo, isFalse);
      expect(s.canRedo, isTrue);
      await s.redo();
      expect(pen.strokes, hasLength(1));
    },
  );

  test('silgi uzaktaki çizgiye dokunmaz; çizim sırasında kayıttan yeniden çözme yok', () async {
    final (_, repo) = await _open();
    final s = PdfInkSession(documentId: _doc, repository: repo);
    addTearDown(s.dispose);
    final pen = s.penFor(0);
    await s.flush();
    for (var i = 0; i < 5; i++) {
      s.addStroke(
        0,
        const InkBrush(width: 3),
        _line(100, 100 + i * 50.0),
        _coords(2),
      );
    }
    expect(pen.strokes, hasLength(5)); // kayıt beklenmeden ekranda
    expect(s.eraseAt(0, 400, 700, 5), isEmpty);
    await s.flush();
    expect(pen.strokes.map((e) => e.id).toSet(), hasLength(5));
  });

  test(
    'fosforlu araç adı ve rengi geri yüklenir; çizilebilir resim üretilir',
    () async {
      final (_, repo) = await _open();
      final s = PdfInkSession(documentId: _doc, repository: repo);
      addTearDown(s.dispose);
      s.addStroke(
        0,
        const InkBrush(tool: InkTool.highlighter, color: 0xFFF9A825, width: 16),
        _line(10, 10),
        _coords(2),
      );
      await s.flush();
      final s2 = PdfInkSession(documentId: _doc, repository: repo);
      addTearDown(s2.dispose);
      final pen = s2.penFor(0);
      await s2.flush();
      expect(pen.strokes.single.brush.tool, InkTool.highlighter);
      expect(pen.strokes.single.brush.color, 0xFFF9A825);
      final rec = PictureRecorder();
      pen.paint(Canvas(rec), 2, 2);
      rec.endRecording().dispose();
    },
  );
}
