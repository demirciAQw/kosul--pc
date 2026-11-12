import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/export/zip_reader.dart';
import 'package:kocum/core/export/zip_writer.dart';

/// Tek girdili, "deflate" ile sıkıştırılmış ZIP (başka araçların yazdığı gibi).
Uint8List _deflateZip(String name, List<int> data) {
  final nameBytes = utf8.encode(name);
  final packed = ZLibEncoder(raw: true).convert(data);
  final crc = crc32(data);
  final local = ByteData(30)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 0x0800, Endian.little)
    ..setUint16(8, 8, Endian.little)
    ..setUint32(14, crc, Endian.little)
    ..setUint32(18, packed.length, Endian.little)
    ..setUint32(22, data.length, Endian.little)
    ..setUint16(26, nameBytes.length, Endian.little);
  final central = ByteData(46)
    ..setUint32(0, 0x02014b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 20, Endian.little)
    ..setUint16(8, 0x0800, Endian.little)
    ..setUint16(10, 8, Endian.little)
    ..setUint32(16, crc, Endian.little)
    ..setUint32(20, packed.length, Endian.little)
    ..setUint32(24, data.length, Endian.little)
    ..setUint16(28, nameBytes.length, Endian.little)
    ..setUint32(42, 0, Endian.little);
  final localBytes = [...local.buffer.asUint8List(), ...nameBytes, ...packed];
  final centralBytes = [...central.buffer.asUint8List(), ...nameBytes];
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, 1, Endian.little)
    ..setUint16(10, 1, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, localBytes.length, Endian.little);
  return Uint8List.fromList([...localBytes, ...centralBytes, ...end.buffer.asUint8List()]);
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('kocum_zip'));
  tearDown(() => dir.delete(recursive: true));

  Future<File> write(String name, List<int> bytes) async => File('${dir.path}/$name')..writeAsBytesSync(bytes);

  test('yazıcının ZIP\'i geri okunur (Türkçe adlar, klasörler)', () async {
    final w = ZipWriter()
      ..addText('kocum_yedek.json', '{"format":"kocum.backup"}')
      ..add('media/sorular/çözüm.webp', [1, 2, 3, 4]);
    final zip = await ZipFileReader.open(await write('a.zip', w.finish()));
    addTearDown(zip.close);
    expect(zip.entries.map((e) => e.name), ['kocum_yedek.json', 'media/sorular/çözüm.webp']);
    expect(utf8.decode(await zip.read(zip.find('kocum_yedek.json')!)), '{"format":"kocum.backup"}');
    expect(await zip.read(zip.find('media/sorular/çözüm.webp')!), [1, 2, 3, 4]);
    expect(zip.find('yok.txt'), isNull);
  });

  test('deflate ile sıkıştırılmış girdi açılır', () async {
    final data = utf8.encode('tekrar ' * 500);
    final zip = await ZipFileReader.open(await write('b.zip', _deflateZip('kocum.db', data)));
    addTearDown(zip.close);
    final e = zip.find('kocum.db')!;
    expect(e.method, 8);
    expect(e.compressedSize, lessThan(data.length));
    expect(await zip.read(e), data);
  });

  test('bozuk içerik ve ZIP olmayan dosya anlaşılır hata verir', () async {
    final bytes = ZipWriter().finish();
    expect(ZipFileReader.open(await write('bos.zip', bytes)).then((z) => z.close()), completes);
    await expectLater(ZipFileReader.open(await write('metin.zip', utf8.encode('merhaba dünya, ben zip değilim'))),
        throwsA(isA<ZipFormatException>()));

    final good = (ZipWriter()..add('x.bin', [9, 9, 9, 9, 9, 9])).finish();
    final broken = Uint8List.fromList(good);
    broken[30 + 'x.bin'.length] ^= 0xFF; // ilk veri baytı
    final zip = await ZipFileReader.open(await write('bozuk.zip', broken));
    addTearDown(zip.close);
    await expectLater(zip.read(zip.find('x.bin')!), throwsA(isA<ZipFormatException>()));
  });

  test('güvenli yol: mutlak yollar ve klasör dışına çıkış reddedilir', () {
    expect(isSafeZipPath('media/sorular/2026/10/a.webp'), isTrue);
    expect(isSafeZipPath('/etc/passwd'), isFalse);
    expect(isSafeZipPath('media/../../.bashrc'), isFalse);
    expect(isSafeZipPath('..'), isFalse);
    expect(isSafeZipPath(r'media\a.webp'), isFalse);
    expect(isSafeZipPath(''), isFalse);
  });
}
