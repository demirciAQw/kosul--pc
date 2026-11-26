import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/ink_folder.dart';

/// Defter klasörleri deposu (v23). Silme yumuşaktır. Klasör silinince içindeki
/// defterler ve alt klasörler GİZLENMEZ: silinen klasörün ebeveynine (yoksa köke)
/// taşınır; böylece hiçbir defter "kaybolmaz". Geri alınca klasör boş döner.
class InkFolderRepository {
  InkFolderRepository(this._db, {IdGenerator ids = const UuidV7Generator(), DateTime Function()? clock})
      // ignore: prefer_initializing_formals
      : _ids = ids,
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  Future<String> createFolder(String name, {String? parentId, int color = 0xFF607D8B}) => _db.transaction(() async {
        if (parentId != null) await _requireLive(parentId);
        final id = _ids.next();
        final now = _clock();
        await _db.into(_db.inkFolders).insert(InkFoldersCompanion.insert(
              id: id,
              parentId: Value(parentId),
              name: Value(name.trim()),
              color: Value(color),
              sortOrder: Value(await _nextOrder(parentId)),
              createdAt: now,
              updatedAt: now,
            ));
        return id;
      });

  Future<void> renameFolder(String id, String name) => _update(id, InkFoldersCompanion(name: Value(name.trim())));

  Future<void> setFolderColor(String id, int argb) => _update(id, InkFoldersCompanion(color: Value(argb)));

  /// Klasörü [newParentId] altına (null = köke) taşır, sona ekler. Kendisinin ya da bir
  /// torununun altına taşıma [ArgumentError] ile reddedilir; ebeveyn yok/silinmişse [StateError].
  Future<void> moveFolder(String id, String? newParentId) => _db.transaction(() async {
        final f = await _require(id);
        if (f.parentId == newParentId) return;
        if (newParentId != null) await _requireLive(newParentId);
        final parentOf = await _parentMap();
        if (wouldCreateFolderCycle(id, newParentId, parentOf)) {
          throw ArgumentError('Klasör kendi altına taşınamaz');
        }
        await _update(id, InkFoldersCompanion(parentId: Value(newParentId), sortOrder: Value(await _nextOrder(newParentId))));
      });

  /// [parentId] altındaki silinmemiş klasörlerin tamamı [ids]; sıra bu olur.
  Future<void> reorderFolders(String? parentId, List<String> ids) => _db.transaction(() async {
        final visible = [for (final f in await folders(parentId: parentId, onlyChildrenOf: true)) f.id];
        if (visible.length != ids.length || ids.toSet().length != ids.length || !visible.toSet().containsAll(ids)) {
          throw ArgumentError('Sıralama tüm kardeş klasörleri içermeli');
        }
        for (var i = 0; i < ids.length; i++) {
          await (_db.update(_db.inkFolders)..where((t) => t.id.equals(ids[i]) & t.sortOrder.equals(i).not()))
              .write(InkFoldersCompanion(sortOrder: Value(i), updatedAt: Value(_clock())));
        }
      });

  /// Yumuşak siler; içindekiler (defterler, alt klasörler) ebeveyne taşınır.
  Future<void> deleteFolder(String id) => _db.transaction(() async {
        final f = await _require(id);
        if (f.deleted) return;
        final now = _clock();
        final parent = f.parentId;
        await (_db.update(_db.inkNotebooks)..where((t) => t.folderId.equals(id)))
            .write(InkNotebooksCompanion(folderId: Value(parent), updatedAt: Value(now)));
        for (final sub in await (_db.select(_db.inkFolders)..where((t) => t.parentId.equals(id))).get()) {
          await (_db.update(_db.inkFolders)..where((t) => t.id.equals(sub.id)))
              .write(InkFoldersCompanion(parentId: Value(parent), updatedAt: Value(now)));
        }
        await _update(id, const InkFoldersCompanion(deleted: Value(true)));
      });

