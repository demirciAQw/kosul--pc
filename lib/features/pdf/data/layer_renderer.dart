import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../domain/layer_pixels.dart';
import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart';
import '../domain/watermark.dart';

/// ui.Image için en az kullanılan çıkar (LRU) önbellek. Çıkan görüntü dispose edilir:
/// çizen kod önbellekten `clone()` alıp kendi kopyasını yönetmelidir.
class LayerImageCache {
  LayerImageCache({this.capacity = 12});
  final int capacity;
  final _map = <String, ui.Image>{};

  int get length => _map.length;
  Iterable<String> get keys => _map.keys;
  bool contains(String key) => _map.containsKey(key);

  /// Varsa son kullanılana taşır ve KOPYASINI verir (çağıran dispose eder).
  ui.Image? take(String key) {
    final img = _map.remove(key);
    if (img == null) return null;
    _map[key] = img;
    return img.clone();
  }

  void put(String key, ui.Image img) {
    _map.remove(key)?.dispose();
    _map[key] = img;
    while (_map.length > capacity) {
      final k = _map.keys.first;
      _map.remove(k)!.dispose();
    }
  }

  void clear() {
    for (final i in _map.values) {
      i.dispose();
    }
    _map.clear();
  }
}

/// Katman görüntüsünün çözünürlük kovaları (piksel cinsinden sayfa genişliği).
const layerWidthBuckets = [700, 1100, 1700, 2500, 3400];

/// İstenen fiziksel genişliği (piksel) kovaya yuvarlar (üst sınır son kova).
int layerBucketFor(double wantedPx) {
  for (final b in layerWidthBuckets) {
    if (wantedPx <= b) return b;
  }
  return layerWidthBuckets.last;
}

/// Bir sayfanın (ya da bölgesinin) ham, katmansız pikselleri.
class RegionPixels {
  const RegionPixels(this.bytes, this.width, this.height, this.order, this.box, this.pxPerUnit);
  final Uint8List bytes;
  final int width;
  final int height;
  final PixelOrder order;

  /// Bu piksellerin sayfadaki yeri (PDF birimi).
  final PdfBox box;
  final double pxPerUnit;
}

/// Filigran katmanlarının görüntülerini üretir ve önbellekler. PDF dosyası
/// değişmez; yalnızca render edilen piksellere işlem yapılır.
class PdfLayerRenderer {
  PdfLayerRenderer({
    required this.documentId,
    required Future<PdfEngineDocument> Function() open,
    LayerImageCache? cache,
  })  : _open = (() => open()),
        cache = cache ?? LayerImageCache();

  final String documentId;
  final Future<PdfEngineDocument> Function() _open;
  final LayerImageCache cache;
  Future<PdfEngineDocument>? _doc;
  final _inflight = <String, Future<bool>>{};
  bool _disposed = false;

  /// Test/ölçüm için: gerçek üretim sayısı (önbellek isabeti sayılmaz).
  int renders = 0;

  Future<PdfEngineDocument> get _document => _doc ??= _open();

  /// Sayfayı (ya da [box] bölgesini) katmansız, [widthPx] sayfa genişliğinde çizer.
  /// Sayfa pikseli [maxRenderPixels] * 0.9'u aşmayacak biçimde küçültülür.
  Future<RegionPixels> renderRaw(int page, {PdfBox? box, required int widthPx}) async {
    final doc = await _document;
    final size = await doc.pageSize(page);
    var scale = widthPx / size.width;
    while (size.width * scale * size.height * scale > maxRenderPixels * 0.9) {
      scale *= 0.85;
    }
    final w = math.max<int>(1, (size.width * scale).round());
    final h = math.max<int>(1, (size.height * scale).round());
    final img = await doc.renderPage(page, width: w, height: h);
    final order = img.format == PdfPixelFormat.bgra ? PixelOrder.bgra : PixelOrder.rgba;
    final sx = img.width / size.width, sy = img.height / size.height;
    final b = box == null ? null : clampLayerBox(box, size.width, size.height);
    if (b == null) return RegionPixels(img.bytes, img.width, img.height, order, PdfBox(0, 0, size.width, size.height), sx);
    final x0 = (b.left * sx).floor().clamp(0, img.width - 1);
    final y0 = (b.top * sy).floor().clamp(0, img.height - 1);
    final x1 = (b.right * sx).ceil().clamp(x0 + 1, img.width);
    final y1 = (b.bottom * sy).ceil().clamp(y0 + 1, img.height);
    final cw = x1 - x0, ch = y1 - y0;
    final out = Uint8List(cw * ch * 4);
    for (var y = 0; y < ch; y++) {
      final s = ((y0 + y) * img.width + x0) * 4;
      out.setRange(y * cw * 4, (y + 1) * cw * 4, img.bytes, s);
    }
    return RegionPixels(out, cw, ch, order, PdfBox(x0 / sx, y0 / sy, x1 / sx, y1 / sy), sx);
  }

  /// [target] filigran katmanının görüntüsü. [chain]: aynı sayfaya uygulanan görünür
  /// filigran katmanları z sırasıyla ([target] son eleman); böylece üst üste binen
  /// katmanlar birlikte uygulanır. Üretilemezse null.
  Future<ui.Image?> imageFor(int page, PdfPageLayer target, List<PdfPageLayer> chain, int bucket) async {
    final key = cacheKey(page, target, chain, bucket);
    final hit = cache.take(key);
    if (hit != null) return hit;
    final ok = await _inflight.putIfAbsent(key, () async {
      try {
        final raw = await renderRaw(page, box: target.box, widthPx: bucket);
        renders++;
        final out = await applyLayersInIsolate(
          raw.bytes,
          raw.width,
          raw.height,
          raw.pxPerUnit,
          raw.pxPerUnit,
          chain,
          originX: raw.box.left,
          originY: raw.box.top,
          order: raw.order,
        );
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          out,
          raw.width,
          raw.height,
          raw.order == PixelOrder.bgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888,
          c.complete,
        );
        final img = await c.future;
        if (_disposed) {
          img.dispose();
          return false;
        }
        cache.put(key, img);
        return true;
      } catch (_) {
        return false;
      } finally {
        _inflight.removeWhere((k, _) => k == key);
      }
    });
    return ok && !_disposed ? cache.take(key) : null;
  }

  String cacheKey(int page, PdfPageLayer target, List<PdfPageLayer> chain, int bucket) =>
      '$documentId|$page|$bucket|${target.id}|${chain.map((l) => '${l.id}:${l.paramKey}').join(';')}';

  /// Belgeyi kapatır, önbelleği boşaltır (görüntüler dispose edilir).
  Future<void> dispose() async {
    _disposed = true;
    cache.clear();
    final d = _doc;
    _doc = null;
    if (d != null) {
      try {
        await (await d).close();
      } catch (_) {
        // kapanış hatası önemsiz
      }
    }
  }
}
