import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/desktop/sync/data/desktop_sync_store.dart';
import 'package:kocum/desktop/sync/data/sync_server.dart';
import 'package:kocum/features/sync/data/ledger_exchange.dart';
import 'package:kocum/features/sync/domain/ledger_protocol.dart';
import 'package:kocum/features/sync/data/ledger_sync.dart';
import 'package:kocum/features/sync/data/pdf_pull.dart';
import 'package:kocum/features/sync/data/phone_sync_store.dart';
import 'package:kocum/features/sync/data/sync_client.dart';
import 'package:kocum/features/sync/domain/sync_cipher.dart';
import 'package:kocum/features/sync/domain/sync_crypto.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

/// Çok cihaz (v9.15): bir bilgisayara telefon + tablet aynı anda eşleşik, her
/// birinin ayrı anahtarı var; eşzamanlı eşitlenir; tam durum ve `pdf-al`.
class _Dev {
  _Dev(this.kind, this.id, Directory root)
      : db = AppDatabase(NativeDatabase.memory(), kind == 'pc' ? 'pc' : 'telefon'),
        media = Directory('${root.path}/$kind/media')..createSync(recursive: true),
        pdfs = Directory('${root.path}/$kind/pdfs')..createSync(recursive: true) {
    ledger = LedgerService(db);
  }

  final String kind;
  final String id;
  final AppDatabase db;
  final Directory media;
  final Directory pdfs;
  late final LedgerService ledger;
  late SyncClient client;
  late PairedComputer computer;
  late SyncConnection conn;
}

class _CountingClient extends SyncClient {
  _CountingClient() : super(allowLoopback: true);

  int pdfFetches = 0;

  @override
  Future<void> fetchPdf(SyncConnection connection, String sha256, File target,
      {void Function(int received, int total)? onProgress, SyncCancelToken? cancel}) {
    pdfFetches++;
    return super.fetchPdf(connection, sha256, target, onProgress: onProgress, cancel: cancel);
  }
}

