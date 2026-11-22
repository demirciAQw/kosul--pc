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

  SimpleSelectStatement<$InkStrokesTable, InkStrokeRow> _query(StrokeOwner owner, {int? attemptNo, int? layer}) {
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
        return w;
      })
      ..orderBy([(s) => OrderingTerm.asc(s.startedAtMs), (s) => OrderingTerm.asc(s.id)]);
  }

  /// Sayfadaki (silinmemiş) çizgiler, çizim sırasıyla.
  Future<List<InkStroke>> forPage(StrokeOwner owner, {int? attemptNo, int? layer}) async =>
      [for (final r in await _query(owner, attemptNo: attemptNo, layer: layer).get()) _toStroke(r)];

  Stream<List<InkStroke>> watchPage(StrokeOwner owner, {int? attemptNo, int? layer}) =>
      _query(owner, attemptNo: attemptNo, layer: layer).watch().map((rows) => [for (final r in rows) _toStroke(r)]);

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
        tool: r.tool,
        color: r.color,
        width: r.width,
        durationMs: r.durationMs,
        deleted: r.deleted,
      );
}
