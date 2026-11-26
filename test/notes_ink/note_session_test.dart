import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_outline.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_object.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/pdf/domain/page_coords.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';

const _fast = [Duration.zero, Duration.zero];
const _owner = NotePageOwner('sayfa-1', 3);

PageCoords _coords() => PageCoords.tryCreate(pageWidth: 1404, pageHeight: 1984, viewWidth: 1404, viewHeight: 1984)!;

/// Yatay çizgi: (x0, y) → (x0 + 300, y), baskı verilebilir.
List<InkPoint> _hline(double x0, double y, {double pressure = 0.5}) => [
  for (var i = 0; i <= 30; i++) InkPoint(x: x0 + i * 10, y: y, pressure: pressure, tMs: 1000.0 + i * 8),
];

class _Flaky extends InkStrokeRepository {
  _Flaky(super.db);
  int replaceFailures = 0;
  int addFailures = 0;
  int addCalls = 0;

  @override
  Future<({List<String> added, List<String> archived})> replaceDetailed({
    required Iterable<String> deleteIds,
    required List<NewStroke> adds,
    List<NewStroke> archive = const [],
  }) {
    if (replaceFailures > 0) {
      replaceFailures--;
      throw StateError('disk dolu');
    }
    return super.replaceDetailed(deleteIds: deleteIds, adds: adds, archive: archive);
  }

  @override
  Future<String> add({
    required StrokeOwner owner,
    required List<StrokePoint> points,
    required int startedAtMs,
    int layer = 0,
    int attemptNo = 0,
    String? questionId,
    String? tag,
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
      tag: tag,
      tool: tool,
      color: color,
      width: width,
      durationMs: durationMs,
    );
  }
}

Future<(_Flaky, PdfInkSession)> _open() async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  final repo = _Flaky(db);
  final s = PdfInkSession(
    documentId: 'sayfa-1',
    repository: repo,
    attemptNo: 0,
    retryDelays: _fast,
    ownerOf: (_) => _owner,
    penKinds: true,
  );
  addTearDown(s.dispose);
  s.setBrush(const InkBrush(width: 4, color: 0xFF1A56DB, kind: PenKind.fountain));
  return (repo, s);
}

Future<List<InkStroke>> _rows(InkStrokeRepository r) => r.forPage(_owner, attemptNo: 0, layer: 0, noQuestion: true);

