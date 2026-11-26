import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/features/pdf/data/pdf_document_repository.dart';
import 'package:kocum/features/pdf/data/pdf_import_service.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/pdf_import_rules.dart';

import 'pdf_test_support.dart';

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

Future<void> _book(AppDatabase db, String id, String title) => db.into(db.books).insert(BooksCompanion.insert(
    id: id, title: title, examType: 'TYT', subject: 'Matematik', pageCount: 100, avgQuestionsPerPage: 5, createdAt: DateTime(2026)));

String _h(String c) => c * 64;

class _FailingRepo extends PdfDocumentRepository {
  _FailingRepo(super.db);
  @override
  Future<PdfDocumentRecord> add({required String sha256, required String title, required int pageCount, required String fileName}) =>
      throw StateError('ekleme başarısız');
}

void main() {
  late Directory tmp;
  late FakePdfEngine engine;
  late AppDatabase db;
  late PdfDocumentRepository repo;
  late PdfImportService svc;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pdf_ice');
    addTearDown(() => tmp.delete(recursive: true));
    engine = FakePdfEngine();
    db = await _open();
    repo = PdfDocumentRepository(db);
    svc = PdfImportService(engine: engine, repository: repo, pdfDir: Directory('${tmp.path}/veri/pdfs'));
  });

  Future<File> src(String name, List<int> bytes) => File('${tmp.path}/$name').writeAsBytes(bytes);

  test('içe aktarma: pdfs/<sha256>.pdf, sayfa sayısı motordan, başlık dosya adından', () async {
    final f = await src('TYT_Matematik.pdf', FakePdfEngine.bytes(12));
    final r = await svc.importFile(f);
    expect(r.alreadyImported, isFalse);
    expect(r.document.pageCount, 12);
    expect(r.document.title, 'TYT Matematik');
    expect(r.document.id, r.document.sha256);
    expect(r.document.sha256, await PdfImportService.sha256OfFile(f));
    expect(svc.fileOf(r.document).path.endsWith('pdfs/${r.document.sha256}.pdf'), isTrue);
    expect(svc.hasFile(r.document), isTrue);
    expect(engine.closed, engine.opened); // belge kapandı
    expect(Directory('${tmp.path}/veri/pdfs').listSync().whereType<File>().map((e) => e.path.split('/').last),
        ['${r.document.sha256}.pdf']); // .part kalmadı
  });

  test('aynı içerik (başka adla) yeniden kopyalanmaz, mevcut belge döner', () async {
    final a = await svc.importFile(await src('a.pdf', FakePdfEngine.bytes(5)));
    final opened = engine.opened;
    final b = await svc.importFile(await src('baska_ad.pdf', FakePdfEngine.bytes(5)));
    expect(b.alreadyImported, isTrue);
    expect(b.document.id, a.document.id);
    expect(engine.opened, opened); // motor yeniden açılmadı
    expect(await repo.list(), hasLength(1));
  });

  test('farklı içerik ayrı belge', () async {
    await svc.importFile(await src('a.pdf', FakePdfEngine.bytes(5)));
    await svc.importFile(await src('b.pdf', FakePdfEngine.bytes(6)));
    expect(await repo.list(), hasLength(2));
  });

  test('bozuk PDF: hata, klasörde ve veritabanında iz kalmaz', () async {
    await expectLater(svc.importFile(await src('x.pdf', [1, 2, 3])), throwsA(isA<PdfOpenException>()));
    expect(await repo.list(includeDeleted: true), isEmpty);
    final dir = Directory('${tmp.path}/veri/pdfs');
    expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
  });

  test('satır var ama dosya bu cihazda yok (başka cihazdan geldi): dosya yazılır', () async {
    final f = await src('a.pdf', FakePdfEngine.bytes(5));
    final sha = await PdfImportService.sha256OfFile(f);
    await repo.add(sha256: sha, title: 'Senkrondan', pageCount: 5, fileName: 'x.pdf');
    final r = await svc.importFile(f);
    expect(r.alreadyImported, isTrue);
    expect(r.document.title, 'Senkrondan'); // var olan satır korunur
    expect(svc.hasFile(r.document), isTrue);
    expect(await repo.list(), hasLength(1));
  });

  test('silinmiş belge yeniden içe aktarılınca geri gelir; bağ ve ofset durur', () async {
    await _book(db, 'k1', 'TYT Matematik');
    final r = await svc.importFile(await src('a.pdf', FakePdfEngine.bytes(5)));
    final id = r.document.id;
    await repo.linkBook(id, 'k1');
    await repo.setOffset(id, -3);
    expect(await repo.softDelete(id), isTrue);
    expect(await repo.softDelete(id), isFalse);
    expect(await repo.list(), isEmpty);
    expect(await repo.findBySha(id), isNull);
    expect(await db.select(db.pdfDocuments).get(), hasLength(1)); // satır durur
    expect(File(svc.fileOf(r.document).path).existsSync(), isTrue); // dosya silinmez

    final again = await svc.importFile(await src('a2.pdf', FakePdfEngine.bytes(5)));
    expect(again.document.deleted, isFalse);
    expect((again.document.bookId, again.document.pageOffset), ('k1', -3));
    expect(await repo.list(), hasLength(1));
  });

  test('depo: kitaba bağla/kopar, ofset, yeniden adlandır, bilinmeyen kimlik', () async {
    await _book(db, 'k1', 'Kitap');
    final id = (await svc.importFile(await src('a.pdf', FakePdfEngine.bytes(5)))).document.id;
    expect(await repo.linkBook(id, 'k1'), isTrue);
    expect((await repo.findBySha(id))!.bookId, 'k1');
    expect(await repo.linkBook(id, null), isTrue);
    expect((await repo.findBySha(id))!.bookId, isNull);
    expect(await repo.setOffset(id, 4), isTrue);
    expect((await repo.findBySha(id))!.pageOffset, 4);
    expect(await repo.rename(id, '  Yeni ad '), isTrue);
    expect(await repo.rename(id, '   '), isFalse);
    expect((await repo.findBySha(id))!.title, 'Yeni ad');
    expect(await repo.linkBook('yok', 'k1'), isFalse);
    expect(await repo.setOffset('yok', 1), isFalse);
  });

  test('eşleme önerisi döner ama otomatik bağlanmaz; bağlıysa öneri yok', () async {
    await _book(db, 'k1', 'TYT Matematik Soru Bankası');
    await _book(db, 'k2', 'AYT Fizik');
    final r = await svc.importFile(await src('TYT_Matematik_Soru_Bankası.pdf', FakePdfEngine.bytes(5)));
    expect(r.suggestions.first.bookId, 'k1');
    expect(r.document.bookId, isNull);
    expect((await repo.findBySha(r.document.id))!.bookId, isNull);
    await repo.linkBook(r.document.id, 'k1');
    final again = await svc.importFile(await src('b.pdf', FakePdfEngine.bytes(5)));
    expect(again.suggestions, isEmpty);
  });

  test('akış: ekleme ve silme izlenir', () async {
    final seen = <int>[];
    final sub = repo.watchAll().listen((l) => seen.add(l.length));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    final id = (await svc.importFile(await src('a.pdf', FakePdfEngine.bytes(5)))).document.id;
    await pumpEventQueue();
    await repo.softDelete(id);
    await pumpEventQueue();
    expect(seen, [0, 1, 0]);
  });

  test('defter: satır karşıya geçer (id = sha256), dosya geçmez; silme ve geri alma', () async {
    final a = await _open('telefon');
    final b = await _open('pc');
    final ra = PdfDocumentRepository(a);
    final rec = await ra.add(sha256: _h('a'), title: 'T', pageCount: 7, fileName: 'f.pdf');
    await ra.setOffset(rec.id, 5);
    await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
    final got = await b.select(b.pdfDocuments).getSingle();
    expect((got.id, got.sha256, got.pageCount, got.pageOffset), (_h('a'), _h('a'), 7, 5));

    await ra.softDelete(rec.id);
    await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
    expect((await b.select(b.pdfDocuments).getSingle()).deleted, isTrue);

    final la = LedgerService(a);
    final change = (await la.history()).firstWhere((c) => c.table == 'pdf_documents' && c.op == 'degistir');
    await la.undoChange(change.id);
    expect((await a.select(a.pdfDocuments).getSingle()).deleted, isFalse);
  });

  test('aynı sha256: ikinci ekleme yeni satır açmaz; id != sha256 satırı CHECK ile reddedilir', () async {
    final a = await _open('telefon');
    final ra = PdfDocumentRepository(a);
    await ra.add(sha256: _h('c'), title: 'T', pageCount: 3, fileName: 'f');
    await ra.add(sha256: _h('c'), title: 'T2', pageCount: 3, fileName: 'g');
    final rows = await a.select(a.pdfDocuments).get();
    expect(rows, hasLength(1));
    expect(rows.single.title, 'T'); // var olan satır korunur
    await expectLater(
        a.into(a.pdfDocuments).insert(PdfDocumentsCompanion.insert(
            id: 'baska', sha256: _h('c'), title: 'T', pageCount: 1, fileName: 'f', createdAt: DateTime(2026), updatedAt: DateTime(2026))),
        throwsA(anything));
  });

  test('defter: id != sha256 gelen satır uygulanmaz, Çakışmalar\'a düşer, kalan değişiklikler uygulanır', () async {
    final b = await _open('pc');
    String row(String id, String sha) => jsonEncode({
          'id': id, 'sha256': sha, 'title': 'T', 'page_count': 1, 'file_name': 'f', 'book_id': null,
          'page_offset': 0, 'deleted': 0, 'created_at': 1, 'updated_at': 1,
        });
    LedgerChange ch(String cid, String id, String sha, String clock) => LedgerChange(
        id: cid, device: 'uzak', source: 'telefon', table: 'pdf_documents', rowId: id, op: 'ekle', clock: clock, neu: row(id, sha));
    final r = await LedgerService(b).applyRemote([
      ch('c1', 'bozuk', _h('d'), '0000000000001-0000-uzak'),
      ch('c2', _h('e'), _h('e'), '0000000000002-0000-uzak'),
    ]);
    expect((r.failed, r.applied), (1, 1));
    expect((await b.select(b.pdfDocuments).get()).map((e) => e.id), [_h('e')]);
    final c = await b.select(b.cakismalar).get();
    expect(c.single.tablo, 'pdf_documents');
    expect(c.single.satirId, 'bozuk');
    expect(c.single.kaybeden, isNotNull);
    // Senkron takılmadı: aynı toplu yeniden gelirse yinelenen sayılır.
    expect((await LedgerService(b).applyRemote([ch('c1', 'bozuk', _h('d'), '0000000000001-0000-uzak')])).duplicates, 1);
  });

  test('iki cihaz aynı PDF\'i senkrondan önce ayrı içe aktarır: tek satır, kaybeden Çakışmalar\'da (alan birleştirme yok)', () async {
    final a = await _open('telefon');
    final b = await _open('pc');
    final ra = PdfDocumentRepository(a);
    final rb = PdfDocumentRepository(b);
    await ra.add(sha256: _h('f'), title: 'T', pageCount: 4, fileName: 'f');
    await ra.linkBook(_h('f'), 'k1');
    await rb.add(sha256: _h('f'), title: 'T', pageCount: 4, fileName: 'f');
    await rb.setOffset(_h('f'), 7);
    final r = await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
    expect(r.conflicts, greaterThan(0));
    expect(await b.select(b.pdfDocuments).get(), hasLength(1));
    // Kazanan HLC'ye göre tümden yazılır; her iki sürümün izi kaybolmaz.
    expect((await b.select(b.cakismalar).get()), isNotEmpty);
  });

  test('sha256 doğrulaması: fileOf, storedFileName ve add geçersiz kimliği reddeder (yol çıkışı yok)', () async {
    final bad = ['../../etc/passwd', 'abc', 'A' * 64, '${'a' * 63}/', ''];
    for (final s in bad) {
      expect(() => storedFileName(s), throwsArgumentError, reason: s);
      expect(() => svc.fileOf(PdfDocumentRecord(id: s, sha256: s, title: 't', pageCount: 1, fileName: 'f', pageOffset: 0, deleted: false)),
          throwsArgumentError,
          reason: s);
      await expectLater(repo.add(sha256: s, title: 't', pageCount: 1, fileName: 'f'), throwsArgumentError);
    }
    expect(storedFileName(_h('a')), '${_h('a')}.pdf');
    expect(await repo.list(includeDeleted: true), isEmpty);
  });

  test('başlık: kırpılır, 300 karakterle sınırlanır, boşsa PDF', () async {
    final a = await repo.add(sha256: _h('1'), title: '  Ad  ', pageCount: 1, fileName: 'f');
    expect(a.title, 'Ad');
    final b = await repo.add(sha256: _h('2'), title: 'x' * 400, pageCount: 1, fileName: 'f');
    expect(b.title.length, 300);
    final c = await repo.add(sha256: _h('3'), title: '   ', pageCount: 1, fileName: 'f');
    expect(c.title, 'PDF');
    await repo.rename(a.id, 'y' * 500);
    expect((await repo.findBySha(a.id))!.title.length, 300);
  });

  test('satır eklenemezse yeni yazılan dosya silinir; önceden var olan dosya silinmez', () async {
    final failing = _FailingRepo(db);
    final s2 = PdfImportService(engine: engine, repository: failing, pdfDir: Directory('${tmp.path}/veri/pdfs'));
    final f = await src('a.pdf', FakePdfEngine.bytes(5));
    final sha = await PdfImportService.sha256OfFile(f);
    final target = File('${tmp.path}/veri/pdfs/$sha.pdf');

    await expectLater(s2.importFile(f), throwsStateError);
    expect(target.existsSync(), isFalse);
    expect(Directory('${tmp.path}/veri/pdfs').listSync(), isEmpty);

    // Dosya önceden var (satır yok): hata olsa da dosya kalır.
    await target.writeAsBytes(FakePdfEngine.bytes(5));
    await expectLater(s2.importFile(f), throwsStateError);
    expect(target.existsSync(), isTrue);
    expect(Directory('${tmp.path}/veri/pdfs').listSync().whereType<File>().map((e) => e.path.split('/').last), ['$sha.pdf']);
  });

  test('özet .part kopyasından: içerik ve ad uyuşur; çift içe aktarma yarışı tek satır tek dosya', () async {
    final f1 = await src('a.pdf', FakePdfEngine.bytes(5));
    final f2 = await src('b.pdf', FakePdfEngine.bytes(5));
    final rs = await Future.wait([svc.importFile(f1), svc.importFile(f2)]);
    expect(rs.map((e) => e.document.id).toSet(), hasLength(1));
    expect(rs.where((e) => e.alreadyImported), hasLength(1));
    expect(await repo.list(includeDeleted: true), hasLength(1));
    final files = Directory('${tmp.path}/veri/pdfs').listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(await PdfImportService.sha256OfFile(files.single), rs.first.document.id);
  });

  Future<void> migrate(int from) async {
    final dir = await Directory.systemTemp.createTemp('pdf_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var d = AppDatabase(NativeDatabase(file));
    await d.customSelect('SELECT 1').get();
    await d.into(d.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));
    for (final t in ['pdf_documents', if (from < 15) 'ink_strokes', if (from < 14) 'silme_onerileri']) {
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%$t%'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      await d.customStatement('DROP TABLE $t');
    }
    await d.customStatement('PRAGMA user_version = $from');
    await d.close();

    d = AppDatabase(NativeDatabase(file));
    addTearDown(d.close);
    final names = {for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
    expect(names, containsAll(['pdf_documents', 'ink_strokes']));
    expect((await d.select(d.anlikNotes).getSingle()).body, 'eski not');
    expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 23);
    // Tetikleyici kurulu: yeni belge deftere yazılır.
    await PdfDocumentRepository(d).add(sha256: _h('b'), title: 'T', pageCount: 1, fileName: 'f');
    expect((await LedgerService(d).history()).any((c) => c.table == 'pdf_documents'), isTrue);
  }

  test('v15 -> v17 göçü', () => migrate(15));
  test('v14 -> v17 göçü', () => migrate(14));
}
