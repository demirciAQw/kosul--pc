import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/layer_renderer.dart';
import '../domain/layer_pixels.dart';
import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart' show PdfBox;
import '../domain/watermark.dart';
import 'layer_overlay.dart';

/// Katman ekleme / düzenleme ekranı: canlı önizleme (Önce / Sonra), Güç ve Ton
/// sürgüleri, "Otomatik tespit". Kaydedince katman eklenir (PDF dosyası değişmez).
class PdfLayerEditorPage extends StatefulWidget {
  const PdfLayerEditorPage({
    super.key,
    required this.hub,
    required this.page,
    required this.kind,
    this.box,
    this.allPages = false,
    this.existing,
    this.previewWidth = 900,
  });

  final PdfLayersHub hub;
  final int page;
  final PdfLayerKind kind;

  /// Bölge (PDF birimi); null = tüm sayfa.
  final PdfBox? box;
  final bool allPages;

  /// Düzenlenen katman (kapsamı değişmez).
  final PdfPageLayer? existing;
  final int previewWidth;

  @override
  State<PdfLayerEditorPage> createState() => _PdfLayerEditorPageState();
}

class _PdfLayerEditorPageState extends State<PdfLayerEditorPage> {
  RegionPixels? _raw;
  Uint8List? _base; // altındaki katmanlar uygulanmış
  ui.Image? _before;
  ui.Image? _after;
  String? _error;
  bool _busy = false;
  bool _holdOriginal = false;
  bool _compareSwitch = false;
  bool _saving = false;
  bool _disposed = false;
  int _gen = 0;
  int _loadId = 0;
  Timer? _debounce;
  late int _page = widget.page; // önizlenen sayfa ("Tüm sayfalar"da değiştirilebilir)
  int? _pageCount;

  WatermarkParams _wm = const WatermarkParams();
  CoverParams _cover = const CoverParams(color: 0xFFFFFFFF, opacity: 1);

  static const _swatches = <int>[
    0xFFFFFFFF,
    0xFF000000,
    0xFFFFEB3B,
    0xFFFF9800,
    0xFFF44336,
    0xFF4CAF50,
    0xFF2196F3,
    0xFF9C27B0,
  ];

  PdfPageLayer? get _ex => widget.existing;

