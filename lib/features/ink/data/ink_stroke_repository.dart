import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/ink_stroke_record.dart';
import '../domain/stroke_codec.dart';

/// Çizgi deposu (T2). Silme yumuşaktır: satır kalır, `deleted` işaretlenir.
class InkStrokeRepository {
  InkStrokeRepository(this._db, {IdGenerator ids = const UuidV7Generator(), DateTime Function()? clock})
      : _ids = ids,
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  /// Çizgiyi ekler, kimliğini döner. Süre verilmezse noktalardan hesaplanır.
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
  }) async {
    final id = _ids.next();
    final now = _clock();
    await _db.into(_db.inkStrokes).insert(InkStrokesCompanion.insert(
          id: id,
          pdfDocumentId: Value(owner is PdfPageOwner ? owner.documentId : null),
          pdfPage: Value(owner is PdfPageOwner ? owner.page : null),
          noteId: Value(owner is NotePageOwner ? owner.noteId : null),
          notePage: Value(owner is NotePageOwner ? owner.page : null),
          layer: Value(layer),
          attemptNo: Value(attemptNo),
          questionId: Value(questionId),
          tool: Value(tool),
          color: Value(color),
          width: Value(width),
          startedAtMs: startedAtMs,
          durationMs: Value(durationMs ?? StrokeCodec.durationOf(points)),
          points: StrokeCodec.encode(points),
          pointCount: Value(points.length),
          createdAt: now,
          updatedAt: now,
        ));
    return id;
  }

  /// Alan silgisi: [deleteIds] yumuşak silinir, [adds] eklenir; TEK işlemde (ya hep ya hiç,
  /// bu yüzden yeniden deneme güvenli). Eklenenlerin kimlikleri sırayla döner.
  Future<List<String>> replace({required Iterable<String> deleteIds, required List<NewStroke> adds}) =>
      _db.transaction(() async {
        final ids = <String>[];
        for (final a in adds) {
          ids.add(await add(
            owner: a.owner,
            points: a.points,
            startedAtMs: a.startedAtMs,
            layer: a.layer,
            attemptNo: a.attemptNo,
            questionId: a.questionId,
            tool: a.tool,
            color: a.color,
            width: a.width,
          ));
        }
        await softDeleteMany(deleteIds);
        return ids;
      });

  /// Geri al / yinele: [deleteIds] yumuşak silinir, [restoreIds] geri gelir; tek işlem.
  Future<void> swap({required Iterable<String> deleteIds, required Iterable<String> restoreIds}) =>
      _db.transaction(() async {
        await softDeleteMany(deleteIds);
        for (final id in restoreIds) {
          await restore(id);
        }
      });

  SimpleSelectStatement<$InkStrokesTable, InkStrokeRow> _query(StrokeOwner owner,
      {int? attemptNo, int? layer, String? questionId, bool noQuestion = false}) {
    return _db.select(_db.inkStrokes)
      ..where((s) {
        Expression<bool> w = s.deleted.equals(false);
        w = w &
            switch (owner) {
              PdfPageOwner o => s.pdfDocumentId.equals(o.documentId) & s.pdfPage.equals(o.page),
              NotePageOwner o => s.noteId.equals(o.noteId) & s.notePage.equals(o.page),
            };
        if (attemptNo != null) w = w & s.attemptNo.equals(attemptNo);
        if (layer != null) w = w & s.layer.equals(layer);
        if (questionId != null) w = w & s.questionId.equals(questionId);
        if (noQuestion) w = w & s.questionId.isNull();
        return w;
      })
      ..orderBy([(s) => OrderingTerm.asc(s.startedAtMs), (s) => OrderingTerm.asc(s.id)]);
  }

  /// Sayfadaki (silinmemiş) çizgiler, çizim sırasıyla.
  ///
  /// [questionId]: yalnızca o sorunun çözüm çizgileri; [noQuestion]: yalnızca
  /// bir soruya bağlı OLMAYAN çizgiler (okuyucunun serbest çizgileri).
  Future<List<InkStroke>> forPage(StrokeOwner owner,
          {int? attemptNo, int? layer, String? questionId, bool noQuestion = false}) async =>
      _decodeAll(await _query(owner, attemptNo: attemptNo, layer: layer, questionId: questionId, noQuestion: noQuestion)
          .get());

  Stream<List<InkStroke>> watchPage(StrokeOwner owner,
          {int? attemptNo, int? layer, String? questionId, bool noQuestion = false}) =>
      _query(owner, attemptNo: attemptNo, layer: layer, questionId: questionId, noQuestion: noQuestion)
          .watch()
          .map(_decodeAll);

  /// Sorunun (silinmemiş) çizgi zamanları, tüm denemeler; noktalar çözülmez.
  Stream<List<StrokeTime>> watchSolveTimes(String questionId) {
    final q = _db.selectOnly(_db.inkStrokes)
      ..addColumns([_db.inkStrokes.attemptNo, _db.inkStrokes.startedAtMs, _db.inkStrokes.durationMs])
      ..where(_db.inkStrokes.questionId.equals(questionId) & _db.inkStrokes.deleted.equals(false));
    return q.watch().map((rows) => [
          for (final r in rows)
            StrokeTime(
              attemptNo: r.read(_db.inkStrokes.attemptNo)!,
              startedAtMs: r.read(_db.inkStrokes.startedAtMs)!,
              durationMs: r.read(_db.inkStrokes.durationMs)!,
            ),
        ]);
  }

  final Set<String> _corruptIds = {};

  /// Çözülemeyen (bozuk blob) çizgilerin kimlikleri. Satırlara dokunulmaz,
  /// yalnızca listeden atlanır; kullanıcıya bildirmek çağıranın işidir.
  Set<String> get corruptIds => Set.unmodifiable(_corruptIds);

  List<InkStroke> _decodeAll(List<InkStrokeRow> rows) {
    final out = <InkStroke>[];
    for (final r in rows) {
      try {
        out.add(_toStroke(r));
      } on FormatException {
        _corruptIds.add(r.id);
      }
    }
    return out;
  }

  /// Yumuşak silme; satır senkronla karşıya gider. Bulunamazsa false.
  Future<bool> softDelete(String id) async => await softDeleteMany([id]) == 1;

  Future<int> softDeleteMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return 0;
    return (_db.update(_db.inkStrokes)..where((s) => s.id.isIn(list) & s.deleted.equals(false)))
        .write(InkStrokesCompanion(deleted: const Value(true), updatedAt: Value(_clock())));
  }

  /// Silinmiş çizgiyi geri getirir (geri al).
  Future<bool> restore(String id) async =>
      await (_db.update(_db.inkStrokes)..where((s) => s.id.equals(id) & s.deleted.equals(true)))
          .write(InkStrokesCompanion(deleted: const Value(false), updatedAt: Value(_clock()))) ==
      1;

  InkStroke _toStroke(InkStrokeRow r) => InkStroke(
        id: r.id,
        owner: r.pdfDocumentId != null
            ? PdfPageOwner(r.pdfDocumentId!, r.pdfPage ?? 0)
            : NotePageOwner(r.noteId ?? '', r.notePage ?? 0),
        points: StrokeCodec.decode(r.points),
        startedAtMs: r.startedAtMs,
        layer: r.layer,
        attemptNo: r.attemptNo,
        questionId: r.questionId,
        tool: r.tool,
        color: r.color,
        width: r.width,
        durationMs: r.durationMs,
        deleted: r.deleted,
      );
}

/// [InkStrokeRepository.replace] ile eklenecek yeni çizgi.
class NewStroke {
  const NewStroke({
    required this.owner,
    required this.points,
    required this.startedAtMs,
    this.layer = 0,
    this.attemptNo = 0,
    this.questionId,
    this.tool = 'pen',
    this.color = 0xFF000000,
    this.width = 1.0,
  });
  final StrokeOwner owner;
  final List<StrokePoint> points;
  final int startedAtMs;
  final int layer;
  final int attemptNo;
  final String? questionId;
  final String tool;
  final int color;
  final double width;
}
