import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/export/zip_reader.dart';
import 'package:kocum/core/export/zip_writer.dart';
import 'package:kocum/desktop/sync/data/desktop_sync_store.dart';
import 'package:kocum/desktop/sync/data/sync_server.dart';
import 'package:kocum/features/sync/data/phone_sync_store.dart';
import 'package:kocum/features/sync/data/sync_client.dart';
import 'package:kocum/features/sync/domain/sync_crypto.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

/// Gerçek sunucu ve istemci, aynı makinede (127.0.0.1). Telefon ve Android
/// gerekmez; yalnızca "aynı bilgisayardan gelen istek" testler için açılır.
void main() {
  late Directory tmp;
  late DesktopSyncStore desktopStore;
  late SyncServer server;
  late SyncClient client;
  late Directory phoneMedia;
  late List<List<String>> imported;

  const phoneId = 'telefon0001aa';

  Future<String> importer(File zip) async {
    final reader = await ZipFileReader.open(zip);
    try {
      imported.add([for (final e in reader.entries) e.name]);
    } finally {
      await reader.close();
    }
    return '3 yeni, 1 güncellenen';
  }

  Future<SyncServer> startServer({String platform = 'linux', bool allowLoopback = true}) async {
    final s = SyncServer(
      store: desktopStore,
      mediaRoot: Directory('${tmp.path}/bilgisayar/media'),
      workDir: Directory('${tmp.path}/bilgisayar'),
      importBackup: importer,
      platform: platform,
      allowLoopback: allowLoopback,
    );
    await s.start(port: 0, discoveryPort: 0);
    return s;
  }

  // Widget testlerinin sahte HttpClient'ı devrede olmasın: gerçek bağlantı.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kocum_esitleme_');
    desktopStore = DesktopSyncStore(File('${tmp.path}/bilgisayar/esitleme.json'));
    imported = [];
    server = await startServer();
    client = SyncClient(allowLoopback: true);
    phoneMedia = Directory('${tmp.path}/telefon/media');
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await tmp.delete(recursive: true);
  });

  Future<PairedComputer> pair({String? code, String platform = 'android', String id = phoneId}) async =>
      client.pair(
        host: '127.0.0.1',
        port: server.port!,
        code: code ?? server.pairing!.code,
        phoneId: id,
        phoneName: 'Android · TELE',
        platform: platform,
      );

  String wrongCode() => server.pairing!.code == '000000' ? '111111' : '000000';

  Future<MediaEntry> phonePhoto(String path, int size) async {
    final f = File('${phoneMedia.path}/$path');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List<int>.generate(size, (i) => i % 251));
    return MediaEntry(path, size);
  }

  /// Sunucuya ham istek (saldırı denemeleri için).
  Future<(int, String)> raw(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int> body = const [],
    int? port,
  }) async {
    final http = HttpClient()..findProxy = ((_) => 'DIRECT');
    try {
      final req = await http.openUrl(method, Uri(scheme: 'http', host: '127.0.0.1', port: port ?? server.port, path: path));
      headers.forEach(req.headers.set);
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      final json = jsonDecode(text);
      return (res.statusCode, json is Map ? '${json['hata'] ?? ''}' : '');
    } finally {
      http.close(force: true);
    }
  }

  group('eşleştirme', () {
    test('kod ekranı açık değilken eşleşilmez', () async {
      await expectLater(
        client.pair(host: '127.0.0.1', port: server.port!, code: '123456', phoneId: phoneId, phoneName: 'x', platform: 'android'),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('eşleştirme açık değil'))),
      );
    });

    test('doğru kodla iki taraf aynı anahtarı bulur; anahtar ağdan geçmez', () async {
      await server.openPairing();
      final computer = await pair();
      final phone = (await desktopStore.phone())!;
      expect(phone.id, phoneId);
      expect(phone.platform, 'android');
      expect(computer.key, phone.key);
      expect(computer.id, await desktopStore.computerId());
      expect(server.pairing, isNull, reason: 'kod tek kullanımlık');
    });

    test('yanlış kod hak düşürür; 5. yanlışta kod geçersiz olur', () async {
      await server.openPairing();
      final wrong = wrongCode();
      for (var i = 1; i < SyncLimits.pairingAttempts; i++) {
        await expectLater(
          pair(code: wrong),
          throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('Kalan hak: ${SyncLimits.pairingAttempts - i}'))),
        );
      }
      await expectLater(
        pair(code: wrong),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('yeni kod'))),
      );
      expect(server.pairing, isNull);
      expect(await desktopStore.phone(), isNull);
    });

    test('Windows (Android olmayan) cihaz reddedilir', () async {
      final code = (await server.openPairing()).code;
      await expectLater(
        pair(code: code, platform: 'windows'),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('yalnızca Android'))),
      );
      expect(await desktopStore.phone(), isNull);
    });

    test('birden çok cihaz: ikinci cihaz eşleşir, birincisi kopmaz; yuvalar dolunca yenisi reddedilir', () async {
      await server.openPairing();
      await pair();
      // Yeni cihaz için kod ekranı yine açılır; mevcut eşleşme kopmaz.
      final code = (await server.openPairing()).code;
      await pair(code: code, id: 'telefon0002bb');
      expect((await desktopStore.devices()).map((d) => d.id), [phoneId, 'telefon0002bb']);
      for (final id in ['telefon0003cc', 'telefon0004dd']) {
        await pair(code: (await server.openPairing()).code, id: id);
      }
      expect((await desktopStore.devices()), hasLength(SyncLimits.maxDevices));
      await expectLater(server.openPairing(), throwsA(isA<SyncException>()));
      await expectLater(
        client.pair(host: '127.0.0.1', port: server.port!, code: '123456', phoneId: 'telefon0005ee', phoneName: 'x', platform: 'android'),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('dolu'))),
      );
      expect((await desktopStore.phone())!.id, phoneId);
    });

    test('telefon tarafı da tek bilgisayar tutar', () async {
      final store = PhoneSyncStore(() async => File('${tmp.path}/telefon/esitleme.json'));
      await server.openPairing();
      final computer = await pair();
      await store.saveComputer(computer);
      await store.saveComputer(computer.copyWith(host: '10.0.0.7'));
      expect((await store.computer())!.host, '10.0.0.7');
      final other = PairedComputer(
        id: 'baskabilgisayar1',
        name: 'B',
        host: '10.0.0.8',
        port: 1,
        key: List.filled(32, 0),
        pairedAt: DateTime(2026),
      );
      await expectLater(store.saveComputer(other), throwsA(isA<SyncException>()));
      await store.removeComputer();
      await store.saveComputer(other);
      expect((await store.computer())!.id, 'baskabilgisayar1');
      expect(await store.phoneId(), await store.phoneId(), reason: 'kimlik kalıcı');
    });
  });

  group('aktarım', () {
    late PairedComputer computer;

    setUp(() async {
      await server.openPairing();
      computer = await pair();
    });

    test('yalnızca eksik fotoğraflar gider; kesilirse kaldığı yerden devam eder; yedek içe aktarılır', () async {
      final a = await phonePhoto('questions/2026/10/a.webp', 1000);
      final b = await phonePhoto('solutions/2026/10/b.webp', 2000);
      final c = await phonePhoto('notes/2026/11/c.jpg', 3000);
      final all = [a, b, c];

      // İlk gönderim "c"den önce kesilmiş olsun.
      var conn = await client.connect(computer, phoneId: phoneId);
      var missing = await client.missingPhotos(conn, all);
      expect(missing.missing, [a.path, b.path, c.path]);
      await client.sendPhoto(conn, a, File('${phoneMedia.path}/${a.path}'));
      await client.sendPhoto(conn, b, File('${phoneMedia.path}/${b.path}'));

      // Yeni bağlantı: yalnızca "c" eksik.
      conn = await client.connect(computer, phoneId: phoneId);
      missing = await client.missingPhotos(conn, all);
      expect(missing.missing, [c.path]);
      await client.sendPhoto(conn, c, File('${phoneMedia.path}/${c.path}'));

      final received = File('${tmp.path}/bilgisayar/media/${c.path}');
      expect(await received.readAsBytes(), await File('${phoneMedia.path}/${c.path}').readAsBytes());

      // Yarım kalmış (boyutu tutmayan) dosya yeniden istenir.
      await File('${tmp.path}/bilgisayar/media/${a.path}').writeAsBytes([1, 2, 3]);
      missing = await client.missingPhotos(conn, all);
      expect(missing.missing, [a.path]);

      final zip = File('${tmp.path}/telefon/yedek.zip');
      await zip.writeAsBytes((ZipWriter()
            ..addText('kocum_yedek.json', '{"format":"kocum.backup"}')
            ..add('kocum.db', [1, 2, 3]))
          .finish());
      final result = await client.sendBackup(conn, zip);
      expect(result.summary, '3 yeni, 1 güncellenen');
      expect(imported.single, ['kocum_yedek.json', 'kocum.db']);
      final leftovers = await Directory('${tmp.path}/bilgisayar/kablosuz').list().toList();
      expect(leftovers, isEmpty, reason: 'geçici dosyalar silinir');
    });

    test('kurallara uymayan yol sunulsa da bilgisayar istemez', () async {
      final a = await phonePhoto('questions/2026/10/a.webp', 10);
      final conn = await client.connect(computer, phoneId: phoneId);
      final r = await client.missingPhotos(conn, [a, const MediaEntry('../../.ssh/authorized_keys', 10)]);
      expect(r.missing, [a.path]);
      expect(r.rejected, 1);
    });

    test('aynı istek ikinci kez gönderilirse reddedilir ve oturum kapanır', () async {
      final conn = await client.connect(computer, phoneId: phoneId);
      final body = utf8.encode(jsonEncode(const PhotoListRequest([]).toJson()));
      Map<String, String> headers(int seq) => {
            SyncHeaders.session: conn.session,
            SyncHeaders.sequence: '$seq',
            SyncHeaders.signature: requestSignature(
              computer.key,
              method: 'POST',
              path: SyncPaths.photoList,
              session: conn.session,
              sequence: seq,
              mediaPath: '',
              bodyHash: sha256Hex(body),
            ),
          };
      expect((await raw('POST', SyncPaths.photoList, headers: headers(1), body: body)).$1, 200);
      final replay = await raw('POST', SyncPaths.photoList, headers: headers(1), body: body);
      expect(replay.$1, 401);
      expect(replay.$2, contains('Sıra numarası'));
      // Oturum kapandı: doğru sıradaki istek de artık geçmez; yeni oturum gerekir.
      expect((await raw('POST', SyncPaths.photoList, headers: headers(2), body: body)).$1, 401);
      final again = await client.connect(computer, phoneId: phoneId);
      expect((await client.missingPhotos(again, const [])).missing, isEmpty);
    });

    test('yanlış anahtarla imzalanan istek reddedilir', () async {
      final conn = await client.connect(computer, phoneId: phoneId);
      final body = utf8.encode(jsonEncode(const PhotoListRequest([]).toJson()));
      final r = await raw('POST', SyncPaths.photoList, body: body, headers: {
        SyncHeaders.session: conn.session,
        SyncHeaders.sequence: '1',
        SyncHeaders.signature: requestSignature(
          List.filled(32, 9),
          method: 'POST',
          path: SyncPaths.photoList,
          session: conn.session,
          sequence: 1,
          mediaPath: '',
          bodyHash: sha256Hex(body),
        ),
      });
      expect(r.$1, 401);
      expect(r.$2, contains('İmza'));
    });

    test('anahtarı olmayan bir telefon oturum açamaz', () async {
      final fake = PairedComputer(
        id: computer.id,
        name: computer.name,
        host: computer.host,
        port: computer.port,
        key: List.filled(32, 7),
        pairedAt: computer.pairedAt,
      );
      await expectLater(
        client.connect(fake, phoneId: phoneId),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('Anahtar tutmadı'))),
      );
    });

    test('"../" ile ya da bağlantıyla (symlink) klasör dışına yazılamaz', () async {
      final conn = await client.connect(computer, phoneId: phoneId);
      final evil = File('${tmp.path}/kotu.bin')..writeAsBytesSync([1, 2, 3]);
      await expectLater(
        client.sendPhoto(conn, const MediaEntry('../../disari.webp', 3), evil),
        throwsA(isA<SyncException>()),
      );

      final outside = Directory('${tmp.path}/disarisi')..createSync();
      await Directory('${tmp.path}/bilgisayar/media/questions/2026').create(recursive: true);
      await Link('${tmp.path}/bilgisayar/media/questions/2026/10').create(outside.path);
      final conn2 = await client.connect(computer, phoneId: phoneId);
      await expectLater(
        client.sendPhoto(conn2, const MediaEntry('questions/2026/10/a.webp', 3), evil),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('alanı dışı'))),
      );
      expect(outside.listSync(), isEmpty);
    });

    test('eşleşme bilgisayardan kaldırılınca telefon bağlanamaz', () async {
      await server.forgetDevice(phoneId);
      await expectLater(client.connect(computer, phoneId: phoneId), throwsA(isA<SyncException>()));
    });
  });

  group('ağ korumaları', () {
    test('tarayıcıdan gelen ve alan adıyla gelen istek reddedilir', () async {
      expect((await raw('GET', SyncPaths.hello)).$1, 200);
      expect((await raw('GET', SyncPaths.hello, headers: {'origin': 'http://kotu.example'})).$1, 403);
      expect((await raw('GET', SyncPaths.hello, headers: {'sec-fetch-mode': 'no-cors'})).$1, 403);
      expect((await raw('GET', SyncPaths.hello, headers: {'host': 'kotu.example:47321'})).$1, 403);
      expect((await raw('GET', '/baska/bir/yol')).$1, 404);
    });

    test('çok hatalı istek atan adres bir süre yasaklanır', () async {
      for (var i = 0; i < SyncLimits.failuresPerAddress; i++) {
        await raw('GET', SyncPaths.hello, headers: {'origin': 'http://kotu.example'});
      }
      expect((await raw('GET', SyncPaths.hello)).$1, 429);
    });

    test('yerel ağ dışından (burada: aynı bilgisayardan) gelen istek varsayılan olarak reddedilir', () async {
      final strict = await startServer(allowLoopback: false);
      try {
        expect((await raw('GET', SyncPaths.hello, port: strict.port)).$1, 403);
      } finally {
        await strict.dispose();
      }
    });

    test('telefon yerel ağ dışındaki adrese hiç bağlanmaz', () async {
      final strictClient = SyncClient();
      try {
        for (final host in ['127.0.0.1', '8.8.8.8', 'kotu.example']) {
          await expectLater(
            strictClient.hello(host, 47321),
            throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('yerel ağda'))),
          );
        }
      } finally {
        strictClient.close();
      }
    });

    test('bulma: Linux bilgisayar bulunur; Windows bildiren listelenmez ve ona gönderilmez', () async {
      final found = await client.discover(
        targets: [InternetAddress.loopbackIPv4],
        port: server.discoveryPort!,
        wait: const Duration(milliseconds: 600),
      );
      expect(found.map((c) => c.id), [await desktopStore.computerId()]);
      expect(found.single.port, server.port);

      final windows = await startServer(platform: 'windows');
      try {
        final none = await client.discover(
          targets: [InternetAddress.loopbackIPv4],
          port: windows.discoveryPort!,
          wait: const Duration(milliseconds: 600),
        );
        expect(none, isEmpty);
        await expectLater(
          client.hello('127.0.0.1', windows.port!),
          throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('Windows kabul edilmez'))),
        );
      } finally {
        await windows.dispose();
      }
    });
  });
}
