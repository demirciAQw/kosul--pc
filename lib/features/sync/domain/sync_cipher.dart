/// Kablosuz aktarımın içerik şifrelemesi (protokol sürüm 2).
///
/// Kendi şifre algoritmamız yok: AEAD olarak ChaCha20-Poly1305 (RFC 8439,
/// `pointycastle`, MIT, saf Dart), anahtar türetme HKDF-SHA256 (RFC 5869,
/// `crypto` HMAC'iyle).
///
/// Anahtar: eşleşmede iki tarafta ayrı hesaplanıp `esitleme.json` / `alici.json`'a
/// yazılan eşleşme anahtarından türetilir (yeni eşleşme gerekmez). İMZA anahtarı
/// eşleşme anahtarının kendisidir; şifreleme anahtarı HKDF ile ayrı bir değerdir.
/// HER İLETİ (istek ya da yanıt) için ayrı anahtar: HKDF(eşleşme anahtarı,
/// "yön|oturum|sıra"). Oturum kimliği rastgele, sıra numarası oturumda bir kez
/// kullanılır; yön (`i2a` istemci→alıcı, `a2i` alıcı→istemci) ayrı anahtar verir.
/// Bu yüzden (anahtar, nonce) çifti asla tekrar etmez: nonce = 4 sıfır bayt +
/// 64 bit parça sayacı.
///
/// Gövde parçalıdır: en çok [sealChunkSize] baytlık parçalar, her biri ayrı AEAD.
/// Çerçeve: 4 bayt başlık (bit 31 = SON parça, kalan 31 bit = şifreli metin
/// uzunluğu) + şifreli metin + 16 bayt etiket. İlişkili veri (AAD): yön, oturum,
/// sıra, yol, fotoğraf yolu, parça sırası ve "son" bayrağı. Parça silinirse,
/// yeri değişirse, kesilirse, başka isteğe taşınırsa etiket tutmaz. Boş gövde
/// çerçevesiz boştur (PDF'te "bu özet var mı?" sorusu gövdesizdir).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// `x-kocum-sifre` başlığının değeri.
const syncCipherName = 'chacha20-poly1305';

const sealChunkSize = 64 * 1024;
const _tagLength = 16;
const _headerLength = 4;
const _frameOverhead = _headerLength + _tagLength;
const _finalBit = 0x80000000;

class SealException implements Exception {
  const SealException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// İletinin yönü.
enum SealDirection {
  /// İstemci → alıcı (istek gövdesi).
  toReceiver('i2a'),

  /// Alıcı → istemci (yanıt gövdesi).
  toSender('a2i');

  const SealDirection(this.label);

