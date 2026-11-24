import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/media/photo_capture_service.dart';

/// Sayfaya eklenecek görselin kaynağı.
enum PageImageSource { gallery, file, camera }

/// Seçilen görsel dosyası. [temp]: uygulamanın kendi geçici kopyası (iş bitince silinir);
/// değilse kullanıcının dosyasıdır ve ASLA silinmez.
class PickedPageImage {
  const PickedPageImage(this.path, {this.temp = false});
  final String path;
  final bool temp;
}

/// Görsel seçici (testte değiştirilir). Vazgeçilirse null.
abstract interface class PageImagePicker {
  Future<PickedPageImage?> pick(PageImageSource source);
}

/// Galeri/kamera mevcut fotoğraf hattıyla ([PhotoCaptureService.pickToTemp]), dosya
/// `file_picker` ile (ikisi de zaten pubspec'te).
class PlatformPageImagePicker implements PageImagePicker {
  PlatformPageImagePicker(this._capture);
  final PhotoCaptureService _capture;

  @override
  Future<PickedPageImage?> pick(PageImageSource source) async {
    switch (source) {
      case PageImageSource.file:
        final res = await FilePicker.platform.pickFiles(type: FileType.image);
        final path = res?.files.single.path;
        return path == null ? null : PickedPageImage(path);
      case PageImageSource.gallery:
      case PageImageSource.camera:
        final path = await _capture.pickToTemp(
          source == PageImageSource.camera ? PhotoSource.camera : PhotoSource.gallery,
        );
        return path == null ? null : PickedPageImage(path, temp: true);
    }
  }
}

final pageImagePickerProvider = Provider<PageImagePicker>(
  (ref) => PlatformPageImagePicker(ref.watch(photoCaptureProvider)),
);
