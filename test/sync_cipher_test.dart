import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/sync/domain/sync_cipher.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

List<int> hexToBytes(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

String hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

SealContext ctx({
  List<int>? key,
  SealDirection direction = SealDirection.toReceiver,
  String session = 'oturum-aaaaaaaa',
  int sequence = 1,
  String path = '/kocum/v1/degisiklikler',
  String mediaPath = '',
}) =>
    SealContext(
      pairingKey: key ?? List<int>.filled(32, 5),
      direction: direction,
      session: session,
      sequence: sequence,
      path: path,
      mediaPath: mediaPath,
    );

Uint8List bytesOf(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Future<Uint8List> openAll(Uint8List wire, SealContext c) => openBytes(wire, c);

void main() {
  group('HKDF (RFC 5869)', () {
    test('test vektörü 1 (SHA-256)', () {
      final ikm = List<int>.filled(22, 0x0b);
      final salt = hexToBytes('000102030405060708090a0b0c');
      final info = hexToBytes('f0f1f2f3f4f5f6f7f8f9');
      final prk = hkdfExtract(salt, ikm);
      expect(hex(prk), '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5');
      expect(
        hex(hkdfExpand(prk, info, 42)),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
      );
    });
  });

  group('sürüm uyumu', () {
    SyncHello hello() => const SyncHello(
        id: 'abcdef012345', name: 'B', platform: 'linux', pairingOpen: false, paired: false, challenge: 'c');

    test('eski sürüm (1) şifresize düşmez: "Diğer cihazı güncelleyin"', () {
      expect(syncProtocolVersion, 2);
      expect(
        () => SyncHello.fromJson({...hello().toJson(), 'surum': 1}),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('Diğer cihazı güncelleyin'))),
      );
    });

    test('daha yeni sürüm: bu cihazı güncelleme uyarısı', () {
      expect(
        () => SyncHello.fromJson({...hello().toJson(), 'surum': 3}),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('Bu cihazı güncelleyin'))),
      );
    });

    test('bulma yanıtı farklı sürümde de okunur (bağlanınca anlaşılır hata çıkar)', () {
      final reply = DiscoveryReply(id: 'abcdef012345', name: 'B', port: 1234, platform: 'linux').toJson();
      expect(DiscoveryReply.tryParse(utf8.encode(jsonEncode({...reply, 'surum': 1}))), isNotNull);
      expect(DiscoveryReply.tryParse(utf8.encode(jsonEncode({...reply, 'surum': 'x'}))), isNull);
    });
  });

  group('şifreleme turu', () {
    for (final n in [1, 100, sealChunkSize - 1, sealChunkSize, sealChunkSize + 1, 3 * sealChunkSize, 200 * 1024 + 7]) {
      test('$n bayt: aç(mühürle) = düz; uzunluk formülü tutar', () async {
        final plain = bytesOf(n, n);
        final wire = sealBytes(plain, ctx());
        expect(wire.length, sealedLength(n));
        expect(plainLength(wire.length), n);
        expect(await openAll(wire, ctx()), plain);
        if (n > 40) expect(hex(wire).contains(hex(plain.sublist(0, 32))), isFalse, reason: 'düz metin görünmez');
      });
    }

    test('boş gövde çerçevesiz boştur', () async {
      expect(sealBytes(const [], ctx()), isEmpty);
      expect(sealedLength(0), 0);
      expect(plainLength(0), 0);
      expect(await openAll(Uint8List(0), ctx()), isEmpty);
    });

    test('uzunluk ters işlevi: geçersiz uzunluk null', () {
      expect(plainLength(1), isNull);
      expect(plainLength(20), isNull);
      for (final n in [1, 2, sealChunkSize, sealChunkSize + 1, 5 * sealChunkSize + 3]) {
        expect(plainLength(sealedLength(n)), n);
      }
      expect(plainLength(sealedLength(sealChunkSize) + 1), isNull);
    });

    test('JSON gövdesi: UTF-8 Türkçe metin bozulmadan döner', () async {
      final plain = utf8.encode(jsonEncode({'ad': 'İğdır şıkları ÖĞRENCİ', 'n': 3}));
      final back = await openAll(sealBytes(plain, ctx()), ctx());
      expect(jsonDecode(utf8.decode(back)), {'ad': 'İğdır şıkları ÖĞRENCİ', 'n': 3});
    });
  });

  group('reddedilen (doğrulanamayan) şifreli veri', () {
    final plain = bytesOf(3 * sealChunkSize + 11, 3);

    test('yanlış anahtar', () async {
      final wire = sealBytes(plain, ctx());
      await expectLater(openAll(wire, ctx(key: List<int>.filled(32, 6))), throwsA(isA<SealException>()));
    });

    test('değiştirilmiş şifreli metin (tek bit)', () async {
      for (final at in [4, 100, wireLen(plain) ~/ 2, wireLen(plain) - 1]) {
        final wire = sealBytes(plain, ctx());
        wire[at] ^= 0x01;
        await expectLater(openAll(wire, ctx()), throwsA(isA<SealException>()), reason: 'konum $at');
      }
    });

    test('başlıktaki "son" bitini çevirmek ya da uzunluğu değiştirmek tutmaz', () async {
      final wire = sealBytes(plain, ctx());
      final flipped = Uint8List.fromList(wire)..[0] ^= 0x80; // ilk parçayı SON yap
      await expectLater(openAll(flipped, ctx()), throwsA(isA<SealException>()));
      final lenChanged = Uint8List.fromList(wire)..[3] ^= 0x01;
      await expectLater(openAll(lenChanged, ctx()), throwsA(isA<SealException>()));
    });

    test('kesilmiş akış (son parça yok) reddedilir; parça sınırında kesilse bile', () async {
      final wire = sealBytes(plain, ctx());
      final firstFrame = 4 + sealChunkSize + 16;
      await expectLater(openAll(Uint8List.sublistView(wire, 0, firstFrame), ctx()), throwsA(isA<SealException>()));
      await expectLater(openAll(Uint8List.sublistView(wire, 0, firstFrame + 7), ctx()), throwsA(isA<SealException>()));
      await expectLater(openAll(Uint8List.sublistView(wire, 0, wire.length - 1), ctx()), throwsA(isA<SealException>()));
    });

    test('parça silme, yer değiştirme ve sonuna veri ekleme', () async {
      final wire = sealBytes(plain, ctx());
      final f = 4 + sealChunkSize + 16;
      final dropped = Uint8List.fromList([...wire.sublist(0, f), ...wire.sublist(2 * f)]);
      await expectLater(openAll(dropped, ctx()), throwsA(isA<SealException>()));
      final swapped = Uint8List.fromList([...wire.sublist(f, 2 * f), ...wire.sublist(0, f), ...wire.sublist(2 * f)]);
      await expectLater(openAll(swapped, ctx()), throwsA(isA<SealException>()));
      final extended = Uint8List.fromList([...wire, ...wire.sublist(0, 30)]);
      await expectLater(openAll(extended, ctx()), throwsA(isA<SealException>()));
      final replayed = Uint8List.fromList([...wire, ...wire]);
      await expectLater(openAll(replayed, ctx()), throwsA(isA<SealException>()));
    });

    test('başka isteğe taşıma: oturum, sıra, yol, fotoğraf yolu ve yön bağlıdır', () async {
      final small = bytesOf(500);
      final wire = sealBytes(small, ctx(mediaPath: 'questions/2026/10/a.webp'));
      expect(await openAll(wire, ctx(mediaPath: 'questions/2026/10/a.webp')), small);
      for (final other in [
        ctx(mediaPath: 'questions/2026/10/b.webp'),
        ctx(session: 'oturum-bbbbbbbb', mediaPath: 'questions/2026/10/a.webp'),
        ctx(sequence: 2, mediaPath: 'questions/2026/10/a.webp'),
        ctx(path: '/kocum/v1/fotograf', mediaPath: 'questions/2026/10/a.webp'),
        ctx(direction: SealDirection.toSender, mediaPath: 'questions/2026/10/a.webp'),
      ]) {
        await expectLater(openAll(wire, other), throwsA(isA<SealException>()));
      }
    });

    test('istek şifresi yanıt bağlamında açılmaz (yön başına ayrı anahtar)', () async {
      final wire = sealBytes(bytesOf(64), ctx());
      await expectLater(openAll(wire, ctx().reply()), throwsA(isA<SealException>()));
      final back = sealBytes(bytesOf(64), ctx().reply());
      expect(await openAll(back, ctx().reply()), bytesOf(64));
    });

    test('çözmede sınır (maxPlain) aşılırsa reddedilir', () async {
      final wire = sealBytes(bytesOf(2 * sealChunkSize), ctx());
      await expectLater(openBytes(wire, ctx(), maxPlain: sealChunkSize), throwsA(isA<SealException>()));
    });

    test('bozuk parça uzunluğu bellek şişirmez', () async {
      final bad = Uint8List(8)..buffer.asByteData().setUint32(0, 0x7fffffff);
      await expectLater(openAll(bad, ctx()), throwsA(isA<SealException>()));
    });
  });

  group('nonce tekrarsızlığı', () {
    test('aynı düz metin, farklı (yön, oturum, sıra) → hepsi farklı şifreli metin', () {
      final plain = Uint8List.fromList(utf8.encode('aynı metin'));
      final seen = <String>{};
      for (final dir in SealDirection.values) {
        for (var s = 0; s < 3; s++) {
          for (var seq = 1; seq <= 200; seq++) {
            final c = ctx(direction: dir, session: 'oturum-$s', sequence: seq);
            seen.add(hex(sealBytes(plain, c)));
          }
        }
      }
      expect(seen.length, 2 * 3 * 200);
    });

    test('aynı iletide özdeş parçalar farklı şifreli metin verir (parça sayacı nonce\'ta)', () {
      final one = Uint8List(sealChunkSize); // sıfırlardan iki özdeş parça + kuyruk
      final wire = sealBytes([...one, ...one, 1], ctx());
      final f = 4 + sealChunkSize + 16;
      expect(hex(wire.sublist(4, f)), isNot(hex(wire.sublist(f + 4, 2 * f))));
    });

    test('aynı bağlamla iki kez mühürlemek aynı baytları verir (belirlenimli); tekrar kullanımı üst katman engeller', () {
      // Nonce sayaçtır, rastgele değildir: bu yüzden anahtar HER İLETİ için ayrıdır
      // (oturum + sıra); sıra numarası oturumda bir kez kullanılabilir (SyncSession.claim).
      expect(hex(sealBytes(bytesOf(10), ctx())), hex(sealBytes(bytesOf(10), ctx())));
    });
  });

  group('parçalı akış (büyük dosya)', () {
    test('düzensiz boyutlu giriş parçalarıyla 5 MB: bellek parça başına sabit, tur doğru', () async {
      const total = 5 * 1024 * 1024 + 123;
      final r = Random(9);
      final hashIn = AccumulatorSink<Digest>();
      final input = sha256.startChunkedConversion(hashIn);
      Stream<List<int>> source() async* {
        var left = total;
        while (left > 0) {
          final n = min(left, 1 + r.nextInt(150000));
          final chunk = bytesOf(n, left);
          input.add(chunk);
          left -= n;
          yield chunk;
        }
        input.close();
      }

      final c = ctx(mediaPath: 'x');
      var wireBytes = 0;
      var frames = 0;
      final wire = <Uint8List>[];
      await for (final f in sealStream(source(), c)) {
        expect(f.length, lessThanOrEqualTo(sealChunkSize + 20), reason: 'her çerçeve sınırlı');
        wireBytes += f.length;
        frames++;
        wire.add(f);
      }
      expect(wireBytes, sealedLength(total));
      expect(frames, (total + sealChunkSize - 1) ~/ sealChunkSize);

      // Çözme: çerçeveleri ağdaki gibi düzensiz dilimlerle ver.
      Stream<List<int>> dribble() async* {
        final all = BytesBuilder();
        for (final f in wire) {
          all.add(f);
        }
        final bytes = all.takeBytes();
        var pos = 0;
        while (pos < bytes.length) {
          final n = min(bytes.length - pos, 1 + r.nextInt(100000));
          yield Uint8List.sublistView(bytes, pos, pos + n);
          pos += n;
        }
      }

      final hashOut = AccumulatorSink<Digest>();
      final output = sha256.startChunkedConversion(hashOut);
      var got = 0;
      await for (final p in openStream(dribble(), c, maxPlain: total)) {
        expect(p.length, lessThanOrEqualTo(sealChunkSize));
        output.add(p);
        got += p.length;
      }
      output.close();
      expect(got, total);
      expect(hashOut.events.single, hashIn.events.single);
    });
  });
}

int wireLen(List<int> plain) => sealedLength(plain.length);

class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];

  @override
  void add(T data) => events.add(data);

  @override
  void close() {}
}
