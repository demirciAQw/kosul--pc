import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../../core/media/photo_capture_service.dart' show CropOutput;

/// Resim dosyası uzantıları (sürükle-bırak ve dosya seçici).
const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'};

bool isImagePath(String path) => imageExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

/// Kırpma çıktısını (ham RGBA) PNG dosyası olarak [dir] içine yazar.
/// Bilgisayarda telefondaki WebP sıkıştırma yoktur; PNG kayıpsız ve yeterlidir.
Future<String> writeCropAsPng(CropOutput crop, Directory dir, String name) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(crop.rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: crop.width,
    height: crop.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  if (data == null) throw const FileSystemException('Kırpılan görüntü PNG\'ye çevrilemedi.');
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, '$name.png'));
  await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  return file.path;
}
