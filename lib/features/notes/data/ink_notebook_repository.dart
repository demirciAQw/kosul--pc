import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/id_generator.dart';
import '../../ink/domain/stroke_codec.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_template.dart';

/// Kalemli defter deposu (T6). Silme yumuşaktır; hiçbir şey sessizce yok olmaz.
/// Sayfa sırası `sortOrder`, çizgilerin anahtarı `pageNo` (bkz. `ink_note_pages`).
class InkNotebookRepository {
  InkNotebookRepository(
    this._db, {
    IdGenerator ids = const UuidV7Generator(),
    DateTime Function()? clock,
  })
    // ignore: prefer_initializing_formals
    : _ids = ids,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  // ───────────── Defterler ─────────────

  /// Defteri (ve [withFirstPage] ise ilk sayfayı) oluşturur, defter kimliğini döner.
  Future<String> createNotebook({
    String title = '',
    int coverColor = 0xFF3F51B5,
    PageTemplate defaultTemplate = PageTemplate.ruled,
    bool withFirstPage = true,
    double pageWidth = defaultPageWidth,
    double pageHeight = defaultPageHeight,
  }) => _db.transaction(() async {
    final id = _ids.next();
    final now = _clock();
    final maxOrder = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) AS m FROM ink_notebooks',
          readsFrom: {_db.inkNotebooks},
        )
        .getSingle();
    await _db
        .into(_db.inkNotebooks)
        .insert(
          InkNotebooksCompanion.insert(
            id: id,
            title: Value(title.trim()),
            coverColor: Value(coverColor),
            defaultTemplate: Value(defaultTemplate.key),
            sortOrder: Value(maxOrder.read<int>('m') + 1),
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (withFirstPage) await addPage(id, width: pageWidth, height: pageHeight);
    return id;
  });

  /// Defteri klasöre taşır; [folderId] null = köke. Klasör yoksa ya da silinmişse [StateError].
  Future<void> moveNotebookToFolder(String id, String? folderId) => _db.transaction(() async {
    if (folderId != null) {
      final f = await (_db.select(_db.inkFolders)..where((t) => t.id.equals(folderId))).getSingleOrNull();
      if (f == null || f.deleted) throw StateError('Klasör yok: $folderId');
    }
    await _updateNotebook(id, InkNotebooksCompanion(folderId: Value(folderId)));
  });

  Future<void> renameNotebook(String id, String title) =>
      _updateNotebook(id, InkNotebooksCompanion(title: Value(title.trim())));

  Future<void> setCoverColor(String id, int color) =>
      _updateNotebook(id, InkNotebooksCompanion(coverColor: Value(color)));

  /// Yeni sayfaların şablonu; var olan sayfalara dokunmaz.
  Future<void> setDefaultTemplate(String id, PageTemplate t) =>
      _updateNotebook(id, InkNotebooksCompanion(defaultTemplate: Value(t.key)));

  Future<void> deleteNotebook(String id) =>
      _updateNotebook(id, const InkNotebooksCompanion(deleted: Value(true)));

  Future<void> restoreNotebook(String id) =>
      _updateNotebook(id, const InkNotebooksCompanion(deleted: Value(false)));

  Future<void> _updateNotebook(String id, InkNotebooksCompanion c) async {
    final n =
        await (_db.update(_db.inkNotebooks)..where((t) => t.id.equals(id)))
            .write(c.copyWith(updatedAt: Value(_clock())));
    if (n == 0) throw StateError('Defter yok: $id');
  }

  /// [ids] silinmemiş defterlerin tamamıdır; sıra bu olur.
  Future<void> reorderNotebooks(List<String> ids) => _db.transaction(() async {
    final visible = [for (final n in await notebooks()) n.id];
    if (!_sameSet(visible, ids))
      throw ArgumentError('Sıralama tüm defterleri içermeli');
    for (var i = 0; i < ids.length; i++) {
      await (_db.update(
        _db.inkNotebooks,
      )..where((t) => t.id.equals(ids[i]) & t.sortOrder.equals(i).not())).write(
        InkNotebooksCompanion(sortOrder: Value(i), updatedAt: Value(_clock())),
      );
    }
  });

