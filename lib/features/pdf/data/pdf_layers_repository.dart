import 'dart:async';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart' show PdfBox;
import 'dart:convert';

/// PDF sayfa katman deposu. Silme yumuşaktır (`deleted`); PDF dosyası değişmez.
class PdfLayersRepository {
  PdfLayersRepository(this._db, {IdGenerator? ids, DateTime Function()? clock})
      : _ids = ids ?? const UuidV7Generator(),
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  /// Bu depo üzerinden yapılan her yazmadan sonra tetiklenir (bellek içi; veritabanı akışı değil).
  /// Okuyucu bununla katmanlarını yeniden okur.
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  void _ping() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();

  /// Ekler (en üste: z = belgedeki en büyük z + 1), kimliğini döner.
  /// [page] = [allPdfPages] tüm sayfalar; [box] null = tüm sayfa.
  Future<String> add({
    required String documentId,
    required int page,
    required PdfLayerKind kind,
    PdfBox? box,
    required Map<String, Object?> params,
    String name = '',
  }) async {
    if (page < allPdfPages) throw ArgumentError.value(page, 'page');
    final id = _ids.next();
    final now = _clock();
    final maxZ = await (_db.selectOnly(_db.pdfPageLayers)
          ..addColumns([_db.pdfPageLayers.z.max()])
          ..where(_db.pdfPageLayers.pdfDocumentId.equals(documentId)))
        .map((r) => r.read(_db.pdfPageLayers.z.max()))
        .getSingle();
    await _db.into(_db.pdfPageLayers).insert(PdfPageLayersCompanion.insert(
          id: id,
          pdfDocumentId: documentId,
          page: page,
          kind: kind.key,
          boxLeft: Value(box?.left),
          boxTop: Value(box?.top),
          boxRight: Value(box?.right),
          boxBottom: Value(box?.bottom),
          params: Value(jsonEncode(params)),
          z: Value((maxZ ?? -1) + 1),
          name: Value(name.trim().isEmpty ? kind.label : name.trim()),
          createdAt: now,
          updatedAt: now,
        ));
    _ping();
    return id;
  }

  SimpleSelectStatement<$PdfPageLayersTable, PdfPageLayerRow> _q(String doc, int? page, bool deleted) {
    final t = _db.pdfPageLayers;
    return _db.select(t)
      ..where((r) {
        var e = r.pdfDocumentId.equals(doc) & r.deleted.equals(deleted);
        if (page != null) e = e & (r.page.equals(allPdfPages) | r.page.equals(page));
        return e;
      })
      ..orderBy([(r) => OrderingTerm.asc(r.z), (r) => OrderingTerm.asc(r.id)]);
  }

  /// Sayfa için katmanlar (tüm sayfalar + o sayfa), z sırasıyla; gizliler dahil.
  Future<List<PdfPageLayer>> forPage(String doc, int page) async =>
      [for (final r in await _q(doc, page, false).get()) _map(r)];

  Stream<List<PdfPageLayer>> watchForPage(String doc, int page) =>
      _q(doc, page, false).watch().map((rs) => [for (final r in rs) _map(r)]);

  /// Belgenin tüm katmanları (gizliler dahil, silinmişler hariç).
  Stream<List<PdfPageLayer>> watchAll(String doc) =>
      _q(doc, null, false).watch().map((rs) => [for (final r in rs) _map(r)]);

  Future<List<PdfPageLayer>> all(String doc, {bool deleted = false}) async =>
      [for (final r in await _q(doc, null, deleted).get()) _map(r)];

  Future<bool> setVisible(String id, bool v) => _update(id, PdfPageLayersCompanion(visible: Value(v)));

  Future<bool> rename(String id, String name) =>
      name.trim().isEmpty ? Future.value(false) : _update(id, PdfPageLayersCompanion(name: Value(name.trim())));

  Future<bool> updateParams(String id, Map<String, Object?> params, {PdfBox? box, bool setBox = false}) =>
      _update(
        id,
        PdfPageLayersCompanion(
          params: Value(jsonEncode(params)),
          boxLeft: setBox ? Value(box?.left) : const Value.absent(),
          boxTop: setBox ? Value(box?.top) : const Value.absent(),
          boxRight: setBox ? Value(box?.right) : const Value.absent(),
          boxBottom: setBox ? Value(box?.bottom) : const Value.absent(),
        ),
      );

  /// [orderedIds] (alttan üste) katmanlarına, mevcut z değerleri bu sırayla dağıtılır
  /// (listede olmayan katmanların sırası bozulmaz). Eşit z'ler art arda yapılır.
  Future<void> reorder(List<String> orderedIds) => _db.transaction(() async {
        final t = _db.pdfPageLayers;
        final rows = await (_db.select(t)..where((r) => r.id.isIn(orderedIds))).get();
        if (rows.length != orderedIds.length) throw ArgumentError('Bilinmeyen katman kimliği');
        final zs = [for (final r in rows) r.z]..sort();
        for (var i = 1; i < zs.length; i++) {
          if (zs[i] <= zs[i - 1]) zs[i] = zs[i - 1] + 1;
        }
        final now = _clock();
        for (var i = 0; i < orderedIds.length; i++) {
          final cur = rows.firstWhere((r) => r.id == orderedIds[i]);
          if (cur.z == zs[i]) continue;
          await (_db.update(t)..where((r) => r.id.equals(orderedIds[i])))
              .write(PdfPageLayersCompanion(z: Value(zs[i]), updatedAt: Value(now)));
        }
      }).whenComplete(_ping);

  Future<bool> softDelete(String id) => _update(id, const PdfPageLayersCompanion(deleted: Value(true)));
  Future<bool> restore(String id) => _update(id, const PdfPageLayersCompanion(deleted: Value(false)));

  Future<bool> _update(String id, PdfPageLayersCompanion c) async {
    final n = await (_db.update(_db.pdfPageLayers)..where((r) => r.id.equals(id)))
        .write(c.copyWith(updatedAt: Value(_clock())));
    _ping();
    return n == 1;
  }

  PdfPageLayer _map(PdfPageLayerRow r) => PdfPageLayer(
        id: r.id,
        documentId: r.pdfDocumentId,
        page: r.page,
        kind: PdfLayerKind.parse(r.kind),
        box: (r.boxLeft != null && r.boxTop != null && r.boxRight != null && r.boxBottom != null)
            ? PdfBox(r.boxLeft!, r.boxTop!, r.boxRight!, r.boxBottom!)
            : null,
        params: PdfPageLayer.decodeParams(r.params),
        z: r.z,
        name: r.name,
        visible: r.visible,
        deleted: r.deleted,
      );
}
