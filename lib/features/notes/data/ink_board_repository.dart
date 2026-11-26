import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/board_layout.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_board.dart';
import '../domain/page_template.dart';
import 'ink_notebook_repository.dart';

/// Pano (sayfa kartlarının serbest yerleşimi), sayfa bağlantıları, alt sayfa ve
/// sayfa↔MEB konu eşlemesi (v23). Silme yumuşaktır.
class InkBoardRepository {
  InkBoardRepository(
    this._db, {
    IdGenerator ids = const UuidV7Generator(),
    DateTime Function()? clock,
    InkNotebookRepository? notebooks,
  })
      // ignore: prefer_initializing_formals
      : _ids = ids,
        _clock = clock ?? DateTime.now,
        _notebooks = notebooks ?? InkNotebookRepository(_db, ids: ids, clock: clock);

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;
  final InkNotebookRepository _notebooks;

  // ───────────── Pano konumları ─────────────

  /// Defterin silinmemiş sayfa kartları (sayfa sırasıyla).
  Future<List<BoardCard>> boardCards(String notebookId) async => [
        for (final r in await (_db.select(_db.inkNotePages)
              ..where((t) => t.notebookId.equals(notebookId) & t.deleted.equals(false))
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)]))
            .get())
          _card(r),
      ];

  /// Kart konumu/başlık/boyut değişince yenilenir.
  Stream<List<BoardCard>> watchBoardCards(String notebookId) => (_db.select(_db.inkNotePages)
        ..where((t) => t.notebookId.equals(notebookId) & t.deleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)]))
      .watch()
      .map((rows) => [for (final r in rows) _card(r)]);

  /// Birçok kartın konumunu (ve boyutunu) TEK işlemde yazar: biri başarısız olursa hiçbiri
  /// yazılmaz (yok olan sayfa [StateError]). Yalnızca değişen satır yazılır.
  Future<void> setBoardPositions(Map<String, BoardRect> rects) => _db.transaction(() async {
        final now = _clock();
        for (final e in rects.entries) {
          final r = e.value;
          if (!(r.w > 0) || !(r.h > 0) || r.x.isNaN || r.y.isNaN) throw ArgumentError('Geçersiz kart: ${e.key}');
          final n = await (_db.update(_db.inkNotePages)
                ..where((t) =>
                    t.id.equals(e.key) &
                    (t.boardX.equals(r.x).not() | t.boardX.isNull() | t.boardY.equals(r.y).not() | t.boardY.isNull() |
                        t.boardW.equals(r.w).not() | t.boardW.isNull() | t.boardH.equals(r.h).not() | t.boardH.isNull())))
              .write(InkNotePagesCompanion(
            boardX: Value(r.x),
            boardY: Value(r.y),
            boardW: Value(r.w),
            boardH: Value(r.h),
            updatedAt: Value(now),
          ));
          if (n == 0 && await (_db.select(_db.inkNotePages)..where((t) => t.id.equals(e.key))).getSingleOrNull() == null) {
            throw StateError('Sayfa yok: ${e.key}');
          }
        }
      });

  /// Defterin tüm sayfalarını [autoArrange] ile yerleştirir (konumları üzerine yazar).
  Future<void> arrangeNotebook(String notebookId) async {
    final cards = await boardCards(notebookId);
    final edges = [for (final l in await links(notebookId)) (from: l.fromPageId, to: l.toPageId)];
    await setBoardPositions(autoArrange(cards, edges));
  }

  // ───────────── Bağlantılar ─────────────

  /// İki sayfa arasına bağlantı ekler, kimliğini döner. İki sayfa da var ve AYNI defterde olmalı,
  /// kendine bağlantı olmaz ([ArgumentError]/[StateError]). Aynı yönde, aynı türde zaten etkin
  /// bir bağlantı varsa (çapasız `link` için) yenisi eklenmez, mevcut kimlik döner.
  Future<String> addLink(
    String fromPageId,
    String toPageId, {
    PageLinkKind kind = PageLinkKind.link,
    double? fromX,
    double? fromY,
    String label = '',
    int color = 0xFF607D8B,
  }) => _db.transaction(() async {
        if (fromPageId == toPageId) throw ArgumentError('Sayfa kendine bağlanamaz');
        final a = await _page(fromPageId);
        final b = await _page(toPageId);
        if (a.notebookId != b.notebookId) throw ArgumentError('Sayfalar aynı defterde olmalı');
        if (kind == PageLinkKind.link && fromX == null && fromY == null) {
          final dup = await (_db.select(_db.inkPageLinks)
                ..where((l) =>
                    l.fromPageId.equals(fromPageId) &
                    l.toPageId.equals(toPageId) &
                    l.kind.equals(kind.key) &
                    l.fromX.isNull() &
                    l.deleted.equals(false)))
              .get();
          if (dup.isNotEmpty) return dup.first.id;
        }
        return _insertLink(a.notebookId, fromPageId, toPageId, kind, fromX, fromY, label, color);
      });

  Future<String> _insertLink(String notebookId, String from, String to, PageLinkKind kind, double? fx, double? fy, String label, int color) async {
    final id = _ids.next();
    final now = _clock();
    await _db.into(_db.inkPageLinks).insert(InkPageLinksCompanion.insert(
          id: id,
          notebookId: notebookId,
          fromPageId: from,
          toPageId: to,
          fromX: Value(fx),
          fromY: Value(fy),
          label: Value(label.trim()),
          kind: Value(kind.key),
          color: Value(color),
          createdAt: now,
          updatedAt: now,
        ));
    return id;
  }

  Future<void> setLinkLabel(String id, String label) => _touchLink(id, InkPageLinksCompanion(label: Value(label.trim())));

  Future<void> setLinkColor(String id, int argb) => _touchLink(id, InkPageLinksCompanion(color: Value(argb)));

  /// Çapa (kaynak sayfadaki düğüm) konumunu günceller.
  Future<void> setLinkAnchor(String id, double? x, double? y) => _touchLink(id, InkPageLinksCompanion(fromX: Value(x), fromY: Value(y)));

  /// Yumuşak siler (bağlantı bilgisi kalır; sayfalara dokunulmaz).
  Future<void> deleteLink(String id) => _touchLink(id, const InkPageLinksCompanion(deleted: Value(true)));

  Future<void> restoreLink(String id) => _touchLink(id, const InkPageLinksCompanion(deleted: Value(false)));

  /// Defterin silinmemiş bağlantıları; iki ucu da silinmemiş sayfa olanlar.
  Future<List<PageLinkRecord>> links(String notebookId) async => _linksQuery(notebookId).get().then((rows) => rows.map(_linkFromData).toList());

  Stream<List<PageLinkRecord>> watchLinks(String notebookId) => _linksQuery(notebookId).watch().map((rows) => rows.map(_linkFromData).toList());

  /// [pageId]'den çıkan etkin bağlantılar (sayfa içindeki düğümler).
  Future<List<PageLinkRecord>> linksFrom(String pageId) async => [for (final l in await links((await _page(pageId)).notebookId)) if (l.fromPageId == pageId) l];

  /// Silinmiş bağlantılar dahil, kimlikle.
  Future<PageLinkRecord?> findLink(String id) async {
    final r = await (_db.select(_db.inkPageLinks)..where((l) => l.id.equals(id))).getSingleOrNull();
    return r == null ? null : _link(r);
  }

  Selectable<Map<String, Object?>> _linksQuery(String notebookId) => _db
      .customSelect(
        'SELECT l.* FROM ink_page_links l '
        'JOIN ink_note_pages a ON a.id = l.from_page_id AND a.deleted = 0 '
        'JOIN ink_note_pages b ON b.id = l.to_page_id AND b.deleted = 0 '
        'WHERE l.notebook_id = ? AND l.deleted = 0 ORDER BY l.created_at, l.id',
        variables: [Variable<String>(notebookId)],
        readsFrom: {_db.inkPageLinks, _db.inkNotePages},
      )
      .map((row) => row.data);

  PageLinkRecord _linkFromData(Map<String, Object?> d) => _link(_db.inkPageLinks.map(d));

  Future<void> _touchLink(String id, InkPageLinksCompanion c) async {
    final n = await (_db.update(_db.inkPageLinks)..where((t) => t.id.equals(id))).write(c.copyWith(updatedAt: Value(_clock())));
    if (n == 0) throw StateError('Bağlantı yok: $id');
  }

  // ───────────── Alt sayfa ─────────────

  /// [parentPageId] sayfasının içinde [anchorX],[anchorY] konumundan alt sayfa açar: yeni sayfa
  /// ebeveynin defterine eklenir (ebeveynin şablonu ve boyutuyla), `parentPageId` yazılır,
  /// `child` bağlantısı çapayla eklenir; ebeveyn panoda yerleşmişse alt kart yanında boş yere konur.
  /// HEPSİ tek işlemdir: herhangi bir adım başarısız olursa yetim sayfa kalmaz. Yeni sayfa kimliğini döner.
  Future<String> createChildPage(String parentPageId, double anchorX, double anchorY) => _db.transaction(() async {
        final parent = await _page(parentPageId);
        if (parent.deleted) throw StateError('Silinmiş sayfanın alt sayfası olmaz');
        final childId = await _notebooks.addPage(
          parent.notebookId,
          template: PageTemplate.fromKey(parent.template),
          width: parent.width,
          height: parent.height,
          background: parent.background,
        );
        var companion = InkNotePagesCompanion(parentPageId: Value(parentPageId), updatedAt: Value(_clock()));
        if (parent.boardX != null && parent.boardY != null) {
          final taken = [
            for (final c in await boardCards(parent.notebookId))
              if (c.pageId != childId) c.rect(),
          ].whereType<BoardRect>();
          final slot = freeSlotNear(
            BoardRect(parent.boardX!, parent.boardY!, parent.boardW ?? boardCardW, parent.boardH ?? boardCardH),
            taken,
          );
          companion = companion.copyWith(boardX: Value(slot.x), boardY: Value(slot.y), boardW: Value(slot.w), boardH: Value(slot.h));
        }
        await (_db.update(_db.inkNotePages)..where((t) => t.id.equals(childId))).write(companion);
        await _insertLink(parent.notebookId, parentPageId, childId, PageLinkKind.child, anchorX, anchorY, '', 0xFF607D8B);
        return childId;
      });

  /// [pageId]'nin silinmemiş alt sayfaları.
  Future<List<InkNotePageRecord>> childPages(String pageId) async {
    final rows = await (_db.select(_db.inkNotePages)
          ..where((t) => t.parentPageId.equals(pageId) & t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.id)]))
        .get();
    return [for (final r in rows) (await _notebooks.findPage(r.id))!];
  }

  // ───────────── Konu eşleme ─────────────

  /// Sayfayı MEB konusuna bağlar; [konuId] null ise bağı kaldırır. Konu kimliği doğrulanmaz
  /// (konu ağacı cihaza göre tohumlanır; bilinmeyen kimlik arayüzde "konu yok" görünür).
  Future<void> setPageKonu(String pageId, String? konuId) async {
    final n = await (_db.update(_db.inkNotePages)..where((t) => t.id.equals(pageId)))
        .write(InkNotePagesCompanion(konuId: Value(konuId), updatedAt: Value(_clock())));
    if (n == 0) throw StateError('Sayfa yok: $pageId');
  }

  Future<void> clearPageKonu(String pageId) => setPageKonu(pageId, null);

  Future<String?> konuOfPage(String pageId) async => (await _page(pageId)).konuId;

  /// Konuya bağlı silinmemiş sayfalar (silinmemiş defterlerdeki), defter ve sayfa sırasıyla.
  Future<List<InkNotePageRecord>> pagesForKonu(String konuId) async {
    final rows = await _db
        .customSelect(
          'SELECT p.id AS id FROM ink_note_pages p JOIN ink_notebooks n ON n.id = p.notebook_id '
          'WHERE p.konu_id = ? AND p.deleted = 0 AND n.deleted = 0 ORDER BY n.sort_order, n.created_at, p.sort_order, p.id',
          variables: [Variable<String>(konuId)],
          readsFrom: {_db.inkNotePages, _db.inkNotebooks},
        )
        .get();
    return [for (final r in rows) (await _notebooks.findPage(r.read<String>('id')))!];
  }

  Stream<List<InkNotePageRecord>> watchPagesForKonu(String konuId) => _db
      .customSelect(
        'SELECT p.id AS id FROM ink_note_pages p JOIN ink_notebooks n ON n.id = p.notebook_id '
        'WHERE p.konu_id = ?1 AND p.deleted = 0 AND n.deleted = 0 ORDER BY n.sort_order, n.created_at, p.sort_order, p.id',
        variables: [Variable<String>(konuId)],
        readsFrom: {_db.inkNotePages, _db.inkNotebooks},
      )
      .watch()
      .asyncMap((_) => pagesForKonu(konuId));

  // ───────────── iç ─────────────

  Future<InkNotePageRow> _page(String id) async {
    final r = await (_db.select(_db.inkNotePages)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) throw StateError('Sayfa yok: $id');
    return r;
  }

  BoardCard _card(InkNotePageRow r) => BoardCard(
        pageId: r.id,
        notebookId: r.notebookId,
        pageNo: r.pageNo,
        title: r.title,
        konuId: r.konuId,
        parentPageId: r.parentPageId,
        x: r.boardX,
        y: r.boardY,
        w: r.boardW,
        h: r.boardH,
      );

  PageLinkRecord _link(InkPageLinkRow r) => PageLinkRecord(
        id: r.id,
        notebookId: r.notebookId,
        fromPageId: r.fromPageId,
        toPageId: r.toPageId,
        fromX: r.fromX,
        fromY: r.fromY,
        label: r.label,
        kind: PageLinkKind.fromKey(r.kind),
        color: r.color,
        deleted: r.deleted,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
      );
}
