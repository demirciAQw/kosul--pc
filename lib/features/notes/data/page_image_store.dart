import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;

import '../../../core/media/media_storage.dart';
import '../domain/page_item_geometry.dart';

/// Kodlanmış görsel: baytlar + son piksel boyutu + uzantı (noktasız).
class EncodedPageImage {
  const EncodedPageImage(this.bytes, this.pxW, this.pxH, {this.ext = 'webp'});
  final Uint8List bytes;
  final int pxW;
  final int pxH;
  final String ext;
}

/// Görseli küçültüp sıkıştıran parça (testte sahtesi verilir).
abstract interface class PageImageEncoder {
  Future<EncodedPageImage> encode(Uint8List source, {int maxSide});
}

/// Varsayılan kodlayıcı: en uzun kenar [maxSide]'ı geçmez, WebP. `core/media` hattının
/// kullandığı `flutter_image_compress` yeniden kullanılır (yeni paket yok). Eklenti
/// gerektirir: birim testte çalışmaz.
class FlutterPageImageEncoder implements PageImageEncoder {
  const FlutterPageImageEncoder({this.quality = 85});
  final int quality;

  @override
  Future<EncodedPageImage> encode(Uint8List source, {int maxSide = 2048}) async {
    final codec = await ui.instantiateImageCodec(source);
    final frame = await codec.getNextFrame();
    final w = frame.image.width, h = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    final fit = fitWithin(w, h, maxSide: maxSide);
    // minWidth/minHeight: kısa kenar oranına göre ölçek; hedef boyut verilince en uzun kenar sınırlanır.
    final out = await FlutterImageCompress.compressWithList(
      source,
      minWidth: fit.w,
      minHeight: fit.h,
      quality: quality,
      format: CompressFormat.webp,
      keepExif: false,
    );
    if (out.isEmpty) throw const FileSystemException('Görsel sıkıştırılamadı');
    return EncodedPageImage(out, fit.w, fit.h);
  }
}

/// Sayfa görsellerinin deposu: görseli küçültüp uygulama medya klasörüne
/// `notes/yyyy/mm/<uuid>.<ext>` olarak yazar (kablosuz aktarım kuralına uyan yol).
/// Dosyalar HİÇ silinmez (bkz. `InkPageItemRepository`): öğe silinince ya da sayfa
/// çoğaltılınca dosya paylaşılır; temizlik kullanıcı kararıdır.
class PageImageStore {
  PageImageStore(this._storage, {this.encoder = const FlutterPageImageEncoder(), this.maxSide = 2048, this.tempDir});

  final MediaStorage _storage;
  final PageImageEncoder encoder;
  final Directory? tempDir;

  /// En uzun kenar üst sınırı (piksel).
  final int maxSide;

  /// [source] bayt dizisini küçültüp kaydeder; göreli yol ve piksel boyutu döner.
  Future<StoredPageImage> saveBytes(Uint8List source) async {
    final enc = await encoder.encode(source, maxSide: maxSide);
    final fit = fitWithin(enc.pxW, enc.pxH, maxSide: maxSide);
    final tmpRoot = tempDir ?? Directory.systemTemp;
    final tmp = File(p.join(tmpRoot.path, 'kocum_sayfa_${DateTime.now().microsecondsSinceEpoch}.${enc.ext}'));
    try {
      await tmp.writeAsBytes(enc.bytes, flush: true);
      final rel = await _storage.importFile(tmp.path, bucket: 'notes');
      if (!isPageImagePath(rel)) {
        // Depo kuralı dışı yol üretmiş: kablosuzda taşınamazdı; yazılan dosya yine de SİLİNMEZ.
        throw StateError('Görsel yolu kurala uymuyor: $rel');
      }
      return StoredPageImage(rel, fit.w, fit.h);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete(); // yalnızca kendi geçici dosyamız
      } on FileSystemException {
        // geçici dosya; sistem temizler
      }
    }
  }

  /// Galeriden/kameradan gelen dosyayı kaydeder (kaynak dosyaya dokunulmaz).
  Future<StoredPageImage> saveFile(String sourcePath) async => saveBytes(await File(sourcePath).readAsBytes());

  File resolve(String relativePath) => _storage.resolve(relativePath);
}

class StoredPageImage {
  const StoredPageImage(this.path, this.pxW, this.pxH);
  final String path;
  final int pxW;
  final int pxH;
}
