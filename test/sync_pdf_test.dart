import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/desktop/sync/data/desktop_sync_store.dart';
import 'package:kocum/desktop/sync/data/sync_server.dart';
import 'package:kocum/features/sync/data/pdf_sync.dart';
import 'package:kocum/features/sync/data/phone_sync_store.dart';
import 'package:kocum/features/sync/data/sync_client.dart';
import 'package:kocum/features/sync/domain/pdf_rules.dart';
import 'package:kocum/features/sync/domain/sync_crypto.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

/// PDF dosyası aktarımı (T7): gerçek sunucu ve istemci 127.0.0.1'de.
class _SpyClient extends SyncClient {
  _SpyClient() : super(allowLoopback: true);

  int pdfCalls = 0;

  @override
  Future<PdfSendResult> sendPdf(SyncConnection connection, PdfOffer offer, File file,
      {void Function(int sent, int total)? onProgress, SyncCancelToken? cancel}) {
    pdfCalls++;
    return super.sendPdf(connection, offer, file, onProgress: onProgress, cancel: cancel);
  }
}

void main() {
  late Directory tmp;
  late Directory pdfRoot, incoming, phonePdfs;
  late SyncServer server;
  late _SpyClient client;
  late PairedComputer computer;
  late SyncConnection conn;

  const phoneId = 'tablet00002bb';

  setUpAll(() => HttpOverrides.global = null);

  Future<void> boot({bool withPdf = true}) async {
    server = SyncServer(
      store: DesktopSyncStore(File('${tmp.path}/bilgisayar/esitleme.json')),
      mediaRoot: Directory('${tmp.path}/bilgisayar/media'),
      workDir: Directory('${tmp.path}/bilgisayar'),
      importBackup: (_) async => 'yok',
      platform: 'linux',
      allowLoopback: true,
      pdfRoot: withPdf ? pdfRoot : null,
    );
    await server.start(port: 0, discoveryPort: 0);
    await server.openPairing();
    computer = await client.pair(
      host: '127.0.0.1',
      port: server.port!,
      code: server.pairing!.code,
      phoneId: phoneId,
      phoneName: 'Android · TABL',
      platform: 'android',
    );
    conn = await client.connect(computer, phoneId: phoneId);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kocum_pdf_');
    pdfRoot = Directory('${tmp.path}/bilgisayar/pdfs');
    incoming = Directory('${tmp.path}/bilgisayar/kablosuz');
    phonePdfs = Directory('${tmp.path}/tablet/pdfs')..createSync(recursive: true);
    client = _SpyClient();
    await boot();
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await tmp.delete(recursive: true);
  });

  List<int> bytesOf(int n, [int seed = 1]) {
    final r = Random(seed);
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  Future<PdfOffer> phonePdf(List<int> bytes) async {
    final sha = sha256Hex(bytes);
    await File('${phonePdfs.path}/$sha.pdf').writeAsBytes(bytes);
    return PdfOffer(sha, bytes.length);
  }

  List<String> leftovers() => [
        for (final d in [pdfRoot, incoming])
          if (d.existsSync()) ...d.listSync().whereType<File>().map((f) => f.path).where((p) => p.endsWith('.part')),
      ];

  Map<String, String> signedHeaders(String name, String signedHash, int seq, {List<int>? key, String? session}) => {
        SyncHeaders.session: session ?? conn.session,
        SyncHeaders.sequence: '$seq',
        SyncHeaders.mediaPath: name,
        SyncHeaders.signature: requestSignature(
          key ?? computer.key,
          method: 'PUT',
          path: SyncPaths.pdf,
          session: session ?? conn.session,
          sequence: seq,
          mediaPath: name,
          bodyHash: signedHash,
        ),
      };

  /// Ham HTTP isteği. [declared]: Content-Length; [body]'nin hepsi gönderilir;
  /// [cut]: gövdenin yalnızca bu kadarı gönderilip bağlantı koparılır.
  Future<(int, String)?> raw(
    Map<String, String> headers, {
    required int declared,
    List<int> body = const [],
    int? cut,
    String path = SyncPaths.pdf,
  }) async {
    final socket = await Socket.connect('127.0.0.1', server.port!);
    final response = BytesBuilder();
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    // Yanıt bitince (başlık + Content-Length kadar gövde) ya da bağlantı kapanınca.
    socket.listen((chunk) {
      response.add(chunk);
      final text = latin1.decode(response.toBytes());
      final end = text.indexOf('\r\n\r\n');
      final len = RegExp(r'content-length: (\d+)', caseSensitive: false).firstMatch(text)?.group(1);
      if (end >= 0 && len != null && text.length - end - 4 >= int.parse(len)) finish();
    }, onDone: finish, onError: (_) => finish());
    final head = StringBuffer('PUT $path HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nContent-Length: $declared\r\nConnection: close\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('\r\n');
    socket.add(utf8.encode(head.toString()));
    try {
      socket.add(cut == null ? body : body.sublist(0, cut));
      await socket.flush();
    } on SocketException {
      // sunucu erken yanıtlayıp kapatmış olabilir
    }
    if (cut != null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.destroy();
      return null;
    }
    await done.future.timeout(const Duration(seconds: 10));
    socket.destroy();
    final text = utf8.decode(response.takeBytes(), allowMalformed: true);
    final status = int.parse(text.split(' ')[1]);
    final json = text.substring(text.indexOf('\r\n\r\n') + 4);
    final m = RegExp(r'"hata":"([^"]*)"').firstMatch(json);
    return (status, m?.group(1) ?? json);
  }

  group('başarı', () {
    test('PDF gelir, özet adla tutar, geçici dosya kalmaz, ilerleme toplamı bulur', () async {
      final bytes = bytesOf(3 * 1024 * 1024 + 17);
      final offer = await phonePdf(bytes);
      final progress = <int>[];
      final r = await client.sendPdf(conn, offer, File('${phonePdfs.path}/${offer.name}'), onProgress: (s, t) {
        expect(t, bytes.length);
        progress.add(s);
      });
      expect(r.alreadyThere, isFalse);
      expect(progress.last, bytes.length);
      expect(progress, orderedEquals([...progress]..sort()));
      final stored = File('${pdfRoot.path}/${offer.name}');
      expect(stored.readAsBytesSync(), bytes);
      expect(sha256Hex(stored.readAsBytesSync()), offer.sha256);
      expect(leftovers(), isEmpty);
    });

    test('aynı özet bilgisayarda varsa yeniden aktarılmaz: gövde hiç gitmez, dosya dokunulmaz', () async {
      final bytes = bytesOf(24 * 1024 * 1024);
      final offer = await phonePdf(bytes);
      final file = File('${phonePdfs.path}/${offer.name}');
      expect((await client.sendPdf(conn, offer, file)).alreadyThere, isFalse);
      final stored = File('${pdfRoot.path}/${offer.name}');
      final before = stored.statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final again = await client.connect(computer, phoneId: phoneId);
      var progressCalls = 0;
      final r = await client.sendPdf(again, offer, file, onProgress: (_, __) => progressCalls++);
      expect(r.alreadyThere, isTrue);
      expect(progressCalls, 0, reason: 'gövde yollanmadı');
      expect(stored.statSync().modified, before);
      expect(leftovers(), isEmpty);
      // Oturum çalışır durumda kalır.
      expect((await client.missingPhotos(again, const [])).missing, isEmpty);
    });

    test('önce-sor: yoksa "zatenVar: false" ve hiçbir şey yazılmaz; varsa true', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      final emptyHash = sha256Hex(const <int>[]);
      final no = await raw(signedHeaders('$sha.pdf', emptyHash, 1), declared: 0);
      expect(no!.$1, 200);
      expect(no.$2, contains('"zatenVar":false'));
      expect(Directory(pdfRoot.path).existsSync() ? Directory(pdfRoot.path).listSync() : <Object>[], isEmpty);
      await pdfRoot.create(recursive: true);
      File('${pdfRoot.path}/$sha.pdf').writeAsBytesSync(body);
      final yes = await raw(signedHeaders('$sha.pdf', emptyHash, 2), declared: 0);
      expect(yes!.$2, contains('"zatenVar":true'));
    });

    test('gövdeli istek aradan zaten varsa yeniden yazılmaz (zatenVar)', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      await pdfRoot.create(recursive: true);
      final stored = File('${pdfRoot.path}/$sha.pdf')..writeAsBytesSync(body);
      final before = stored.statSync().modified;
      final r = await raw(signedHeaders('$sha.pdf', sha, 1), declared: body.length, body: body);
      expect(r!.$2, contains('"zatenVar":true'));
      expect(stored.statSync().modified, before);
      expect(incoming.listSync(), isEmpty);
    });

    test('masaüstü okuyucunun klasör düzeni: pdfs/<sha256>.pdf', () async {
      final offer = await phonePdf(bytesOf(1000));
      await client.sendPdf(conn, offer, File('${phonePdfs.path}/${offer.name}'));
      expect(Directory(pdfRoot.path).listSync().map((e) => e.path.split('/').last), [offer.name]);
    });
  });

  group('doğrulama ve saldırılar', () {
    test('adındaki özetle içeriği tutmayan PDF reddedilir ve dosya silinir', () async {
      final real = bytesOf(5000, 1), other = bytesOf(5000, 2);
      final name = '${sha256Hex(real)}.pdf';
      // İmza adın özetiyle atılmış (dürüst istemci gibi) ama gövde başka.
      final r = await raw(signedHeaders(name, sha256Hex(real), 1), declared: other.length, body: other);
      expect(r!.$1, 400);
      expect(r.$2, contains('uyuşmuyor'));
      expect(File('${pdfRoot.path}/$name').existsSync(), isFalse);
      expect(File('${pdfRoot.path}/${sha256Hex(other)}.pdf').existsSync(), isFalse);
      expect(leftovers(), isEmpty);
      expect(incoming.listSync(), isEmpty);
    });

    test('imza gövdenin gerçek özetiyle atılmışsa (ad başka) reddedilir', () async {
      final real = bytesOf(5000, 1), other = bytesOf(5000, 2);
      final name = '${sha256Hex(real)}.pdf';
      final r = await raw(signedHeaders(name, sha256Hex(other), 1), declared: other.length, body: other);
      expect(r!.$1, 401);
      expect(r.$2, contains('İmza'));
      expect(Directory(pdfRoot.path).existsSync() ? Directory(pdfRoot.path).listSync() : <Object>[], isEmpty);
    });

    test('boyut üst sınırı: 300 MB üstü gövde okunmadan reddedilir', () async {
      final sha = sha256Hex([1, 2, 3]);
      final r = await raw(signedHeaders('$sha.pdf', sha, 1), declared: SyncLimits.pdf + 1);
      expect(r!.$1, 413);
      expect(Directory(pdfRoot.path).existsSync() ? Directory(pdfRoot.path).listSync() : <Object>[], isEmpty);
      expect(leftovers(), isEmpty);
    });

    test('istemci de üst sınırı ve bozuk adı yollamadan reddeder', () async {
      final f = File('${phonePdfs.path}/x.pdf')..writeAsBytesSync([1]);
      await expectLater(client.sendPdf(conn, PdfOffer(sha256Hex([1]), SyncLimits.pdf + 1), f), throwsA(isA<SyncException>()));
      await expectLater(client.sendPdf(conn, const PdfOffer('../etc/passwd', 1), f), throwsA(isA<SyncException>()));
      await expectLater(client.sendPdf(conn, PdfOffer(sha256Hex([9]), 1), f), throwsA(isA<SyncException>())); // özet tutmaz
    });

    test('bilgisayarda varsa yerel dosya hiç özetlenmez (adın özeti güvenilir); yoksa tek okumayla özet doğrulanır', () async {
      final body = bytesOf(2000);
      final sha = sha256Hex(body);
      await pdfRoot.create(recursive: true);
      File('${pdfRoot.path}/$sha.pdf').writeAsBytesSync(body);
      // Yerel dosya adla uyuşmuyor: özetlenseydi hata verirdi. Soru adla sorulur, dosya okunmaz.
      final f = File('${phonePdfs.path}/$sha.pdf')..writeAsBytesSync([7, 7, 7]);
      expect((await client.sendPdf(conn, PdfOffer(sha, body.length), f)).alreadyThere, isTrue);
      // Bilgisayarda yok ve dosya adla uyuşmuyor: yollanmaz.
      final other = bytesOf(2000, 9);
      final sha2 = sha256Hex(other);
      final g = File('${phonePdfs.path}/$sha2.pdf')..writeAsBytesSync(bytesOf(2000, 10));
      await expectLater(client.sendPdf(conn, PdfOffer(sha2, other.length), g), throwsA(isA<SyncException>()));
      expect(File('${pdfRoot.path}/$sha2.pdf').existsSync(), isFalse);
    });

    test('"zaten var" dalı büyük gövdeyi okumaz: 200 gelir, bağlantı kapanır, geçici dosya kalmaz', () async {
      final body = bytesOf(5 * 1024 * 1024);
      final sha = sha256Hex(body);
      await pdfRoot.create(recursive: true);
      final stored = File('${pdfRoot.path}/$sha.pdf')..writeAsBytesSync(body);
      final r = await raw(signedHeaders('$sha.pdf', sha, 1), declared: body.length, body: body);
      // Gövde okunmadığı için bağlantı yanıttan hemen sonra kapanır; gövde metni kapanışla yarışabilir, durum kodu yeter.
      expect(r!.$1, 200);
      expect(stored.readAsBytesSync(), body);
      expect(leftovers(), isEmpty);
      // Sunucu ayakta ve sonraki istek çalışır.
      final again = await client.connect(computer, phoneId: phoneId);
      expect((await client.missingPhotos(again, const [])).missing, isEmpty);
    });

    test('yol enjeksiyonu: kalıba uymayan ad hiçbir şey yazmaz', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      final bad = [
        '../$sha.pdf',
        '../../evil.pdf',
        'pdfs/$sha.pdf',
        '$sha.pdf/../x',
        '${sha.toUpperCase()}.pdf',
        '$sha.PDF',
        '$sha.pdf.part',
        '${sha.substring(1)}.pdf',
        '$sha.exe',
        '.$sha.pdf',
        '%2e%2e/$sha.pdf',
        '$sha.pdf\n',
      ];
      var seq = 0;
      for (final name in bad) {
        seq++;
        // Her denemede oturum kapanabilir; yeni oturumla sırayla dene.
        final c = await client.connect(computer, phoneId: phoneId);
        final r = await raw(signedHeaders(name, sha, 1, session: c.session), declared: body.length, body: body);
        expect(r!.$1, anyOf(400, 401, 403), reason: name);
      }
      expect(seq, bad.length);
      expect(Directory(pdfRoot.path).existsSync() ? Directory(pdfRoot.path).listSync() : <Object>[], isEmpty);
      expect(tmp.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('evil.pdf')), isEmpty);
    });

    test('hedef bir bağlantıysa (symlink) dışarıya yazılmaz', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      final outside = File('${tmp.path}/disari.txt')..writeAsStringSync('dokunma');
      await pdfRoot.create(recursive: true);
      await Link('${pdfRoot.path}/$sha.pdf').create(outside.path);
      final r = await raw(signedHeaders('$sha.pdf', sha, 1), declared: body.length, body: body);
      expect(r!.$1, 403);
      expect(outside.readAsStringSync(), 'dokunma');
    });

    test('yarım kesilen aktarım: .part dosyası temizlenir, hedef oluşmaz', () async {
      final body = bytesOf(4 * 1024 * 1024);
      final sha = sha256Hex(body);
      await raw(signedHeaders('$sha.pdf', sha, 1), declared: body.length, body: body, cut: 1024 * 1024);
      // Sunucu hatayı fark edip temizleyene kadar bekle.
      for (var i = 0; i < 50 && (incoming.listSync().isNotEmpty); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(incoming.listSync(), isEmpty);
      expect(leftovers(), isEmpty);
      expect(File('${pdfRoot.path}/$sha.pdf').existsSync(), isFalse);
      // Sunucu ayakta ve yeniden gönderme çalışır.
      final c = await client.connect(computer, phoneId: phoneId);
      final offer = await phonePdf(body);
      await client.sendPdf(c, offer, File('${phonePdfs.path}/${offer.name}'));
      expect(File('${pdfRoot.path}/${offer.name}').readAsBytesSync(), body);
    });

    test('iptal: istek yarıda kesilir, bilgisayarda PDF ve geçici dosya kalmaz', () async {
      final bytes = bytesOf(16 * 1024 * 1024);
      final offer = await phonePdf(bytes);
      final cancel = SyncCancelToken();
      await expectLater(
        client.sendPdf(conn, offer, File('${phonePdfs.path}/${offer.name}'),
            cancel: cancel, onProgress: (s, t) {
          if (s > 1024 * 1024) cancel.cancel();
        }),
        throwsA(isA<SyncCancelledException>()),
      );
      for (var i = 0; i < 50 && incoming.listSync().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(incoming.listSync(), isEmpty);
      expect(File('${pdfRoot.path}/${offer.name}').existsSync(), isFalse);
    });
  });

  group('kimlik doğrulama', () {
    test('oturum açmadan (anahtarsız) PDF alınmaz', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      final r = await raw({SyncHeaders.mediaPath: '$sha.pdf'}, declared: body.length, body: body);
      expect(r!.$1, 401);
      expect(Directory(pdfRoot.path).existsSync() ? Directory(pdfRoot.path).listSync() : <Object>[], isEmpty);
    });

    test('yanlış anahtarla imzalanan PDF isteği reddedilir; önce-sor da varlık bilgisi sızdırmaz', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      await pdfRoot.create(recursive: true);
      File('${pdfRoot.path}/$sha.pdf').writeAsBytesSync(body);
      final r = await raw(signedHeaders('$sha.pdf', sha, 1, key: List.filled(32, 9)), declared: body.length, body: body);
      expect(r!.$1, 401);
      final c = await client.connect(computer, phoneId: phoneId);
      final q = await raw(signedHeaders('$sha.pdf', sha256Hex(const <int>[]), 1, key: List.filled(32, 9), session: c.session), declared: 0);
      expect(q!.$1, 401);
      expect(q.$2, isNot(contains('zatenVar')));
    });

    test('aynı sıra numarası ikinci kez gelirse reddedilir', () async {
      final body = bytesOf(100);
      final sha = sha256Hex(body);
      expect((await raw(signedHeaders('$sha.pdf', sha, 1), declared: body.length, body: body))!.$1, 200);
      final replay = await raw(signedHeaders('$sha.pdf', sha, 1), declared: body.length, body: body);
      expect(replay!.$1, 401);
    });

    test('eşleşme kaldırılınca PDF gönderilemez', () async {
      await server.forgetDevice(phoneId);
      final offer = await phonePdf(bytesOf(100));
      await expectLater(client.sendPdf(conn, offer, File('${phonePdfs.path}/${offer.name}')), throwsA(isA<SyncException>()));
    });

    test('bilgisayar PDF klasörü vermediyse (pdfRoot yok) 404', () async {
      await server.dispose();
      await Directory(tmp.path).list().drain<void>();
      await File('${tmp.path}/bilgisayar/esitleme.json').delete();
      client.close();
      client = _SpyClient();
      await boot(withPdf: false);
      final offer = await phonePdf(bytesOf(100));
      await expectLater(
        client.sendPdf(conn, offer, File('${phonePdfs.path}/${offer.name}')),
        throwsA(isA<SyncException>().having((e) => e.status, 'durum', 404)),
      );
    });
  });

  group('isteğe bağlılık (PdfSync)', () {
    test('ayar kapalıyken istemci hiç istek yapmaz', () async {
      final offer = await phonePdf(bytesOf(2000));
      final sync = PdfSync(client: client, pdfDir: phonePdfs, enabled: () async => false);
      final r = await sync.run(conn, [offer.sha256]);
      expect(r.enabled, isFalse);
      expect(client.pdfCalls, 0);
      expect(Directory(pdfRoot.path).existsSync() ? Directory(pdfRoot.path).listSync() : <Object>[], isEmpty);
    });

    test('ayar açıkken yalnızca bu cihazda dosyası olanlar gider; olmayan ve bozuk satırlar atlanır', () async {
      final a = await phonePdf(bytesOf(2000, 1));
      final b = await phonePdf(bytesOf(3000, 2));
      final ghost = sha256Hex([42]); // satır var, dosya yok
      final sync = PdfSync(client: client, pdfDir: phonePdfs, enabled: () async => true);
      final r = await sync.run(conn, [a.sha256, b.sha256, ghost, 'zararli/../ad']);
      expect((r.sent, r.missingFile, r.alreadyThere), (2, 1, 0));
      expect(client.pdfCalls, 2);
      expect(Directory(pdfRoot.path).listSync().length, 2);
      expect(r.summary, contains('2 PDF gönderildi'));
      // Tekrar: hepsi zaten var.
      final c = await client.connect(computer, phoneId: phoneId);
      final again = await sync.run(c, [a.sha256, b.sha256]);
      expect((again.sent, again.alreadyThere), (0, 2));
    });

    test('iptal edilince kalanlar gönderilmez ve sonuç iptal der', () async {
      final a = await phonePdf(bytesOf(2000, 1));
      final b = await phonePdf(bytesOf(3000, 2));
      final cancel = SyncCancelToken();
      final sync = PdfSync(
        client: client,
        pdfDir: phonePdfs,
        enabled: () async => true,
        cancel: cancel,
        onProgress: (i, n, name, s, t) {
          if (i == 1 && s == t) cancel.cancel();
        },
      );
      final r = await sync.run(conn, [a.sha256, b.sha256]);
      expect(r.cancelled, isTrue);
      expect(r.sent, 1);
      expect(client.pdfCalls, 1);
    });

    test('ayar varsayılan KAPALI, anahtarla açılır ve eşleşme kaldırılınca korunur', () async {
      final store = PhoneSyncStore(() async => File('${tmp.path}/tablet/esitleme.json'));
      expect(await store.sendPdfs(), isFalse);
      await store.setSendPdfs(true);
      expect(await PhoneSyncStore(() async => File('${tmp.path}/tablet/esitleme.json')).sendPdfs(), isTrue);
      await store.removeComputer();
      expect(await store.sendPdfs(), isTrue);
    });
  });

  group('kurallar (saf)', () {
    test('ad kalıbı', () {
      final sha = 'a' * 64;
      expect(isTransferablePdfName('$sha.pdf'), isTrue);
      for (final bad in ['', 'a.pdf', '${'A' * 64}.pdf', '$sha.pdf ', '../$sha.pdf', '$sha.pdf/x', '$sha.PDF']) {
        expect(isTransferablePdfName(bad), isFalse, reason: bad);
      }
      expect(shaOfPdfName('$sha.pdf'), sha);
      expect(pdfNameOfSha('nope'), isNull);
    });

    test('gönderim planı: küçükler önce; yok, boş ve aşırı büyük ayrılır', () {
      final plan = selectPdfsToSend({
        'b' * 64: 5000,
        'a' * 64: 100,
        'c' * 64: null,
        'd' * 64: 0,
        'e' * 64: SyncLimits.pdf + 1,
        'bozuk': 10,
      });
      expect(plan.send.map((o) => o.size), [100, 5000]);
      expect((plan.missingFile, plan.tooBig), (2, 1));
    });

    test('boyut yazısı', () {
      expect(formatPdfSize(500), '1 KB');
      expect(formatPdfSize(5 * 1024 * 1024), '5,0 MB');
      expect(formatPdfSize(300 * 1024 * 1024), '300 MB');
    });
  });
}
