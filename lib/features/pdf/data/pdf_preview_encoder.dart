import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../../../core/media/bmp_encoder.dart';

/// Önizleme baytları ve dosya uzantısı.
class EncodedPreview {
  const EncodedPreview(this.bytes, this.extension);
  final Uint8List bytes;

  /// ".webp" ya da ".png"
  final String extension;
}

/// Ham RGBA pikselleri küçük önizleme dosyasına çevirir.
///
/// Önce projenin mevcut fotoğraf hattı: BMP ara biçimi + `flutter_image_compress`
/// ile WebP (Android). O eklenti yoksa (Linux/test) ya da hata verirse Flutter'ın
/// yerel kodlayıcısıyla PNG: `dart:ui` yalnızca PNG üretir, WebP üretemez.
Future<EncodedPreview> encodePreview(Uint8List rgba, int width, int height, {int quality = 80}) async {
  try {
    final bmp = rgbaToBmp(rgba, width, height);
    final out = await FlutterImageCompress.compressWithList(
      bmp,
      minWidth: width,
      minHeight: height,
      quality: quality,
      format: CompressFormat.webp,
      keepExif: false,
    );
    if (out.isNotEmpty) return EncodedPreview(out, '.webp');
  } catch (_) {
    // Eklenti yok ya da kodlayamadı: PNG'ye düş.
  }
  return EncodedPreview(await _png(rgba, width, height), '.png');
}

Future<Uint8List> _png(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer,
      width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG kodlanamadı');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
