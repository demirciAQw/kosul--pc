import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/desktop/sync/data/desktop_sync_store.dart';
import 'package:kocum/desktop/sync/data/sync_server.dart';
import 'package:kocum/features/sync/data/ledger_exchange.dart';
import 'package:kocum/features/sync/data/ledger_sync.dart';
import 'package:kocum/features/sync/data/sync_client.dart';

/// Bilgisayar MERKEZDİR: telefon ve tablet birbiriyle eşleşmez, sırayla (en
/// fazla bir eşleşme) bilgisayarla alışveriş eder. Üç gerçek veritabanı, gerçek
/// sunucu ve istemci 127.0.0.1'de: üçü de aynı satırlara yakınsamalı.
class _Device {
  _Device(this.name, this.id, this.media, {String source = 'telefon'})
      : db = AppDatabase(NativeDatabase.memory(), source) {
    ledger = LedgerService(db);
  }

  final String name;
  final String id;
  final Directory media;
  final AppDatabase db;
  late final LedgerService ledger;
}

void main() {
  late Directory tmp;
  late SyncServer server;
  late _Device phone, tablet, pc;
  late Directory pcMedia;

  final t0 = DateTime(2026, 11, 2, 9);
  const sha1 = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a';
  const sha2 = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b';

  setUpAll(() {
    HttpOverrides.global = null;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kocum_merkez_');
    Directory media(String n) => Directory('${tmp.path}/$n/media')..createSync(recursive: true);
    phone = _Device('telefon', 'telefon0001aa', media('telefon'));
    tablet = _Device('tablet', 'tablet00002bb', media('tablet'));
    pcMedia = media('bilgisayar');
    pc = _Device('pc', 'unused-by-pc', pcMedia, source: 'pc');
    for (final d in [phone, tablet, pc]) {
      await d.db.customSelect('SELECT 1').get();
    }
    server = SyncServer(
      store: DesktopSyncStore(File('${tmp.path}/bilgisayar/esitleme.json')),
      mediaRoot: pcMedia,
      workDir: Directory('${tmp.path}/bilgisayar'),
      importBackup: (_) async => 'yok',
      platform: 'linux',
      allowLoopback: true,
      ledger: LedgerExchange(
        ledger: pc.ledger,
        schemaVersion: pc.db.schemaVersion,
        mediaFile: (p) => File('${pcMedia.path}/$p'),
      ),
    );
    await server.start(port: 0, discoveryPort: 0);
  });

  tearDown(() async {
    await server.dispose();
    for (final d in [phone, tablet, pc]) {
      await d.db.close();
    }
    await tmp.delete(recursive: true);
  });

  /// Cihaz bilgisayarla eşleşir, alışveriş eder, eşleşme kaldırılır (tek eşleşme kuralı).
  Future<LedgerSyncResult> visit(_Device d) async {
    final client = SyncClient(allowLoopback: true);
    try {
      await server.openPairing();
      final computer = await client.pair(
        host: '127.0.0.1',
        port: server.port!,
        code: server.pairing!.code,
        phoneId: d.id,
        phoneName: 'Android · ${d.name}',
        platform: 'android',
      );
      final connection = await client.connect(computer, phoneId: d.id);
      return await LedgerSync(
        ledger: d.ledger,
        client: client,
        schemaVersion: d.db.schemaVersion,
        mediaFile: (p) => File('${d.media.path}/$p'),
      ).run(connection);
    } finally {
      client.close();
      await server.forgetPhone();
    }
  }

  Future<void> stroke(AppDatabase db, String id, {String? pdf, int? page, String? note, int? notePage, int a = 1}) =>
      db.into(db.inkStrokes).insert(InkStrokesCompanion.insert(
            id: id,
            startedAtMs: 1000,
            points: Uint8List.fromList([a, 2, 3, 250, 255, 0]),
            createdAt: t0,
            updatedAt: t0,
            pdfDocumentId: Value(pdf),
            pdfPage: Value(page),
            noteId: Value(note),
            notePage: Value(notePage),
            pointCount: const Value(3),
          ));

  Future<void> pdfDoc(AppDatabase db, String sha, String title) => db.into(db.pdfDocuments).insert(PdfDocumentsCompanion.insert(
      id: sha, sha256: sha, title: title, pageCount: 12, fileName: '$title.pdf', createdAt: t0, updatedAt: t0));

  Future<void> pdfCard(AppDatabase db, String id, String sha) => db.into(db.questionCards).insert(QuestionCardsCompanion.insert(
        id: id,
        status: 'wrong',
        origin: 'independent',
        sourceName: 'PDF',
        subject: 'TYT Matematik',
        difficulty: 3,
        searchText: '',
        createdAt: t0,
        pdfDocumentId: Value(sha),
        pdfPage: const Value(4),
        pdfBoxLeft: const Value(0.1),
        pdfBoxTop: const Value(0.2),
        pdfBoxRight: const Value(0.9),
        pdfBoxBottom: const Value(0.6),
      ));

  Future<void> notebook(AppDatabase db, String nb, String page, String tag) async {
    await db.into(db.inkNotebooks).insert(InkNotebooksCompanion.insert(id: nb, createdAt: t0, updatedAt: t0, title: const Value('Matematik')));
    await db.into(db.inkNotePages).insert(InkNotePagesCompanion.insert(id: page, notebookId: nb, pageNo: 1, createdAt: t0, updatedAt: t0));
    await db.into(db.tags).insert(TagsCompanion.insert(id: tag, name: 'turev', label: 'Türev', createdAt: t0));
    await db.into(db.inkNotebookTags).insert(InkNotebookTagsCompanion.insert(id: '$nb:$tag', notebookId: nb, tagId: tag));
  }

  /// Bir cihazdaki tüm senkron tabloları, satır satır kararlı metin.
  Future<Map<String, List<String>>> snapshot(_Device d) async {
    final out = <String, List<String>>{};
    for (final t in d.ledger.syncTables) {
      final name = t.actualTableName;
      final cols = [for (final c in t.$columns) c.$name];
      final rows = await d.db.customSelect('SELECT * FROM "$name"').get();
      final lines = [
        for (final r in rows)
          cols.map((c) {
            final v = r.data[c];
            return '$c=${v is Uint8List ? v.join(',') : v}';
          }).join('|'),
      ]..sort();
      if (lines.isNotEmpty) out[name] = lines;
    }
    return out;
  }

  test('telefon ve tablet bilgisayar üzerinden aynı satırlara yakınsar (çizgi, PDF, kart, defter, bağlar)', () async {
    // Telefon: PDF belgesi, o PDF'te soru kartı ve çizgi.
    await pdfDoc(phone.db, sha1, 'Telefon PDF');
    await pdfCard(phone.db, 'kart-tel', sha1);
    await stroke(phone.db, 's-tel', pdf: sha1, page: 3);
    // Tablet: defter + sayfa + çizgi + etiket bağı, kendi PDF'i ve çizgisi.
    await notebook(tablet.db, 'defter1', 'sayfa1', 'etiket1');
    await stroke(tablet.db, 's-tab-not', note: 'sayfa1', notePage: 1, a: 9);
    await pdfDoc(tablet.db, sha2, 'Tablet PDF');
    await stroke(tablet.db, 's-tab-pdf', pdf: sha2, page: 0, a: 7);
    // Bilgisayar: kendi notu.
    await pc.db.into(pc.db.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'pc-not', createdAt: t0, updatedAt: t0, body: 'pc', searchText: const Value('pc')));

    final first = await visit(phone);
    expect(first.sent, greaterThan(0));
    final tabletFirst = await visit(tablet);
    // Tablet, telefonun satırlarını bilgisayar aracılığıyla aldı.
    expect(tabletFirst.received, greaterThan(0));
    expect((await tablet.db.select(tablet.db.pdfDocuments).get()).map((d) => d.id), containsAll([sha1, sha2]));
    expect((await tablet.db.select(tablet.db.inkStrokes).get()).map((s) => s.id), containsAll(['s-tel', 's-tab-not', 's-tab-pdf']));
    await visit(phone); // telefon tabletin satırlarını alır

    // İkinci tur: telefonda çizgi sil, tablette defter başlığı değiştir, pc'de PDF başlığı.
    await (phone.db.update(phone.db.inkStrokes)..where((s) => s.id.equals('s-tel')))
        .write(const InkStrokesCompanion(deleted: Value(true)));
    await (tablet.db.update(tablet.db.inkNotebooks)..where((n) => n.id.equals('defter1')))
        .write(const InkNotebooksCompanion(title: Value('Fizik')));
    await (pc.db.update(pc.db.pdfDocuments)..where((d) => d.id.equals(sha2))).write(const PdfDocumentsCompanion(title: Value('Yeni ad')));
    await visit(tablet);
    await visit(phone);
    await visit(tablet);
    await visit(phone);

    final a = await snapshot(phone), b = await snapshot(tablet), c = await snapshot(pc);
    expect(b, a, reason: 'tablet = telefon');
    expect(c, a, reason: 'bilgisayar = telefon');
    expect(a.keys, containsAll(['ink_strokes', 'pdf_documents', 'question_cards', 'ink_notebooks', 'ink_note_pages', 'ink_notebook_tags', 'tags']));
    final del = (await phone.db.select(phone.db.inkStrokes).get()).firstWhere((s) => s.id == 's-tel');
    expect(del.deleted, isTrue);
    expect((await tablet.db.select(tablet.db.inkStrokes).get()).firstWhere((s) => s.id == 's-tel').deleted, isTrue);
    expect((await phone.db.select(phone.db.inkNotebooks).get()).single.title, 'Fizik');
    expect((await tablet.db.select(tablet.db.pdfDocuments).get()).firstWhere((d) => d.id == sha2).title, 'Yeni ad');
    // BLOB bayt bayt aynı.
    final blob = (await phone.db.select(phone.db.inkStrokes).get()).firstWhere((s) => s.id == 's-tab-not').points;
    expect(blob, [9, 2, 3, 250, 255, 0]);
    // Çakışma yok, kimse kendi satırını geri almadı: iki kez daha gezilince hareket yok.
    final quietPhone = await visit(phone);
    final quietTablet = await visit(tablet);
    expect((quietPhone.sent, quietPhone.received, quietTablet.sent, quietTablet.received), (0, 0, 0, 0));
    expect(await phone.db.select(phone.db.cakismalar).get(), isEmpty);
    expect(await tablet.db.select(tablet.db.cakismalar).get(), isEmpty);
  });

  test('telefondaki fotoğraf bilgisayar üzerinden tablete de gelir; öbür cihazın satırı geri dönmez', () async {
    final f = File('${phone.media.path}/questions/2026/11/a.jpg')..createSync(recursive: true);
    f.writeAsBytesSync([5, 6, 7]);
    await phone.db.into(phone.db.questionCards).insert(QuestionCardsCompanion.insert(
        id: 'foto',
        status: 'wrong',
        origin: 'independent',
        sourceName: 'x',
        subject: 'TYT Matematik',
        difficulty: 3,
        searchText: '',
        createdAt: t0,
        questionImage: const Value('questions/2026/11/a.jpg')));
    await visit(phone);
    final r = await visit(tablet);
    expect(r.photosReceived, 1);
    expect(File('${tablet.media.path}/questions/2026/11/a.jpg').readAsBytesSync(), [5, 6, 7]);
    // Telefona kendi satırı geri gelmez (aynı kimlik: yine de çift sayılmaz).
    final back = await visit(phone);
    expect(back.received, 0);
  });

  test('telefon ve tablet aynı satırı ayrı ayrı değiştirirse HLC\'si yeni olan kazanır, üçü de aynı olur, kaybeden silinmez', () async {
    for (final d in [phone, tablet, pc]) {
      await d.ledger.setTestClock(1_000_000);
    }
    await pc.db.into(pc.db.pdfDocuments).insert(PdfDocumentsCompanion.insert(
        id: sha1, sha256: sha1, title: 'ilk', pageCount: 3, fileName: 'a.pdf', createdAt: t0, updatedAt: t0));
    await visit(phone);
    await visit(tablet);
    await phone.ledger.setTestClock(2_000_000);
    await (phone.db.update(phone.db.pdfDocuments)..where((d) => d.id.equals(sha1))).write(const PdfDocumentsCompanion(title: Value('telefon')));
    await tablet.ledger.setTestClock(3_000_000);
    await (tablet.db.update(tablet.db.pdfDocuments)..where((d) => d.id.equals(sha1))).write(const PdfDocumentsCompanion(title: Value('tablet')));
    await visit(phone);
    await visit(tablet);
    await visit(phone);
    await visit(tablet);
    for (final d in [phone, tablet, pc]) {
      expect((await d.db.select(d.db.pdfDocuments).get()).single.title, 'tablet', reason: d.name);
    }
    final conflicts = [...await phone.db.select(phone.db.cakismalar).get(), ...await tablet.db.select(tablet.db.cakismalar).get()];
    expect(conflicts.where((c) => c.kaybeden?.contains('telefon') ?? false), isNotEmpty);
  });
}
