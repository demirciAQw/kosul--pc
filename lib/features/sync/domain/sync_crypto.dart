/// Kablosuz aktarımın şifreleme yapı taşları. Yalnızca standart parçalar:
/// SHA-256, HMAC-SHA256 (crypto paketi) ve RFC 7919 ffdhe2048 grubunda
/// Diffie-Hellman (Dart'ın BigInt.modPow'u). Kendi şifre algoritmamız yok.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_protocol.dart';

/// RFC 7919 ffdhe2048: 2048 bitlik güvenli asal, üreteç 2.
final BigInt dhPrime = BigInt.parse(
  'FFFFFFFFFFFFFFFFADF85458A2BB4A9AAFDC5620273D3CF1D8B9C583CE2D3695A9E13641146433FBCC939DCE249B3EF97D2FE363630C75D8F68'
  '1B202AEC4617AD3DF1ED5D5FD65612433F51F5F066ED0856365553DED1AF3B557135E7F57C935984F0C70E0E68B77E2A689DAF3EFE8721DF15'
  '8A136ADE73530ACCA4F483A797ABC0AB182B324FB61D108A94BB2C8E3FBB96ADAB760D7F4681D4F42A3DE394DF4AE56EDE76372BB190B07A7C'
  '8EE0A6D709E02FCE1CDF7E2ECC03404CD28342F619172FE9CE98583FF8E4F1232EEF28183C3FE3B1B4C6FAD733BB5FCBC2EC22005C58EF1837'
  'D1683B2C6F34A26C1B2EFFA886B423861285C97FFFFFFFFFFFFFFFF',
  radix: 16,
);
final BigInt dhGenerator = BigInt.two;
const dhBytes = 256;

List<int> randomBytes(Random random, int length) => List<int>.generate(length, (_) => random.nextInt(256));

/// URL'de ve başlıkta güvenle taşınan rastgele değer.
String randomToken(Random random, [int bytes = 18]) => base64Url.encode(randomBytes(random, bytes)).replaceAll('=', '');

String toHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

BigInt bigIntFromBytes(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b & 0xff);
  }
  return v;
}

/// Sabit uzunlukta, büyük uçlu (big-endian) bayt dizisi.
Uint8List bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  final mask = BigInt.from(0xff);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return out;
}

final _hex = RegExp(r'^[0-9a-fA-F]+$');

/// Karşı tarafın açık değeri: 1 < y < p-1 olmalı (0, 1 ve p-1 gibi
/// anahtarı tahmin edilebilir kılan değerler reddedilir).
BigInt? parseDhPublic(String hex) {
  if (hex.isEmpty || hex.length > 2 * dhBytes || !_hex.hasMatch(hex)) return null;
  final v = BigInt.parse(hex, radix: 16);
  if (v <= BigInt.one || v >= dhPrime - BigInt.one) return null;
  return v;
}

/// Tek eşleştirmelik Diffie-Hellman anahtar çifti. Gizli üs bellekte kalır,
/// hiçbir yere yazılmaz.
class DhKeyPair {
  DhKeyPair._(this._secret, this.public);

  factory DhKeyPair.generate(Random random) {
    // 256 bitlik gizli üs (RFC 7919: ffdhe2048 için en az 225 bit önerilir).
    final secret = bigIntFromBytes(randomBytes(random, 32)) | (BigInt.one << 255);
    return DhKeyPair._(secret, dhGenerator.modPow(secret, dhPrime));
  }

  final BigInt _secret;
  final BigInt public;

  String get publicHex => public.toRadixString(16);

  /// Ortak sır (256 bayt); karşı değer geçersizse null.
  Uint8List? sharedSecret(String peerHex) {
    final peer = parseDhPublic(peerHex);
    if (peer == null) return null;
    return bigIntToBytes(peer.modPow(_secret, dhPrime), dhBytes);
  }
}

List<int> hmacSha256(List<int> key, List<int> message) => Hmac(sha256, key).convert(message).bytes;

/// Eşleştirme anahtarı: ortak sır + ekrandaki kod + iki tarafın kimlikleri
/// ve açık değerleri. Kodu bilmeyen, ortak sırrı bilse de aynı anahtarı
/// bulamaz; ortak sırrı bilmeyen (ağı dinleyen) kodu görse de bulamaz.
List<int> derivePairingKey({
  required List<int> sharedSecret,
  required String code,
  required String computerId,
  required String phoneId,
  required String challenge,
  required String phonePublic,
  required String computerPublic,
}) =>
    hmacSha256(
      sha256.convert(sharedSecret).bytes,
      utf8.encode(['kocum-eslesme-v$syncProtocolVersion', code, computerId, phoneId, challenge, phonePublic, computerPublic]
          .join('|')),
    );

/// Etiketli kanıt (onaltılık HMAC). Parçalarda "|" bulunmaz: kimlikler,
/// rastgele değerler ve doğrulanmış yollar bu karakteri içeremez.
String proofOf(List<int> key, String label, List<String> parts) =>
    toHex(hmacSha256(key, utf8.encode([label, ...parts].join('|'))));

/// İmzalı isteğin kanıtı: yöntem, yol, oturum, sıra, fotoğraf yolu ve
/// gövdenin özeti birlikte imzalanır; biri değişirse imza tutmaz.
String requestSignature(
  List<int> key, {
  required String method,
  required String path,
  required String session,
  required int sequence,
  required String mediaPath,
  required String bodyHash,
}) =>
    proofOf(key, ProofLabels.request, [method.toUpperCase(), path, session, '$sequence', mediaPath, bodyHash]);

String sha256Hex(List<int> data) => sha256.convert(data).toString();

/// Süre sızdırmayan karşılaştırma: imza tahmini için zamanlama ölçülemesin.
bool safeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

/// Büyük dosyayı belleğe almadan SHA-256 özeti.
class StreamingSha256 {
  StreamingSha256() {
    _input = sha256.startChunkedConversion(_sink);
  }

  final _DigestSink _sink = _DigestSink();
  late final Sink<List<int>> _input;

  void add(List<int> chunk) => _input.add(chunk);

  String close() {
    _input.close();
    return _sink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('Özet henüz hazır değil.'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
