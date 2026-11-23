import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/page_template.dart';

class _Ids implements IdGenerator {
  _Ids([this.p = 'i']);
  final String p;
  var _n = 0;
  @override
  String next() => '$p${(_n++).toString().padLeft(3, '0')}';
}

const _pts = [StrokePoint(1, 2, pressure: 0.5, t: 0), StrokePoint(3, 4, pressure: 0.6, t: 9)];

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

Future<void> _tagAndPerson(AppDatabase db) async {
  await db.customStatement("INSERT INTO tags (id, name, label, source, created_at) VALUES ('t1', 'his', 'his', 'ben', 1)");
  await db.customStatement("INSERT INTO people (id, name, aliases, about, source, created_at) VALUES ('p1', 'Şule', '[]', '', 'ben', 1)");
}

void main() {
  late AppDatabase db;
  late InkNotebookRepository repo;
  var tick = 0;

  setUp(() async {
    db = await _open();
    tick = 0;
    repo = InkNotebookRepository(db, ids: _Ids(), clock: () => DateTime(2026, 1, 1).add(Duration(minutes: tick++)));
  });

  Future<List<String>> order(String nb) async => [for (final p in await repo.pages(nb)) p.id];

  test('defter oluştur: ilk sayfa varsayılan şablonla, A4 oranı; yeniden adlandır; sayfa sayısı', () async {
    final id = await repo.createNotebook(title: '  Tarih  ', defaultTemplate: PageTemplate.grid);
    final nb = (await repo.findNotebook(id))!;
    expect((nb.title, nb.pageCount, nb.defaultTemplate), ('Tarih', 1, PageTemplate.grid));
    final p = (await repo.pages(id)).single;
    expect((p.template, p.width, p.height, p.pageNo, p.sortOrder), (PageTemplate.grid, 1404.0, 1984.0, 0, 0));
    await repo.renameNotebook(id, 'Coğrafya');
    expect((await repo.findNotebook(id))!.title, 'Coğrafya');
    expect(() => repo.renameNotebook('yok', 'x'), throwsStateError);
    final empty = await repo.createNotebook(withFirstPage: false);
    expect((await repo.findNotebook(empty))!.pageCount, 0);
  });

  test('defter sıralama ve yumuşak silme/geri alma; sayfalar ve çizgiler durur', () async {
    final a = await repo.createNotebook(title: 'A');
    final b = await repo.createNotebook(title: 'B');
    final c = await repo.createNotebook(title: 'C');
    expect([for (final n in await repo.notebooks()) n.id], [a, b, c]);
    await repo.reorderNotebooks([c, a, b]);
    expect([for (final n in await repo.notebooks()) n.title], ['C', 'A', 'B']);
    expect(() => repo.reorderNotebooks([a, b]), throwsArgumentError);

    final page = (await repo.pages(a)).single;
    await InkStrokeRepository(db).add(owner: NotePageOwner(page.id, page.pageNo), points: _pts, startedAtMs: 1);
    await repo.deleteNotebook(a);
    expect([for (final n in await repo.notebooks()) n.id], [c, b]);
    expect((await repo.notebooks(includeDeleted: true)), hasLength(3));
    expect(await db.select(db.inkNotePages).get(), hasLength(3)); // satır durur
    expect(await db.select(db.inkStrokes).get(), hasLength(1));
    await repo.restoreNotebook(a);
    expect([for (final n in await repo.notebooks()) n.id], [c, a, b]);
  });

  test('sayfa ekle: sona, araya, numara hiç yeniden kullanılmaz', () async {
    final nb = await repo.createNotebook();
    final first = (await order(nb)).single;
    final p2 = await repo.addPage(nb);
    final p3 = await repo.addPage(nb, index: 1);
    final p4 = await repo.addPage(nb, index: 0, template: PageTemplate.plain, width: 700, height: 900, background: 0xFFFFF8E1);
    expect(await order(nb), [p4, first, p3, p2]);
    expect([for (final p in await repo.pages(nb)) p.sortOrder], [0, 1, 2, 3]);
    final pages = {for (final p in await repo.pages(nb)) p.id: p};
    expect([pages[first]!.pageNo, pages[p2]!.pageNo, pages[p3]!.pageNo, pages[p4]!.pageNo], [0, 1, 2, 3]);
    expect((pages[p4]!.template, pages[p4]!.width, pages[p4]!.background), (PageTemplate.plain, 700.0, 0xFFFFF8E1));
    expect(pages[p3]!.template, PageTemplate.ruled); // defter varsayılanı
    await repo.addPage(nb, index: 99); // kırpılır
    expect((await order(nb)).last, isNot(anyOf(p2, p3, p4)));
    // Silinen sayfanın numarası geri verilmez.
    await repo.deletePage(p2);
    final p6 = await repo.addPage(nb);
    expect((await repo.findPage(p6))!.pageNo, 5);
    expect(() => repo.addPage('yok'), throwsStateError);
    expect(() => repo.addPage(nb, width: 0), throwsArgumentError);
  });

  test('sayfa sırala/taşı; yanlış liste reddedilir; yalnızca değişen satır yazılır', () async {
    final nb = await repo.createNotebook();
    final a = (await order(nb)).single;
    final b = await repo.addPage(nb);
    final c = await repo.addPage(nb);
    await repo.reorderPages(nb, [c, a, b]);
    expect(await order(nb), [c, a, b]);
    await repo.movePage(c, 2);
    expect(await order(nb), [a, b, c]);
    await repo.movePage(a, -5);
    expect(await order(nb), [a, b, c]);
    expect(() => repo.reorderPages(nb, [a, b]), throwsArgumentError);
    expect(() => repo.reorderPages(nb, [a, a, b]), throwsArgumentError);
    final before = (await LedgerService(db).history()).length;
    await repo.reorderPages(nb, [a, b, c]); // değişiklik yok
    expect((await LedgerService(db).history()).length, before);
  });

  test('yumuşak sil / geri al: sıra eski yerine yakın; son sayfa silinmez', () async {
    final nb = await repo.createNotebook();
    final a = (await order(nb)).single;
    final b = await repo.addPage(nb);
    final c = await repo.addPage(nb);
    await repo.deletePage(b);
    expect(await order(nb), [a, c]);
    expect((await repo.findNotebook(nb))!.pageCount, 2);
    expect(await repo.pages(nb, includeDeleted: true), hasLength(3));
    await repo.restorePage(b);
    expect(await order(nb), [a, b, c]);
    await repo.deletePage(a);
    await repo.deletePage(b);
    expect(() => repo.deletePage(c), throwsStateError);
    await repo.deletePage(a); // zaten silinmiş: sessiz
    expect(() => repo.deletePage('yok'), throwsStateError);
    await repo.restorePage(c); // silinmemiş: sessiz
  });

  test('çoğalt: hemen arkaya, çizgilerle; yeni numara ve sayfa kimliği; silinmiş çizgi kopyalanmaz', () async {
    final nb = await repo.createNotebook();
    final a = (await order(nb)).single;
    final b = await repo.addPage(nb);
    await repo.setPageTemplate(a, PageTemplate.grid);
    await repo.setPageBackground(a, 0xFF112233);
    final strokes = InkStrokeRepository(db);
    await strokes.add(owner: const NotePageOwner('', 0), points: _pts, startedAtMs: 1); // başka sahip
    final s1 = await strokes.add(owner: NotePageOwner(a, 0), points: _pts, startedAtMs: 10, color: 0xFFFF0000);
    final s2 = await strokes.add(owner: NotePageOwner(a, 0), points: _pts, startedAtMs: 20);
    await strokes.softDelete(s2);
    final d = await repo.duplicatePage(a);
    expect(await order(nb), [a, d, b]);
    final dp = (await repo.findPage(d))!;
    expect((dp.template, dp.background, dp.pageNo), (PageTemplate.grid, 0xFF112233, 2));
    final copied = await strokes.forPage(NotePageOwner(d, dp.pageNo));
    expect(copied, hasLength(1));
    expect(copied.single.id, isNot(s1));
    expect((copied.single.color, copied.single.startedAtMs), (0xFFFF0000, 10));
    expect(copied.single.points, hasLength(2));
    expect(await strokes.forPage(NotePageOwner(a, 0)), hasLength(1)); // asıl dokunulmadı
  });

  test('şablon değiştir: sayfa, defter varsayılanı, hepsi', () async {
    final nb = await repo.createNotebook();
    final a = (await order(nb)).single;
    final b = await repo.addPage(nb);
    await repo.setPageTemplate(b, PageTemplate.plain);
    expect((await repo.findPage(b))!.template, PageTemplate.plain);
    await repo.setDefaultTemplate(nb, PageTemplate.grid);
    final c = await repo.addPage(nb);
    expect((await repo.findPage(c))!.template, PageTemplate.grid);
    expect((await repo.findPage(a))!.template, PageTemplate.ruled);
    await repo.setNotebookPagesTemplate(nb, PageTemplate.plain);
    expect((await repo.pages(nb)).every((p) => p.template == PageTemplate.plain), isTrue);
    expect(() => repo.setPageTemplate('yok', PageTemplate.grid), throwsStateError);
  });

  test('akışlar: defter listesi sayfa sayısıyla, sayfa listesi', () async {
    final counts = <int>[];
    final sub = repo.watchNotebooks().listen((l) => counts.add(l.isEmpty ? -1 : l.single.pageCount));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    final nb = await repo.createNotebook();
    await pumpEventQueue();
    final pageCounts = <int>[];
    final sub2 = repo.watchPages(nb).listen((l) => pageCounts.add(l.length));
    addTearDown(sub2.cancel);
    await pumpEventQueue();
    await repo.addPage(nb);
    await pumpEventQueue();
    expect(counts.last, 2);
    expect(counts.first, -1);
    expect(pageCounts.last, 2);
    expect(await repo.pageCount(nb), 2);
  });

  test('etiket ve kişi: defter ve sayfa düzeyi; çift bağ olmaz; kaldırma; etiket silinince bağ gider', () async {
    await _tagAndPerson(db);
    final nb = await repo.createNotebook();
    final page = (await order(nb)).single;
    await repo.addNotebookTag(nb, 't1');
    await repo.addNotebookTag(nb, 't1');
    await repo.addNotebookPerson(nb, 'p1');
    await repo.addPageTag(page, 't1');
    await repo.addPagePerson(page, 'p1', source: 'claude');
    expect(await repo.notebookTagIds(nb), {'t1'});
    expect(await repo.notebookPersonIds(nb), {'p1'});
    expect(await repo.pageTagIds(page), {'t1'});
    expect(await repo.pagePersonIds(page), {'p1'});
    expect(await db.select(db.inkNotebookTags).get(), hasLength(1));
    expect((await db.select(db.inkPagePeople).getSingle()).source, 'claude');
    expect(await repo.notebookIdsWithTag('t1'), {nb});
    await repo.removeNotebookTag(nb, 't1');
    expect(await repo.notebookTagIds(nb), isEmpty);
    expect(await repo.notebookIdsWithTag('t1'), {nb}); // sayfa etiketi yeter
    await repo.deleteNotebook(nb);
    expect(await repo.notebookIdsWithTag('t1'), isEmpty);
    await db.customStatement("DELETE FROM tags WHERE id = 't1'");
    expect(await repo.pageTagIds(page), isEmpty); // cascade
    await repo.removePagePerson(page, 'p1');
    expect(() => repo.addNotebookTag('yok', 't1'), throwsStateError);
    expect(() => repo.addPageTag('yok', 't1'), throwsStateError);
  });

  test('defter: yeni tablolar iki cihaza geçer, silme ve geri alma çalışır', () async {
    final b = await _open('pc');
    await _tagAndPerson(db);
    await _tagAndPerson(b);
    final la = LedgerService(db), lb = LedgerService(b);
    final nb = await repo.createNotebook(title: 'Fizik');
    final page = (await order(nb)).single;
    await repo.addNotebookTag(nb, 't1');
    await repo.addPagePerson(page, 'p1');
    await InkStrokeRepository(db).add(owner: NotePageOwner(page, 0), points: _pts, startedAtMs: 3);

    final res = await lb.applyRemote(await la.pendingFor(0));
    expect(res.applied, greaterThan(0));
    expect((await b.select(b.inkNotebooks).getSingle()).title, 'Fizik');
    expect((await b.select(b.inkNotePages).getSingle()).id, page);
    expect(await b.select(b.inkNotebookTags).get(), hasLength(1));
    expect(await b.select(b.inkPagePeople).get(), hasLength(1));
    expect(StrokeCodec.decode((await b.select(b.inkStrokes).getSingle()).points), hasLength(2));

    await repo.deleteNotebook(nb);
    await lb.applyRemote(await la.pendingFor(0));
    expect((await b.select(b.inkNotebooks).getSingle()).deleted, isTrue);
    expect((await b.select(b.inkNotePages).getSingle()).deleted, isFalse);

    final change = (await la.history()).firstWhere((c) => c.table == 'ink_notebooks' && c.op == 'degistir');
    await la.undoChange(change.id);
    expect((await db.select(db.inkNotebooks).getSingle()).deleted, isFalse);
  });

  test('bilgisayar birleştirici defteri, sayfaları ve bağları satır satır alır', () async {
    final dir = await Directory.systemTemp.createTemp('defter_birles');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tel.db');
    final phone = AppDatabase(NativeDatabase(file));
    await _tagAndPerson(phone);
    final prepo = InkNotebookRepository(phone, ids: _Ids('t'));
    final nb = await prepo.createNotebook(title: 'Telefondan');
    final p2 = await prepo.addPage(nb);
    await prepo.addNotebookTag(nb, 't1');
    await prepo.addNotebookPerson(nb, 'p1');
    await prepo.addPageTag(p2, 't1');
    await prepo.addPagePerson(p2, 'p1');
    await phone.close();

    final pc = await _open('pc');
    final merges = await SnapshotMerger(pc).merge(file);
    int added(String t) => merges.firstWhere((m) => m.table == t).added;
    expect([added('ink_notebooks'), added('ink_note_pages'), added('ink_notebook_tags'), added('ink_notebook_people')], [1, 2, 1, 1]);
    expect([added('ink_page_tags'), added('ink_page_people')], [1, 1]);
    expect((await InkNotebookRepository(pc).notebooks()).single.pageCount, 2);
    final again = await SnapshotMerger(pc).merge(file);
    expect(again.where((m) => m.table.startsWith('ink_n') || m.table.startsWith('ink_p')).fold<int>(0, (s, m) => s + m.added + m.updated), 0);
  });

  test('kocum aracı: duzelt ve sil-oner yeni tablolarda çalışır, hiçbir şey silinmez', () async {
    final pc = await _open('pc');
    final r = InkNotebookRepository(pc, ids: _Ids('c'));
    final nb = await r.createNotebook(title: 'Eski');
    final page = (await r.pages(nb)).single.id;
    Future<int> run(List<String> args) => runKocum(args,
        db: pc, out: (_) {}, err: (_) {}, now: () => DateTime(2026, 10, 20), env: const {}, ids: _Ids('k'));
    expect(await run(['duzelt', 'ink_notebooks', nb, 'title', 'Yeni']), 0);
    expect((await r.findNotebook(nb))!.title, 'Yeni');
    expect(await run(['duzelt', 'ink_note_pages', page, 'template', 'grid']), 0);
    expect((await r.findPage(page))!.template, PageTemplate.grid);
    expect(await run(['duzelt', 'ink_note_pages', page, 'width', '700.5']), 0);
    expect((await r.findPage(page))!.width, 700.5);
    expect(await run(['sil-oner', 'ink_notebooks', nb, '--neden', 'boş']), 0);
    expect(await pc.select(pc.silmeOnerileri).get(), hasLength(1));
    expect(await r.notebooks(), hasLength(1));
    final h = await LedgerService(pc).history();
    expect(h.where((c) => c.source == 'claude' && c.table == 'ink_notebooks'), isNotEmpty);
  });

  test('silinmiş sayfa çoğaltılamaz', () async {
    final nb = await repo.createNotebook();
    final a = (await repo.pages(nb)).single.id;
    await repo.addPage(nb);
    await repo.deletePage(a);
    expect(() => repo.duplicatePage(a), throwsStateError);
  });

  test('ensureVisiblePage: görünür sayfa varsa dokunmaz; yoksa en son silineni geri getirir; hiç yoksa ekler', () async {
    final nb = await repo.createNotebook();
    final a = (await repo.pages(nb)).single.id;
    expect(await repo.ensureVisiblePage(nb), a);
    final b = await repo.addPage(nb);
    // Senkronda iki cihaz son iki sayfayı ayrı sildi: depo kuralı aşılmış olur.
    await db.customStatement('UPDATE ink_note_pages SET deleted = 1');
    await db.customStatement("UPDATE ink_note_pages SET updated_at = updated_at + 10 WHERE id = '$b'");
    expect(await repo.pages(nb), isEmpty);
    expect(await repo.ensureVisiblePage(nb), b);
    expect(await order(nb), [b]);
    // Hiç sayfa yok (ya da hepsi yok): yeni sayfa eklenir.
    final empty = await repo.createNotebook(withFirstPage: false);
    final n = await repo.ensureVisiblePage(empty);
    expect(await order(empty), [n]);
    expect(() => repo.ensureVisiblePage('yok'), throwsStateError);
  });

  // ───────────── Göç ─────────────

  Future<void> migrate(int from) async {
    final dir = await Directory.systemTemp.createTemp('defter_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var d = AppDatabase(NativeDatabase(file));
    await d.customSelect('SELECT 1').get();
    await d.into(d.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));
    if (from >= 15) {
      await InkStrokeRepository(d).add(owner: const PdfPageOwner('d', 1), points: _pts, startedAtMs: 1);
    }
    final drop = [
      'ink_notebooks',
      'ink_note_pages',
      'ink_notebook_tags',
      'ink_notebook_people',
      'ink_page_tags',
      'ink_page_people',
      if (from < 16) 'pdf_documents',
      if (from < 15) 'ink_strokes',
      if (from < 14) 'silme_onerileri',
    ];
    for (final t in drop) {
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%$t%'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      await d.customStatement('DROP TABLE $t');
    }
    await d.customStatement('DROP INDEX IF EXISTS ix_defter_sayfa');
    if (from >= 15 && from < 18) {
      // Gerçek v15-17 şeması: ink_strokes question_id sütunu ve indeksi olmadan.
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'ink_strokes'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      await d.customStatement('DROP INDEX IF EXISTS ix_ink_question');
      await d.customStatement('ALTER TABLE ink_strokes DROP COLUMN question_id');
      final cols = {for (final c in await d.customSelect('PRAGMA table_info(ink_strokes)').get()) c.read<String>('name')};
      expect(cols.contains('question_id'), isFalse, reason: 'eski şema kurulamadı');
    }
    await d.customStatement('PRAGMA user_version = $from');
    await d.close();

    d = AppDatabase(NativeDatabase(file));
    addTearDown(d.close);
    final names = {for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
    expect(names, containsAll(['ink_notebooks', 'ink_note_pages', 'ink_notebook_tags', 'ink_notebook_people', 'ink_page_tags', 'ink_page_people', 'ink_strokes', 'pdf_documents']));
    expect((await d.select(d.anlikNotes).getSingle()).body, 'eski not');
    if (from >= 15) expect(await d.select(d.inkStrokes).get(), hasLength(1)); // eski çizgi bozulmadı
    final cols = {for (final c in await d.customSelect('PRAGMA table_info(ink_strokes)').get()) c.read<String>('name')};
    expect(cols, contains('question_id'));
    if (from >= 15) expect((await d.select(d.inkStrokes).getSingle()).questionId, isNull);
    expect(await d.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_ink_question'").get(), hasLength(1));
    expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 21);
    expect(await d.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_defter_sayfa'").get(), hasLength(1));
    // Yeni defter çalışır ve deftere yazılır.
    final r2 = InkNotebookRepository(d);
    final nb = await r2.createNotebook(title: 'Yeni');
    expect((await r2.pages(nb)), hasLength(1));
    final tables = (await LedgerService(d).history()).map((c) => c.table).toSet();
    expect(tables, containsAll(['ink_notebooks', 'ink_note_pages']));
  }

  test('v16 -> v19 göçü (question_id sütunu gerçekten eklenir)', () => migrate(16));
  test('v14 -> v19 göçü', () => migrate(14));
  test('v17 -> v19 göçü', () => migrate(17));
  test('v18 -> v19 göçü', () => migrate(18));

  test('sıfırdan kurulum: tablolar, indeksler, tetikleyiciler tamam', () async {
    final idx = await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'ix_defter_%'").get();
    expect(idx, hasLength(5));
    for (final t in ['ink_notebooks', 'ink_note_pages', 'ink_notebook_tags', 'ink_notebook_people', 'ink_page_tags', 'ink_page_people']) {
      expect(LedgerService(db).syncTables.any((x) => x.actualTableName == t), isTrue, reason: t);
    }
  });
}