  @override
  void initState() {
    super.initState();
    final ex = _ex;
    if (ex != null) {
      _wm = ex.watermark;
      _cover = ex.cover;
    } else if (widget.kind == PdfLayerKind.watermark) {
      // İkinci katman için farklı bir başlangıç tonu; kullanıcı ayarlar ya da otomatik tespit eder.
      final n = widget.hub.listFor(_page).where((l) => l.kind == PdfLayerKind.watermark).length;
      if (n > 0) _wm = const WatermarkParams(tone: 185, toneRange: 25);
    } else {
      _cover = const CoverParams(color: 0xFFFFFFFF, opacity: 1);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _before?.dispose();
    _after?.dispose();
    super.dispose();
  }

  PdfBox? get _box => _ex?.box ?? widget.box;

  /// Düzenlenen/eklenen katmanın ALTINDAKİ görünür katmanlar (önizleme zemini).
  List<PdfPageLayer> _below() {
    final ex = _ex;
    return [
      for (final l in widget.hub.visibleFor(_page))
        if (ex == null || (l.id != ex.id && l.z < ex.z)) l,
    ];
  }

  Future<ui.Image> _decode(Uint8List px, int w, int h, PixelOrder o) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, w, h, o == PixelOrder.bgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// Kapsam birden çok sayfayı kapsıyor mu ("Tüm sayfalar" / "Bölge, tüm sayfalar").
  bool get _multiPage => widget.allPages || (_ex?.isAllPages ?? false);

  Future<void> _load() async {
    final id = ++_loadId;
    setState(() => _busy = true);
    try {
      if (_multiPage && _pageCount == null) {
        try {
          final n = await widget.hub.renderer.pageCount();
          if (!_disposed) setState(() => _pageCount = n);
        } catch (_) {
          // sayfa sayısı bilinmezse uyarı sayısız gösterilir
        }
      }
      final raw = await widget.hub.renderer.renderRaw(_page, box: _box, widthPx: widget.previewWidth);
      final base = await applyLayersInIsolate(raw.bytes, raw.width, raw.height, raw.pxPerUnit, raw.pxPerUnit, _below(),
          originX: raw.box.left, originY: raw.box.top, order: raw.order);
      final before = await _decode(base, raw.width, raw.height, raw.order);
      if (_disposed || id != _loadId) {
        before.dispose();
        return;
      }
      setState(() {
        _raw = raw;
        _base = base;
        _before = before;
      });
      await _recompute();
    } catch (e) {
      if (mounted && id == _loadId) setState(() => _error = 'Sayfa çizilemedi: $e');
    } finally {
      if (mounted && id == _loadId) setState(() => _busy = false);
    }
  }

  /// "Tüm sayfalar" kapsamında başka bir sayfada önizle (kayıt kapsamı değişmez).
  void _previewPage(int n) {
    final max = (_pageCount ?? n + 1) - 1;
    final target = n.clamp(0, max < 0 ? 0 : max);
    if (target == _page) return;
    setState(() {
      _page = target;
      _error = null;
    });
    unawaited(_load());
  }

  Future<void> _askPage() async {
    final ctrl = TextEditingController(text: '${_page + 1}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Başka sayfada önizle'),
        content: TextField(
          key: const Key('layer-preview-page-field'),
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(helperText: _pageCount == null ? null : '1 ile $_pageCount arası'),
          onSubmitted: (t) => Navigator.pop(ctx, int.tryParse(t.trim())),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            key: const Key('layer-preview-page-ok'),
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: const Text('Göster'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (v != null && mounted) _previewPage(v - 1);
  }

  Widget _multiPageBar(BuildContext context) {
    final n = _pageCount;
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('layer-all-warning'),
      color: cs.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: cs.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${n == null ? 'Tüm' : '$n'} sayfada uygulanır; önizleme yalnız bu sayfada. '
              'Harita/grafik sayfalarını kontrol et.',
              style: TextStyle(color: cs.onSecondaryContainer, fontSize: 12.5),
            ),
          ),
          IconButton(
            key: const Key('layer-preview-prev'),
            tooltip: 'Önceki sayfa',
            visualDensity: VisualDensity.compact,
            onPressed: _page > 0 ? () => _previewPage(_page - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text('${_page + 1}${n == null ? '' : ' / $n'}', key: const Key('layer-preview-page')),
          IconButton(
            key: const Key('layer-preview-next'),
            tooltip: 'Sonraki sayfa',
            visualDensity: VisualDensity.compact,
            onPressed: n == null || _page + 1 < n ? () => _previewPage(_page + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
          TextButton(key: const Key('layer-preview-other'), onPressed: _askPage, child: const Text('Başka sayfada önizle')),
        ],
      ),
    );
  }

  PdfPageLayer _candidate() => PdfPageLayer(
        id: 'onizleme',
        documentId: widget.hub.documentId,
        page: _page,
        kind: widget.kind,
        // Önizleme zaten bölgeye kırpılmış: kutu verilmez (tüm piksel).
        params: widget.kind == PdfLayerKind.watermark ? _wm.toJson() : _cover.toJson(),
      );

  Future<void> _recompute() async {
    final raw = _raw, base = _base;
    if (raw == null || base == null) return;
    final gen = ++_gen;
    final out = await applyLayersInIsolate(base, raw.width, raw.height, raw.pxPerUnit, raw.pxPerUnit, [_candidate()],
        originX: raw.box.left, originY: raw.box.top, order: raw.order);
    if (_disposed || gen != _gen) return;
    final img = await _decode(out, raw.width, raw.height, raw.order);
    if (_disposed || gen != _gen) {
      img.dispose();
      return;
    }
    final old = _after;
    setState(() => _after = img);
    old?.dispose();
  }

  void _changed() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _recompute);
  }

