import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/handwriting/data/handwriting_service.dart';
import 'package:kocum/features/handwriting/data/page_text_repository.dart';
import 'package:kocum/features/handwriting/domain/transcript.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';

import '_helpers.dart';

class _Ids implements IdGenerator {
  _Ids([this.p = 'k']);
  final String p;
  var _n = 0;
  @override
  String next() => '$p${(_n++).toString().padLeft(3, '0')}';
}

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

const _pts = [StrokePoint(0, 0, t: 0), StrokePoint(20, 30, t: 10)];

void main() {
  late AppDatabase db;
  late PageTextRepository repo;
  late InkNotebookRepository nbs;
  late InkStrokeRepository strokes;
  var tick = 0;
  DateTime clock() => DateTime(2026, 1, 1).add(Duration(minutes: tick++));

  setUp(() async {
    db = await _open();
    tick = 0;
    repo = PageTextRepository(db, clock: clock);
    nbs = InkNotebookRepository(db, ids: _Ids('n'), clock: clock);
    strokes = InkStrokeRepository(db, ids: _Ids('s'), clock: clock);
  });

  Future<({String nb, String page})> newBook(String title) async {
    final nb = await nbs.createNotebook(title: title);
    final page = (await nbs.pages(nb)).first;
    return (nb: nb, page: page.id);
  }

  Future<String> addStroke(String page) =>
      strokes.add(owner: NotePageOwner(page, 1), points: _pts, startedAtMs: 0);

  test('kaydet, oku, düzelt; çizgiler hiç silinmez', () async {
    final b = await newBook('Fizik');
    final s1 = await addStroke(b.page);
    final sig = await repo.currentSig(b.page);
    await repo.save(
      pageId: b.page,
      text: 'Newton',
      lines: const [TranscriptLine(text: 'Newton', strokeIds: ['x'], left: 0, top: 0, right: 10, bottom: 10)],
      strokeSig: sig,
    );
    final last = await repo.get(b.page);
    expect(last!.text, 'Newton');
    expect(last.lines.single.strokeIds, ['x']);
    expect(last.languageCode, 'tr-TR');
    expect(await repo.updateText(b.page, 'Newton kanunu'), isTrue);
    expect((await repo.get(b.page))!.text, 'Newton kanunu');
    expect((await repo.get(b.page))!.strokeSig, sig); // düzeltme özeti değiştirmez
    expect(await repo.updateText('yok', 'x'), isFalse);
    expect(await db.select(db.inkPageText).get(), hasLength(1)); // sayfa başına tek satır
    // Orijinal çizgi durur.
    final st = await strokes.forPage(NotePageOwner(b.page, 1), attemptNo: 0, layer: 0, noQuestion: true);
    expect([for (final s in st) s.id], [s1]);
  });

  test('yeniden kaydetme aynı satırı günceller; yumuşak sil ve geri al', () async {
    final b = await newBook('A');
    await repo.save(pageId: b.page, text: 'bir', lines: const [], strokeSig: '');
    await repo.save(pageId: b.page, text: 'iki', lines: const [], strokeSig: '');
    expect(await db.select(db.inkPageText).get(), hasLength(1));
    expect((await repo.get(b.page))!.text, 'iki');
    expect(await repo.softDelete(b.page), isTrue);
    expect(await repo.get(b.page), isNull);
    expect(await db.select(db.inkPageText).get(), hasLength(1)); // satır durur
    expect(await repo.restore(b.page), isTrue);
    expect((await repo.get(b.page))!.text, 'iki');
    await repo.softDelete(b.page);
    await repo.save(pageId: b.page, text: 'üç', lines: const [], strokeSig: ''); // kaydetmek geri getirir
    expect((await repo.get(b.page))!.text, 'üç');
  });

  test('güncel değil: çizgi eklenince, taşınınca, silinince işaretlenir; metin yoksa değil', () async {
    final b = await newBook('A');
    expect(await repo.isStale(b.page), isFalse); // kayıt yok
    final s1 = await addStroke(b.page);
    await repo.save(pageId: b.page, text: 't', lines: const [], strokeSig: await repo.currentSig(b.page));
    expect(await repo.isStale(b.page), isFalse);
    // Yeni çizgi.
    final s2 = await addStroke(b.page);
    expect(await repo.isStale(b.page), isTrue);
    // Yeniden tanıyınca güncel.
    await repo.save(pageId: b.page, text: 't', lines: const [], strokeSig: await repo.currentSig(b.page));
    expect(await repo.isStale(b.page), isFalse);
    // Taşıma (noktalar yerinde güncellenir, updatedAt değişir).
    await strokes.updatePoints({s1: const [StrokePoint(5, 5, t: 0), StrokePoint(30, 40, t: 10)]});
    expect(await repo.isStale(b.page), isTrue);
    await repo.save(pageId: b.page, text: 't', lines: const [], strokeSig: await repo.currentSig(b.page));
    // Silme.
    await strokes.softDelete(s2);
    expect(await repo.isStale(b.page), isTrue);
  });

  test('izleme: kayıt ve silme akışa yansır; defter metinleri sırayla', () async {
    final b = await newBook('A');
    final p2 = await nbs.addPage(b.nb);
    final seen = <String?>[];
    final sub = repo.watch(b.page).listen((r) => seen.add(r?.text));
    addTearDown(sub.cancel);
    Future<void> pump() => Future.delayed(const Duration(milliseconds: 30));
    await pump();
    await repo.save(pageId: b.page, text: 'ilk', lines: const [], strokeSig: '');
    await pump();
    await repo.softDelete(b.page);
    await pump();
    expect(seen, [null, 'ilk', null]);
    await repo.restore(b.page);
    await repo.save(pageId: p2, text: 'ikinci', lines: const [], strokeSig: '');
    final n = await repo.notebookTexts(b.nb);
    expect([for (final e in n) (e.pageNumber, e.text?.text)], [(1, 'ilk'), (2, 'ikinci')]);
    // Silinen sayfa listede yok.
    await nbs.deletePage(p2);
    expect((await repo.notebookTexts(b.nb)), hasLength(1));
  });

  test('arama: Türkçe büyük/küçük harf, İ/ı ve aksan duyarsız; silinen defter/sayfa yok', () async {
    final a = await newBook('Fizik');
    final c = await newBook('Kimya');
    final a2 = await nbs.addPage(a.nb);
    await repo.save(pageId: a.page, text: 'Isıl denge ve SICAKLIK', lines: const [], strokeSig: '');
    await repo.save(pageId: a2, text: 'İş ve enerji\nkinetik enerji', lines: const [], strokeSig: '');
    await repo.save(pageId: c.page, text: 'Mol kavramı', lines: const [], strokeSig: '');
    var hits = await repo.search('sicaklik');
    expect([for (final h in hits) (h.notebookId, h.pageNumber)], [(a.nb, 1)]);
    expect(hits.single.snippet, contains('SICAKLIK'));
    hits = await repo.search('ENERJİ');
    expect([for (final h in hits) (h.notebookId, h.pageNumber, h.pageId)], [(a.nb, 2, a2)]);
    expect([for (final h in await repo.search('isil')) h.pageNumber], [1]); // "Isıl" ~ "isil"
    expect(await repo.search('  '), isEmpty);
    expect(await repo.search('yok böyle'), isEmpty);
    await nbs.deletePage(a2);
    expect(await repo.search('enerji'), isEmpty);
    await nbs.deleteNotebook(c.nb);
    expect(await repo.search('mol'), isEmpty);
    await repo.softDelete(a.page);
    expect(await repo.search('sicaklik'), isEmpty);
  });

  test('HandwritingService: sayfayı tanır, kaydeder; yalnız seçili çizgiler; çizgiler değişmez', () async {
    final b = await newBook('A');
    final page = (await nbs.pages(b.nb)).first;
    final ids = <String>[];
    for (var i = 0; i < 3; i++) {
      ids.add(await strokes.add(
        owner: NotePageOwner(page.id, page.pageNo),
        points: [StrokePoint(100.0 + i * 40, 100, t: 0), StrokePoint(130.0 + i * 40, 140, t: 20)],
        startedAtMs: i,
      ));
    }
    final rec = FakeRecognizer(['abc']);
    final svc = HandwritingService(rec, strokes, repo);
    final r = await svc.recognizePage(page);
    expect(r.transcription.text, 'abc');
    expect(r.strokeSig, await repo.currentSig(page.id));
    await svc.savePage(page.id, r);
    expect((await repo.get(page.id))!.text, 'abc');
    expect(await repo.isStale(page.id), isFalse);
    // Seçim: yalnız ilk iki çizgi tanıyıcıya gider.
    final rec2 = FakeRecognizer(['ab']);
    final sel = await HandwritingService(rec2, strokes, repo).recognizePage(page, onlyIds: {ids[0], ids[1]});
    expect(sel.transcription.lines.single.strokeIds, [ids[0], ids[1]]);
    expect(rec2.calls.single.strokes, hasLength(2));
    // Hiçbir çizgi silinmedi ya da değişmedi.
    expect(await strokes.forPage(NotePageOwner(page.id, page.pageNo), attemptNo: 0, layer: 0, noQuestion: true), hasLength(3));
  });

  test('defter: metin iki cihaza geçer; ikinci cihazın düzeltmesi geri döner', () async {
    final pc = await _open('pc');
    final la = LedgerService(db), lb = LedgerService(pc);
    final b = await newBook('A');
    await repo.save(pageId: b.page, text: 'telefon metni', lines: const [], strokeSig: 'sig1');
    final res = await lb.applyRemote(await la.pendingFor(0));
    expect(res.applied, greaterThan(0));
    final r = await pc.select(pc.inkPageText).getSingle();
    expect((r.id, r.pageId, r.body, r.strokeSig, r.deleted), (b.page, b.page, 'telefon metni', 'sig1', false));
    // Bilgisayar yalnız okur/düzeltir: kayıtlı metin görünür ve aranır.
    final pcRepo = PageTextRepository(pc, clock: clock);
    expect((await pcRepo.get(b.page))!.text, 'telefon metni');
    await pcRepo.updateText(b.page, 'düzeltilmiş');
    await la.applyRemote(await lb.pendingFor(0));
    expect((await repo.get(b.page))!.text, 'düzeltilmiş');
    final change = (await la.history()).firstWhere((c) => c.table == 'ink_page_text');
    expect(change.table, 'ink_page_text');
  });

  test('bilgisayar birleştirici metni satır satır alır, tekrar çalıştırınca değişmez', () async {
    final dir = await Directory.systemTemp.createTemp('metin_birles');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tel.db');
    final phone = AppDatabase(NativeDatabase(file));
    await PageTextRepository(phone, clock: clock).save(pageId: 'pg1', text: 'merhaba', lines: const [], strokeSig: 's');
    await phone.close();
    final pc = await _open('pc');
    final merges = await SnapshotMerger(pc).merge(file);
    expect(merges.firstWhere((m) => m.table == 'ink_page_text').added, 1);
    expect((await PageTextRepository(pc).get('pg1'))!.text, 'merhaba');
    final again = await SnapshotMerger(pc).merge(file);
    expect(again.where((m) => m.table == 'ink_page_text').fold<int>(0, (s, m) => s + m.added + m.updated), 0);
  });

  test('kocum aracı: duzelt metin satırında çalışır (otomatik kapsam)', () async {
    final pc = await _open('pc');
    await PageTextRepository(pc, clock: clock).save(pageId: 'pg', text: 'eski', lines: const [], strokeSig: '');
    final code = await runKocum(['duzelt', 'ink_page_text', 'pg', 'body', 'yeni'],
        db: pc, out: (_) {}, err: (_) {}, now: () => DateTime(2026, 10, 20), env: const {}, ids: _Ids('k'));
    expect(code, 0);
    expect((await PageTextRepository(pc).get('pg'))!.text, 'yeni');
  });

  // ───────────── Göç ─────────────

  Future<void> migrate(int from) async {
    final dir = await Directory.systemTemp.createTemp('metin_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var d = AppDatabase(NativeDatabase(file));
    await d.customSelect('SELECT 1').get();
    await d.into(d.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));
    final drop = [
      'ink_page_text',
      if (from < 20) 'pdf_page_layers',
      if (from < 19) ...['ink_notebooks', 'ink_note_pages', 'ink_notebook_tags', 'ink_notebook_people', 'ink_page_tags', 'ink_page_people'],
      if (from < 16) 'pdf_documents',
      if (from < 15) 'ink_strokes',
    ];
    for (final t in drop) {
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%$t%'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      await d.customStatement('DROP TABLE $t');
    }
    await d.customStatement('DROP INDEX IF EXISTS ix_page_text_page');
    await d.customStatement('DROP INDEX IF EXISTS ix_pdf_layer_doc');
    await d.customStatement('DROP INDEX IF EXISTS ix_defter_sayfa');
    await d.customStatement('PRAGMA user_version = $from');
    await d.close();

    d = AppDatabase(NativeDatabase(file));
    addTearDown(d.close);
    final names = {for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
    expect(names, contains('ink_page_text'));
    expect((await d.select(d.anlikNotes).getSingle()).body, 'eski not');
    expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 23);
    expect(await d.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_page_text_page'").get(), hasLength(1));
    final r2 = PageTextRepository(d);
    await r2.save(pageId: 'p', text: 'm', lines: const [], strokeSig: '');
    expect((await r2.get('p'))!.text, 'm');
    expect((await LedgerService(d).history()).map((c) => c.table), contains('ink_page_text')); // tetikleyici kuruldu
  }

  test('v14 -> v21 göçü', () => migrate(14));
  test('v17 -> v21 göçü', () => migrate(17));
  test('v19 -> v21 göçü', () => migrate(19));
  test('v20 -> v21 göçü', () => migrate(20));

  test('sıfırdan kurulum: indeks ve tetikleyiciler tamam', () async {
    expect(await db.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_page_text_page'").get(), hasLength(1));
    expect(await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'ink_page_text'").get(), isNotEmpty);
  });
}
