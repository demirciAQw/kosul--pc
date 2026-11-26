import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../domain/pdf_engine.dart';

/// PDF'in 1. sayfasından küçük kapak resmi (PNG) üretir ve diskte önbelleğe alır.
/// Ad = pdf sha256 (`<dir>/<sha256>.png`); bir kez üretilir, sonra dosyadan okunur.
/// Üretim SIRAYLA yapılır (aynı anda tek PDF açılır): liste kaydırmayı yavaşlatmaz.
class PdfCoverStore {
  PdfCoverStore({required this.engine, required this.dir, this.width = 300});

  final PdfEngine engine;
  final Directory dir;
  final int width;

  Future<void> _tail = Future.value();
  final Map<String, Future<File?>> _pending = {};

  File fileFor(String sha256) => File(p.join(dir.path, '$sha256.png'));

  /// Kapak dosyası; yoksa üretir. PDF dosyası yoksa ya da üretim başarısızsa null.
  Future<File?> coverFor(String sha256, File pdf) {
    final cached = fileFor(sha256);
    if (cached.existsSync() && cached.lengthSync() > 0) return Future.value(cached);
    return _pending[sha256] ??= _enqueue(sha256, pdf).whenComplete(() => _pending.remove(sha256));
  }

  Future<File?> _enqueue(String sha256, File pdf) {
    final c = Completer<File?>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await _generate(sha256, pdf));
      } catch (_) {
        c.complete(null);
      }
    });
    return c.future;
  }

  Future<File?> _generate(String sha256, File pdf) async {
    final out = fileFor(sha256);
    if (out.existsSync() && out.lengthSync() > 0) return out;
    if (!pdf.existsSync()) return null;
    final doc = await engine.openFile(pdf.path);
    try {
      if (doc.pageCount < 1) return null;
      final size = await doc.pageSize(0);
      if (size.width <= 0 || size.height <= 0) return null;
      final h = (width * size.height / size.width).round().clamp(1, 1200);
      final img = await doc.renderPage(0, width: width, height: h);
      final png = await _png(img);
      await dir.create(recursive: true);
      final tmp = File('${out.path}.part');
      await tmp.writeAsBytes(png, flush: true);
      await tmp.rename(out.path);
      return out;
    } finally {
      await doc.close();
    }
  }

  Future<List<int>> _png(PdfRenderedImage img) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(img.bytes);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: img.width,
        height: img.height,
        pixelFormat: img.format == PdfPixelFormat.bgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888);
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
}