  /// Geri getirir; ebeveyni silinmiş/yoksa köke gelir.
  Future<void> restoreFolder(String id) => _db.transaction(() async {
        final f = await _require(id);
        if (!f.deleted) return;
        final p = f.parentId == null ? null : await (_db.select(_db.inkFolders)..where((t) => t.id.equals(f.parentId!))).getSingleOrNull();
        final parentOk = p != null && !p.deleted && !wouldCreateFolderCycle(id, p.id, await _parentMap());
        await _update(id, InkFoldersCompanion(deleted: const Value(false), parentId: Value(parentOk ? f.parentId : null)));
      });

  /// Klasörler. [onlyChildrenOf]: true ise yalnızca [parentId]'nin doğrudan çocukları
  /// (null = kökler); false ise hepsi (düz liste, ağacı arayüz kurar).
  Future<List<InkFolderRecord>> folders({String? parentId, bool onlyChildrenOf = false, bool includeDeleted = false}) async {
    final rows = await (_db.select(_db.inkFolders)
          ..where((t) =>
              (includeDeleted ? const Constant(true) : t.deleted.equals(false)) &
              (onlyChildrenOf ? (parentId == null ? t.parentId.isNull() : t.parentId.equals(parentId)) : const Constant(true)))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)]))
        .get();
    return _withCounts(rows);
  }

  /// Tüm klasörler (silinmemiş; defter sayısıyla); defter ya da klasör değişince yenilenir.
  Stream<List<InkFolderRecord>> watchFolders({bool includeDeleted = false}) {
    final q = _db.customSelect(
      'SELECT f.id AS id FROM ink_folders f ${includeDeleted ? '' : 'WHERE f.deleted = 0'} ORDER BY f.sort_order, f.created_at, f.id',
      readsFrom: {_db.inkFolders, _db.inkNotebooks},
    );
    return q.watch().asyncMap((_) => folders(includeDeleted: includeDeleted));
  }

  Future<InkFolderRecord?> findFolder(String id) async => (await folders(includeDeleted: true)).where((f) => f.id == id).firstOrNull;

  /// Kökten [id]'ye klasör yolu (kendisi dahil); döngülü bozuk veri keser.
  Future<List<InkFolderRecord>> pathOf(String id) async {
    final all = {for (final f in await folders(includeDeleted: true)) f.id: f};
    return [for (final p in folderPath(id, {for (final f in all.values) f.id: f.parentId})) if (all[p] != null) all[p]!];
  }

  Future<List<InkFolderRecord>> _withCounts(List<InkFolderRow> rows) async {
    final counts = {
      for (final r in await _db
          .customSelect(
            'SELECT folder_id AS f, COUNT(*) AS c FROM ink_notebooks WHERE deleted = 0 AND folder_id IS NOT NULL GROUP BY folder_id',
            readsFrom: {_db.inkNotebooks},
          )
          .get())
        r.read<String>('f'): r.read<int>('c'),
    };
    return [
      for (final r in rows)
        InkFolderRecord(
          id: r.id,
          parentId: r.parentId,
          name: r.name,
          color: r.color,
          sortOrder: r.sortOrder,
          deleted: r.deleted,
          createdAt: r.createdAt,
          updatedAt: r.updatedAt,
          notebookCount: counts[r.id] ?? 0,
        ),
    ];
  }

  Future<Map<String, String?>> _parentMap() async => {for (final f in await _db.select(_db.inkFolders).get()) f.id: f.parentId};

  Future<int> _nextOrder(String? parentId) async {
    final r = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) AS m FROM ink_folders WHERE deleted = 0 AND ${parentId == null ? 'parent_id IS NULL' : 'parent_id = ?'}',
          variables: [if (parentId != null) Variable<String>(parentId)],
          readsFrom: {_db.inkFolders},
        )
        .getSingle();
    return r.read<int>('m') + 1;
  }

  Future<InkFolderRow> _require(String id) async {
    final r = await (_db.select(_db.inkFolders)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) throw StateError('Klasör yok: $id');
    return r;
  }

  Future<void> _requireLive(String id) async {
    if ((await _require(id)).deleted) throw StateError('Klasör silinmiş: $id');
  }

  Future<void> _update(String id, InkFoldersCompanion c) async {
    final n = await (_db.update(_db.inkFolders)..where((t) => t.id.equals(id))).write(c.copyWith(updatedAt: Value(_clock())));
    if (n == 0) throw StateError('Klasör yok: $id');
  }
}
