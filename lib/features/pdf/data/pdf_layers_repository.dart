import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart' show PdfBox;

/// PDF katman deposu (`pdf_page_layers`). Eski 'watermark'/'cover' satırları okunmaz
/// ama silinmez. Silme yumuşaktır (`deleted`); çizgiler silinmez, yalnız gizlenir.
class PdfLayersRepository {
  PdfLayersRepository(this._db, {IdGenerator? ids, DateTime Function()? clock})
      : _ids = ids ?? const UuidV7Generator(),
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  /// Ekler (en sona: z = belgedeki en büyük z + 1), kimliğini döner.
  /// Tam sayfa: [page] [allPdfPages], [box] null. Soru: sayfa (0'dan) + [box].
  Future<String> add({
    required String documentId,
    required int page,
    required PdfLayerKind kind,
    PdfBox? box,
    Map<String, Object?> params = const {},
    String name = '',
  }) async {
    if (page < allPdfPages) throw ArgumentError.value(page, 'page');
    final id = _ids.next();
    final now = _clock();
    final t = _db.pdfPageLayers;
    final maxZ = await (_db.selectOnly(t)
          ..addColumns([t.z.max()])
          ..where(t.pdfDocumentId.equals(documentId)))
        .map((r) => r.read(t.z.max()))
        .getSingle();
    await _db.into(t).insert(PdfPageLayersCompanion.insert(
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
          name: Value(name),
          createdAt: now,
          updatedAt: now,
        ));
    return id;
  }

  /// Belgenin geçerli (full/question, silinmemiş) katmanları, numaralı ve sıralı.
  Future<List<PdfPageLayer>> all(String doc) async {
    final t = _db.pdfPageLayers;
    final rows = await (_db.select(t)..where((r) => r.pdfDocumentId.equals(doc) & r.deleted.equals(false))).get();
    return orderLayers(rows.map(_map).whereType<PdfPageLayer>());
  }

  Future<bool> setParams(String id, Map<String, Object?> params) async {
    final n = await (_db.update(_db.pdfPageLayers)..where((r) => r.id.equals(id))).write(
      PdfPageLayersCompanion(params: Value(jsonEncode(params)), updatedAt: Value(_clock())),
    );
    return n == 1;
  }

  /// Yumuşak silme / geri alma (çizgilere dokunulmaz).
  Future<bool> setDeleted(String id, bool deleted) async {
    final n = await (_db.update(_db.pdfPageLayers)..where((r) => r.id.equals(id))).write(
      PdfPageLayersCompanion(deleted: Value(deleted), updatedAt: Value(_clock())),
    );
    return n == 1;
  }

  PdfPageLayer? _map(PdfPageLayerRow r) {
    final kind = PdfLayerKind.parse(r.kind);
    if (kind == null) return null; // eski (kullanılmayan) türler
    return PdfPageLayer(
      id: r.id,
      documentId: r.pdfDocumentId,
      page: r.page,
      kind: kind,
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
}
