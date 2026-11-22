import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
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

/// Hata atabilen sahte depo (gerçek deponun üstünde).
class _FlakyRepo extends InkStrokeRepository {
  _FlakyRepo(super.db);
  int addFailures = 0;
  int deleteFailures = 0;
  int addCalls = 0;
  @override
  Future<String> add({
    required StrokeOwner owner,
    required List<StrokePoint> points,
    required int startedAtMs,
    int layer = 0,
    int attemptNo = 0,
    String? questionId,
    String tool = 'pen',
    int color = 0xFF000000,
    double width = 1.0,
    int? durationMs,
  }) {
    addCalls++;
    if (addFailures > 0) {
      addFailures--;
      throw StateError('disk dolu');
    }
    return super.add(
      owner: owner,
      points: points,
      startedAtMs: startedAtMs,
      layer: layer,
      attemptNo: attemptNo,
      questionId: questionId,
      tool: tool,
      color: color,
      width: width,
      durationMs: durationMs,
    );
  }

  @override
  Future<int> softDeleteMany(Iterable<String> ids) {
    if (deleteFailures > 0) {
      deleteFailures--;
      throw StateError('disk dolu');
    }
    return super.softDeleteMany(ids);
  }
}

const _fast = [Duration.zero, Duration.zero];

/// Çözüm oturumu (soru + deneme) da aynı altyapıyı kullanır.
void _solveTests() {
  test('çözüm oturumu: questionId ve denemeNo ile kaydeder; serbest oturum görmez; geri al yalnız o denemeyi', () async {
    final (_, repo) = await _open();
    final s1 = PdfInkSession(documentId: _doc, repository: repo, attemptNo: 1, questionId: 'q1', retryDelays: _fast);
    final s2 = PdfInkSession(documentId: _doc, repository: repo, attemptNo: 2, questionId: 'q1', retryDelays: _fast);
    final free = PdfInkSession(documentId: _doc, repository: repo, retryDelays: _fast);
    addTearDown(s1.dispose);
    addTearDown(s2.dispose);
    addTearDown(free.dispose);
    s1.addStroke(0, const InkBrush(width: 2), _line(10, 10), _coords(1));
    s2.addStroke(0, const InkBrush(width: 2), _line(20, 20), _coords(1));
    free.addStroke(0, const InkBrush(width: 2), _line(30, 30), _coords(1));
    await Future.wait([s1.flush(), s2.flush(), free.flush()]);
    expect((await repo.forPage(PdfPageOwner(_doc, 0), questionId: 'q1', attemptNo: 2)).single.questionId, 'q1');
    expect(s1.hasStrokes, isTrue);

    final r1 = PdfInkSession(documentId: _doc, repository: repo, attemptNo: 1, questionId: 'q1');
    final rf = PdfInkSession(documentId: _doc, repository: repo);
    addTearDown(r1.dispose);
    addTearDown(rf.dispose);
    final p1 = r1.penFor(0), pf = rf.penFor(0);
    await Future.wait([r1.flush(), rf.flush()]);
    expect(p1.strokes, hasLength(1));
    expect(pf.strokes, hasLength(1)); // yalnız serbest çizgi

    await s2.undo();
    expect(await repo.forPage(PdfPageOwner(_doc, 0), questionId: 'q1', attemptNo: 2), isEmpty);
    expect(await repo.forPage(PdfPageOwner(_doc, 0), questionId: 'q1', attemptNo: 1), hasLength(1));
    await s2.redo();
    expect(await repo.forPage(PdfPageOwner(_doc, 0), questionId: 'q1', attemptNo: 2), hasLength(1));
  });

  test('startedAtMs çizginin BAŞLANGICI: bitiş saati - çizgi süresi', () async {
    final (_, repo) = await _open();
    final s = PdfInkSession(
      documentId: _doc,
      repository: repo,
      attemptNo: 1,
      questionId: 'q1',
      retryDelays: _fast,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000000),
    );
    addTearDown(s.dispose);
    s.addStroke(0, const InkBrush(width: 2), _line(10, 10), _coords(1)); // süre 32 ms
    await s.flush();
    final r = await repo.forPage(PdfPageOwner(_doc, 0), questionId: 'q1');
    expect(r.single.durationMs, 32);
    expect(r.single.startedAtMs, 1000000 - 32);
  });

  test('çözüm oturumunda kayıt hatası yeniden denenir, kayıp olmaz ve questionId korunur', () async {
    final (db, _) = await _open();
    final repo = _FlakyRepo(db)..addFailures = 5;
    final s = PdfInkSession(documentId: _doc, repository: repo, attemptNo: 3, questionId: 'q7', retryDelays: _fast);
    addTearDown(s.dispose);
    final errors = <String>[];
    s.errors.listen(errors.add);
    s.addStroke(0, const InkBrush(width: 2), _line(10, 10), _coords(1));
    await s.flush();
    await Future<void>.delayed(Duration.zero);
    expect(errors, isNotEmpty);
    expect(s.hasStrokes, isTrue); // ekranda duruyor
    await s.flush(); // 2 hata kaldı; _fast = 2 yeniden deneme (3 çağrı) -> bu turda biter
    final rows = await repo.forPage(PdfPageOwner(_doc, 0), questionId: 'q7', attemptNo: 3);
    expect(rows, hasLength(1));
  });
}

