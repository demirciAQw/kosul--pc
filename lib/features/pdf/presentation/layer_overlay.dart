import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/layer_renderer.dart';
import '../data/pdf_layers_repository.dart';
import '../domain/page_layer.dart';

/// Okuyucunun katman durumu: belgenin katmanları, "orijinali göster" anahtarı ve
/// filigran görüntülerini üreten [PdfLayerRenderer]. PDF dosyası değişmez.
class PdfLayersHub {
  PdfLayersHub({required this.documentId, required this.repository, required this.renderer});

  final String documentId;
  final PdfLayersRepository repository;
  final PdfLayerRenderer renderer;

  /// Belgenin tüm (silinmemiş, gizliler dahil) katmanları, z sırasıyla.
  final layers = ValueNotifier<List<PdfPageLayer>>(const []);

  /// true: katmanlar uygulanmaz, özgün sayfa görünür.
  final showOriginal = ValueNotifier<bool>(false);

  /// Kalem çizgilerinin görünümü (yalnız görünüm; çizgi silinmez). Çizgiler sayfa
  /// koordinatında, katmanlardan bağımsız saklanır ve HER ZAMAN katmanların üstüne
  /// çizilir (okuyucuda `PdfPageInkLayer` katman örtüsünden sonra gelir; çözüm
  /// ekranında katmanlı arka planın üstündedir). "Orijinali göster" çizgileri gizlemez.
  final inkVisible = ValueNotifier<bool>(true);
  StreamSubscription<void>? _sub;
  StreamSubscription<List<PdfPageLayer>>? _dbSub;
  bool _disposed = false;
  int _gen = 0;

  DateTime? _lastRead;

  /// Katmanları okur ve depodaki her yazmadan sonra (bellek içi bildirim) yeniden okur.
  ///
  /// Başka cihazdan eşitlemeyle gelen ekleme/silme/gizleme için: veritabanı AKIŞI
  /// ([watchDatabase], `repository.watchAll`) varsayılan KAPALIDIR. Okuyucu testlerinde
  /// (sahte zaman) Drift akışı bir sonraki kareyi hiç tamamlatmayıp testi kilitliyor
  /// (denendi: `pdf_reader_page_test` zaman aşımı). Bunun yerine okuyucu sayfa
  /// değişince [refreshIfStale] ile yeniden okur (en çok 2 sn'de bir), panel de
  /// açılınca [refresh] çağırır; eşitleme farkı en geç bir sayfa çevirmede görünür.
  void start({bool watchDatabase = false}) {
    _sub = repository.changes.listen((_) => refresh());
    if (watchDatabase) {
      try {
        _dbSub = repository.watchAll(documentId).listen(
          (l) {
            if (!_disposed) {
              ++_gen; // uçuştaki eski okuma sonucu ezmesin
              layers.value = l;
            }
          },
          onError: (Object _) {},
        );
      } catch (_) {
        _dbSub = null;
      }
    }
    refresh();
  }

  /// Son okumadan [maxAge] geçtiyse yeniden okur (sayfa değişiminde ucuz güncelleme).
  void refreshIfStale({Duration maxAge = const Duration(seconds: 2)}) {
    final t = _lastRead;
    if (t != null && DateTime.now().difference(t) < maxAge) return;
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final gen = ++_gen;
    _lastRead = DateTime.now();
    try {
      final l = await repository.all(documentId);
      if (!_disposed && gen == _gen) layers.value = l;
    } catch (_) {
      // veritabanı kapanmış olabilir (okuyucu kapanırken)
    }
  }

  /// Bu sayfada uygulanacak görünür katmanlar (z sırasıyla).
  List<PdfPageLayer> visibleFor(int page) => visibleLayersFor(layers.value, page);

  /// Bu sayfaya ait tüm katmanlar (gizliler dahil): panel listesi.
  List<PdfPageLayer> listFor(int page) {
    final l = [for (final x in layers.value) if (x.appliesTo(page)) x];
    l.sort((a, b) => a.z != b.z ? a.z.compareTo(b.z) : a.id.compareTo(b.id));
    return l;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    await _dbSub?.cancel();
    layers.dispose();
    showOriginal.dispose();
    inkVisible.dispose();
    await renderer.dispose();
  }
}

/// Bir sayfanın üstündeki katman çizimi (kalem çizgilerinin ALTINDA, dokunuş almaz).
/// Filigran: önce düşük çözünürlüklü görüntü, zum durunca yüksek çözünürlüklü;
/// örtü: düz dikdörtgen.
class PdfPageLayerOverlay extends StatefulWidget {
  const PdfPageLayerOverlay({
    super.key,
    required this.hub,
    required this.page,
    required this.pageWidth,
    required this.pageHeight,
    this.zoom,
    this.zoomOf,
    this.settle = const Duration(milliseconds: 250),
  });

  final PdfLayersHub hub;
  final int page;
  final double pageWidth;
  final double pageHeight;

  /// Zum değişimini bildiren kaynak ve mevcut zum (yoksa 1).
  final Listenable? zoom;
  final double Function()? zoomOf;
  final Duration settle;

  @override
  State<PdfPageLayerOverlay> createState() => _PdfPageLayerOverlayState();
}

class _Shown {
  _Shown(this.image, this.bucket, this.paramKey);
  final ui.Image image;
  final int bucket;
  final String paramKey;
}

class _PdfPageLayerOverlayState extends State<PdfPageLayerOverlay> {
  final Map<String, _Shown> _shown = {};
  Timer? _timer;
  double _lastZoom = 1;
  double _layoutWidth = 0;
  double _dpr = 1;
  int _gen = 0;
  bool _disposed = false;
  LayerJobToken _token = LayerJobToken(); // bu sayfanın bekleyen işleri