void main() {
  late Directory tmp;
  late SyncServer server;
  late DesktopSyncStore store;
  late _Dev phone, tablet, pc;
  late Directory pcPdfs;

  final t0 = DateTime(2026, 11, 2, 9);

  setUpAll(() {
    HttpOverrides.global = null;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  LedgerExchange plainExchange() => LedgerExchange(
        ledger: pc.ledger,
        schemaVersion: pc.db.schemaVersion,
        mediaFile: (p) => File('${pc.media.path}/$p'),
      );

  Future<SyncServer> boot({
    bool withPdf = true,
    LedgerExchange? exchange,
    Duration? lockWait,
    BackupImporter? importer,
  }) async {
    final s = SyncServer(
      store: store,
      lockWait: lockWait ?? const Duration(seconds: 20),
      mediaRoot: pc.media,
      workDir: Directory('${tmp.path}/bilgisayar'),
      importBackup: importer ?? (_) async => 'yok',
      platform: 'linux',
      allowLoopback: true,
      pdfRoot: withPdf ? pcPdfs : null,
      ledger: exchange ?? plainExchange(),
    );
    await s.start(port: 0, discoveryPort: 0);
    return s;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kocum_cokcihaz_');
    store = DesktopSyncStore(File('${tmp.path}/bilgisayar/esitleme.json'));
    phone = _Dev('telefon', 'telefon0001aa', tmp);
    tablet = _Dev('tablet', 'tablet00002bb', tmp);
    pc = _Dev('pc', 'unused', tmp);
    pcPdfs = Directory('${tmp.path}/bilgisayar/pdfs');
    for (final d in [phone, tablet, pc]) {
      await d.db.customSelect('SELECT 1').get();
    }
    server = await boot();
  });

  tearDown(() async {
    for (final d in [phone, tablet]) {
      try {
        d.client.close();
      } catch (_) {}
    }
    await server.dispose();
    for (final d in [phone, tablet, pc]) {
      await d.db.close();
    }
    await tmp.delete(recursive: true);
  });

  /// Cihaz bilgisayarla eşleşir ve oturum açar; öbürlerine dokunulmaz.
  Future<void> enroll(_Dev d, {String? kind, SyncClient? client}) async {
    d.client = client ?? SyncClient(allowLoopback: true);
    await server.openPairing();
    d.computer = await d.client.pair(
      host: '127.0.0.1',
      port: server.port!,
      code: server.pairing!.code,
      phoneId: d.id,
      phoneName: 'Cihaz ${d.kind}',
      platform: 'android',
      kind: kind ?? d.kind,
    );
    d.conn = await d.client.connect(d.computer, phoneId: d.id);
  }

  Future<LedgerSyncResult> sync(_Dev d) => LedgerSync(
        ledger: d.ledger,
        client: d.client,
        schemaVersion: d.db.schemaVersion,
        mediaFile: (p) => File('${d.media.path}/$p'),
      ).run(d.conn);

  Future<void> stroke(AppDatabase db, String id, {String? pdf, int? page, int a = 1}) =>
      db.into(db.inkStrokes).insert(InkStrokesCompanion.insert(
            id: id,
            startedAtMs: 1000,
            points: Uint8List.fromList([a, 2, 3, 250, 255, 0]),
            createdAt: t0,
            updatedAt: t0,
            pdfDocumentId: Value(pdf),
            pdfPage: Value(page),
            pointCount: const Value(3),
          ));

  Future<void> pdfDoc(AppDatabase db, String sha, String title) => db.into(db.pdfDocuments).insert(PdfDocumentsCompanion.insert(
      id: sha, sha256: sha, title: title, pageCount: 12, fileName: '$title.pdf', createdAt: t0, updatedAt: t0));

  Future<Set<String>> ids(AppDatabase db, String table) async =>
      {for (final r in await db.customSelect('SELECT id FROM "$table"').get()) r.read<String>('id')};

  group('saklama biçimi', () {
    test('eski tek cihaz (telefon:) biçimi okunur; eşleşme bozulmaz, sunucu eski cihazı tanır', () async {
      await enroll(phone);
      final key = (await store.devices()).single.key;
      // Dosyayı v9.14 biçimine çevir.
      final file = File('${tmp.path}/bilgisayar/esitleme.json');
      final j = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final dev = (j['cihazlar']! as List).single as Map;
      j
        ..remove('cihazlar')
        ..['telefon'] = {
          'id': dev['id'],
          'ad': dev['ad'],
          'platform': dev['platform'],
          'anahtar': dev['anahtar'],
          'eslesme': dev['eslesme'],
        };
      await file.writeAsString(jsonEncode(j));
      await server.dispose();
      store = DesktopSyncStore(file);
      server = await boot();
      expect((await store.devices()).single.key, key);
      expect((await store.devices()).single.kind, deviceKindPhone);
      final after = jsonDecode(await file.readAsString()) as Map;
      expect(after.containsKey('telefon'), isFalse, reason: 'yeni biçime taşındı');
      expect(after['cihazlar'], hasLength(1));
      // Eski eşleşmeyle bağlanılır.
      final conn = await phone.client.connect(phone.computer.copyWith(port: server.port!), phoneId: phone.id);
      expect(conn.session, isNotEmpty);
      // Yanına yeni cihaz eklenir.
      await enroll(tablet);
      expect((await store.devices()).map((d) => d.id), [phone.id, tablet.id]);
    });

    test('cihaz türü ve son eşitleme saklanır', () async {
      await enroll(tablet, kind: deviceKindTablet);
      await sync(tablet);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final d = (await store.device(tablet.id))!;
      expect(d.isTablet, isTrue);
      expect(d.lastSyncAt, isNotNull);
    });
  });

  group('çok cihaz', () {
    test('telefon ve tablet ayrı anahtarla aynı anda eşleşik; eşzamanlı eşitleyip yakınsarlar', () async {
      await pdfDoc(phone.db, 'a' * 64, 'Telefon PDF');
      await stroke(phone.db, 's-tel', pdf: 'a' * 64, page: 1);
      await pdfDoc(tablet.db, 'b' * 64, 'Tablet PDF');
      await stroke(tablet.db, 's-tab', pdf: 'b' * 64, page: 2, a: 9);
      await pc.db.into(pc.db.anlikNotes).insert(AnlikNotesCompanion.insert(
          id: 'pc-not', createdAt: t0, updatedAt: t0, body: 'pc', searchText: const Value('pc')));

      await enroll(phone);
      await enroll(tablet); // telefon kopmaz
      final devices = await store.devices();
      expect(devices.map((d) => d.id), [phone.id, tablet.id]);
      expect(devices[0].key, isNot(devices[1].key), reason: 'her cihazın kendi anahtarı');
      expect(phone.computer.key, devices[0].key);
      expect(tablet.computer.key, devices[1].key);

      // Telefonun açık oturumu tablet eşleşince de geçerli: ikisi aynı anda eşitler.
      final first = await Future.wait([sync(phone), sync(tablet)]);
      expect(first.every((r) => r.sent > 0), isTrue);
      for (var i = 0; i < 2; i++) {
        await Future.wait([sync(phone), sync(tablet)]);
      }
      for (final t in ['ink_strokes', 'pdf_documents', 'anlik_notes']) {
        final p = await ids(phone.db, t), tb = await ids(tablet.db, t), c = await ids(pc.db, t);
        expect(p, tb, reason: t);
        expect(p, c, reason: t);
      }
      expect(await ids(phone.db, 'ink_strokes'), {'s-tel', 's-tab'});
      expect(await ids(tablet.db, 'anlik_notes'), {'pc-not'});
    });

    test('bir cihazı kaldırmak öbürünü etkilemez; kaldırılan bağlanamaz, açık oturumu da düşer', () async {
      await enroll(phone);
      await enroll(tablet);
      await stroke(phone.db, 's1');
      await server.forgetDevice(tablet.id);
      expect((await store.devices()).map((d) => d.id), [phone.id]);
      await expectLater(tablet.client.connect(tablet.computer, phoneId: tablet.id), throwsA(isA<SyncException>()));
      await expectLater(sync(tablet), throwsA(isA<SyncException>()), reason: 'açık oturum da kalktı');
      // Telefon aynı oturumla eşitlemeye devam eder.
      final r = await sync(phone);
      expect(r.sent, greaterThan(0));
      expect(await ids(pc.db, 'ink_strokes'), {'s1'});
      // Yeni cihaz eklemek de telefonu koparmaz.
      await enroll(tablet);
      expect((await sync(phone)).rounds, greaterThan(0));
    });

    test('en fazla 4 cihaz; beşincisi reddedilir ve hiçbiri kopmaz', () async {
      final extra = [
        for (var i = 3; i <= 4; i++) _Dev('telefon', 'telefon000${i}cc', tmp),
      ];
      await enroll(phone);
      await enroll(tablet);
      for (final d in extra) {
        await d.db.customSelect('SELECT 1').get();
        await enroll(d);
      }
      expect(await store.devices(), hasLength(SyncLimits.maxDevices));
      await expectLater(server.openPairing(), throwsA(isA<SyncException>()));
      final fifth = _Dev('telefon', 'telefon0005ee', tmp);
      fifth.client = SyncClient(allowLoopback: true);
      await expectLater(
        fifth.client.pair(host: '127.0.0.1', port: server.port!, code: '123456', phoneId: fifth.id, phoneName: 'x', platform: 'android'),
        throwsA(isA<SyncException>()),
      );
      expect((await sync(phone)).rounds, greaterThan(0));
      for (final d in [...extra, fifth]) {
        d.client.close();
        await d.db.close();
      }
    });

    test('aynı anda gelen istekler hata almaz, sırayla işlenir', () async {
      await enroll(phone);
      await enroll(tablet);
      for (var i = 0; i < 20; i++) {
        await stroke(phone.db, 'p$i');
        await stroke(tablet.db, 't$i');
      }
      final rs = await Future.wait([sync(phone), sync(tablet)]);
      expect(rs.every((r) => r.failed == 0), isTrue);
      await Future.wait([sync(phone), sync(tablet)]);
      await Future.wait([sync(phone), sync(tablet)]);
      expect((await ids(pc.db, 'ink_strokes')).length, 40);
      expect((await ids(phone.db, 'ink_strokes')).length, 40);
      expect((await ids(tablet.db, 'ink_strokes')).length, 40);
    });
  });

  group('tam durum', () {
    test('yeni boş cihaz bilgisayardaki eski (deftersiz) veriyi de alır; çakışma çıkmaz, geçmiş yeniden oynatılmaz', () async {
      final sha = 'c' * 64;
      // Bilgisayarda "yedekle gelmiş eski veri": deftere girmez.
      await pc.ledger.silently(() async {
        await pdfDoc(pc.db, sha, 'Eski kitap');
        await stroke(pc.db, 'eski-cizgi', pdf: sha, page: 3);
      });
      expect(await pc.ledger.maxSeq(), 0);
      // Bilgisayarda ayrıca deftere girmiş yeni bir kayıt.
      await stroke(pc.db, 'yeni-cizgi', pdf: sha, page: 4);

      await enroll(tablet);
      await tablet.ledger.setIntState(LedgerService.keyNeedSnapshot, 1);
      final r = await sync(tablet);
      expect(r.snapshotRows, greaterThanOrEqualTo(3));
      expect(r.snapshotPending, isFalse);
      expect(await ids(tablet.db, 'pdf_documents'), {sha});
      expect(await ids(tablet.db, 'ink_strokes'), {'eski-cizgi', 'yeni-cizgi'});
      expect(await tablet.db.select(tablet.db.cakismalar).get(), isEmpty);
      expect(await tablet.ledger.intState(LedgerService.keyNeedSnapshot), 0);
      // Anlık görüntü satırları cihaz defterine girmez (bilgisayara geri gitmez).
      expect(await tablet.ledger.pendingFor(0), isEmpty);

      // Cihaz eski satırı değiştirirse bilgisayarda temiz uygulanır (çakışma yok).
      await (tablet.db.update(tablet.db.pdfDocuments)..where((d) => d.id.equals(sha))).write(const PdfDocumentsCompanion(title: Value('Yeni ad')));
      await sync(tablet);
      await sync(tablet);
      expect((await pc.db.select(pc.db.pdfDocuments).getSingle()).title, 'Yeni ad');
      expect(await pc.db.select(pc.db.cakismalar).get(), isEmpty);
    });

    test('yalnızca eksik satır eklenir: var olana dokunulmaz, cihazda silinen geri gelmez', () async {
      await pc.ledger.silently(() async {
        await stroke(pc.db, 'ortak', a: 5);
        await stroke(pc.db, 'silinmis');
        await stroke(pc.db, 'bende-yok');
      });
      // Cihazda: "ortak" farklı içerikle var; "silinmis" önceden vardı ve silindi (defterde sil kaydı).
      await stroke(tablet.db, 'ortak', a: 9);
      await stroke(tablet.db, 'silinmis');
      await (tablet.db.delete(tablet.db.inkStrokes)..where((s) => s.id.equals('silinmis'))).go();
      await enroll(tablet);
      await tablet.ledger.setIntState(LedgerService.keyNeedSnapshot, 1);
      await sync(tablet);
      final rows = await tablet.db.select(tablet.db.inkStrokes).get();
      expect({for (final s in rows) s.id}, containsAll(['ortak', 'bende-yok']));
      expect(rows.any((s) => s.id == 'silinmis'), isFalse, reason: 'cihazda silinen geri gelmez');
      expect(rows.firstWhere((s) => s.id == 'ortak').points.first, 9, reason: 'var olan satıra dokunulmadı');
      expect(await tablet.db.select(tablet.db.cakismalar).get(), isEmpty);
    });

    test('bayrak kapalıysa (eski eşleşme) tam durum istenmez: eski deftersiz veri gelmez', () async {
      await pc.ledger.silently(() async => stroke(pc.db, 'eski'));
      await enroll(tablet);
      final r = await sync(tablet);
      expect(r.snapshotRows, 0);
      expect(await ids(tablet.db, 'ink_strokes'), isEmpty);
    });

    test('çok sayfalı tam durum: imleç kaldığı yerden sürer; sonuç eksiksiz', () async {
      await pc.ledger.silently(() async {
        for (var i = 0; i < 1000; i++) {
          await stroke(pc.db, 'k${i.toString().padLeft(4, '0')}');
        }
      });
      await enroll(tablet);
      await tablet.ledger.setIntState(LedgerService.keyNeedSnapshot, 1);
      final r = await sync(tablet);
      expect(r.snapshotRows, 1000);
      expect((await ids(tablet.db, 'ink_strokes')).length, 1000);
    });

    test('sayfa dökümü bozuk imleci reddeder', () async {
      expect(() => pc.ledger.snapshotPage('bozuk'), throwsA(isA<ArgumentError>()));
      expect(() => pc.ledger.snapshotPage(jsonEncode(['yok_tablo', 'x'])), throwsA(isA<ArgumentError>()));
    });
  });

  group('pdf-al', () {
    final bytes = List<int>.generate(200000, (i) => Random(7).nextInt(256) ^ (i & 255));
    final sha = sha256Hex(bytes);

    Future<void> pcHasPdf({List<int>? content, String? name}) async {
      await pdfDoc(pc.db, name ?? sha, 'Kitap');
      await pcPdfs.create(recursive: true);
      await File('${pcPdfs.path}/${name ?? sha}.pdf').writeAsBytes(content ?? bytes);
    }

    List<String> parts(Directory d) => [
          if (d.existsSync()) ...d.listSync().map((e) => e.path).where((p) => p.endsWith('.part')),
        ];

    /// Ham imzalı POST (yeni oturum; sıra 1'den).
    Future<(int, String)> rawPost(_Dev d, Object body, {bool sign = true, List<int>? key, int seq = 1, String? session}) async {
      final conn = session == null ? await d.client.connect(d.computer, phoneId: d.id) : null;
      final sess = session ?? conn!.session;
      final plain = utf8.encode(jsonEncode(body));
      final data = sealBytes(
          plain,
          SealContext(
              pairingKey: d.computer.key,
              direction: SealDirection.toReceiver,
              session: sess,
              sequence: seq,
              path: SyncPaths.pdfGet));
      final http = HttpClient()..findProxy = ((_) => 'DIRECT');
      try {
        final req = await http.openUrl('POST', Uri.parse('http://127.0.0.1:${server.port}${SyncPaths.pdfGet}'));
        if (sign) {
          req.headers
            ..set(SyncHeaders.cipher, syncCipherName)
            ..set(SyncHeaders.session, sess)
            ..set(SyncHeaders.sequence, '$seq')
            ..set(
              SyncHeaders.signature,
              requestSignature(key ?? d.computer.key,
                  method: 'POST', path: SyncPaths.pdfGet, session: sess, sequence: seq, mediaPath: '', bodyHash: sha256Hex(plain)),
            );
        }
        req.contentLength = data.length;
        req.add(data);
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        return (res.statusCode, text.length > 200 ? '' : text);
      } finally {
        http.close(force: true);
      }
    }

    test('başarı: iner, SHA-256 adla tutar, .part kalmaz; iki cihaz aynı anda indirebilir', () async {
      await pcHasPdf();
      await enroll(phone);
      await enroll(tablet);
      final progress = <int>[];
      final fut = Future.wait([
        phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf'), onProgress: (r, t) => progress.add(t)),
        tablet.client.fetchPdf(tablet.conn, sha, File('${tablet.pdfs.path}/$sha.pdf')),
      ]);
      await fut;
      for (final d in [phone, tablet]) {
        expect(sha256Hex(await File('${d.pdfs.path}/$sha.pdf').readAsBytes()), sha);
        expect(parts(d.pdfs), isEmpty);
      }
      expect(progress.last, bytes.length);
    });

    test('kopan indirme .part dosyasından sürer', () async {
      await pcHasPdf();
      await enroll(phone);
      final target = File('${phone.pdfs.path}/$sha.pdf');
      await File('${target.path}.part').writeAsBytes(bytes.sublist(0, 70000));
      await phone.client.fetchPdf(phone.conn, sha, target);
      expect(await target.readAsBytes(), bytes);
      expect(parts(phone.pdfs), isEmpty);
    });

    test('yol enjeksiyonu, bozuk ad ve negatif başlangıç hiçbir şey vermez', () async {
      await pcHasPdf();
      await enroll(phone);
      for (final name in ['../../etc/passwd', '../$sha.pdf', '${sha.toUpperCase()}.pdf', '$sha.txt', 'a/$sha.pdf', '$sha.pdf/..', '']) {
        final (status, _) = await rawPost(phone, {'yol': name, 'baslangic': 0});
        expect(status, 400, reason: name);
      }
      final (negative, _) = await rawPost(phone, {'yol': '$sha.pdf', 'baslangic': -5});
      expect(negative, 400);
      final (beyond, _) = await rawPost(phone, {'yol': '$sha.pdf', 'baslangic': bytes.length + 1});
      expect(beyond, 400);
    });

    test('imzasız, yanlış anahtarlı ve oturumsuz istek reddedilir', () async {
      await pcHasPdf();
      await enroll(phone);
      expect((await rawPost(phone, {'yol': '$sha.pdf'}, sign: false)).$1, 401);
      expect((await rawPost(phone, {'yol': '$sha.pdf'}, key: List<int>.filled(32, 7))).$1, 401);
      expect((await rawPost(phone, {'yol': '$sha.pdf'}, session: 'yok-oturum-0000')).$1, 401);
    });

    test('bilgisayarın pdf_documents satırında olmayan özet verilmez (dosya diskte olsa da)', () async {
      await pcPdfs.create(recursive: true);
      await File('${pcPdfs.path}/$sha.pdf').writeAsBytes(bytes); // satır yok
      await enroll(phone);
      await expectLater(
        phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')),
        throwsA(isA<PdfNotOnComputer>()),
      );
      expect(File('${phone.pdfs.path}/$sha.pdf').existsSync(), isFalse);
      expect(parts(phone.pdfs), isEmpty);
    });

    test('satır var, dosya yok: bilgisayarda yok denir', () async {
      await pdfDoc(pc.db, sha, 'Kitap');
      await enroll(phone);
      await expectLater(phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')), throwsA(isA<PdfNotOnComputer>()));
    });

    test('hedef symlink ise dışarıdaki dosya verilmez', () async {
      final outside = File('${tmp.path}/disari.bin')..writeAsBytesSync(bytes);
      await pdfDoc(pc.db, sha, 'Kitap');
      await pcPdfs.create(recursive: true);
      await Link('${pcPdfs.path}/$sha.pdf').create(outside.path);
      await enroll(phone);
      await expectLater(phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')), throwsA(isA<SyncException>()));
      expect(File('${phone.pdfs.path}/$sha.pdf').existsSync(), isFalse);
    });

    test('cihazda hedef symlink ise yazılmaz', () async {
      await pcHasPdf();
      await enroll(phone);
      final outside = File('${tmp.path}/disari2.bin')..writeAsBytesSync([1, 2, 3]);
      await Link('${phone.pdfs.path}/$sha.pdf').create(outside.path);
      await expectLater(phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')), throwsA(isA<SyncException>()));
      expect(outside.readAsBytesSync(), [1, 2, 3]);
    });

    test('içerik adın özetiyle uyuşmazsa istemci atar: dosya ve .part kalmaz', () async {
      final other = List<int>.generate(5000, (i) => i % 251);
      await pcHasPdf(content: other); // ad = sha(bytes), içerik başka
      await enroll(phone);
      await expectLater(
        phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('uyuşmuyor'))),
      );
      expect(File('${phone.pdfs.path}/$sha.pdf').existsSync(), isFalse);
      expect(parts(phone.pdfs), isEmpty);
    });

    test('300 MB sınırı: büyük dosya verilmez', () async {
      await pdfDoc(pc.db, sha, 'Dev');
      await pcPdfs.create(recursive: true);
      final raf = File('${pcPdfs.path}/$sha.pdf').openSync(mode: FileMode.write);
      raf.truncateSync(SyncLimits.pdf + 1);
      raf.closeSync();
      await enroll(phone);
      await expectLater(
        phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')),
        throwsA(isA<SyncException>().having((e) => e.status, 'durum', 413)),
      );
      expect(File('${phone.pdfs.path}/$sha.pdf').existsSync(), isFalse);
    });

    test('eşleşmesi kaldırılan cihaz PDF alamaz', () async {
      await pcHasPdf();
      await enroll(phone);
      await server.forgetDevice(phone.id);
      await expectLater(phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')), throwsA(isA<SyncException>()));
    });

    test('pdfRoot yoksa (bilgisayar PDF vermiyor) 404', () async {
      await server.dispose();
      server = await boot(withPdf: false);
      await pcHasPdf();
      await enroll(phone);
      await expectLater(
        phone.client.fetchPdf(phone.conn, sha, File('${phone.pdfs.path}/$sha.pdf')),
        throwsA(isA<SyncException>().having((e) => e.status, 'durum', 404)),
      );
    });

    test('PdfPull: ayar kapalıyken hiç istek yapılmaz; açıkken yalnızca eksik olan iner; iptal temizler', () async {
      await pcHasPdf();
      final counting = _CountingClient();
      await enroll(phone, client: counting);
      var enabled = false;
      PdfPull pull({SyncCancelToken? cancel}) => PdfPull(
            client: counting,
            pdfDir: phone.pdfs,
            enabled: () async => enabled,
            cancel: cancel,
          );
      final off = await pull().run(phone.conn, [sha]);
      expect(off.enabled, isFalse);
      expect(counting.pdfFetches, 0);
      expect(phone.pdfs.listSync(), isEmpty);

      // İptal edilmiş belirteç: hiçbir şey iner.
      enabled = true;
      final token = SyncCancelToken()..cancel();
      final cancelled = await pull(cancel: token).run(phone.conn, [sha]);
      expect(cancelled.cancelled, isTrue);
      expect(phone.pdfs.listSync(), isEmpty);

      final on = await pull().run(phone.conn, [sha, 'f' * 64, 'bozuk']);
      expect(on.fetched, 1);
      expect(on.notOnComputer, 1);
      expect(counting.pdfFetches, 2, reason: 'iptalde istek yok; bozuk özet atlanır');
      // Zaten var olan yeniden istenmez.
      final before = counting.pdfFetches;
      final again = await pull().run(phone.conn, [sha]);
      expect(again.fetched, 0);
      expect(counting.pdfFetches, before);
      expect(sha256Hex(File('${phone.pdfs.path}/$sha.pdf').readAsBytesSync()), sha);
    });
  });

  group('inceleme düzeltmeleri (v9.15)', () {
    test('imleç N\'de dolu cihaz tam durum isterse: N sonrası güncelleme ve silme de gelir, imleç korunur', () async {
      await stroke(pc.db, 'a');
      await stroke(pc.db, 'b');
      await enroll(tablet);
      await sync(tablet);
      await sync(tablet);
      expect(await ids(tablet.db, 'ink_strokes'), {'a', 'b'});
      final n = await tablet.ledger.intState(LedgerService.keyReceivedSeq);
      expect(n, greaterThan(0));
      // Bilgisayarda N'den sonra bir güncelleme ve bir silme.
      await (pc.db.update(pc.db.inkStrokes)..where((t) => t.id.equals('a')))
          .write(InkStrokesCompanion(points: Value(Uint8List.fromList([7, 7, 7, 250, 255, 0]))));
      await (pc.db.delete(pc.db.inkStrokes)..where((t) => t.id.equals('b'))).go();
      final m = await pc.ledger.maxSeq();
      expect(m, greaterThan(n));
      // Tam durum istenir (yeniden eşleşme ya da "her şeyi yeniden al" düğmesi).
      await tablet.ledger.setIntState(LedgerService.keyNeedSnapshot, 1);
      final r = await sync(tablet);
      expect(r.snapshotPending, isFalse);
      expect(await ids(tablet.db, 'ink_strokes'), {'a'}, reason: 'silme geldi');
      final pts = (await tablet.db.select(tablet.db.inkStrokes).getSingle()).points;
      expect(pts.first, 7, reason: 'güncelleme geldi');
      expect(await tablet.ledger.intState(LedgerService.keyReceivedSeq), greaterThanOrEqualTo(m));
    });

    test('boş cihazda imleç işarete çekilir (eski davranış korunur)', () async {
      await stroke(pc.db, 'x');
      await enroll(phone);
      await phone.ledger.setIntState(LedgerService.keyNeedSnapshot, 1);
      expect(await phone.ledger.intState(LedgerService.keyReceivedSeq), 0);
      await sync(phone);
      expect(await ids(phone.db, 'ink_strokes'), {'x'});
      expect(await phone.ledger.intState(LedgerService.keyReceivedSeq), greaterThan(0));
    });

    test('hasPdfDocument: yumuşak silinmiş belgenin PDF\'i verilmez', () async {
      final sha = 'd' * 64;
      await pdfDoc(pc.db, sha, 'Silinecek');
      expect(await pc.ledger.hasPdfDocument(sha), isTrue);
      await (pc.db.update(pc.db.pdfDocuments)..where((d) => d.id.equals(sha))).write(const PdfDocumentsCompanion(deleted: Value(true)));
      expect(await pc.ledger.hasPdfDocument(sha), isFalse);
    });

    test('tam durum fotoğraf izni cihaza özgü: A\'nın tam durumu B\'ye izin vermez', () async {
      const path = 'notes/2026/11/foto1.jpg';
      File('${pc.media.path}/$path')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await pc.ledger.silently(() async {
        await pc.db.into(pc.db.anlikNotes).insert(AnlikNotesCompanion.insert(
            id: 'fotolu', createdAt: t0, updatedAt: t0, body: path, searchText: const Value('')));
      });
      final ex = plainExchange();
      final r = await ex.handle(
        LedgerRequest(schema: pc.db.schemaVersion, device: 'a-ledger', received: 0, changes: const [], lastSeq: 0, snapshotCursor: ''),
        peer: 'cihaz-A',
      );
      expect(r.photos.map((e) => e.path), contains(path));
      expect(await ex.maySend(path, device: 'cihaz-A'), isTrue);
      expect(await ex.maySend(path, device: 'cihaz-B'), isFalse);
    });

    test('kimlik taklidi: A\'nın oturumu B\'nin anahtarıyla imzalanırsa reddedilir', () async {
      await enroll(phone);
      await enroll(tablet);
      final body = utf8.encode(jsonEncode(
          LedgerRequest(schema: pc.db.schemaVersion, device: 'x' * 8, received: 0, changes: const [], lastSeq: 0).toJson()));
      Future<int> post(List<int> key, int seq) async {
        final http = HttpClient();
        try {
          final req = await http.postUrl(Uri.parse('http://127.0.0.1:${server.port}${SyncPaths.ledger}'));
          req.headers
            ..set(SyncHeaders.cipher, syncCipherName)
            ..set(SyncHeaders.session, phone.conn.session)
            ..set(SyncHeaders.sequence, '$seq')
            ..set(SyncHeaders.signature,
                requestSignature(key, method: 'POST', path: SyncPaths.ledger, session: phone.conn.session, sequence: seq, mediaPath: '', bodyHash: sha256Hex(body)));
          req.add(sealBytes(
              body,
              SealContext(
                  pairingKey: phone.computer.key,
                  direction: SealDirection.toReceiver,
                  session: phone.conn.session,
                  sequence: seq,
                  path: SyncPaths.ledger)));
          final res = await req.close();
          await res.drain<void>();
          return res.statusCode;
        } finally {
          http.close(force: true);
        }
      }

      expect(await post(tablet.computer.key, 1), 401, reason: 'B\'nin anahtarı A\'nın oturumunda geçmez');
      // Oturum ilk hatalı istekte düşer; A yeniden bağlanır, kendi anahtarı çalışır.
      phone.conn = await phone.client.connect(phone.computer, phoneId: phone.id);
      expect((await sync(phone)).failed, 0);
    });

    test('başka cihazın kimliğiyle yanlış kodla eşleşme mevcut cihazı ezmez; doğru kodlu yeniden eşleşme yalnız o cihazı yeniler', () async {
      await enroll(phone);
      await enroll(tablet);
      final keyA = (await store.device(phone.id))!.key;
      final keyB = (await store.device(tablet.id))!.key;
      await server.openPairing();
      final wrong = server.pairing!.code == '000000' ? '111111' : '000000';
      final rogue = SyncClient(allowLoopback: true);
      await expectLater(
        rogue.pair(host: '127.0.0.1', port: server.port!, code: wrong, phoneId: phone.id, phoneName: 'Sahte', platform: 'android'),
        throwsA(isA<SyncException>()),
      );
      expect((await store.device(phone.id))!.key, keyA);
      expect((await sync(phone)).failed, 0);
      // Yetkili yeniden eşleşme (kod doğru): yalnız A'nın anahtarı değişir, B etkilenmez.
      final again = await rogue.pair(
          host: '127.0.0.1', port: server.port!, code: server.pairing!.code, phoneId: phone.id, phoneName: 'Yeni', platform: 'android');
      expect((await store.device(phone.id))!.key, isNot(keyA));
      expect(again.key, (await store.device(phone.id))!.key);
      expect((await store.device(tablet.id))!.key, keyB);
      await expectLater(sync(phone), throwsA(isA<SyncException>()), reason: 'eski anahtar/oturum artık geçmez');
      expect((await sync(tablet)).failed, 0);
      rogue.close();
    });

    test('kilit: bekleme sınırlı (409 meşgul) ve bekleyen işin cihazı kaldırılırsa iş UYGULANMAZ', () async {
      final gate = _GateExchange(plainExchange());
      await server.dispose();
      server = await boot(exchange: gate, lockWait: const Duration(milliseconds: 400));
      await enroll(phone);
      await enroll(tablet);
      await stroke(phone.db, 'p1');
      await stroke(tablet.db, 't1');
      final tabId = await tablet.ledger.deviceId();
      gate.hold = Completer<void>();
      final first = sync(phone);
      while (gate.entered == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Sınır aşılır: 409, iş hiç çalışmaz.
      await expectLater(sync(tablet), throwsA(isA<SyncException>()));
      expect(gate.devices, isNot(contains(tabId)));
      expect(await ids(pc.db, 'ink_strokes'), isEmpty, reason: 'kilit tutulurken hiçbir şey uygulanmadı');
      gate.hold!.complete();
      await first;
      expect(await ids(pc.db, 'ink_strokes'), {'p1'});

      // Bekleyen isteğin cihazı kaldırılırsa kilitten çıkınca uygulanmaz.
      await server.dispose();
      server = await boot(exchange: gate, lockWait: const Duration(seconds: 10));
      await enroll(phone);
      await enroll(tablet);
      gate.hold = Completer<void>();
      final entered = gate.entered;
      final second = sync(phone);
      while (gate.entered == entered) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final waiting = sync(tablet);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await server.forgetDevice(tablet.id);
      gate.hold!.complete();
      await second;
      await expectLater(waiting, throwsA(isA<SyncException>()));
      expect(gate.devices, isNot(contains(tabId)));
      expect(await ids(pc.db, 'ink_strokes'), isNot(contains('t1')));
    });

    test('yedek sürerken defter isteği beklemez: hemen 409 meşgul', () async {
      final release = Completer<void>();
      var started = false;
      await server.dispose();
      server = await boot(importer: (_) async {
        started = true;
        await release.future;
        return 'tamam';
      });
      await enroll(phone);
      await enroll(tablet);
      final zip = File('${tmp.path}/yedek.zip')..writeAsBytesSync(List.filled(64, 1));
      final backup = phone.client.sendBackup(phone.conn, zip);
      while (!started) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final sw = Stopwatch()..start();
      await expectLater(sync(tablet), throwsA(isA<SyncException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)), reason: '20 sn kilit beklemedi');
      release.complete();
      await backup;
      // Yedek bitince defter isteği yine çalışır.
      tablet.conn = await tablet.client.connect(tablet.computer, phoneId: tablet.id);
      expect((await sync(tablet)).failed, 0);
    });

    test('cihaz kaldırılınca süren PDF akışı kesilir', () async {
      final bytes = Uint8List(24 * 1024 * 1024);
      for (var i = 0; i < bytes.length; i += 4099) {
        bytes[i] = i & 255;
      }
      final sha = sha256Hex(bytes);
      pcPdfs.createSync(recursive: true);
      File('${pcPdfs.path}/$sha.pdf').writeAsBytesSync(bytes);
      await pdfDoc(pc.db, sha, 'Buyuk');
      await enroll(tablet);
      final target = File('${tablet.pdfs.path}/$sha.pdf');
      var cut = false;
      Future<void>? forgetting;
      await expectLater(
        tablet.client.fetchPdf(tablet.conn, sha, target, onProgress: (received, total) {
          if (!cut && received > 0) {
            cut = true;
            forgetting = server.forgetDevice(tablet.id);
          }
        }),
        throwsA(isA<Object>()),
      );
      expect(cut, isTrue);
      await forgetting;
      expect(target.existsSync(), isFalse, reason: 'yarım PDF tamamlanmış gibi kalmaz');
    });

    test('kilidi gerçekten sınar: iki cihaz aynı anda aynı tabloya yazarken bilgisayar işlemleri iç içe girmez', () async {
      // Kilit yoksa iki handle() iç içe girer (applyRemote ve pendingFor aralarında kesişir).
      final probe = _GateExchange(plainExchange(), slow: const Duration(milliseconds: 40));
      await server.dispose();
      server = await boot(exchange: probe);
      await enroll(phone);
      await enroll(tablet);
      for (var i = 0; i < 6; i++) {
        await stroke(phone.db, 'p$i');
        await stroke(tablet.db, 't$i');
      }
      await Future.wait([sync(phone), sync(tablet)]);
      await Future.wait([sync(phone), sync(tablet)]);
      await Future.wait([sync(phone), sync(tablet)]);
      expect(probe.maxConcurrent, 1, reason: '_dbLock olmadan en az iki istek iç içe çalışırdı');
      expect((await ids(pc.db, 'ink_strokes')).length, 12);
      expect((await ids(phone.db, 'ink_strokes')).length, 12);
      expect((await ids(tablet.db, 'ink_strokes')).length, 12);
    });
  });
}

/// Sarmalayıcı: çağrıları sayar, ilkini [hold] bırakılana dek tutar; eşzamanlılığı ölçer.
class _GateExchange extends LedgerExchange {
  _GateExchange(LedgerExchange inner, {this.slow})
      : _inner = inner,
        super(ledger: inner.ledger, schemaVersion: inner.schemaVersion, mediaFile: inner.mediaFile);

  final LedgerExchange _inner;
  final Duration? slow;
  Completer<void>? hold;
  int entered = 0;
  int _running = 0;
  int maxConcurrent = 0;
  final devices = <String>[];

  @override
  Future<LedgerResponse> handle(LedgerRequest req, {String? peer}) async {
    entered++;
    devices.add(req.device);
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    try {
      final h = hold;
      if (h != null && !h.isCompleted) await h.future;
      if (slow != null) await Future<void>.delayed(slow!);
      return await _inner.handle(req, peer: peer);
    } finally {
      _running--;
    }
  }

  @override
  Future<bool> maySend(String path, {required String device}) => _inner.maySend(path, device: device);

  @override
  Future<bool> hasPdfDocument(String sha256) => _inner.hasPdfDocument(sha256);
}