  final String label;
}

List<int> _hmac(List<int> key, List<int> data) => Hmac(sha256, key).convert(data).bytes;

/// RFC 5869 HKDF-Extract.
List<int> hkdfExtract(List<int> salt, List<int> ikm) => _hmac(salt, ikm);

/// RFC 5869 HKDF-Expand.
Uint8List hkdfExpand(List<int> prk, List<int> info, int length) {
  assert(length > 0 && length <= 255 * 32);
  final out = BytesBuilder(copy: false);
  var previous = <int>[];
  for (var i = 1; out.length < length; i++) {
    previous = _hmac(prk, [...previous, ...info, i]);
    out.add(previous);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

final _salt = utf8.encode('kocum-sifre-v2');

/// Bir iletinin (tek istek ya da tek yanıt) şifreleme bağlamı.
class SealContext {
  SealContext({
    required List<int> pairingKey,
    required this.direction,
    required this.session,
    required this.sequence,
    required this.path,
    this.mediaPath = '',
  }) : _pairingKey = List<int>.unmodifiable(pairingKey),
       _key = hkdfExpand(
         hkdfExtract(_salt, pairingKey),
         utf8.encode('ileti|${direction.label}|$session|$sequence'),
         32,
       ),
       _aad = utf8.encode('kocum-sifre|${direction.label}|$session|$sequence|$path|$mediaPath');

  final SealDirection direction;
  final String session;
  final int sequence;
  final String path;
  final String mediaPath;
  final List<int> _pairingKey;
  final Uint8List _key;
  final List<int> _aad;

  /// Aynı isteğin yanıtı için bağlam (ters yön, fotoğraf yolu yok).
  SealContext reply() => SealContext(
    pairingKey: _pairingKey,
    direction: SealDirection.toSender,
    session: session,
    sequence: sequence,
    path: path,
  );

  Uint8List _nonce(int index) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, index);
    return n;
  }

  Uint8List _aadFor(int index, bool last) {
    final tail = Uint8List(9);
    ByteData.sublistView(tail).setUint64(0, index);
    tail[8] = last ? 1 : 0;
    return Uint8List.fromList([..._aad, ...tail]);
  }

  /// Tek parçayı şifreler (encrypt) ya da çözer; çözmede etiket yanlışsa fırlatır.
  Uint8List _run(bool encrypt, Uint8List input, int index, bool last) {
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(encrypt, AEADParameters(KeyParameter(_key), _tagLength * 8, _nonce(index), _aadFor(index, last)));
    final out = Uint8List(cipher.getOutputSize(input.length));
    var n = cipher.processBytes(input, 0, input.length, out, 0);
    n += cipher.doFinal(out, n);
    return n == out.length ? out : Uint8List.sublistView(out, 0, n);
  }

  /// Tek çerçeve: başlık + şifreli metin + etiket.
  Uint8List sealFrame(Uint8List plain, int index, {required bool last}) {
    final cipher = _run(true, plain, index, last);
    final out = Uint8List(_headerLength + cipher.length);
    ByteData.sublistView(out).setUint32(0, cipher.length | (last ? _finalBit : 0));
    out.setRange(_headerLength, out.length, cipher);
    return out;
  }

  Uint8List openFrame(Uint8List cipherText, int index, {required bool last}) {
    try {
      return _run(false, cipherText, index, last);
    } on InvalidCipherTextException {
      throw const SealException('Şifreli veri doğrulanamadı (anahtar yanlış ya da veri değiştirilmiş).');
    } on ArgumentError {
      throw const SealException('Şifreli veri doğrulanamadı.');
    }
  }
}

/// Şifreli gövdenin bayt uzunluğu (Content-Length için).
int sealedLength(int plainLength) {
  if (plainLength <= 0) return 0;
  return plainLength + ((plainLength + sealChunkSize - 1) ~/ sealChunkSize) * _frameOverhead;
}

/// [sealedLength]'in tersi; geçersiz uzunluk için null.
int? plainLength(int wireLength) {
  if (wireLength == 0) return 0;
  if (wireLength < _frameOverhead + 1) return null;
  final frames = (wireLength + sealChunkSize + _frameOverhead - 1) ~/ (sealChunkSize + _frameOverhead);
  final plain = wireLength - frames * _frameOverhead;
  return plain > 0 && sealedLength(plain) == wireLength ? plain : null;
}

/// Düz akışı parça parça şifreler (belleğe tamamını almaz). Toplam düz uzunluk
/// 0 ise hiçbir şey üretmez.
Stream<Uint8List> sealStream(Stream<List<int>> plain, SealContext ctx) async* {
  final fill = Uint8List(sealChunkSize);
  var filled = 0;
  var index = 0;
  await for (final data in plain) {
    var offset = 0;
    while (offset < data.length) {
      if (filled == sealChunkSize) {
        // Daha veri var: dolu parça SON değil.
        yield ctx.sealFrame(Uint8List.sublistView(fill, 0, filled), index++, last: false);
        filled = 0;
      }
      final n = _min(data.length - offset, sealChunkSize - filled);
      fill.setRange(filled, filled + n, data, offset);
      filled += n;
      offset += n;
    }
  }
  if (filled > 0) yield ctx.sealFrame(Uint8List.sublistView(fill, 0, filled), index, last: true);
}

int _min(int a, int b) => a < b ? a : b;

/// Şifreli akışı çözer. Her parça etiketle doğrulanmadan hiçbir bayt verilmez;
/// SON parça gelmeden biten (kesilmiş) akış, sonrasında veri olan akış ve sınır
/// aşımı [SealException] fırlatır. Tümüyle boş akış boş gövdedir.
Stream<Uint8List> openStream(Stream<List<int>> wire, SealContext ctx, {int? maxPlain}) async* {
  var carry = Uint8List(0);
  var index = 0;
  var total = 0;
  var sawFinal = false;
  await for (final data in wire) {
    if (sawFinal && data.isNotEmpty) throw const SealException('Şifreli gövdenin sonundan sonra veri geldi.');
    carry = carry.isEmpty
        ? (data is Uint8List ? data : Uint8List.fromList(data))
        : (Uint8List(carry.length + data.length)
            ..setRange(0, carry.length, carry)
            ..setRange(carry.length, carry.length + data.length, data));
    var pos = 0;
    while (carry.length - pos >= _headerLength) {
      final head = ByteData.sublistView(carry, pos, pos + _headerLength).getUint32(0);
      final last = (head & _finalBit) != 0;
      final length = head & ~_finalBit;
      if (length < _tagLength + 1 || length > sealChunkSize + _tagLength) {
        throw const SealException('Şifreli parça uzunluğu geçersiz.');
      }
      if (sawFinal) throw const SealException('Şifreli gövdenin sonundan sonra veri geldi.');
      if (carry.length - pos - _headerLength < length) break;
      final start = pos + _headerLength;
      final plain = ctx.openFrame(Uint8List.sublistView(carry, start, start + length), index++, last: last);
      pos = start + length;
      sawFinal = last;
      total += plain.length;
      if (maxPlain != null && total > maxPlain) throw const SealException('Şifreli gövde beklenenden büyük.');
      yield plain;
    }
    carry = pos == carry.length ? Uint8List(0) : Uint8List.fromList(Uint8List.sublistView(carry, pos));
  }
  if (carry.isNotEmpty) throw const SealException('Şifreli gövde yarıda kesildi.');
  if (index > 0 && !sawFinal) throw const SealException('Şifreli gövde yarıda kesildi.');
}

/// Küçük gövde (JSON) için: tümünü şifreler.
Uint8List sealBytes(List<int> plain, SealContext ctx) {
  if (plain.isEmpty) return Uint8List(0);
  final out = BytesBuilder(copy: false);
  var index = 0;
  for (var pos = 0; pos < plain.length; pos += sealChunkSize) {
    final end = _min(pos + sealChunkSize, plain.length);
    out.add(ctx.sealFrame(Uint8List.fromList(plain.sublist(pos, end)), index++, last: end == plain.length));
  }
  return out.takeBytes();
}

/// Küçük gövde (JSON) için: tümünü çözer.
Future<Uint8List> openBytes(List<int> wire, SealContext ctx, {int? maxPlain}) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in openStream(Stream.value(wire), ctx, maxPlain: maxPlain)) {
    out.add(chunk);
  }
  return out.takeBytes();
}
