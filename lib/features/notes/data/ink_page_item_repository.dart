import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/page_board.dart';
import '../domain/page_item_geometry.dart';

/// Sayfa öğeleri deposu (v23): metin kutusu ve görsel. Silme yumuşaktır. Görsel
/// DOSYALARI hiçbir koşulda silinmez ("kullanıcı verisi sessizce silinmez"); bir dosyayı
/// birden çok öğe (çoğaltılmış sayfa) paylaşabilir. Temizlik gerekirse [isMediaReferenced]
/// ile sayılır, silme kararı kullanıcıdadır.
class InkPageItemRepository {
  InkPageItemRepository(this._db, {IdGenerator ids = const UuidV7Generator(), DateTime Function()? clock})
      // ignore: prefer_initializing_formals
      : _ids = ids,
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  /// Metin kutusu ekler, kimliğini döner. z: sayfadaki en üst öğenin üstü.
  Future<String> addText(String pageId, BoardRect rect, {TextItemPayload payload = const TextItemPayload(), double rotation = 0}) =>
      _add(pageId, PageItemKind.text, rect, payload.toJson(), null, rotation);

  /// Görsel ekler. [mediaPath] `notes/yyyy/mm/ad.uzantı` olmalı ([ArgumentError]); dosya
  /// `PageImageStore` ile önceden kaydedilmiş olmalı.
  Future<String> addImage(String pageId, BoardRect rect, String mediaPath, {ImageItemPayload payload = const ImageItemPayload(), double rotation = 0}) {
    if (!isPageImagePath(mediaPath)) throw ArgumentError('Geçersiz görsel yolu: $mediaPath');
    return _add(pageId, PageItemKind.image, rect, payload.toJson(), mediaPath, rotation);
  }

  Future<String> _add(String pageId, PageItemKind kind, BoardRect r, String payload, String? media, double rotation) => _db.transaction(() async {
        if (await (_db.select(_db.inkNotePages)..where((t) => t.id.equals(pageId))).getSingleOrNull() == null) {
          throw StateError('Sayfa yok: $pageId');
        }
        _checkRect(r);
        final id = _ids.next();
        final now = _clock();
        final top = await _db
            .customSelect('SELECT COALESCE(MAX(z), -1) AS m FROM ink_page_items WHERE page_id = ?',
                variables: [Variable<String>(pageId)], readsFrom: {_db.inkPageItems})
            .getSingle();
        await _db.into(_db.inkPageItems).insert(InkPageItemsCompanion.insert(
              id: id,
              pageId: pageId,
              kind: kind.key,
              x: Value(r.x),
              y: Value(r.y),
              w: Value(r.w),
              h: Value(r.h),
              rotation: Value(rotation),
              z: Value(top.read<int>('m') + 1),
              payload: Value(payload),
              mediaPath: Value(media),
              createdAt: now,
              updatedAt: now,
            ));
        return id;
      });

  /// Konum/boyut/döndürme/z günceller (verilenler değişir).
  Future<void> updateGeometry(String id, {BoardRect? rect, double? rotation, int? z}) {
    if (rect != null) _checkRect(rect);
    return _touch(
      id,
      InkPageItemsCompanion(
        x: rect == null ? const Value.absent() : Value(rect.x),
        y: rect == null ? const Value.absent() : Value(rect.y),
        w: rect == null ? const Value.absent() : Value(rect.w),
        h: rect == null ? const Value.absent() : Value(rect.h),
        rotation: rotation == null ? const Value.absent() : Value(rotation),
        z: z == null ? const Value.absent() : Value(z),
      ),
    );
  }

  /// Birçok öğenin kutusunu tek işlemde yazar (kement ile çoklu taşıma).
  Future<void> updateGeometries(Map<String, BoardRect> rects) => _db.transaction(() async {
        for (final e in rects.entries) {
          await updateGeometry(e.key, rect: e.value);
        }
      });

