import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../domain/layer_pixels.dart';
import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart';
import '../domain/watermark.dart';

/// ui.Image için en az kullanılan çıkar (LRU) önbellek; BAYT sınırlıdır (piksel
/// boyutuna göre: genişlik x yükseklik x 4). Çıkan görüntü dispose edilir:
/// çizen kod önbellekten `clone()` alıp kendi kopyasını yönetmelidir.
class LayerImageCache {
  LayerImageCache({this.capacity = 1 << 30, this.maxBytes = defaultMaxBytes});

  /// En çok kaç görüntü (varsayılan: sınırsız; asıl sınır [maxBytes]).
  final int capacity;

  /// Toplam piksel baytı üst sınırı (varsayılan 96 MB).
  final int maxBytes;
  static const defaultMaxBytes = 96 * 1024 * 1024;

  final _map = <String, ui.Image>{};
  int _bytes = 0;

  int get length => _map.length;
  int get bytes => _bytes;
  Iterable<String> get keys => _map.keys;
  bool contains(String key) => _map.containsKey(key);

  static int sizeOf(ui.Image i) => i.width * i.height * 4;

  /// Varsa son kullanılana taşır ve KOPYASINI verir (çağıran dispose eder).
  ui.Image? take(String key) {
    final img = _map.remove(key);
    if (img == null) return null;
    _map[key] = img;
    return img.clone();
  }

  void put(String key, ui.Image img) {
    final old = _map.remove(key);
    if (old != null) {
      _bytes -= sizeOf(old);
      old.dispose();
    }
    _map[key] = img;
    _bytes += sizeOf(img);
    // En yeni görüntü tek başına sınırı aşsa bile tutulur (çizilebilsin).
    while (_map.length > 1 && (_map.length > capacity || _bytes > maxBytes)) {
      final k = _map.keys.first;
      final i = _map.remove(k)!;
      _bytes -= sizeOf(i);
      i.dispose();
    }
  }

  void clear() {
    for (final i in _map.values) {
      i.dispose();
    }
    _map.clear();
    _bytes = 0;
  }
}

/// Bekleyen render işini iptal etmek için (sayfa görünmez olunca).
class LayerJobToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
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

class _Full {
  const _Full(this.bytes, this.width, this.height, this.order, this.pageW, this.pageH);
  final Uint8List bytes;
  final int width, height;
  final PixelOrder order;
  final double pageW, pageH;
}

class _Job {
  _Job(this.key, this.page, this.target, this.chain, this.bucket);
  final String key;
  final int page;
  final PdfPageLayer target;
  final List<PdfPageLayer> chain;
  final int bucket;
  final tokens = <LayerJobToken>[];
  bool anonymous = false; // tokensiz istek: iptal edilemez
  final done = Completer<bool>();
  bool get cancelled => !anonymous && tokens.every((t) => t.cancelled);
}

/// Filigran katmanlarının görüntülerini üretir ve önbellekler. PDF dosyası
/// değişmez; yalnızca render edilen piksellere işlem yapılır.
///
/// Bellek: tam sayfa render ~47 MB, işlem sırasında bunun birkaç katı. Bu yüzden
/// işler TEK kuyrukta ([maxConcurrent], varsayılan 1) çalışır; görünmeyen sayfanın
/// bekleyen işi [LayerJobToken] ile düşer; aynı sayfa/çözünürlükteki katmanlar tek
/// tam sayfa render'ı paylaşır (kuyruk boşalınca bırakılır).
class PdfLayerRenderer {
  PdfLayerRenderer({
    required this.documentId,
    required Future<PdfEngineDocument> Function() open,
    LayerImageCache? cache,
    this.maxConcurrent = 1,
  })  : _open = (() => open()),
        cache = cache ?? LayerImageCache();

  final String documentId;
  final Future<PdfEngineDocument> Function() _open;
  final LayerImageCache cache;
  final int maxConcurrent;
  Future<PdfEngineDocument>? _doc;
  final _jobs = <String, _Job>{};
  final _pending = <_Job>[];
  int _active = 0;
  bool _disposed = false;
  String? _fullKey;
  Future<_Full>? _fullFuture;

  /// Test/ölçüm için: gerçek üretim sayısı (önbellek isabeti sayılmaz).
  int renders = 0;

  /// Test/ölçüm için: tam sayfa PDF render sayısı ve aynı anda çalışan iş zirvesi.
  int fullRenders = 0;
  int peakActive = 0;
  int cancelledJobs = 0;

  Future<PdfEngineDocument> get _document => _doc ??= _open();

  /// Belgenin sayfa sayısı.
  Future<int> pageCount() async => (await _document).pageCount;

  Future<_Full> _renderFull(int page, int widthPx) async {
    final doc = await _document;
    final size = await doc.pageSize(page);
    var scale = widthPx / size.width;
    while (size.width * scale * size.height * scale > maxRenderPixels * 0.9) {
      scale *= 0.85;
    }
    final w = math.max<int>(1, (size.width * scale).round());
    final h = math.max<int>(1, (size.height * scale).round());
    final img = await doc.renderPage(page, width: w, height: h);
    fullRenders++;
    final order = img.format == PdfPixelFormat.bgra ? PixelOrder.bgra : PixelOrder.rgba;
    return _Full(img.bytes, img.width, img.height, order, size.width, size.height);
  }