  Future<List<InkNotebookRecord>> notebooks({
    bool includeDeleted = false,
  }) async {
    final rows =
        await (_db.select(_db.inkNotebooks)
              ..where(
                (t) => includeDeleted
                    ? const Constant(true)
                    : t.deleted.equals(false),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sortOrder),
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final counts = {
      for (final r
          in await _db
              .customSelect(
                'SELECT notebook_id AS n, COUNT(*) AS c FROM ink_note_pages WHERE deleted = 0 GROUP BY notebook_id',
                readsFrom: {_db.inkNotePages},
              )
              .get())
        r.read<String>('n'): r.read<int>('c'),
    };
    return [
      for (final r in rows)
        InkNotebookRecord(
          id: r.id,
          title: r.title,
          coverColor: r.coverColor,
          folderId: r.folderId,
          defaultTemplate: PageTemplate.fromKey(r.defaultTemplate),
          sortOrder: r.sortOrder,
          pageCount: counts[r.id] ?? 0,
          deleted: r.deleted,
          createdAt: r.createdAt,
          updatedAt: r.updatedAt,
        ),
    ];
  }

  Future<InkNotebookRecord?> findNotebook(String id) async =>
      (await notebooks(includeDeleted: true))
          .where((n) => n.id == id)
          .firstOrNull;

  /// Defter listesi; sayfa sayısı da değişince yenilenir.
  Stream<List<InkNotebookRecord>> watchNotebooks({
    bool includeDeleted = false,
  }) => _db
      .customSelect('SELECT 1', readsFrom: {_db.inkNotebooks, _db.inkNotePages})
      .watch()
      .asyncMap((_) => notebooks(includeDeleted: includeDeleted));

  Future<int> pageCount(String notebookId) async =>
      (await pages(notebookId)).length;

  // ───────────── Sayfalar ─────────────

  Future<List<InkNotePageRecord>> pages(
    String notebookId, {
    bool includeDeleted = false,
  }) async => [
    for (final r in await _pageRows(notebookId, includeDeleted: includeDeleted))
      _page(r),
  ];

  Stream<List<InkNotePageRecord>> watchPages(String notebookId) => _db
      .customSelect('SELECT 1', readsFrom: {_db.inkNotePages})
      .watch()
      .asyncMap((_) => pages(notebookId));

  Future<InkNotePageRecord?> findPage(String pageId) async {
    final r = await (_db.select(
      _db.inkNotePages,
    )..where((t) => t.id.equals(pageId))).getSingleOrNull();
    return r == null ? null : _page(r);
  }

  Future<List<InkNotePageRow>> _pageRows(
    String notebookId, {
    bool includeDeleted = false,
  }) =>
      (_db.select(_db.inkNotePages)
            ..where(
              (t) =>
                  t.notebookId.equals(notebookId) &
                  (includeDeleted
                      ? const Constant(true)
                      : t.deleted.equals(false)),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.createdAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// Sayfa ekler, kimliğini döner. [index]: silinmemiş sayfalar arasındaki yeri
  /// (boşsa sona; aralık dışı kırpılır). Şablon boşsa defterin varsayılanı.
  Future<String> addPage(
    String notebookId, {
    int? index,
    PageTemplate? template,
    double? width,
    double? height,
    int background = 0xFFFFFFFF,
  }) => _db.transaction(() async {
    final nb = await (_db.select(
      _db.inkNotebooks,
    )..where((t) => t.id.equals(notebookId))).getSingleOrNull();
    if (nb == null) throw StateError('Defter yok: $notebookId');
    // Boyut verilmezse defterin son sayfasının boyutu (yoksa A4) kullanılır.
    final last = (await _pageRows(notebookId)).lastOrNull;
    final w = width ?? last?.width ?? defaultPageWidth;
    final h = height ?? last?.height ?? defaultPageHeight;
    if (!(w > 0) || !(h > 0))
      throw ArgumentError('Sayfa boyutu pozitif olmalı');
    final id = _ids.next();
    final now = _clock();
    // Silinmişler dahil en büyük numaranın sonrası: numara yeniden kullanılmaz.
    final maxNo = await _db
        .customSelect(
          'SELECT COALESCE(MAX(page_no), -1) AS m FROM ink_note_pages WHERE notebook_id = ?',
          variables: [Variable<String>(notebookId)],
          readsFrom: {_db.inkNotePages},
        )
        .getSingle();
    await _db
        .into(_db.inkNotePages)
        .insert(
          InkNotePagesCompanion.insert(
            id: id,
            notebookId: notebookId,
            pageNo: maxNo.read<int>('m') + 1,
            template: Value(
              (template ?? PageTemplate.fromKey(nb.defaultTemplate)).key,
            ),
            width: Value(w),
            height: Value(h),
            background: Value(background),
            createdAt: now,
            updatedAt: now,
          ),
        );
    final order = [for (final r in await _pageRows(notebookId)) r.id]
      ..remove(id);
    order.insert((index ?? order.length).clamp(0, order.length), id);
    await _applyOrder(notebookId, order);
    return id;
  });

  /// Sayfayı hemen arkasına, çizgileriyle birlikte çoğaltır. Etiket/kişi bağları kopyalanmaz.
  /// Silinmiş sayfa çoğaltılamaz ([StateError]); önce geri getirilmeli.
  Future<String> duplicatePage(String pageId) => _db.transaction(() async {
    final src = await _requirePage(pageId);
    if (src.deleted) throw StateError('Silinmiş sayfa çoğaltılamaz');
    final visible = [for (final r in await _pageRows(src.notebookId)) r.id];
    final newId = await addPage(
      src.notebookId,
      index: visible.indexOf(pageId) + 1,
      template: PageTemplate.fromKey(src.template),
      width: src.width,
      height: src.height,
      background: src.background,
    );
    // v23: başlık kopyalanır; konu, alt sayfa bağı ve Pano konumu kopyalanmaz (kopya bağsız ve
    // yerleşmemiş başlar). Öğeler (metin/görsel) kopyalanır; görsel DOSYALARI paylaşılır.
    if (src.title != null) await _touchPage(newId, InkNotePagesCompanion(title: Value(src.title)));
    for (final it in await (_db.select(_db.inkPageItems)
          ..where((i) => i.pageId.equals(pageId) & i.deleted.equals(false))
          ..orderBy([(i) => OrderingTerm.asc(i.z), (i) => OrderingTerm.asc(i.createdAt), (i) => OrderingTerm.asc(i.id)]))
        .get()) {
      await _db.into(_db.inkPageItems).insert(it.toCompanion(false).copyWith(
            id: Value(_ids.next()),
            pageId: Value(newId),
            createdAt: Value(_clock()),
            updatedAt: Value(_clock()),
          ));
    }
    final newNo = (await _requirePage(newId)).pageNo;
    final now = _clock();
    final strokes =
        await (_db.select(_db.inkStrokes)
              ..where(
                (s) =>
                    s.noteId.equals(pageId) &
                    s.notePage.equals(src.pageNo) &
                    s.deleted.equals(false),
              )
              ..orderBy([
                (s) => OrderingTerm.asc(s.startedAtMs),
                (s) => OrderingTerm.asc(s.id),
              ]))
            .get();
    for (final s in strokes) {
      await _db
          .into(_db.inkStrokes)
          .insert(
            s
                .toCompanion(false)
                .copyWith(
                  id: Value(_ids.next()),
                  noteId: Value(newId),
                  notePage: Value(newNo),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
          );
    }
    return newId;
  });

  /// Silinmemiş sayfaların yeni sırası; [ids] hepsini içermeli.
  Future<void> reorderPages(String notebookId, List<String> ids) =>
      _db.transaction(() async {
        final visible = [for (final r in await _pageRows(notebookId)) r.id];
        if (!_sameSet(visible, ids))
          throw ArgumentError('Sıralama tüm sayfaları içermeli');
        await _applyOrder(notebookId, ids);
      });

  /// Sayfayı silinmemiş sayfalar arasında [toIndex]'e taşır (kırpılır).
  Future<void> movePage(String pageId, int toIndex) =>
      _db.transaction(() async {
        final p = await _requirePage(pageId);
        final order = [for (final r in await _pageRows(p.notebookId)) r.id];
        if (!order.remove(pageId)) throw StateError('Silinmiş sayfa taşınamaz');
        order.insert(toIndex.clamp(0, order.length), pageId);
        await _applyOrder(p.notebookId, order);
      });

  /// Yumuşak siler (çizgiler kalır). Defterin son sayfası silinemez ([StateError]).
  Future<void> deletePage(String pageId) => _db.transaction(() async {
    final p = await _requirePage(pageId);
    if (p.deleted) return;
    final visible = await _pageRows(p.notebookId);
    if (visible.length <= 1) throw StateError('Defterin son sayfası silinemez');
    await _touchPage(pageId, const InkNotePagesCompanion(deleted: Value(true)));
    await _applyOrder(p.notebookId, [
      for (final r in visible)
        if (r.id != pageId) r.id,
    ]);
  });

  /// Defterde görünür sayfa yoksa (iki cihaz son iki sayfayı ayrı sildi: "son sayfa
  /// silinemez" kuralı senkronda aşılabilir) en son silineni geri getirir, o da
  /// yoksa yeni sayfa ekler; döner: görünür kalan/oluşan sayfanın kimliği (zaten
  /// görünür sayfa varsa ilki, hiçbir şey değişmez).
  /// T6b: defter açılırken ve senkrondan sonra çağrılmalı (T6a'da çağıran yok).
  Future<String> ensureVisiblePage(String notebookId) =>
      _db.transaction(() async {
        await _requireNotebook(notebookId);
        final visible = await _pageRows(notebookId);
        if (visible.isNotEmpty) return visible.first.id;
        final all = await _pageRows(notebookId, includeDeleted: true);
        if (all.isEmpty) return addPage(notebookId);
        final last = all.reduce(
          (a, b) =>
              (b.updatedAt.isAfter(a.updatedAt) ||
                  (b.updatedAt == a.updatedAt && b.pageNo > a.pageNo))
              ? b
              : a,
        );
        await restorePage(last.id);
        return last.id;
      });

  /// Silinen sayfayı eski yerine yakın geri getirir.
  Future<void> restorePage(String pageId) => _db.transaction(() async {
    final p = await _requirePage(pageId);
    if (!p.deleted) return;
    await _touchPage(
      pageId,
      const InkNotePagesCompanion(deleted: Value(false)),
    );
    await _applyOrder(p.notebookId, [
      for (final r in await _pageRows(p.notebookId)) r.id,
    ]);
  });

  Future<void> setPageTemplate(String pageId, PageTemplate t) =>
      _touchPage(pageId, InkNotePagesCompanion(template: Value(t.key)));

  /// Sayfa boyutunu değiştirir. Büyütme her zaman güvenli; küçültme, mevcut
  /// çizgilerden herhangi biri yeni sınırın dışında kalacaksa [StateError]
  /// ile engellenir (çizgi kırpılmaz, silinmez).
  Future<void> setPageSize(String pageId, double width, double height) =>
      _db.transaction(() async {
        if (!(width > 0) || !(height > 0))
          throw ArgumentError('Sayfa boyutu pozitif olmalı');
        final p = await _requirePage(pageId);
        if (width < p.width || height < p.height) {
          final rows =
              await (_db.select(_db.inkStrokes)..where(
                    (s) =>
                        s.noteId.equals(pageId) &
                        s.notePage.equals(p.pageNo) &
                        s.deleted.equals(false),
                  ))
                  .get();
          var maxX = 0.0, maxY = 0.0;
          for (final r in rows) {
            for (final pt in StrokeCodec.decode(r.points)) {
              if (pt.x > maxX) maxX = pt.x;
              if (pt.y > maxY) maxY = pt.y;
            }
          }
          if (maxX > width || maxY > height) {
            throw StateError(
              'Sayfa küçültülemez: çizgilerin bir kısmı yeni sınırın dışında kalır.',
            );
          }
        }
        await _touchPage(
          pageId,
          InkNotePagesCompanion(width: Value(width), height: Value(height)),
        );
      });

  /// Sayfa başlığı; boş/boşluk metin null olur.
  Future<void> setPageTitle(String pageId, String? title) {
    final t = title?.trim();
    return _touchPage(pageId, InkNotePagesCompanion(title: Value(t == null || t.isEmpty ? null : t)));
  }

  Future<void> setPageBackground(String pageId, int argb) =>
      _touchPage(pageId, InkNotePagesCompanion(background: Value(argb)));

  /// Defterdeki tüm silinmemiş sayfaların şablonunu değiştirir.
  Future<void> setNotebookPagesTemplate(String notebookId, PageTemplate t) =>
      _db.transaction(() async {
        for (final r in await _pageRows(notebookId)) {
          if (r.template != t.key) await setPageTemplate(r.id, t);
        }
      });

  Future<InkNotePageRow> _requirePage(String id) async {
    final r = await (_db.select(
      _db.inkNotePages,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) throw StateError('Sayfa yok: $id');
    return r;
  }

  Future<void> _touchPage(String id, InkNotePagesCompanion c) async {
    final n =
        await (_db.update(_db.inkNotePages)..where((t) => t.id.equals(id)))
            .write(c.copyWith(updatedAt: Value(_clock())));
    if (n == 0) throw StateError('Sayfa yok: $id');
  }

  /// `sortOrder`'ı 0..n-1 yapar; yalnızca değişen satırı yazar (gereksiz defter kaydı olmasın).
  Future<void> _applyOrder(String notebookId, List<String> ids) async {
    final now = _clock();
    for (var i = 0; i < ids.length; i++) {
      await (_db.update(_db.inkNotePages)..where(
            (t) =>
                t.id.equals(ids[i]) &
                t.notebookId.equals(notebookId) &
                t.sortOrder.equals(i).not(),
          ))
          .write(
            InkNotePagesCompanion(sortOrder: Value(i), updatedAt: Value(now)),
          );
    }
  }

  InkNotePageRecord _page(InkNotePageRow r) => InkNotePageRecord(
    id: r.id,
    notebookId: r.notebookId,
    pageNo: r.pageNo,
    sortOrder: r.sortOrder,
    template: PageTemplate.fromKey(r.template),
    width: r.width,
    height: r.height,
    background: r.background,
    deleted: r.deleted,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    title: r.title,
    konuId: r.konuId,
    parentPageId: r.parentPageId,
    boardX: r.boardX,
    boardY: r.boardY,
    boardW: r.boardW,
    boardH: r.boardH,
  );

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length &&
      b.toSet().length == b.length &&
      a.toSet().containsAll(b);

  // ───────────── Anlık etiket ve kişi bağları ─────────────
  // Etiket (`tags`) ve kişi (`people`) Anlık'ın ortak tablolarıdır; ((etiket)) ve
  // @kişi çözümlemesi features/anlik'te kalır, burada yalnızca bağ yazılır.

  Future<void> addNotebookTag(
    String notebookId,
    String tagId, {
    String source = 'ben',
  }) async {
    await _requireNotebook(notebookId);
    await _db
        .into(_db.inkNotebookTags)
        .insert(
          InkNotebookTagsCompanion.insert(
            id: '$notebookId:$tagId',
            notebookId: notebookId,
            tagId: tagId,
            source: Value(source),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> removeNotebookTag(String notebookId, String tagId) =>
      (_db.delete(_db.inkNotebookTags)..where(
            (r) => r.notebookId.equals(notebookId) & r.tagId.equals(tagId),
          ))
          .go();

  Future<void> addNotebookPerson(
    String notebookId,
    String personId, {
    String source = 'ben',
  }) async {
    await _requireNotebook(notebookId);
    await _db
        .into(_db.inkNotebookPeople)
        .insert(
          InkNotebookPeopleCompanion.insert(
            id: '$notebookId:$personId',
            notebookId: notebookId,
            personId: personId,
            source: Value(source),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> removeNotebookPerson(String notebookId, String personId) =>
      (_db.delete(_db.inkNotebookPeople)..where(
            (r) =>
                r.notebookId.equals(notebookId) & r.personId.equals(personId),
          ))
          .go();

  Future<void> addPageTag(
    String pageId,
    String tagId, {
    String source = 'ben',
  }) async {
    await _requirePage(pageId);
    await _db
        .into(_db.inkPageTags)
        .insert(
          InkPageTagsCompanion.insert(
            id: '$pageId:$tagId',
            pageId: pageId,
            tagId: tagId,
            source: Value(source),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> removePageTag(String pageId, String tagId) => (_db.delete(
    _db.inkPageTags,
  )..where((r) => r.pageId.equals(pageId) & r.tagId.equals(tagId))).go();

  Future<void> addPagePerson(
    String pageId,
    String personId, {
    String source = 'ben',
  }) async {
    await _requirePage(pageId);
    await _db
        .into(_db.inkPagePeople)
        .insert(
          InkPagePeopleCompanion.insert(
            id: '$pageId:$personId',
            pageId: pageId,
            personId: personId,
            source: Value(source),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> removePagePerson(String pageId, String personId) => (_db.delete(
    _db.inkPagePeople,
  )..where((r) => r.pageId.equals(pageId) & r.personId.equals(personId))).go();

  Future<Set<String>> notebookTagIds(String notebookId) async => {
    for (final r in await (_db.select(
      _db.inkNotebookTags,
    )..where((t) => t.notebookId.equals(notebookId))).get())
      r.tagId,
  };

  Future<Set<String>> notebookPersonIds(String notebookId) async => {
    for (final r in await (_db.select(
      _db.inkNotebookPeople,
    )..where((t) => t.notebookId.equals(notebookId))).get())
      r.personId,
  };

  Future<Set<String>> pageTagIds(String pageId) async => {
    for (final r in await (_db.select(
      _db.inkPageTags,
    )..where((t) => t.pageId.equals(pageId))).get())
      r.tagId,
  };

  Future<Set<String>> pagePersonIds(String pageId) async => {
    for (final r in await (_db.select(
      _db.inkPagePeople,
    )..where((t) => t.pageId.equals(pageId))).get())
      r.personId,
  };

  /// Defter kimliği → etiket kimlikleri (defterin kendi etiketleri + sayfa etiketleri; silinmemiş
  /// defter ve sayfalar). Etiket çipleri ve etikete göre süzme bunu kullanır.
  Stream<Map<String, Set<String>>> watchNotebookTagMap() => _db
      .customSelect(
        'SELECT nt.notebook_id AS nb, nt.tag_id AS tag FROM ink_notebook_tags nt '
        'UNION SELECT p.notebook_id, pt.tag_id FROM ink_page_tags pt '
        'JOIN ink_note_pages p ON p.id = pt.page_id WHERE p.deleted = 0',
        readsFrom: {_db.inkNotebookTags, _db.inkPageTags, _db.inkNotePages},
      )
      .watch()
      .map((rows) {
        final out = <String, Set<String>>{};
        for (final r in rows) {
          (out[r.read<String>('nb')] ??= {}).add(r.read<String>('tag'));
        }
        return out;
      });

  /// Etikete bağlı silinmemiş defterler (defter ya da sayfası bağlıysa).
  Future<Set<String>> notebookIdsWithTag(String tagId) async {
    final rows = await _db
        .customSelect(
          'SELECT nt.notebook_id AS id FROM ink_notebook_tags nt WHERE nt.tag_id = ?1 '
          'UNION SELECT p.notebook_id FROM ink_page_tags pt JOIN ink_note_pages p ON p.id = pt.page_id '
          'WHERE pt.tag_id = ?1 AND p.deleted = 0',
          variables: [Variable<String>(tagId)],
          readsFrom: {_db.inkNotebookTags, _db.inkPageTags, _db.inkNotePages},
        )
        .get();
    final alive = {for (final n in await notebooks()) n.id};
    return {for (final r in rows) r.read<String>('id')}.intersection(alive);
  }

  Future<void> _requireNotebook(String id) async {
    final r = await (_db.select(
      _db.inkNotebooks,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) throw StateError('Defter yok: $id');
  }
}
