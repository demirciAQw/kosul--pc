import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/features/sync/data/ledger_exchange.dart';
import 'package:kocum/features/sync/data/ledger_sync.dart';
import 'package:kocum/features/sync/data/phone_sync_store.dart';
import 'package:kocum/features/sync/data/server_sync_store.dart';
import 'package:kocum/features/sync/data/sync_client.dart';
import 'package:kocum/features/sync/data/sync_server.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

/// v9.23: her cihaz hem istemci hem alıcı (sunucu) olabilir. Üçgen: telefon (P),
/// tablet (T, ekranı açık Android alıcı rolünde) ve bilgisayar (PC, Linux alıcı).
/// Kenarlar: P→PC, P→T, T→PC. Üç gerçek veritabanı, iki gerçek sunucu 127.0.0.1'de.
class _Node {
  _Node(this.name, this.clientId, this.media, {String source = 'telefon'})
      : db = AppDatabase(NativeDatabase.memory(), source) {
    ledger = LedgerService(db);
  }

  final String name;

  /// Bu cihazın İSTEMCİ kimliği (eşleşmede alıcıya bildirdiği).
  final String clientId;
  final Directory media;
  final AppDatabase db;
  late final LedgerService ledger;
}

void main() {
  late Directory tmp;
  late _Node phone, tablet, pc;
  late SyncServer pcServer, tabServer;

  final t0 = DateTime(2026, 11, 2, 9);

  String sha(int n) => n.toRadixString(16).padLeft(64, '0');

  setUpAll(() {
    HttpOverrides.global = null;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  SyncServer serverFor(_Node n, {required String platform, String kind = deviceKindComputer, bool backup = false, bool loopback = true, String label = 'Bilgisayar'}) {
    return SyncServer(
      store: ServerSyncStore(File('${tmp.path}/${n.name}/alici.json'), label: label),
      mediaRoot: n.media,
      pdfRoot: Directory('${tmp.path}/${n.name}/pdfs'),
      workDir: Directory('${tmp.path}/${n.name}'),
      importBackup: backup ? (_) async => 'yok' : null,
      platform: platform,
      kind: kind,
      allowLoopback: loopback,
      ledger: LedgerExchange(
        ledger: n.ledger,
        schemaVersion: n.db.schemaVersion,
        mediaFile: (p) => File('${n.media.path}/$p'),
      ),
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kocum_p2p_');
    Directory media(String n) => Directory('${tmp.path}/$n/media')..createSync(recursive: true);
    phone = _Node('telefon', 'telefon0001aa', media('telefon'));
    tablet = _Node('tablet', 'tablet00002bb', media('tablet'));
    pc = _Node('pc', 'pc00000003cc', media('pc'), source: 'pc');
    for (final d in [phone, tablet, pc]) {
      await d.db.customSelect('SELECT 1').get();
    }
    pcServer = serverFor(pc, platform: 'linux', backup: true);
    tabServer = serverFor(tablet, platform: 'android', kind: deviceKindTablet, label: 'Tablet');
    await pcServer.start(port: 0, discoveryPort: 0);
    await tabServer.start(port: 0, discoveryPort: 0);
  });

  tearDown(() async {
    await pcServer.dispose();
    await tabServer.dispose();
    for (final d in [phone, tablet, pc]) {
      await d.db.close();
    }
    await tmp.delete(recursive: true);
  });

  Future<PairedComputer> pairTo(_Node client, SyncServer server, {bool markNew = true}) async {
    final c = SyncClient(allowLoopback: true);
    try {
      await server.openPairing();
      final peer = await c.pair(
        host: '127.0.0.1',
        port: server.port!,
        code: server.pairing!.code,
        phoneId: client.clientId,
        phoneName: 'Android · ${client.name}',
        platform: 'android',
      );
      if (markNew) {
        await LedgerSync.markNewPeer(client.ledger, peer.id, push: peer.isAndroid);
        if (!peer.isAndroid) {
          // Gerçek akışta bilgisayara ilk tam yedek gider (SendController); satırlar o sıraya kadar
          // yedekle gitmiş sayılır.
          await client.ledger.setIntState('${LedgerService.keySentSeq}:${peer.id}', await client.ledger.maxSeq());
        }
      }
      return peer;
    } finally {
      c.close();
    }
  }

  Future<LedgerSyncResult> sync(_Node n, PairedComputer peer) async {
    final c = SyncClient(allowLoopback: true);
    try {
      final conn = await c.connect(peer, phoneId: n.clientId);
      return await LedgerSync(
        ledger: n.ledger,
        client: c,
        schemaVersion: n.db.schemaVersion,
        mediaFile: (p) => File('${n.media.path}/$p'),
        scope: peer.id,
      ).run(conn);
    } finally {
      c.close();
    }
  }

  Future<void> pdfDoc(AppDatabase db, String id, String title) => db.into(db.pdfDocuments).insert(
      PdfDocumentsCompanion.insert(id: id, sha256: id, title: title, pageCount: 3, fileName: '$title.pdf', createdAt: t0, updatedAt: t0));

  Future<void> rename(AppDatabase db, String id, String title) =>
      (db.update(db.pdfDocuments)..where((d) => d.id.equals(id))).write(PdfDocumentsCompanion(title: Value(title)));

  Future<Map<String, String>> titles(_Node n) async =>
      {for (final d in await n.db.select(n.db.pdfDocuments).get()) d.id: d.title};

  Future<void> stroke(AppDatabase db, String id, {int a = 1}) => db.into(db.inkStrokes).insert(InkStrokesCompanion.insert(
        id: id,
        startedAtMs: 1000,
        points: Uint8List.fromList([a, 2, 3, 250, 255, 0]),
        createdAt: t0,
        updatedAt: t0,
        noteId: const Value('sayfa'),
        notePage: const Value(1),
        pointCount: const Value(3),
      ));

  /// Üç kenarı sırayla gez; bir turda hiçbir şey olmayana dek. Tur sonuçlarını döner.
  Future<List<List<LedgerSyncResult>>> settle(PairedComputer pToPc, PairedComputer pToT, PairedComputer tToPc) async {
    final passes = <List<LedgerSyncResult>>[];
    for (var i = 0; i < 8; i++) {
      final pass = [await sync(phone, pToPc), await sync(phone, pToT), await sync(tablet, tToPc)];
      passes.add(pass);
      if (pass.every((r) => r.sent == 0 && r.received == 0 && r.duplicates == 0 && r.conflicts == 0)) break;
    }
    return passes;
  }

  group('üçgen: telefon, tablet (Android alıcı), bilgisayar', () {
    late PairedComputer pToPc, pToT, tToPc;

    setUp(() async {
      pToPc = await pairTo(phone, pcServer);
      pToT = await pairTo(phone, tabServer);
      tToPc = await pairTo(tablet, pcServer);
      expect(pToT.isAndroid, isTrue);
      expect(pToT.kind, deviceKindTablet);
      expect(pToPc.kind, deviceKindComputer);
      await settle(pToPc, pToT, tToPc);
    });

    test('her cihazın yazdığı üç cihazda da görünür; sessiz turda hareket, çift kayıt ve çakışma yok', () async {
      await pdfDoc(phone.db, sha(1), 'P belgesi');
      await pdfDoc(tablet.db, sha(2), 'T belgesi');
      await pdfDoc(pc.db, sha(3), 'PC belgesi');
      await stroke(phone.db, 'cizgi-p', a: 9);
      final passes = await settle(pToPc, pToT, tToPc);
      expect(passes.last.every((r) => r.sent == 0 && r.received == 0 && r.duplicates == 0), isTrue,
          reason: 'son tur sessiz: sonsuz döngü ve yankı yok (${passes.length} tur)');
      expect(passes.length, lessThanOrEqualTo(4));
      final expected = {sha(1): 'P belgesi', sha(2): 'T belgesi', sha(3): 'PC belgesi'};
      for (final n in [phone, tablet, pc]) {
        expect(await titles(n), expected, reason: n.name);
        expect((await n.db.select(n.db.inkStrokes).get()).single.points, [9, 2, 3, 250, 255, 0], reason: n.name);
        expect(await n.db.select(n.db.cakismalar).get(), isEmpty, reason: n.name);
      }
    });

    test('yankı: eşten alınan satır eşe geri gitmez; alınan satır öbür eşe gider', () async {
      await pdfDoc(phone.db, sha(1), 'P');
      await pdfDoc(tablet.db, sha(2), 'T');
      // P↔T: P, T'nin satırını alır, T P'ninkini.
      final r1 = await sync(phone, pToT);
      expect((r1.sent, r1.received), (1, 1));
      // P→PC: P kendi satırını VE tabletten aldığını bilgisayara aktarır (aracı); bilgisayarın
      // cevabı aynı isteğin uyguladıklarını geri yankılamaz.
      final r2 = await sync(phone, pToPc);
      expect(r2.sent, 2, reason: 'telefon: kendi + tabletten aldığı (aracı)');
      expect((r2.received, r2.duplicates), (0, 0), reason: 'bilgisayar uyguladığı satırları telefona geri vermez');
      expect((await titles(pc)).keys, containsAll([sha(1), sha(2)]));
      // T→PC: tablet, telefondan aldığı satırı bilgisayara geri YOLLAMAZ da (zaten bilgisayarın
      // kendisine telefonun elinden gelmiş olabilir ama bunu bilmez): kendi satırı + telefonun satırı gider.
      // Önemli olan: tablet kendi satırını bilgisayardan GERİ ALMAZ (kimlik süzgeci).
      final r3 = await sync(tablet, tToPc);
      expect(r3.received, 0);
      expect(r3.duplicates, 1, reason: 'yalnızca telefonun satırı (üçüncü yol); tabletin kendi satırı geri gelmez');
      // Hepsi yakınsadı ve sessiz.
      final passes = await settle(pToPc, pToT, tToPc);
      expect(passes.last.every((r) => r.sent == 0 && r.received == 0 && r.duplicates == 0), isTrue);
    });

    test('bilgisayardan alınan satır bilgisayara geri gönderilmez (alınan aralık atlanır)', () async {
      await pdfDoc(pc.db, sha(3), 'PC');
      final r = await sync(tablet, tToPc);
      expect(r.received, 1);
      final again = await sync(tablet, tToPc);
      expect((again.sent, again.received, again.duplicates), (0, 0, 0));
      // Tablet bu satırı öbür eşe (telefon, tablet sunucusu üzerinden) taşıyabilir: telefon alır.
      final p = await sync(phone, pToT);
      expect(p.received, 1);
      expect((await titles(phone))[sha(3)], 'PC');
    });

    test('aynı satırı iki cihaz aynı anda değiştirir: üçü de aynı değere yakınsar, kaybeden Çakışmalar\'da kalır', () async {
      await pdfDoc(phone.db, sha(1), 'ilk');
      await settle(pToPc, pToT, tToPc);
      await phone.ledger.setTestClock(DateTime(2026, 11, 3, 10).millisecondsSinceEpoch);
      await rename(phone.db, sha(1), 'telefonun');
      await tablet.ledger.setTestClock(DateTime(2026, 11, 3, 11).millisecondsSinceEpoch);
      await rename(tablet.db, sha(1), 'tabletin');
      await settle(pToPc, pToT, tToPc);
      final a = await titles(phone), b = await titles(tablet), c = await titles(pc);
      expect(a, b);
      expect(a, c);
      expect(a[sha(1)], 'tabletin', reason: 'HLC yeni olan kazanır');
      final conflicts = (await phone.db.select(phone.db.cakismalar).get()).length +
          (await tablet.db.select(tablet.db.cakismalar).get()).length +
          (await pc.db.select(pc.db.cakismalar).get()).length;
      expect(conflicts, greaterThan(0));
    });

    test('imleçler eş başınadır: bir eşle eşitlemek öbür eşin imlecini oynatmaz; eş kaldırılınca silinir', () async {
      await pdfDoc(phone.db, sha(1), 'P');
      String k(String base, PairedComputer p) => '$base:${p.id}';
      final sentPc = await phone.ledger.intState(k(LedgerService.keySentSeq, pToPc));
      final recvPc = await phone.ledger.intState(k(LedgerService.keyReceivedSeq, pToPc));
      await sync(phone, pToT);
      expect(await phone.ledger.intState(k(LedgerService.keySentSeq, pToT)), greaterThan(0));
      expect(await phone.ledger.intState(k(LedgerService.keySentSeq, pToPc)), sentPc);
      expect(await phone.ledger.intState(k(LedgerService.keyReceivedSeq, pToPc)), recvPc);
      expect(await phone.ledger.textState(k(LedgerSync.keyPeerLedger, pToT)), await tablet.ledger.deviceId());
      await LedgerSync.forgetPeer(phone.ledger, pToT.id);
      expect(await phone.ledger.textState(k(LedgerService.keySentSeq, pToT)), isNull);
      expect(await phone.ledger.intState(k(LedgerService.keySentSeq, pToPc)), sentPc);
    });
  });

  group('Android alıcı: tam durum (iki yön) ve kısıtlar', () {
    test('eşleşmeden ÖNCE var olan (deftersiz) kayıtlar iki yönde taşınır; var olan satırın üstüne yazılmaz', () async {
      // Defter öncesi veri: tetikleyiciler susturulur (yedekle gelmiş/eski veri gibi).
      Future<void> silent(_Node n, Future<void> Function() body) async => n.ledger.silently(body);
      await silent(phone, () async {
        await pdfDoc(phone.db, sha(1), 'telefon eski');
        await pdfDoc(phone.db, sha(9), 'ortak (telefon)');
      });
      await silent(tablet, () async {
        await pdfDoc(tablet.db, sha(2), 'tablet eski');
        await pdfDoc(tablet.db, sha(9), 'ortak (tablet)');
      });
      expect(await phone.ledger.maxSeq(), 0);
      final peer = await pairTo(phone, tabServer);
      final r = await sync(phone, peer);
      expect(r.snapshotRows, 1, reason: 'telefon tabletten yalnız eksik olanı aldı');
      expect(r.pushedRows, greaterThanOrEqualTo(2), reason: 'telefon kendi tam durumunu tablete verdi');
      expect(r.snapshotPending || r.pushPending, isFalse);
      final p = await titles(phone), t = await titles(tablet);
      expect(p.keys.toSet(), {sha(1), sha(2), sha(9)});
      expect(t.keys.toSet(), {sha(1), sha(2), sha(9)});
      expect(p[sha(9)], 'ortak (telefon)', reason: 'var olan satıra dokunulmaz');
      expect(t[sha(9)], 'ortak (tablet)', reason: 'var olan satıra dokunulmaz');
      expect(await phone.db.select(phone.db.cakismalar).get(), isEmpty);
      // Bundan sonrası normal defter akışı.
      await pdfDoc(phone.db, sha(5), 'yeni');
      await sync(phone, peer);
      expect((await titles(tablet))[sha(5)], 'yeni');
    });

    test('Android alıcı tam yedek (ZIP) almaz: 404', () async {
      final peer = await pairTo(phone, tabServer);
      final c = SyncClient(allowLoopback: true);
      try {
        final conn = await c.connect(peer, phoneId: phone.clientId);
        final zip = File('${tmp.path}/x.zip')..writeAsBytesSync([1, 2, 3]);
        await expectLater(
            c.sendBackup(conn, zip), throwsA(isA<SyncException>().having((e) => e.status, 'durum', 404)));
      } finally {
        c.close();
      }
    });

    test('eşleşme kuralları Android alıcıda da geçerli: yanlış kod 5 hak, Windows reddi, yerel ağ dışı', () async {
      final c = SyncClient(allowLoopback: true);
      try {
        // Windows bildiren istemci reddedilir.
        await tabServer.openPairing();
        await expectLater(
          c.pair(
              host: '127.0.0.1',
              port: tabServer.port!,
              code: tabServer.pairing!.code,
              phoneId: 'windows0001xx',
              phoneName: 'x',
              platform: 'windows'),
          throwsA(isA<SyncException>().having((e) => e.status, 'durum', 403)),
        );
        // Yanlış kod: 5 hakta kapanır.
        await tabServer.openPairing();
        final wrong = tabServer.pairing!.code == '000000' ? '111111' : '000000';
        for (var i = 0; i < SyncLimits.pairingAttempts; i++) {
          await expectLater(
              c.pair(host: '127.0.0.1', port: tabServer.port!, code: wrong, phoneId: 'telefon0001aa', phoneName: 'x', platform: 'android'),
              throwsA(isA<SyncException>()));
        }
        expect(tabServer.pairing, isNull, reason: '5 yanlıştan sonra kod kapanır');
        expect(await tabServer.store.devices(), isEmpty);
      } finally {
        c.close();
      }
      // Loopback yalnızca testte açık: kapalı sunucu (gerçek kullanım) aynı makineden isteği reddeder.
      final strict = serverFor(pc, platform: 'android', loopback: false);
      await strict.start(port: 0, discoveryPort: null);
      final c2 = SyncClient(allowLoopback: true);
      try {
        await expectLater(
            c2.hello('127.0.0.1', strict.port!), throwsA(isA<SyncException>().having((e) => e.status, 'durum', 403)));
      } finally {
        c2.close();
        await strict.dispose();
      }
    });

    test('imzasız ve eşleşmemiş istek Android alıcıda reddedilir; genel okuma yok', () async {
      final peer = await pairTo(phone, tabServer);
      final stranger = PairedComputer(
          id: peer.id, name: 'x', host: '127.0.0.1', port: tabServer.port!, key: List.filled(32, 1), pairedAt: DateTime(2026), platform: 'android');
      final c = SyncClient(allowLoopback: true);
      try {
        await expectLater(c.connect(stranger, phoneId: phone.clientId), throwsA(isA<SyncException>()), reason: 'yanlış anahtar');
        await expectLater(c.connect(peer, phoneId: 'eslesmemis00001'), throwsA(isA<SyncException>()), reason: 'eşleşmemiş cihaz');
      } finally {
        c.close();
      }
      final raw = HttpClient()..findProxy = ((_) => 'DIRECT');
      try {
        for (final path in [SyncPaths.ledger, SyncPaths.photoGet, SyncPaths.pdfGet, SyncPaths.photoList]) {
          final req = await raw.postUrl(Uri(scheme: 'http', host: '127.0.0.1', port: tabServer.port!, path: path));
          req.contentLength = 2;
          req.add([123, 125]);
          final resp = await req.close();
          await resp.drain<void>();
          expect(resp.statusCode, 401, reason: path);
        }
        final listing = await raw.getUrl(Uri(scheme: 'http', host: '127.0.0.1', port: tabServer.port!, path: '/kocum/v1/liste'));
        final lr = await listing.close();
        await lr.drain<void>();
        expect(lr.statusCode, 404);
      } finally {
        raw.close(force: true);
      }
    });

    test('Android alıcıda en çok maxDevices cihaz; sunucu durunca bağlantı gider, yeniden başlayınca eşleşme kalır', () async {
      for (var i = 0; i < SyncLimits.maxDevices; i++) {
        final c = SyncClient(allowLoopback: true);
        try {
          await tabServer.openPairing();
          await c.pair(
              host: '127.0.0.1',
              port: tabServer.port!,
              code: tabServer.pairing!.code,
              phoneId: 'istemci${i}0000aa',
              phoneName: 'c$i',
              platform: 'android');
        } finally {
          c.close();
        }
      }
      await expectLater(tabServer.openPairing(), throwsA(isA<SyncException>()));
      expect(await tabServer.store.devices(), hasLength(SyncLimits.maxDevices));
      final port = tabServer.port!;
      await tabServer.stop(); // ekran kapandı / uygulama arka plana gitti
      expect(tabServer.isRunning, isFalse);
      final c = SyncClient(allowLoopback: true, connectTimeout: const Duration(seconds: 1));
      try {
        await expectLater(c.hello('127.0.0.1', port), throwsA(isA<SocketException>()));
      } finally {
        c.close();
      }
      await tabServer.start(port: 0, discoveryPort: null); // ön plana dönüş
      expect(await tabServer.store.devices(), hasLength(SyncLimits.maxDevices), reason: 'eşleşmeler kalıcı');
    });
  });

  group('eski kayıtlar', () {
    test('genel (eş kimliksiz) imleçler eski eşe bir kez kopyalanır; yeni eş sıfırdan başlar', () async {
      await phone.ledger.setIntState(LedgerService.keySentSeq, 12);
      await phone.ledger.setIntState(LedgerService.keyReceivedSeq, 34);
      await phone.ledger.setIntState(LedgerService.keyStarted, 1);
      await LedgerSync.migrateLegacyCursors(phone.ledger, 'eskies000001');
      expect(await phone.ledger.intState('${LedgerService.keySentSeq}:eskies000001'), 12);
      expect(await phone.ledger.intState('${LedgerService.keyReceivedSeq}:eskies000001'), 34);
      expect(await phone.ledger.intState('${LedgerService.keyStarted}:eskies000001'), 1);
      // İkinci kez çağrılınca kopyalanmış değer ezilmez.
      await phone.ledger.setIntState('${LedgerService.keySentSeq}:eskies000001', 20);
      await LedgerSync.migrateLegacyCursors(phone.ledger, 'eskies000001');
      expect(await phone.ledger.intState('${LedgerService.keySentSeq}:eskies000001'), 20);
      expect(await phone.ledger.intState('${LedgerService.keySentSeq}:yenies000001'), 0);
    });
  });
}