  Future<void> _auto() async {
    final raw = _base;
    if (raw == null || _raw == null) return;
    final r = _raw!;
    final p = await detectWatermarkInIsolate(raw, r.width, r.height, order: r.order);
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Belirgin bir filigran bulunamadı. Sürgülerle elle ayarla.')));
      return;
    }
    _wm = p.copyWith(strength: _wm.strength == 0 ? 1 : _wm.strength);
    _changed();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = widget.hub.repository;
      final params = widget.kind == PdfLayerKind.watermark ? _wm.toJson() : _cover.toJson();
      final ex = _ex;
      if (ex != null) {
        await repo.updateParams(ex.id, params);
      } else {
        await repo.add(
          documentId: widget.hub.documentId,
          page: widget.allPages ? allPdfPages : widget.page,
          kind: widget.kind,
          box: widget.box,
          params: params,
          name: widget.kind.label,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wm = widget.kind == PdfLayerKind.watermark;
    final showBefore = _holdOriginal || _compareSwitch;
    final img = showBefore ? _before : (_after ?? _before);
    return Scaffold(
      appBar: AppBar(
        title: Text(_ex == null ? (wm ? 'Filigranı temizle' : 'Örtü ekle') : 'Katmanı düzenle'),
        actions: [
          TextButton(
            key: const Key('layer-save'),
            onPressed: _raw == null || _saving ? null : _save,
            child: const Text('Kaydet'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_multiPage) _multiPageBar(context),
          Expanded(
            child: Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: _error != null
                  ? Center(child: Text(_error!))
                  : img == null
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(
                          children: [
                            Positioned.fill(
                              child: InteractiveViewer(
                                maxScale: 6,
                                child: Center(
                                  child: ColoredBox(
                                    color: Colors.white,
                                    child: RawImage(
                                      key: Key(showBefore ? 'layer-preview-before' : 'layer-preview-after'),
                                      image: img,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.medium,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 12,
                              top: 12,
                              child: Chip(label: Text(showBefore ? 'Önce' : 'Sonra')),
                            ),
                            if (_busy) const Positioned(right: 12, top: 12, child: CircularProgressIndicator()),
                          ],
                        ),
            ),
          ),
          Material(
            elevation: 4,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Listener(
                            onPointerDown: (_) => setState(() => _holdOriginal = true),
                            onPointerUp: (_) => setState(() => _holdOriginal = false),
                            onPointerCancel: (_) => setState(() => _holdOriginal = false),
                            child: OutlinedButton.icon(
                              key: const Key('layer-hold-original'),
                              onPressed: () {},
                              icon: const Icon(Icons.compare),
                              label: const Text('Basılı tut: Önce'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text('Önce'),
                          Switch(
                            key: const Key('layer-compare-switch'),
                            value: _compareSwitch,
                            onChanged: (v) => setState(() => _compareSwitch = v),
                          ),
                          const Spacer(),
                          if (wm)
                            FilledButton.tonalIcon(
                              key: const Key('layer-auto'),
                              onPressed: _base == null ? null : _auto,
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text('Otomatik tespit'),
                            ),
                        ],
                      ),
                      if (wm) ...[
                        _slider('Güç', 'wm-strength', _wm.strength, 0, 1, (v) {
                          _wm = _wm.copyWith(strength: v);
                          _changed();
                        }, '${(_wm.strength * 100).round()}%'),
                        _slider('Ton', 'wm-tone', _wm.tone, WatermarkParams.minTone, 250, (v) {
                          _wm = _wm.copyWith(tone: v);
                          _changed();
                        }, '${_wm.tone.round()}'),
                        _slider('Ton aralığı', 'wm-range', _wm.toneRange, 0, 80, (v) {
                          _wm = _wm.copyWith(toneRange: v);
                          _changed();
                        }, '±${_wm.toneRange.round()}'),
                        if (_wm.hue != null)
                          _slider('Renk aralığı', 'wm-hue-range', _wm.hueRange, 5, 90, (v) {
                            _wm = _wm.copyWith(hueRange: v);
                            _changed();
                          }, '±${_wm.hueRange.round()}°'),
                      ] else ...[
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final c in _swatches)
                              InkWell(
                                key: Key('cover-color-${c.toRadixString(16)}'),
                                onTap: () {
                                  _cover = CoverParams(color: c, opacity: _cover.opacity);
                                  _changed();
                                },
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Color(c),
                                    border: Border.all(
                                      width: _cover.color == c ? 3 : 1,
                                      color: _cover.color == c ? Theme.of(context).colorScheme.primary : Colors.black38,
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        _slider('Opaklık', 'cover-opacity', _cover.opacity, 0.05, 1, (v) {
                          _cover = CoverParams(color: _cover.color, opacity: v);
                          _changed();
                        }, '${(_cover.opacity * 100).round()}%'),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(String label, String key, double v, double min, double max, ValueChanged<double> on, String text) =>
      Row(
        children: [
          SizedBox(width: 92, child: Text(label)),
          Expanded(child: Slider(key: Key(key), value: v.clamp(min, max), min: min, max: max, onChanged: on)),
          SizedBox(width: 48, child: Text(text, textAlign: TextAlign.end)),
        ],
      );
}
