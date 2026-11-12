import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/sync/domain/media_rules.dart';
import 'package:kocum/features/sync/domain/network_rules.dart';
import 'package:kocum/features/sync/domain/pairing_window.dart';
import 'package:kocum/features/sync/domain/sync_crypto.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';
import 'package:kocum/features/sync/domain/sync_session.dart';

void main() {
  group('ağ kuralları', () {
    test('yalnızca yerel ağ adresleri kabul edilir', () {
      for (final ok in ['10.0.0.5', '172.16.0.1', '172.31.255.255', '192.168.1.20', '169.254.3.4']) {
        expect(isPrivateNetworkAddress(parseIpv4(ok)!), isTrue, reason: ok);
      }
      for (final no in ['8.8.8.8', '172.15.0.1', '172.32.0.1', '100.64.0.1', '100.100.1.1', '127.0.0.1', '0.0.0.0']) {
        expect(isPrivateNetworkAddress(parseIpv4(no)!), isFalse, reason: no);
      }
    });

    test('IPv6: ULA ve bağlantı yerel kabul, genel ve geri döngü değil', () {
      final ula = [0xfd, 0x12, ...List.filled(14, 0)];
      final linkLocal = [0xfe, 0x80, ...List.filled(14, 0)];
      final global = [0x20, 0x01, 0x0d, 0xb8, ...List.filled(12, 0)];
      final loop = [...List.filled(15, 0), 1];
      final mapped = [...List.filled(10, 0), 0xff, 0xff, 192, 168, 1, 9];
      expect(isPrivateNetworkAddress(ula), isTrue);
      expect(isPrivateNetworkAddress(linkLocal), isTrue);
      expect(isPrivateNetworkAddress(global), isFalse);
      expect(isPrivateNetworkAddress(loop), isFalse);
      expect(isPrivateNetworkAddress(mapped), isTrue);
      expect(isLoopbackAddress(loop), isTrue);
    });

    test('aynı bilgisayardan gelen istek yalnızca açıkça izin verilirse', () {
      final loop = parseIpv4('127.0.0.1')!;
      expect(isAcceptedPeer(loop), isFalse);
      expect(isAcceptedPeer(loop, allowLoopback: true), isTrue);
      expect(isAcceptedPeer(parseIpv4('8.8.8.8')!, allowLoopback: true), isFalse);
    });

    test('Host başlığı IP olmalı (DNS rebinding)', () {
      expect(isIpLiteralHost('192.168.1.20'), isTrue);
      expect(isIpLiteralHost('192.168.1.20:47321'), isTrue);
      expect(isIpLiteralHost('[fe80::1]:47321'), isTrue);
      expect(isIpLiteralHost('kotu-site.com'), isFalse);
      expect(isIpLiteralHost('kotu-site.com:47321'), isFalse);
      expect(isIpLiteralHost('192.168.1'), isFalse);
      expect(isIpLiteralHost(''), isFalse);
      expect(isIpLiteralHost(null), isFalse);
    });

    test('elle yazılan adres: yalnızca yerel IPv4, isteğe bağlı port', () {
      expect(parseComputerAddress(' 192.168.1.20 ', defaultPort: 47321), (host: '192.168.1.20', port: 47321));
      expect(parseComputerAddress('10.0.0.2:5000', defaultPort: 47321), (host: '10.0.0.2', port: 5000));
      expect(parseComputerAddress('8.8.8.8', defaultPort: 47321), isNull);
      expect(parseComputerAddress('192.168.1.20:0', defaultPort: 47321), isNull);
      expect(parseComputerAddress('192.168.1.20:70000', defaultPort: 47321), isNull);
      expect(parseComputerAddress('bilgisayar.local', defaultPort: 47321), isNull);
      expect(parseComputerAddress('127.0.0.1', defaultPort: 1), isNull);
      expect(parseComputerAddress('127.0.0.1', defaultPort: 1, allowLoopback: true), isNotNull);
    });

    test('tarayıcı başlıkları yakalanır', () {
      expect(looksLikeBrowserRequest((n) => null), isFalse);
      expect(looksLikeBrowserRequest((n) => n == 'origin' ? 'http://x' : null), isTrue);
      expect(looksLikeBrowserRequest((n) => n == 'sec-fetch-mode' ? 'cors' : null), isTrue);
    });
  });

  group('şifreleme', () {
    test('ffdhe2048: 2048 bit, üreteç q mertebeli alt grupta', () {
      expect(dhPrime.bitLength, 2048);
      final q = (dhPrime - BigInt.one) ~/ BigInt.two;
      expect(dhGenerator.modPow(q, dhPrime), BigInt.one);
    });

    test('iki taraf aynı ortak sırrı bulur; araya giren farklı', () {
      final a = DhKeyPair.generate(Random(1));
      final b = DhKeyPair.generate(Random(2));
      final c = DhKeyPair.generate(Random(3));
      final ab = a.sharedSecret(b.publicHex)!;
      expect(ab, hasLength(dhBytes));
      expect(b.sharedSecret(a.publicHex), ab);
      expect(c.sharedSecret(a.publicHex), isNot(ab));
    });

    test('tehlikeli açık değerler reddedilir', () {
      final a = DhKeyPair.generate(Random(1));
      for (final bad in ['0', '1', (dhPrime - BigInt.one).toRadixString(16), dhPrime.toRadixString(16), 'xyz', '']) {
        expect(parseDhPublic(bad), isNull, reason: bad);
        expect(a.sharedSecret(bad), isNull);
      }
      expect(parseDhPublic('f' * 600), isNull);
    });

    test('anahtar kod, kimlik ve açık değerlerin hepsine bağlı', () {
      List<int> key({String code = '123456', String phone = 'telefon-0001'}) => derivePairingKey(
            sharedSecret: List.filled(256, 7),
            code: code,
            computerId: 'bilgisayar-01',
            phoneId: phone,
            challenge: 'mo',
            phonePublic: 'aa',
            computerPublic: 'bb',
          );
      expect(key(), key());
      expect(key(code: '123457'), isNot(key()));
      expect(key(phone: 'telefon-0002'), isNot(key()));
      expect(key(), hasLength(32));
    });

    test('istek imzası her alanı kapsar', () {
      final k = List.filled(32, 1);
      String sig({String m = 'PUT', String p = '/x', String s = 'o', int n = 1, String y = '', String h = 'h'}) =>
          requestSignature(k, method: m, path: p, session: s, sequence: n, mediaPath: y, bodyHash: h);
      final base = sig();
      expect(sig(m: 'put'), base, reason: 'yöntem büyük harfe çevrilir');
      for (final other in [sig(m: 'POST'), sig(p: '/y'), sig(s: 'p'), sig(n: 2), sig(y: 'a'), sig(h: 'g')]) {
        expect(other, isNot(base));
      }
      expect(proofOf(k, ProofLabels.phonePair, ['a']), isNot(proofOf(k, ProofLabels.computerPair, ['a'])));
    });

    test('sabit süreli karşılaştırma', () {
      expect(safeEquals('abc', 'abc'), isTrue);
      expect(safeEquals('abc', 'abd'), isFalse);
      expect(safeEquals('abc', 'ab'), isFalse);
      expect(safeEquals('', 'a'), isFalse);
    });

    test('akış hâlinde özet, tek seferlik özetle aynı', () {
      final data = utf8.encode('Koçum ' * 5000);
      final h = StreamingSha256();
      for (var i = 0; i < data.length; i += 777) {
        h.add(data.sublist(i, min(i + 777, data.length)));
      }
      expect(h.close(), sha256Hex(data));
      expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('sayı ↔ bayt', () {
      final v = BigInt.parse('0102ff', radix: 16);
      expect(bigIntToBytes(v, 4), [0, 1, 2, 255]);
      expect(bigIntFromBytes([0, 1, 2, 255]), v);
      expect(toHex([0, 15, 255]), '000fff');
    });
  });

  group('eşleştirme penceresi', () {
    late DateTime now;
    setUp(() => now = DateTime(2026, 11, 12, 16));

    test('6 haneli kod, 5 dakika geçerli', () {
      final w = PairingWindow(random: Random(5), now: () => now);
      expect(w.isOpen, isFalse);
      final c = w.open();
      expect(c.code, matches(RegExp(r'^\d{6}$')));
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(w.current?.code, c.code);
      now = now.add(const Duration(seconds: 1));
      expect(w.current, isNull);
      expect(w.isOpen, isFalse);
    });

    test('5 yanlış denemede kod geçersiz', () {
      final w = PairingWindow(random: Random(5), now: () => now)..open();
      for (var i = 0; i < SyncLimits.pairingAttempts - 1; i++) {
        expect(w.registerFailure(), PairingFailure.wrong);
      }
      expect(w.current!.attemptsLeft, 1);
      expect(w.registerFailure(), PairingFailure.exhausted);
      expect(w.isOpen, isFalse);
      expect(w.registerFailure(), PairingFailure.exhausted);
    });
  });

  group('oturum korumaları', () {
    late DateTime now;
    setUp(() => now = DateTime(2026, 11, 12, 16));

    test('meydan okuma tek kullanımlık ve süreli', () {
      final book = ChallengeBook(random: Random(1), now: () => now);
      final a = book.issue();
      expect(book.consume(a), isTrue);
      expect(book.consume(a), isFalse, reason: 'ikinci kullanım');
      final b = book.issue();
      now = now.add(SyncLimits.challengeTtl);
      expect(book.consume(b), isFalse, reason: 'süresi dolmuş');
      expect(book.consume('uydurma'), isFalse);
    });

    test('açık meydan okuma sayısı sınırlı (en eskisi düşer)', () {
      final book = ChallengeBook(random: Random(1), now: () => now);
      final first = book.issue();
      for (var i = 0; i < SyncLimits.openChallenges; i++) {
        book.issue();
      }
      expect(book.consume(first), isFalse);
    });

    test('sıra numarası tam bir sonraki olmalı; tekrar reddedilir', () {
      final s = SyncSession(id: 'o', phoneId: 't', now: now);
      expect(s.claim(1, now), isTrue);
      expect(s.claim(1, now), isFalse, reason: 'tekrar oynatma');
      expect(s.claim(3, now), isFalse, reason: 'atlama');
      expect(s.claim(2, now), isTrue);
      expect(s.isExpired(now.add(SyncLimits.sessionIdle)), isFalse);
      expect(s.isExpired(now.add(SyncLimits.sessionIdle + const Duration(seconds: 1))), isTrue);
    });

    test('çok hatalı istek atan adres bir süre yasaklanır', () {
      final g = FailureGuard(now: () => now);
      for (var i = 0; i < SyncLimits.failuresPerAddress - 1; i++) {
        g.record('192.168.1.50');
      }
      expect(g.isBanned('192.168.1.50'), isFalse);
      g.record('192.168.1.50');
      expect(g.isBanned('192.168.1.50'), isTrue);
      expect(g.isBanned('192.168.1.51'), isFalse);
      now = now.add(SyncLimits.banDuration);
      expect(g.isBanned('192.168.1.50'), isFalse);
    });

    test('eski hatalar pencere dışında kalınca sayılmaz', () {
      final g = FailureGuard(now: () => now);
      for (var i = 0; i < SyncLimits.failuresPerAddress - 1; i++) {
        g.record('10.0.0.9');
      }
      now = now.add(SyncLimits.failureWindow + const Duration(seconds: 1));
      g.record('10.0.0.9');
      expect(g.isBanned('10.0.0.9'), isFalse);
    });
  });

  group('fotoğraf yolları (yalnızca uygulamanın alanı)', () {
    test('geçerli ve geçersiz yollar', () {
      for (final ok in [
        'questions/2026/10/0192d1e2-7a3b-7c4d-8e5f-0123456789ab.webp',
        'solutions/2025/01/abc_DEF-1.jpg',
        'notes/2026/11/x',
      ]) {
        expect(isTransferableMediaPath(ok), isTrue, reason: ok);
      }
      for (final no in [
        '../kocum.sqlite',
        '/etc/passwd',
        'questions/2026/10/../../../x.jpg',
        'questions/2026/10/.gizli',
        'questions/2026/10/a/b.jpg',
        'ayarlar/2026/10/a.jpg',
        r'questions\2026\10\a.jpg',
        'questions/2026/10/a b.jpg',
        'questions/26/10/a.jpg',
        'questions/2026/10/',
        '',
      ]) {
        expect(isTransferableMediaPath(no), isFalse, reason: no);
      }
    });

    test('eksikler: olmayan ya da boyutu tutmayan; geçersizler sayılır', () {
      const a = MediaEntry('questions/2026/10/a.webp', 100);
      const b = MediaEntry('questions/2026/10/b.webp', 200);
      const c = MediaEntry('notes/2026/10/c.jpg', 300);
      const bad = MediaEntry('../x', 1);
      const huge = MediaEntry('notes/2026/10/d.jpg', SyncLimits.photo + 1);
      final r = selectMissingMedia([a, b, c, bad, huge, a], {a.path: 100, b.path: 150, c.path: null});
      expect(r.missing, [b.path, c.path]);
      expect(r.rejected, 2);
    });

    test('telefon yalnızca kendi sunduğu dosyaları gönderir', () {
      const a = MediaEntry('questions/2026/10/a.webp', 100);
      const b = MediaEntry('questions/2026/10/b.webp', 200);
      final out = requestedFromOffer([a, b], [b.path, '../ayarlar.json', 'notes/2026/10/baska.jpg', b.path]);
      expect(out, [b]);
    });
  });

  group('protokol mesajları', () {
    test('bulma isteği doldurulmuş ve tanınır', () {
      final p = discoveryProbe();
      expect(p, hasLength(discoveryProbeLength));
      expect(isDiscoveryProbe(p), isTrue);
      expect(isDiscoveryProbe(ascii.encode(discoveryProbeTag)), isFalse, reason: 'doldurulmamış');
      expect(isDiscoveryProbe([...p]..[0] = 0x41), isFalse);
    });

    test('bulma yanıtı gidip gelir; bozuk olan yok sayılır', () {
      const r = DiscoveryReply(id: 'abcdef012345', name: 'Bilgisayar · ABCD', port: 47321, platform: 'linux');
      final back = DiscoveryReply.tryParse(utf8.encode(jsonEncode(r.toJson())))!;
      expect((back.id, back.name, back.port, back.platform), (r.id, r.name, r.port, r.platform));
      expect(DiscoveryReply.tryParse(utf8.encode('{"uygulama":"baska"}')), isNull);
      expect(DiscoveryReply.tryParse(utf8.encode('çöp')), isNull);
      expect(
        DiscoveryReply.tryParse(utf8.encode(jsonEncode({...r.toJson(), 'id': '../x'}))),
        isNull,
      );
    });

    test('merhaba: sürüm farkı anlaşılır bir hata verir', () {
      const h = SyncHello(
        id: 'abcdef012345',
        name: 'B',
        platform: 'linux',
        pairingOpen: true,
        paired: false,
        challenge: 'c',
        dhPublic: 'ab',
      );
      final back = SyncHello.fromJson(jsonDecode(jsonEncode(h.toJson())));
      expect((back.pairingOpen, back.paired, back.dhPublic), (true, false, 'ab'));
      expect(
        () => SyncHello.fromJson({...h.toJson(), 'surum': 99}),
        throwsA(isA<SyncException>().having((e) => e.message, 'mesaj', contains('sürüm'))),
      );
    });

    test('cihaz adı temizlenir ve kısaltılır; gerçek ad yerine kısa etiket', () {
      expect(cleanDeviceName('  Telefon\u0000\n  '), 'Telefon');
      expect(cleanDeviceName(''), 'Adsız cihaz');
      expect(cleanDeviceName('x' * 100), hasLength(SyncLimits.nameLength));
      expect(deviceLabel('Android', '9c1b77aa'), 'Android · 9C1B');
    });

    test('fotoğraf listesi: bozuk öğeler atlanır', () {
      final r = PhotoListRequest.fromJson({
        'fotograflar': [
          {'yol': 'questions/2026/10/a.webp', 'boyut': 5},
          {'yol': 3, 'boyut': 5},
          'çöp',
        ],
      });
      expect(r.photos, [const MediaEntry('questions/2026/10/a.webp', 5)]);
    });
  });
}
