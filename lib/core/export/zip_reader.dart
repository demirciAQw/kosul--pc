import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'zip_writer.dart' show crc32;

class ZipFormatException implements Exception {
  const ZipFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.crc,
    required this.localHeaderOffset,
  });

  final String name;
  final int method; // 0: sıkıştırmasız, 8: deflate
  final int compressedSize;
  final int size;
  final int crc;
  final int localHeaderOffset;

  bool get isDirectory => name.endsWith('/');
}

/// Arşivdeki ad güvenli bir göreli yol mu? Mutlak yollar ve ".." ile klasör
/// dışına çıkan adlar ("zip slip") reddedilir.
bool isSafeZipPath(String name) {
  if (name.isEmpty || name.startsWith('/') || name.contains('\\') || name.contains('\u0000')) return false;
  return !name.split('/').any((s) => s == '..');
}

/// Bağımlılıksız ZIP okuyucu ([ZipWriter]'ın karşılığı). Sıkıştırmasız ve
/// "deflate" girdileri okur (başka bir araçla yeniden sıkıştırılmış yedekler
/// için). ZIP64 ve şifreli arşivler desteklenmez. Dosyanın tamamı belleğe
/// alınmaz; yalnızca istenen girdi okunur ve CRC ile doğrulanır.
class ZipFileReader {
  ZipFileReader._(this._file, this.entries);

  final RandomAccessFile _file;
  final List<ZipEntry> entries;

  static Future<ZipFileReader> open(File file) async {
    final raf = await file.open();
    try {
      return ZipFileReader._(raf, await _readCentralDirectory(raf));
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  ZipEntry? find(String name) {
    for (final e in entries) {
      if (e.name == name) return e;
    }
    return null;
  }

  Future<Uint8List> read(ZipEntry e) async {
    await _file.setPosition(e.localHeaderOffset);
    final header = ByteData.sublistView(await _readExact(_file, 30));
    if (header.getUint32(0, Endian.little) != 0x04034b50) {
      throw ZipFormatException('ZIP bozuk (yerel başlık): ${e.name}');
    }
    final nameLength = header.getUint16(26, Endian.little);
    final extraLength = header.getUint16(28, Endian.little);
    await _file.setPosition(e.localHeaderOffset + 30 + nameLength + extraLength);
    final raw = await _readExact(_file, e.compressedSize);
    final data = switch (e.method) {
      0 => raw,
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
      _ => throw ZipFormatException('Desteklenmeyen sıkıştırma yöntemi (${e.method}): ${e.name}'),
    };
    if (data.length != e.size || crc32(data) != e.crc) {
      throw ZipFormatException('ZIP içindeki dosya bozuk: ${e.name}');
    }
    return data;
  }

  /// Girdiyi diske yazar (ör. veritabanı kopyası).
  Future<void> extractTo(ZipEntry e, File target) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes(await read(e), flush: true);
  }

  Future<void> close() => _file.close();

  static Future<List<ZipEntry>> _readCentralDirectory(RandomAccessFile f) async {
    final length = await f.length();
    if (length < 22) throw const ZipFormatException('Bu dosya bir ZIP değil');
    // Dizin sonu kaydı en fazla 64 KB'lık bir açıklamayla birlikte sondadır.
    final tailLength = math.min<int>(length, 22 + 0xFFFF);
    await f.setPosition(length - tailLength);
    final tail = ByteData.sublistView(await _readExact(f, tailLength));
    var end = -1;
    for (var i = tailLength - 22; i >= 0; i--) {
      if (tail.getUint32(i, Endian.little) == 0x06054b50) {
        end = i;
        break;
      }
    }
    if (end < 0) throw const ZipFormatException('Bu dosya bir ZIP değil');
    final count = tail.getUint16(end + 10, Endian.little);
    final directorySize = tail.getUint32(end + 12, Endian.little);
    final directoryOffset = tail.getUint32(end + 16, Endian.little);
    if (count == 0xFFFF || directoryOffset == 0xFFFFFFFF) {
      throw const ZipFormatException('Çok büyük (ZIP64) arşivler desteklenmiyor');
    }
    if (directoryOffset + directorySize > length) throw const ZipFormatException('ZIP bozuk (dizin)');

    await f.setPosition(directoryOffset);
    final bytes = await _readExact(f, directorySize);
    final d = ByteData.sublistView(bytes);
    final entries = <ZipEntry>[];
    var p = 0;
    for (var i = 0; i < count; i++) {
      if (p + 46 > bytes.length || d.getUint32(p, Endian.little) != 0x02014b50) {
        throw const ZipFormatException('ZIP bozuk (dizin kaydı)');
      }
      final flags = d.getUint16(p + 8, Endian.little);
      if ((flags & 1) != 0) throw const ZipFormatException('Şifreli ZIP desteklenmiyor');
      final nameLength = d.getUint16(p + 28, Endian.little);
      final extraLength = d.getUint16(p + 30, Endian.little);
      final commentLength = d.getUint16(p + 32, Endian.little);
      if (p + 46 + nameLength > bytes.length) throw const ZipFormatException('ZIP bozuk (dosya adı)');
      entries.add(ZipEntry(
        // Bayrak olmasa da güncel araçlar adları UTF-8 yazar.
        name: utf8.decode(bytes.sublist(p + 46, p + 46 + nameLength), allowMalformed: true),
        method: d.getUint16(p + 10, Endian.little),
        crc: d.getUint32(p + 16, Endian.little),
        compressedSize: d.getUint32(p + 20, Endian.little),
        size: d.getUint32(p + 24, Endian.little),
        localHeaderOffset: d.getUint32(p + 42, Endian.little),
      ));
      p += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
  }

  static Future<Uint8List> _readExact(RandomAccessFile f, int n) async {
    final b = await f.read(n);
    if (b.length != n) throw const ZipFormatException('ZIP beklenenden kısa (yarım inmiş olabilir)');
    return b;
  }
}
