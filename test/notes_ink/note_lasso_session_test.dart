import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/lasso_gesture.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/pdf/domain/page_coords.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';

const _owner = NotePageOwner('sayfa-1', 0);

PageCoords _coords() => PageCoords.tryCreate(pageWidth: 1000, pageHeight: 1000, viewWidth: 1000, viewHeight: 1000)!;

List<InkPoint> _hline(double x0, double y) => [
  for (var i = 0; i <= 30; i++) InkPoint(x: x0 + i * 10, y: y, pressure: 0.5, tMs: 1000.0 + i * 8),
];

List<InkPoint> _square(double l, double t, double r, double b) => [
  InkPoint(x: l, y: t),
  InkPoint(x: r, y: t),
  InkPoint(x: r, y: b),
  InkPoint(x: l, y: b),
];

class _Flaky extends InkStrokeRepository {
  _Flaky(super.db);
  int updateFailures = 0;
  int updateCalls = 0;

  @override
  Future<void> updatePoints(Map<String, List<StrokePoint>> byId) {
    updateCalls++;
    if (updateFailures > 0) {
      updateFailures--;
      throw StateError('disk dolu');
    }
    return super.updatePoints(byId);
  }
}

Future<(_Flaky, PdfInkSession, List<String>)> _open() async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  final repo = _Flaky(db);
  final s = PdfInkSession(
    documentId: 'sayfa-1',
    repository: repo,
    attemptNo: 0,
    retryDelays: const [Duration.zero, Duration.zero],
    ownerOf: (_) => _owner,
    penKinds: true,
  );
  addTearDown(s.dispose);
  final errors = <String>[];
  s.errors.listen(errors.add);
  s.setBrush(const InkBrush(width: 4, color: 0xFF1A56DB, kind: PenKind.fountain));
  s.penFor(0);
  await s.flush();
  return (repo, s, errors);
}

Future<List<InkStroke>> _rows(InkStrokeRepository r) => r.forPage(_owner, attemptNo: 0, layer: 0, noQuestion: true);

/// Bir çizgi çizer, kaydı bitirir ve (300 geniş) çizgiyi kementle seçer.
Future<void> _drawAndSelect(PdfInkSession s) async {
  s.addStroke(0, s.brush, _hline(100, 200), _coords());
  await s.flush();
  expect(s.selectLasso(0, _square(50, 150, 500, 250)), 1);
}