  /// Öğeyi sayfadaki diğer (silinmemiş) öğelerin üstüne alır; zaten en üstteyse dokunmaz.
  Future<void> bringToFront(String id) => _db.transaction(() async {
        final it = await _require(id);
        final others = await _db
            .customSelect('SELECT MAX(z) AS m FROM ink_page_items WHERE page_id = ? AND deleted = 0 AND id <> ?',
                variables: [Variable<String>(it.pageId), Variable<String>(id)], readsFrom: {_db.inkPageItems})
            .getSingle();
        final m = others.read<int?>('m');
        if (m != null && it.z <= m) await _touch(id, InkPageItemsCompanion(z: Value(m + 1)));
      });

  /// Metin kutusunun içeriğini/biçimini günceller; görsel öğede [StateError].
  Future<void> updateText(String id, TextItemPayload payload) => _db.transaction(() async {
        final it = await _require(id);
        if (it.kind != PageItemKind.text.key) throw StateError('Metin öğesi değil: $id');
        await _touch(id, InkPageItemsCompanion(payload: Value(payload.toJson())));
      });

  /// Görselin saydamlığı (0..1) ve piksel boyutu; metin öğesinde [StateError].
  Future<void> updateImage(String id, ImageItemPayload payload) => _db.transaction(() async {
        final it = await _require(id);
        if (it.kind != PageItemKind.image.key) throw StateError('Görsel öğesi değil: $id');
        await _touch(id, InkPageItemsCompanion(payload: Value(payload.toJson())));
      });

  Future<void> deleteItem(String id) => _touch(id, const InkPageItemsCompanion(deleted: Value(true)));

  Future<void> restoreItem(String id) => _touch(id, const InkPageItemsCompanion(deleted: Value(false)));

  /// Sayfanın öğeleri, alttan üste (z, sonra oluşturma sırası).
  Future<List<PageItemRecord>> items(String pageId, {bool includeDeleted = false}) async => [
        for (final r in await _query(pageId, includeDeleted).get()) _item(r),
      ];

  Stream<List<PageItemRecord>> watchItems(String pageId) => _query(pageId, false).watch().map((rows) => [for (final r in rows) _item(r)]);

  Future<PageItemRecord?> findItem(String id) async {
    final r = await (_db.select(_db.inkPageItems)..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _item(r);
  }

  /// Bu görsel yolunu (silinmiş öğeler dahil) kullanan öğe sayısı.
  Future<int> mediaReferenceCount(String mediaPath) async {
    final r = await _db
        .customSelect('SELECT COUNT(*) AS c FROM ink_page_items WHERE media_path = ?',
            variables: [Variable<String>(mediaPath)], readsFrom: {_db.inkPageItems})
        .getSingle();
    return r.read<int>('c');
  }

  Future<bool> isMediaReferenced(String mediaPath) async => await mediaReferenceCount(mediaPath) > 0;

  SimpleSelectStatement<$InkPageItemsTable, InkPageItemRow> _query(String pageId, bool includeDeleted) => _db.select(_db.inkPageItems)
    ..where((t) => t.pageId.equals(pageId) & (includeDeleted ? const Constant(true) : t.deleted.equals(false)))
    ..orderBy([(t) => OrderingTerm.asc(t.z), (t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)]);

  void _checkRect(BoardRect r) {
    if (!(r.w > 0) || !(r.h > 0) || r.x.isNaN || r.y.isNaN || r.x.isInfinite || r.y.isInfinite) {
      throw ArgumentError('Öğe kutusu geçersiz: $r');
    }
  }

  Future<InkPageItemRow> _require(String id) async {
    final r = await (_db.select(_db.inkPageItems)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) throw StateError('Öğe yok: $id');
    return r;
  }

  Future<void> _touch(String id, InkPageItemsCompanion c) async {
    final n = await (_db.update(_db.inkPageItems)..where((t) => t.id.equals(id))).write(c.copyWith(updatedAt: Value(_clock())));
    if (n == 0) throw StateError('Öğe yok: $id');
  }

  PageItemRecord _item(InkPageItemRow r) => PageItemRecord(
        id: r.id,
        pageId: r.pageId,
        kind: PageItemKind.fromKey(r.kind),
        x: r.x,
        y: r.y,
        w: r.w,
        h: r.h,
        rotation: r.rotation,
        z: r.z,
        payloadJson: r.payload,
        mediaPath: r.mediaPath,
        deleted: r.deleted,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
      );
}