  RegionPixels _crop(_Full f, PdfBox? box) {
    final sx = f.width / f.pageW, sy = f.height / f.pageH;
    final b = box == null ? null : clampLayerBox(box, f.pageW, f.pageH);
    if (b == null) return RegionPixels(f.bytes, f.width, f.height, f.order, PdfBox(0, 0, f.pageW, f.pageH), sx);
    final x0 = (b.left * sx).floor().clamp(0, f.width - 1);
    final y0 = (b.top * sy).floor().clamp(0, f.height - 1);
    final x1 = (b.right * sx).ceil().clamp(x0 + 1, f.width);
    final y1 = (b.bottom * sy).ceil().clamp(y0 + 1, f.height);
    final cw = x1 - x0, ch = y1 - y0;
    final out = Uint8List(cw * ch * 4);
    for (var y = 0; y < ch; y++) {
      final s = ((y0 + y) * f.width + x0) * 4;
      out.setRange(y * cw * 4, (y + 1) * cw * 4, f.bytes, s);
    }
    return RegionPixels(out, cw, ch, f.order, PdfBox(x0 / sx, y0 / sy, x1 / sx, y1 / sy), sx);
  }

  /// Sayfayı (ya da [box] bölgesini) katmansız, [widthPx] sayfa genişliğinde çizer.
  /// Sayfa pikseli [maxRenderPixels] * 0.9'u aşmayacak biçimde küçültülür.
  Future<RegionPixels> renderRaw(int page, {PdfBox? box, required int widthPx}) async =>
      _crop(await _renderFull(page, widthPx), box);

  /// Kuyruk işleri için paylaşılan tam sayfa render'ı (tek giriş).
  Future<_Full> _sharedFull(int page, int widthPx) {
    final k = '$page|$widthPx';
    if (_fullKey == k && _fullFuture != null) return _fullFuture!;
    _fullKey = k;
    return _fullFuture = _renderFull(page, widthPx);
  }

  /// [target] filigran katmanının görüntüsü. [chain]: aynı sayfaya uygulanan TÜM görünür
  /// katmanlar (filigran ve örtü) z sırasıyla ([target] son eleman); böylece alttaki
  /// örtüler ve üst üste binen filigranlar birlikte uygulanır (bkz. [layerChainUpTo]).
  /// [token] iptal edilirse ve iş henüz başlamadıysa hiç çalıştırılmaz (null döner).
  /// Üretilemezse null.
  Future<ui.Image?> imageFor(int page, PdfPageLayer target, List<PdfPageLayer> chain, int bucket,
      {LayerJobToken? token}) async {
    if (_disposed) return null;
    final key = cacheKey(page, target, chain, bucket);
    final hit = cache.take(key);
    if (hit != null) return hit;
    final job = _jobs.putIfAbsent(key, () {
      final j = _Job(key, page, target, chain, bucket);
      _pending.add(j);
      return j;
    });
    if (token == null) {
      job.anonymous = true;
    } else {
      job.tokens.add(token);
    }
    _pump();
    final ok = await job.done.future;
    return ok && !_disposed ? cache.take(key) : null;
  }

  void _pump() {
    while (!_disposed && _active < maxConcurrent && _pending.isNotEmpty) {
      final j = _pending.removeAt(0);
      if (j.cancelled) {
        cancelledJobs++;
        _jobs.remove(j.key);
        j.done.complete(false);
        continue;
      }
      _active++;
      peakActive = math.max(peakActive, _active);
      _run(j).then((ok) {
        _active--;
        _jobs.remove(j.key);
        if (!j.done.isCompleted) j.done.complete(ok);
        if (_active == 0 && _pending.isEmpty) {
          _fullKey = null;
          _fullFuture = null; // 47 MB'lık ham sayfa bırakılır
        }
        _pump();
      });
    }
  }

  Future<bool> _run(_Job j) async {
    try {
      final full = await _sharedFull(j.page, j.bucket);
      if (_disposed || j.cancelled) {
        cancelledJobs++;
        return false;
      }
      final raw = _crop(full, j.target.box);
      renders++;
      final out = await applyLayersInIsolate(
        raw.bytes,
        raw.width,
        raw.height,
        raw.pxPerUnit,
        raw.pxPerUnit,
        j.chain,
        originX: raw.box.left,
        originY: raw.box.top,
        order: raw.order,
      );
      if (_disposed || j.cancelled) {
        cancelledJobs++;
        return false;
      }
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
      cache.put(j.key, img);
      return true;
    } catch (_) {
      return false;
    }
  }

  String cacheKey(int page, PdfPageLayer target, List<PdfPageLayer> chain, int bucket) =>
      '$documentId|$page|$bucket|${target.id}|${chain.map((l) => '${l.id}:${l.paramKey}').join(';')}';

  /// Belgeyi kapatır, önbelleği boşaltır (görüntüler dispose edilir).
  Future<void> dispose() async {
    _disposed = true;
    for (final j in _pending) {
      _jobs.remove(j.key);
      if (!j.done.isCompleted) j.done.complete(false);
    }
    _pending.clear();
    _fullFuture = null;
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
