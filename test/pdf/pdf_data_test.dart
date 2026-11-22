import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/features/pdf/data/pdf_document_repository.dart';
import 'package:kocum/features/pdf/data/pdf_import_service.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';

import 'pdf_test_support.dart';

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

Future<void> _book(AppDatabase db, String id, String title) => db.into(db.books).insert(BooksCompanion.insert(
    id: id, title: title, examType: 'TYT', subject: 'Matematik', pageCount: 100, avgQuestionsPerPage: 5, createdAt: DateTime(2026)));

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
    final rec = await ra.add(sha256: 'abc123', title: 'T', pageCount: 7, fileName: 'f.pdf');
    await ra.setOffset(rec.id, 5);
    await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
    final got = await b.select(b.pdfDocuments).getSingle();
    expect((got.id, got.sha256, got.pageCount, got.pageOffset), ('abc123', 'abc123', 7, 5));

    await ra.softDelete(rec.id);
    await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
    expect((await b.select(b.pdfDocuments).getSingle()).deleted, isTrue);

    final la = LedgerService(a);
    final change = (await la.history()).firstWhere((c) => c.table == 'pdf_documents' && c.op == 'degistir');
    await la.undoChange(change.id);
    expect((await a.select(a.pdfDocuments).getSingle()).deleted, isFalse);
  });

  test('iki cihazda aynı PDF: sha256 benzersiz, ikinci ekleme yeni satır açmaz', () async {
    final a = await _open('telefon');
    final ra = PdfDocumentRepository(a);
    await ra.add(sha256: 'x', title: 'T', pageCount: 3, fileName: 'f');
    await ra.add(sha256: 'x', title: 'T2', pageCount: 3, fileName: 'g');
    expect(await a.select(a.pdfDocuments).get(), hasLength(1));
    // Aynı sha256, başka kimlikle zorla eklenirse veritabanı reddeder.
    await expectLater(
        a.into(a.pdfDocuments).insert(PdfDocumentsCompanion.insert(
            id: 'baska', sha256: 'x', title: 'T', pageCount: 1, fileName: 'f', createdAt: DateTime(2026), updatedAt: DateTime(2026))),
        throwsA(anything));
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
    expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 16);
    // Tetikleyici kurulu: yeni belge deftere yazılır.
    await PdfDocumentRepository(d).add(sha256: 's', title: 'T', pageCount: 1, fileName: 'f');
    expect((await LedgerService(d).history()).any((c) => c.table == 'pdf_documents'), isTrue);
  }

  test('v15 -> v16 göçü', () => migrate(15));
  test('v14 -> v16 göçü', () => migrate(14));
}