  PdfLayersHub get _hub => widget.hub;

  @override
  void initState() {
    super.initState();
    _hub.layers.addListener(_onChange);
    _hub.showOriginal.addListener(_onChange);
    widget.zoom?.addListener(_onZoom);
  }

  @override
  void dispose() {
    _disposed = true;
    _token.cancel(); // görünmeyen sayfanın bekleyen işi düşer
    _timer?.cancel();
    _hub.layers.removeListener(_onChange);
    _hub.showOriginal.removeListener(_onChange);
    widget.zoom?.removeListener(_onZoom);
    for (final s in _shown.values) {
      s.image.dispose();
    }
    _shown.clear();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _request();
  }

  void _onZoom() {
    final z = widget.zoomOf?.call() ?? 1;
    if ((z - _lastZoom).abs() < 0.01) return;
    _lastZoom = z;
    // Zum sürerken eldeki görüntü ölçeklenerek çizilir; durunca keskin olanı iste.
    _timer?.cancel();
    _timer = Timer(widget.settle, () => _request());
  }

  /// Bu sayfanın görünür katmanları (z sırasıyla; filigran ve örtü).
  List<PdfPageLayer> get _ordered => _hub.visibleFor(widget.page);

  int _wantedBucket() => layerBucketFor(_layoutWidth * _lastZoom * _dpr);

  void _request() {
    if (_disposed || _layoutWidth <= 0 || _hub.showOriginal.value) return;
    // Önceki isteğin henüz başlamamış işleri düşer (zum / sayfa / katman değişti).
    _token.cancel();
    final token = _token = LayerJobToken();
    final ordered = _ordered;
    final gen = ++_gen;
    // Artık görünmeyen / değişen katmanların görüntüleri bırakılır.
    final live = {for (final l in ordered) if (l.kind == PdfLayerKind.watermark) l.id};
    for (final id in _shown.keys.toList()) {
      if (!live.contains(id)) _shown.remove(id)!.image.dispose();
    }
    final want = _wantedBucket();
    for (var i = 0; i < ordered.length; i++) {
      final l = ordered[i];
      if (l.kind != PdfLayerKind.watermark) continue;
      // Zincir: bu katmandan alttaki TÜM katmanlar (örtüler dahil), z sırası korunur.
      final chain = layerChainUpTo(ordered, i);
      final chainKey = chain.map((c) => c.paramKey).join(';');
      final cur = _shown[l.id];
      if (cur != null && cur.paramKey == chainKey && cur.bucket == want) continue;
      // Hiç görüntü yoksa (ya da parametre değiştiyse) önce düşük çözünürlük.
      if (cur == null || cur.paramKey != chainKey) {
        final low = want < layerWidthBuckets.first ? want : layerWidthBuckets.first;
        if (low != want) _load(gen, token, l, chain, chainKey, low);
      }
      _load(gen, token, l, chain, chainKey, want);
    }
  }

  Future<void> _load(int gen, LayerJobToken token, PdfPageLayer l, List<PdfPageLayer> chain, String chainKey, int bucket) async {
    final img = await _hub.renderer.imageFor(widget.page, l, chain, bucket, token: token);
    if (img == null) return;
    final cur = _shown[l.id];
    final ordered = _ordered;
    final idx = ordered.indexWhere((x) => x.id == l.id);
    final stillWanted = !_disposed &&
        mounted &&
        idx >= 0 &&
        layerChainUpTo(ordered, idx).map((c) => c.paramKey).join(';') == chainKey;
    // Daha keskin görüntü varsa onu bozma (geç gelen düşük çözünürlük).
    final worse = cur != null && cur.paramKey == chainKey && cur.bucket > bucket;
    if (!stillWanted || worse) {
      img.dispose();
      return;
    }
    cur?.image.dispose();
    setState(() => _shown[l.id] = _Shown(img, bucket, chainKey));
  }

  @override
  void didUpdateWidget(PdfPageLayerOverlay old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page) _request();
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : widget.pageWidth;
      if (w != _layoutWidth) {
        _layoutWidth = w;
        WidgetsBinding.instance.addPostFrameCallback((_) => _request());
      }
      final original = _hub.showOriginal.value;
      final visible = original ? const <PdfPageLayer>[] : _hub.visibleFor(widget.page);
      return IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _LayerPainter(
              layers: visible,
              images: {for (final e in _shown.entries) e.key: e.value.image},
              pageWidth: widget.pageWidth,
              pageHeight: widget.pageHeight,
              version: Object.hashAll([for (final e in _shown.entries) '${e.key}:${e.value.bucket}:${e.value.paramKey}', for (final l in visible) l.paramKey]),
            ),
          ),
        ),
      );
    });
  }
}

class _LayerPainter extends CustomPainter {
  _LayerPainter({
    required this.layers,
    required this.images,
    required this.pageWidth,
    required this.pageHeight,
    required this.version,
  });
  final List<PdfPageLayer> layers;
  final Map<String, ui.Image> images;
  final double pageWidth;
  final double pageHeight;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / pageWidth, sy = size.height / pageHeight;
    for (final l in layers) {
      final b = l.box;
      final rect = b == null
          ? Offset.zero & size
          : Rect.fromLTRB(b.left * sx, b.top * sy, b.right * sx, b.bottom * sy);
      switch (l.kind) {
        case PdfLayerKind.cover:
          final c = l.cover;
          canvas.drawRect(rect, Paint()..color = Color(c.color).withValues(alpha: c.opacity));
        case PdfLayerKind.watermark:
          final img = images[l.id];
          if (img == null) continue;
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            rect,
            Paint()..filterQuality = FilterQuality.medium,
          );
      }
    }
  }

  @override
  bool shouldRepaint(_LayerPainter o) => o.version != version || o.pageWidth != pageWidth;
}