void main() {
  test('kement seçer: yalnız kayıtlı ve içeride kalan çizgiler', () async {
    final (_, s, _) = await _open();
    s.addStroke(0, s.brush, _hline(100, 200), _coords());
    s.addStroke(0, s.brush, _hline(100, 800), _coords());
    await s.flush();
    expect(s.selectLasso(0, _square(50, 150, 500, 250)), 1);
    expect(s.hasSelection, isTrue);
    final b = s.selectionBoundsSaved!;
    expect(b.left, lessThan(100));
    expect(b.right, greaterThan(399));
    // Boş alan: seçim kalkar.
    expect(s.selectLasso(0, _square(600, 600, 700, 700)), 0);
    expect(s.hasSelection, isFalse);
    // Çok küçük yol (3 noktadan az) hiçbir şey seçmez.
    expect(s.selectLasso(0, [const InkPoint(x: 1, y: 1)]), 0);
  });

  test('taşı: önizleme veritabanına yazmaz; bırakınca TEK güncelleme, aynı kimlik; geri al/yinele', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    final id = (await _rows(repo)).single.id;
    final origX = (await _rows(repo)).single.points.first.x;

    final drag = LassoDrag(LassoHandle.body, s.selectionBoundsSaved!, 200, 200);
    s.previewSelection(drag.apply(s.selectionOriginals, 260, 230));
    s.previewSelection(drag.apply(s.selectionOriginals, 300, 260));
    expect((await _rows(repo)).single.points.first.x, origX); // henüz yazılmadı
    expect(repo.updateCalls, 0);
    await s.commitSelectionTransform();

    var rows = await _rows(repo);
    expect(rows, hasLength(1)); // yeni satır yok
    expect(rows.single.id, id); // aynı kimlik
    expect(repo.updateCalls, 1); // tek işlem
    expect(rows.single.points.first.x, closeTo(origX + 100, 0.2));
    expect(rows.single.points.first.y, closeTo(260, 0.2));
    expect(rows.single.points.first.pressure, closeTo(0.5, 0.01)); // baskı korunur

    await s.undo(); // TEK geri al
    rows = await _rows(repo);
    expect(rows.single.id, id);
    expect(rows.single.points.first.x, closeTo(origX, 0.2));
    expect(s.penFor(0).strokes.single.points.first.x, closeTo(origX, 0.2));

    await s.redo();
    expect((await _rows(repo)).single.points.first.x, closeTo(origX + 100, 0.2));
    expect(s.penFor(0).strokes.single.points.first.x, closeTo(origX + 100, 0.2));
  });

  test('boyutlandır (köşe, orantılı) ve döndür; geri al özgün noktaları getirir', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    final orig = (await _rows(repo)).single.points;
    final b = s.selectionBoundsSaved!;
    final corner = LassoDrag(LassoHandle.bottomRight, b, b.right, b.bottom);
    s.previewSelection(corner.apply(s.selectionOriginals, b.left + b.width * 2, b.top + b.height * 2));
    await s.commitSelectionTransform();
    var pts = (await _rows(repo)).single.points;
    expect(pts.last.x - pts.first.x, closeTo((orig.last.x - orig.first.x) * 2, 1));

    final b2 = s.selectionBoundsSaved!;
    final rot = LassoDrag(LassoHandle.rotate, b2, b2.centerX, b2.top - 28);
    s.previewSelection(rot.apply(s.selectionOriginals, b2.centerX + 100, b2.centerY)); // +90 derece
    await s.commitSelectionTransform();
    pts = (await _rows(repo)).single.points;
    expect((pts.last.x - pts.first.x).abs(), lessThan(2)); // yatay çizgi dikey oldu
    expect((pts.last.y - pts.first.y).abs(), greaterThan(500));

    await s.undo();
    await s.undo();
    final back = (await _rows(repo)).single.points;
    expect(back.first.x, closeTo(orig.first.x, 0.2));
    expect(back.last.x, closeTo(orig.last.x, 0.2));
  });

  test('sıfır boyutlu hedef: kalınlık ve noktalar çökmez', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    final b = s.selectionBoundsSaved!;
    final d = LassoDrag(LassoHandle.right, b, b.right, b.centerY);
    s.previewSelection(d.apply(s.selectionOriginals, b.left, b.centerY)); // genişlik 0'a sürüklendi
    await s.commitSelectionTransform();
    final row = (await _rows(repo)).single;
    expect(row.width, 4);
    expect(row.points.every((p) => p.x.isFinite && p.y.isFinite), isTrue);
    expect(row.points.last.x - row.points.first.x, greaterThan(0));
  });

  test('sil: yumuşak silinir, geri al getirir', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    s.deleteSelection();
    await s.flush();
    expect(await _rows(repo), isEmpty);
    expect(s.penFor(0).strokes, isEmpty);
    expect(s.hasSelection, isFalse);
    await s.undo();
    expect(await _rows(repo), hasLength(1));
    expect(s.penFor(0).strokes, hasLength(1));
  });

  test('kopyala/yapıştır: yeni kimlikli kopya, ofsetli, seçili; tek geri al kaydı', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    final clip = s.copySelection();
    expect(clip, hasLength(1));
    await s.pasteObjects(0, clip, dx: 30, dy: 40);
    final rows = await _rows(repo);
    expect(rows, hasLength(2));
    expect(rows[0].id, isNot(rows[1].id));
    final copy = rows.firstWhere((r) => r.points.first.y > 230);
    expect(copy.points.first.y, closeTo(240, 0.2));
    expect(s.hasSelection, isTrue); // yapıştırılan seçili
    await s.undo();
    expect(await _rows(repo), hasLength(1));
  });

  test('kayıt hatası: yeniden dener; kalıcı hatada çizgiler eski yerine döner ve ikaz çıkar', () async {
    final (repo, s, errors) = await _open();
    await _drawAndSelect(s);
    final origX = (await _rows(repo)).single.points.first.x;
    final b = s.selectionBoundsSaved!;
    final drag = LassoDrag(LassoHandle.body, b, 0, 0);

    // Geçici hata: yeniden deneme başarır.
    repo.updateFailures = 1;
    s.previewSelection(drag.apply(s.selectionOriginals, 50, 0));
    await s.commitSelectionTransform();
    expect(repo.updateCalls, 2);
    expect((await _rows(repo)).single.points.first.x, closeTo(origX + 50, 0.2));
    expect(errors, isEmpty);

    // Kalıcı hata (1 + 2 yeniden deneme): geri sarılır.
    repo.updateFailures = 99;
    final d2 = LassoDrag(LassoHandle.body, s.selectionBoundsSaved!, 0, 0);
    s.previewSelection(d2.apply(s.selectionOriginals, 70, 0));
    expect(s.penFor(0).strokes.single.points.first.x, closeTo(origX + 120, 0.2)); // önizleme ekranda
    await s.commitSelectionTransform();
    await Future<void>.delayed(Duration.zero);
    expect(s.penFor(0).strokes.single.points.first.x, closeTo(origX + 50, 0.2)); // eski yerine döndü
    expect((await _rows(repo)).single.points.first.x, closeTo(origX + 50, 0.2));
    expect(errors, isNotEmpty);
    expect(s.selectionBusy, isFalse);
    // Geri al yığını yalnız başarılı taşımayı tutar.
    repo.updateFailures = 0;
    await s.undo();
    expect((await _rows(repo)).single.points.first.x, closeTo(origX, 0.2));
    await s.undo(); // sıradaki kayıt çizginin kendi eklemesi: başarısız taşıma araya girmedi
    expect(await _rows(repo), isEmpty);
  });

  test('iptal: önizleme kayıtlı konuma döner, yazım olmaz', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    final origX = s.penFor(0).strokes.single.points.first.x;
    final d = LassoDrag(LassoHandle.body, s.selectionBoundsSaved!, 0, 0);
    s.previewSelection(d.apply(s.selectionOriginals, 80, 0));
    s.cancelSelectionTransform();
    expect(s.penFor(0).strokes.single.points.first.x, origX);
    expect(repo.updateCalls, 0);
    expect(s.canUndo, isTrue); // çizginin kendi ekleme kaydı
  });

  test('hareketsiz bırakma (aynı konum) kayıt ve geri al kaydı üretmez', () async {
    final (repo, s, _) = await _open();
    await _drawAndSelect(s);
    final d = LassoDrag(LassoHandle.body, s.selectionBoundsSaved!, 0, 0);
    s.previewSelection(d.apply(s.selectionOriginals, 0, 0));
    await s.commitSelectionTransform();
    expect(repo.updateCalls, 0);
  });

  test('depo updatePoints: ya hep ya hiç (bilinmeyen kimlikte işlem geri sarılır)', () async {
    final (repo, s, _) = await _open();
    s.addStroke(0, s.brush, _hline(100, 200), _coords());
    await s.flush();
    final row = (await _rows(repo)).single;
    final moved = [for (final p in row.points) StrokePoint(p.x + 50, p.y, pressure: p.pressure, t: p.t)];
    await expectLater(repo.updatePoints({row.id: moved, 'yok': moved}), throwsStateError);
    expect((await _rows(repo)).single.points.first.x, closeTo(row.points.first.x, 1e-9)); // dokunulmadı
    await repo.updatePoints({row.id: moved});
    final after = (await _rows(repo)).single;
    expect(after.points.first.x, closeTo(row.points.first.x + 50, 0.2));
    expect(after.durationMs, row.durationMs); // süre ve başlangıç korunur
    expect(after.startedAtMs, row.startedAtMs);
  });
}