void main() {
  test('defter oturumu NotePageOwner ile yazar; kalem türü saklanır ve geri okunur', () async {
    final (repo, s) = await _open();
    s.addStroke(0, s.brush, _hline(100, 200), _coords());
    await s.flush();
    final rows = await _rows(repo);
    expect(rows, hasLength(1));
    final o = rows.single.owner as NotePageOwner;
    expect((o.noteId, o.page), ('sayfa-1', 3));
    expect(rows.single.tool, 'fountain');
    expect(rows.single.width, closeTo(4, 1e-9)); // 4 görünüm px × 1 sayfa birimi/px
    // Yeni oturum aynı çizgiyi kalem türüyle okur.
    final s2 = PdfInkSession(
      documentId: 'sayfa-1',
      repository: repo,
      attemptNo: 0,
      ownerOf: (_) => _owner,
      penKinds: true,
    );
    addTearDown(s2.dispose);
    final pen = s2.penFor(0);
    await s2.flush();
    expect(pen.strokes.single.brush.kind, PenKind.fountain);
    expect(pen.strokes.single.brush.tool, InkTool.pen);
  });

  test('sertlik ayarı: aynı ham baskı farklı biçimlenir; kalem türü yoksa aynen', () async {
    final (_, s) = await _open();
    s.setHardness(0.0);
    final soft = s.shapePressure(0.5);
    s.setHardness(1.0);
    final hard = s.shapePressure(0.5);
    expect(soft, greaterThan(hard));
    s.setBrush(const InkBrush(tool: InkTool.highlighter, kind: PenKind.highlighter, width: 16));
    expect(s.shapePressure(0.5), 0.5); // fosforlu baskıya duyarsız
    s.setBrush(const InkBrush());
    expect(s.shapePressure(0.5), 0.5);
  });

  test('çizgi kalınlığı pen_profiles ile uyumlu: dolma kalem baskıyla belirgin değişir, tükenmez az', () {
    double thickness(PenKind k, double p) {
      final pts = [
        for (var i = 0; i <= 20; i++) InkPoint(x: i * 5.0, y: 50, pressure: p, tMs: i * 8.0),
      ];
      final b = InkBrush(color: 0xFF000000, width: 10, kind: k);
      return inkOutlinePath(pts, b, complete: true).getBounds().height;
    }

    final fountain = thickness(PenKind.fountain, 1) / thickness(PenKind.fountain, 0);
    final ball = thickness(PenKind.ballpoint, 1) / thickness(PenKind.ballpoint, 0);
    expect(fountain, greaterThan(2.5)); // 1,6 / 0,4 = 4
    expect(ball, lessThan(1.6)); // 1,15 / 0,85 = 1,35
    expect(fountain, greaterThan(ball));
    final hl = penProfiles[PenKind.highlighter]!;
    expect(inkPaintFor(const InkBrush(color: 0xFFFFEB3B, width: 16, kind: PenKind.highlighter)).blendMode,
        BlendMode.multiply);
    expect(inkPaintFor(const InkBrush(color: 0xFFFFEB3B, width: 16, kind: PenKind.highlighter)).color.a,
        closeTo(hl.opacity, 0.01));
    expect(inkPaintFor(const InkBrush(color: 0xFF000000, kind: PenKind.ballpoint)).blendMode, BlendMode.srcOver);
  });

  test('kayıt hatası yeniden denenir, kalıcı hatada çizgi ekranda kalır ve sonra kaydolur', () async {
    final (repo, s) = await _open();
    repo.addFailures = 2;
    s.addStroke(0, s.brush, _hline(100, 200), _coords());
    await s.flush();
    expect(repo.addCalls, 3);
    expect(await _rows(repo), hasLength(1));

    final msgs = <String>[];
    s.errors.listen(msgs.add);
    repo.addFailures = 100;
    final pen = s.penFor(0);
    s.addStroke(0, s.brush, _hline(100, 400), _coords());
    await s.flush();
    await Future<void>.delayed(Duration.zero);
    expect(msgs, hasLength(1));
    expect(pen.strokes, hasLength(2)); // ekranda duruyor
    expect(await _rows(repo), hasLength(1));
    repo.addFailures = 0;
    await s.flush();
    expect(await _rows(repo), hasLength(2));
  });

  test('baskı ham saklanır, sertlik çizgiyle yazılır; sabit baskı ve eski kayıt olduğu gibi', () async {
    final (repo, s) = await _open();
    s.setHardness(1.0);
    // Canlı çizim biçimlenmiş baskı taşır (sertlik 1: p^2).
    final raws = [0.2, 0.5, 0.8, 0.9];
    final live = [
      for (var i = 0; i < raws.length; i++)
        InkPoint(x: 100.0 + i * 20, y: 300, pressure: s.shapePressure(raws[i]), tMs: 1000.0 + i * 8),
    ];
    s.addStroke(0, s.brush, live, _coords());
    // Sabit baskı (fare/parmak): sertlikle eğilmez, hiç biçimlenmemiş yazılır.
    s.addStroke(0, s.brush, _hline(100, 500), _coords());
    await s.flush();
    // Sıra başlangıç zamanına göre; araç adından seç.
    final all = await _rows(repo);
    final rows = [all.firstWhere((r) => r.tool.contains(':')), all.firstWhere((r) => !r.tool.contains(':'))];
    expect(rows[0].tool, 'fountain:1.00');
    expect([for (final p in rows[0].points) p.pressure], [for (final r in raws) closeTo(r, 0.002)]);
    expect(rows[1].tool, 'fountain');
    expect(rows[1].points.every((p) => (p.pressure - 0.5).abs() < 0.002), isTrue);
    // Yeniden açılınca sertlik fırçada; çizimde uygulanır (ham baskıdan aynı biçim).
    final s2 = PdfInkSession(
      documentId: 'sayfa-1',
      repository: repo,
      attemptNo: 0,
      ownerOf: (_) => _owner,
      penKinds: true,
    );
    addTearDown(s2.dispose);
    final pen = s2.penFor(0);
    await s2.flush();
    final hs = pen.strokes.firstWhere((x) => x.brush.hardness != null);
    expect(hs.brush.hardness, 1.0);
    expect(pen.strokes.where((x) => x.brush.hardness == null), hasLength(1));
    final soft = inkOutlinePath(hs.points, hs.brush.copyWith(hardness: 0.0), complete: true);
    final hard = inkOutlinePath(hs.points, hs.brush, complete: true);
    expect(soft.getBounds(), isNot(hard.getBounds()));
    // Sertlik 0,5 eğriyi değiştirmez: ham baskıyla aynı yol.
    final mid = inkOutlinePath(hs.points, hs.brush.copyWith(hardness: 0.5), complete: true);
    final none = inkOutlinePath(hs.points, hs.brush.copyWith(hardness: null), complete: true);
    expect(mid.getBounds(), none.getBounds());
  });

  test('fırça: copyWith kind/hardness null yapabilir; tool sütunu gidiş dönüş', () {
    const b = InkBrush(kind: PenKind.pencil, hardness: 0.3);
    expect(b.copyWith(kind: null).kind, isNull);
    expect(b.copyWith(hardness: null).hardness, isNull);
    expect(b.copyWith(width: 9).kind, PenKind.pencil);
    expect(b.copyWith(width: 9).hardness, 0.3);
    expect(toolColumnOf(b), 'pencil:0.30');
    expect(toolColumnOf(b.copyWith(hardness: null)), 'pencil');
    expect(parseToolColumn('pencil:0.30'), (name: 'pencil', hardness: 0.3));
    expect(parseToolColumn('pencil'), (name: 'pencil', hardness: null));
  });

  test('InkObject.halfWidth dolma kalemin en kalın payını sayar', () {
    const w = 4.0;
    expect(const InkObject(id: 'a', points: [], brush: InkBrush(width: w)).halfWidth, 2.0);
    expect(const InkObject(id: 'a', points: [], brush: InkBrush(width: w, kind: PenKind.fountain)).halfWidth, closeTo(3.2, 1e-9));
    expect(const InkObject(id: 'a', points: [], brush: InkBrush(width: w, kind: PenKind.highlighter)).halfWidth, 2.0);
  });

  group('alan silgisi', () {
    test('hareket başına TEK kayıt: özgün yumuşak silinir, parçalar eklenir; geri al/yinele', () async {
      final (repo, s) = await _open();
      s.addStroke(0, s.brush, _hline(100, 200), _coords());
      await s.flush();
      final originalId = (await _rows(repo)).single.id;
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      // Hareket: iki ayrı noktada sil (aynı hareket) → iki boşluk, üç parça.
      final a = s.eraseAt(0, 180, 200, 6);
      final b = s.eraseAt(0, 350, 200, 6);
      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
      expect(s.penFor(0).strokes, hasLength(3));
      s.commitErase(0, [...a, ...b]);
      s.setErasing(false);
      await s.flush();
      var rows = await _rows(repo);
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.id), isNot(contains(originalId)));
      expect(rows.every((r) => r.tool == 'fountain' && r.width == 4), isTrue);
      // Özgün köşeler korunur: parça uçları dışında tüm noktalar özgün x'lerden.
      // Silgi payı = yarıçap 6 + dolma kalem en kalın yarı genişlik (4 * 1,6 / 2 = 3,2) = 9,2:
      // kesim uçları tam 180 ± 9,2 ve 350 ± 9,2 olmalı; geri kalan tüm x özgün 10'luk ızgarada.
      final xs = {for (final r in rows) ...r.points.map((p) => p.x)};
      final cuts = xs.where((x) => x % 10 != 0).toList()..sort();
      expect(cuts, hasLength(4));
      for (final (i, expected) in [170.8, 189.2, 340.8, 359.2].indexed) {
        expect(cuts[i], closeTo(expected, 0.1));
      }
      // TEK kayıt: bir geri al hepsini eski haline getirir.
      expect(s.canUndo, isTrue);
      await s.undo();
      rows = await _rows(repo);
      expect(rows.map((r) => r.id), [originalId]);
      expect(s.penFor(0).strokes, hasLength(1));
      await s.redo();
      rows = await _rows(repo);
      expect(rows, hasLength(3));
      expect(s.penFor(0).strokes, hasLength(3));
      await s.undo();
      expect(s.canUndo, isTrue); // yığında yalnız ilk çizimin 'eklendi' kaydı kaldı
      await s.undo();
      expect(s.canUndo, isFalse);
      expect(await _rows(repo), isEmpty);
    }, skip: false);

    test('silgi değmezse kayıt oluşmaz', () async {
      final (repo, s) = await _open();
      s.addStroke(0, s.brush, _hline(100, 200), _coords());
      await s.flush();
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      final hit = s.eraseAt(0, 500, 900, 6);
      expect(hit, isEmpty);
      s.commitErase(0, hit);
      s.setErasing(false);
      await s.flush();
      expect(await _rows(repo), hasLength(1));
    });

    test('hareketin kendi parçası yeniden silinirse ara parça kaydedilmez', () async {
      final (repo, s) = await _open();
      s.addStroke(0, s.brush, _hline(100, 200), _coords());
      await s.flush();
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      // Ortadan kes, sonra sağ parçayı da tamamen kaz.
      s.eraseAt(0, 300, 200, 6);
      s.eraseAt(0, 340, 200, 60, prevX: 300, prevY: 200); // sağ parça tamamen, sol parçanın ucu gider
      s.commitErase(0, const []);
      s.setErasing(false);
      await s.flush();
      final rows = await _rows(repo);
      expect(rows, hasLength(1)); // yalnız kalan sol parça; ara/sağ parça hiç yazılmadı
      expect(repo.addCalls, 2); // özgün + sol parça
      // Kayıtlı çizgi silgi alanına (x >= 340 - 60 - 3,2) girmez ve soldan başlar.
      expect(rows.single.points.first.x, closeTo(100, 0.1));
      expect(rows.single.points.every((p) => p.x < 280), isTrue);
    });

    test('kayıt kalıcı başarısız: özgün çizgi geri konur, hiçbir şey yazılmaz, ikaz gelir', () async {
      final (repo, s) = await _open();
      s.addStroke(0, s.brush, _hline(100, 200), _coords());
      await s.flush();
      final originalId = (await _rows(repo)).single.id;
      final msgs = <String>[];
      s.errors.listen(msgs.add);
      repo.replaceFailures = 100;
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      final hit = s.eraseAt(0, 300, 200, 6);
      s.commitErase(0, hit);
      s.setErasing(false);
      await s.flush();
      await Future<void>.delayed(Duration.zero);
      expect(msgs, isNotEmpty);
      final pen = s.penFor(0);
      expect(pen.strokes, hasLength(1));
      expect(pen.strokes.single.erased, isFalse);
      expect((await _rows(repo)).map((r) => r.id), [originalId]);
      // Geri al yığınına yalnız ilk çizim girmiştir.
      expect(s.canUndo, isTrue);
    });

    test('kaydı bitmemiş çizgi alan silgisiyle kesilirse özgün kaydolmaz, yalnız parçalar', () async {
      final (repo, s) = await _open();
      s.addStroke(0, s.brush, _hline(100, 200), _coords()); // kayıt kuyrukta
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      final hit = s.eraseAt(0, 300, 200, 6);
      expect(hit, isNotEmpty);
      s.commitErase(0, hit);
      s.setErasing(false);
      await s.flush();
      var rows = await _rows(repo);
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.points.every((p) => (p.x - 300).abs() > 3)), isTrue);
      // Geri al: özgün çizgi TAMAMEN geri gelir (kimliği kayda girmişti), parçalar gider.
      expect(s.canUndo, isTrue);
      await s.undo();
      rows = await _rows(repo);
      expect(rows, hasLength(1));
      expect(rows.single.points, hasLength(31));
      expect(s.penFor(0).strokes, hasLength(1));
      await s.redo();
      expect(await _rows(repo), hasLength(2));
    });

    test('kaydı bekleyen çizgi kesilir, silme kalıcı başarısız: çizgi kaybolmaz, yeniden kaydolur', () async {
      final (repo, s) = await _open();
      final msgs = <String>[];
      s.errors.listen(msgs.add);
      repo.replaceFailures = 100;
      s.addStroke(0, s.brush, _hline(100, 200), _coords()); // kayıt kuyrukta
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      final hit = s.eraseAt(0, 300, 200, 6);
      expect(hit, isNotEmpty);
      s.commitErase(0, hit);
      s.setErasing(false);
      await s.flush();
      await Future<void>.delayed(Duration.zero);
      expect(msgs, isNotEmpty);
      final pen = s.penFor(0);
      expect(pen.strokes, hasLength(1));
      expect(pen.strokes.single.erased, isFalse);
      expect(pen.strokes.single.points, hasLength(31)); // bütün çizgi ekranda
      final rows = await _rows(repo);
      expect(rows, hasLength(1)); // ... ve veritabanında
      expect(rows.single.points, hasLength(31));
      expect(pen.strokes.single.id, rows.single.id);
    });

    test('kaydı bekleyen çizgi kesilir, silme VE kayıt başarısız: çizgi başarısızlar listesine girer, sonra kaydolur', () async {
      final (repo, s) = await _open();
      repo.replaceFailures = 100;
      repo.addFailures = 100;
      s.addStroke(0, s.brush, _hline(100, 200), _coords());
      s.setEraseMode(EraseMode.area);
      s.setErasing(true);
      s.commitErase(0, s.eraseAt(0, 300, 200, 6));
      s.setErasing(false);
      await s.flush();
      expect(s.penFor(0).strokes, hasLength(1));
      expect(await _rows(repo), isEmpty);
      repo.addFailures = 0;
      repo.replaceFailures = 0;
      await s.flush(); // yeniden deneme: çizgi yazılır (silme bayrağı kalktı)
      expect(await _rows(repo), hasLength(1));
    });

    test('radius NaN/negatif: silgi yok sayılır, çizgi değişmez', () async {
      final (repo, s) = await _open();
      s.addStroke(0, s.brush, _hline(100, 200), _coords());
      await s.flush();
      s.setEraseMode(EraseMode.area);
      expect(s.eraseAt(0, 300, 200, double.nan), isEmpty);
      expect(s.eraseAt(0, 300, 200, -1), isEmpty);
      expect(s.eraseAt(0, double.infinity, 200, 5), isEmpty);
      expect(s.penFor(0).strokes, hasLength(1));
      expect(await _rows(repo), hasLength(1));
    });
  });

  test('çizgi silgisi modu: hareket başına tek kayıt, geri al getirir', () async {
    final (repo, s) = await _open();
    s.addStroke(0, s.brush, _hline(100, 200), _coords());
    s.addStroke(0, s.brush, _hline(100, 220), _coords());
    await s.flush();
    s.setEraseMode(EraseMode.stroke);
    s.setErasing(true);
    final hit = [...s.eraseAt(0, 200, 200, 8), ...s.eraseAt(0, 200, 220, 8, prevX: 200, prevY: 200)];
    s.commitErase(0, hit);
    s.setErasing(false);
    await s.flush();
    expect(await _rows(repo), isEmpty);
    await s.undo();
    expect(await _rows(repo), hasLength(2));
  });
}