void main() {
  _solveTests();
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

  test('kayıt hatası: çizgi ekranda kalır, yeniden dener, sonunda kaydolur', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    final repo = _FlakyRepo(db)..addFailures = 2; // 3. denemede başarır
    final s = PdfInkSession(documentId: _doc, repository: repo, retryDelays: _fast);
    addTearDown(s.dispose);
    final pen = s.penFor(0);
    s.addStroke(0, const InkBrush(width: 3), _line(100, 100), _coords(2));
    await s.flush();
    expect(repo.addCalls, 3);
    expect(pen.strokes.single.id, isNotNull);
    expect(await repo.forPage(PdfPageOwner(_doc, 0)), hasLength(1));
  });

  test('kalıcı kayıt hatası: ikaz gelir, çizgi kalır, sonraki flush kaydeder', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    final repo = _FlakyRepo(db)..addFailures = 100;
    final s = PdfInkSession(documentId: _doc, repository: repo, retryDelays: _fast);
    addTearDown(s.dispose);
    final msgs = <String>[];
    s.errors.listen(msgs.add);
    final pen = s.penFor(0);
    s.addStroke(0, const InkBrush(width: 3), _line(100, 100), _coords(2));
    await s.flush();
    await Future<void>.delayed(Duration.zero);
    expect(msgs, hasLength(1));
    expect(pen.strokes, hasLength(1));
    expect(pen.strokes.single.failed, isTrue);
    expect(pen.strokes.single.id, isNull);
    repo.addFailures = 0; // disk düzeldi
    await s.flush();
    expect(pen.strokes.single.failed, isFalse);
    expect(await repo.forPage(PdfPageOwner(_doc, 0)), hasLength(1));
    expect(s.canUndo, isTrue);
    expect(msgs, hasLength(1)); // yeniden ikaz yok
  });

  test('silme kaydı kalıcı başarısız: çizgi ekrana geri konur', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    final repo = _FlakyRepo(db);
    final s = PdfInkSession(documentId: _doc, repository: repo, retryDelays: _fast);
    addTearDown(s.dispose);
    final msgs = <String>[];
    s.errors.listen(msgs.add);
    final pen = s.penFor(0);
    s.addStroke(0, const InkBrush(width: 3), _line(100, 100), _coords(2));
    await s.flush();
    repo.deleteFailures = 100;
    final hit = s.eraseAt(0, 120, 104, 10);
    expect(pen.strokes, isEmpty);
    s.commitErase(0, hit);
    await s.flush();
    await Future<void>.delayed(Duration.zero);
    expect(pen.strokes, hasLength(1));
    expect(msgs, isNotEmpty);
    expect(await repo.forPage(PdfPageOwner(_doc, 0)), hasLength(1));
  });

  test('geri al hatası: eylem yığına geri döner, sonra yeniden alınabilir', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    final repo = _FlakyRepo(db);
    final s = PdfInkSession(documentId: _doc, repository: repo, retryDelays: _fast);
    addTearDown(s.dispose);
    final pen = s.penFor(0);
    s.addStroke(0, const InkBrush(width: 3), _line(100, 100), _coords(2));
    await s.flush();
    repo.deleteFailures = 100;
    await s.undo();
    expect(s.canUndo, isTrue);
    expect(s.canRedo, isFalse);
    expect(pen.strokes, hasLength(1));
    repo.deleteFailures = 0;
    await s.undo();
    expect(s.canUndo, isFalse);
    expect(pen.strokes, isEmpty);
  });

  test('kaydı bitmemiş çizgi silinirse kayıt bitince yumuşak silinir; yükleme silinmekte olanı almaz', () async {
    final (_, repo) = await _open();
    final s = PdfInkSession(documentId: _doc, repository: repo);
    addTearDown(s.dispose);
    final pen = s.penFor(0);
    await s.flush();
    s.addStroke(0, const InkBrush(width: 3), _line(100, 100), _coords(2));
    final hit = s.eraseAt(0, 120, 104, 10); // henüz kaydı yok (id null)
    expect(hit, hasLength(1));
    s.commitErase(0, hit);
    await s.flush();
    expect(pen.strokes, isEmpty);
    expect(await repo.forPage(PdfPageOwner(_doc, 0)), isEmpty);
    // Silme artık geri alınabilir (kayıt arşivlenip yumuşak silinir; T6b2 inceleme düzeltmesi).
    expect(s.canUndo, isTrue);
    await s.undo();
    expect(await repo.forPage(PdfPageOwner(_doc, 0)), hasLength(1));
    expect(pen.strokes, hasLength(1));
  });

  test('flush sonrası kuyruk boş: sonraki flush anında biter', () async {
    final (_, repo) = await _open();
    final s = PdfInkSession(documentId: _doc, repository: repo);
    addTearDown(s.dispose);
    for (var i = 0; i < 4; i++) {
      s.addStroke(0, const InkBrush(width: 3), _line(10, 10.0 + i * 40), _coords(2));
    }
    await s.flush();
    expect(await repo.forPage(PdfPageOwner(_doc, 0)), hasLength(4));
    await s.flush();
  });
}
