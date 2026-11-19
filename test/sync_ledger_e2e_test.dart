import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/desktop/sync/data/desktop_sync_store.dart';
import 'package:kocum/desktop/sync/data/sync_server.dart';
import 'package:kocum/features/sync/data/ledger_exchange.dart';
import 'package:kocum/features/sync/data/ledger_sync.dart';
import 'package:kocum/features/sync/data/sync_client.dart';
import 'package:kocum/features/sync/domain/ledger_protocol.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

/// Gerçek sunucu ve istemci 127.0.0.1'de; iki ayrı veritabanı (telefon, pc).
void main() {
  late Directory tmp;
  late AppDatabase phoneDb, pcDb;
  late LedgerService phone, pc;
  late SyncServer server;
  late SyncClient client;
  late DesktopSyncStore store;
  late Directory phoneMedia, pcMedia;
  late SyncConnection connection;
  late LedgerSync sync;

  const phoneId = 'telefon0001aa';
  final t0 = DateTime(2026, 10, 20, 9);

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kocum_defter_');
    phoneDb = AppDatabase(NativeDatabase.memory(), 'telefon');
    pcDb = AppDatabase(NativeDatabase.memory(), 'pc');
    phone = LedgerService(phoneDb);
    pc = LedgerService(pcDb);
    await phoneDb.customSelect('SELECT 1').get();
    await pcDb.customSelect('SELECT 1').get();
    phoneMedia = Directory('${tmp.path}/telefon/media')..createSync(recursive: true);
    pcMedia = Directory('${tmp.path}/bilgisayar/media')..createSync(recursive: true);
    store = DesktopSyncStore(File('${tmp.path}/bilgisayar/esitleme.json'));
    server = SyncServer(
      store: store,
      mediaRoot: pcMedia,
      workDir: Directory('${tmp.path}/bilgisayar'),
      importBackup: (_) async => 'yok',
      platform: 'linux',
      allowLoopback: true,
      ledger: LedgerExchange(
        ledger: pc,
        schemaVersion: pcDb.schemaVersion,
        mediaFile: (p) => File('${pcMedia.path}/$p'),
      ),
    );
    await server.start(port: 0, discoveryPort: 0);
    client = SyncClient(allowLoopback: true);
    await server.openPairing();
    final computer = await client.pair(
      host: '127.0.0.1',
      port: server.port!,
      code: server.pairing!.code,
      phoneId: phoneId,
      phoneName: 'Android · TELE',
      platform: 'android',
    );
    connection = await client.connect(computer, phoneId: phoneId);
    sync = LedgerSync(
      ledger: phone,
      client: client,
      schemaVersion: phoneDb.schemaVersion,
      mediaFile: (p) => File('${phoneMedia.path}/$p'),
    );
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await phoneDb.close();
    await pcDb.close();
    await tmp.delete(recursive: true);
  });

  Future<void> note(AppDatabase db, String id, String body) => db.into(db.anlikNotes).insert(
      AnlikNotesCompanion.insert(id: id, createdAt: t0, updatedAt: t0, body: body, searchText: Value(body)));

  Future<String?> body(AppDatabase db, String id) async =>
      (await (db.select(db.anlikNotes)..where((n) => n.id.equals(id))).getSingleOrNull())?.body;

  Future<void> card(AppDatabase db, String id, String? image) => db.into(db.questionCards).insert(QuestionCardsCompanion.insert(
        id: id,
        status: 'wrong',
        origin: 'independent',
        sourceName: 'x',
        subject: 'TYT Matematik',
        difficulty: 3,
        searchText: '',
        createdAt: t0,
        questionImage: Value(image),
      ));

  Future<void> photo(Directory media, String path, List<int> bytes) async {
    final f = File('${media.path}/$path');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  test('iki yönlü: telefondaki ve bilgisayardaki değişiklikler birbirine geçer', () async {
    await note(phoneDb, 'p1', 'telefonda yazdım');
    await note(pcDb, 'b1', 'bilgisayarda yazdım');
    final r = await sync.run(connection);
    expect(r.sent, 1);
    expect(r.received, 1);
    expect(await body(pcDb, 'p1'), 'telefonda yazdım');
    expect(await body(phoneDb, 'b1'), 'bilgisayarda yazdım');

    // İkinci tur: yeni bir şey yok, hiçbir şey tekrar gitmez.
    final again = await sync.run(connection);
    expect((again.sent, again.received), (0, 0));

    // Bilgisayarda düzenle, telefona geçsin.
    await (pcDb.update(pcDb.anlikNotes)..where((n) => n.id.equals('p1'))).write(const AnlikNotesCompanion(body: Value('düzeltildi')));
    await sync.run(connection);
    expect(await body(phoneDb, 'p1'), 'düzeltildi');
  });

  test('çakışma iki tarafta da kaydolur; kazanan HLC ile belli, kaybeden silinmez', () async {
    await phone.setTestClock(1_000_000);
    await pc.setTestClock(1_000_000);
    await note(phoneDb, 'n', 'ilk');
    await sync.run(connection);
    await phone.setTestClock(2_000_000);
    await (phoneDb.update(phoneDb.anlikNotes)..where((n) => n.id.equals('n'))).write(const AnlikNotesCompanion(body: Value('telefon')));
    await pc.setTestClock(3_000_000);
    await (pcDb.update(pcDb.anlikNotes)..where((n) => n.id.equals('n'))).write(const AnlikNotesCompanion(body: Value('pc')));
    final r = await sync.run(connection);
    expect(await body(phoneDb, 'n'), 'pc');
    expect(await body(pcDb, 'n'), 'pc');
    expect(r.conflicts, 1);
    expect((await phone.watchConflicts().first).single.kaybeden, contains('telefon'));
    expect((await pc.watchConflicts().first).single.kaybeden, contains('telefon'));
  });

  test('fotoğraf telefondan bilgisayara gider, satırdan önce', () async {
    await photo(phoneMedia, 'questions/2026/10/a.jpg', List.generate(5000, (i) => i % 251));
    await card(phoneDb, 'c1', 'questions/2026/10/a.jpg');
    final r = await sync.run(connection);
    expect(r.photosSent, 1);
    expect(await File('${pcMedia.path}/questions/2026/10/a.jpg').length(), 5000);
    expect((await pcDb.select(pcDb.questionCards).get()).single.questionImage, 'questions/2026/10/a.jpg');
    expect((await sync.run(connection)).photosSent, 0); // ikinci kez gitmez
  });

  test('bilgisayarda eklenen fotoğraf telefona gelir; satır geldiğinde dosya hazırdır', () async {
    final bytes = List.generate(7000, (i) => (i * 7) % 251);
    await photo(pcMedia, 'questions/2026/10/b.jpg', bytes);
    await card(pcDb, 'c2', 'questions/2026/10/b.jpg');
    final r = await sync.run(connection);
    expect(r.photosReceived, 1);
    expect(await File('${phoneMedia.path}/questions/2026/10/b.jpg').readAsBytes(), bytes);
    expect((await phoneDb.select(phoneDb.questionCards).get()).single.questionImage, 'questions/2026/10/b.jpg');
  });

  test('bilgisayar değişikliklerinde geçmeyen fotoğrafı telefona vermez (genel okuma yok)', () async {
    await photo(pcMedia, 'questions/2026/10/gizli.jpg', [1, 2, 3]);
    await expectLater(
      client.fetchPhoto(connection, const MediaEntry('questions/2026/10/gizli.jpg', 3), File('${phoneMedia.path}/gizli.jpg')),
      throwsA(isA<SyncException>().having((e) => e.status, 'durum', 404)),
    );
    expect(File('${phoneMedia.path}/gizli.jpg').existsSync(), isFalse);
    // Kural dışı yol hiç gönderilmez.
    await expectLater(
      client.fetchPhoto(connection, const MediaEntry('../ayarlar', 1), File('${phoneMedia.path}/x')),
      throwsA(isA<SyncException>()),
    );
  });

  test('bağlantı yarıda kopup aynı değişiklikler yeniden gelince bilgisayarda çift kayıt olmaz', () async {
    await note(phoneDb, 'n', 'bir');
    await (phoneDb.update(phoneDb.anlikNotes)..where((n) => n.id.equals('n'))).write(const AnlikNotesCompanion(body: Value('iki')));
    // Bilgisayar uyguladı ama yanıt telefona ulaşmadı: imleç ilerlemedi.
    final out = await phone.pendingFor(0);
    await client.exchangeLedger(
      connection,
      LedgerRequest(schema: phoneDb.schemaVersion, device: await phone.deviceId(), received: 0, changes: out, lastSeq: out.last.seq),
    );
    expect(await phone.intState(LedgerService.keySentSeq), 0);
    // Telefon yeniden dener: aynı iki değişiklik gider.
    final conn2 = await client.connect(
      (await store.phone()) == null ? throw StateError('eşleşme yok') : connection.computer,
      phoneId: phoneId,
    );
    final r = await sync.run(conn2);
    expect(r.sent, 2);
    final n = await pcDb.customSelect("SELECT COUNT(*) AS n FROM degisiklikler WHERE tablo = 'anlik_notes'").getSingle();
    expect(n.read<int>('n'), 2);
    expect(await body(pcDb, 'n'), 'iki');
    expect(await phone.intState(LedgerService.keySentSeq), out.last.seq);
  });

  test('çok sayıda değişiklik birkaç turda gider', () async {
    await phone.silently(() async {}); // bağlam hazır
    for (var i = 0; i < ledgerBatch * 2 + 50; i++) {
      await note(phoneDb, 'n$i', 'not $i');
    }
    final r = await sync.run(connection);
    expect(r.rounds, 3);
    expect(r.sent, ledgerBatch * 2 + 50);
    expect((await pcDb.select(pcDb.anlikNotes).get()).length, ledgerBatch * 2 + 50);
  });

  test('uygulama sürümleri (şema) farklıysa açık hata ile durur, hiçbir şey uygulanmaz', () async {
    await note(phoneDb, 'n', 'x');
    final old = LedgerSync(
      ledger: phone,
      client: client,
      schemaVersion: phoneDb.schemaVersion - 1,
      mediaFile: (p) => File('${phoneMedia.path}/$p'),
    );
    await expectLater(old.run(connection), throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('farklı sürümde'))));
    expect(await body(pcDb, 'n'), isNull);
  });

  test('geri alma ve oturum bilgisi telefona da gider', () async {
    await pc.withSource('claude', session: 'oturum-9', body: () => note(pcDb, 'c', 'claude ekledi'));
    await sync.run(connection);
    expect((await phone.history(session: 'oturum-9')).single.source, 'claude');
    await pc.undoSession('oturum-9');
    await sync.run(connection);
    expect(await body(phoneDb, 'c'), isNull);
    expect(await phone.undoneIds(), isNotEmpty);
  });
}
