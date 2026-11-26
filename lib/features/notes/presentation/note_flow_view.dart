import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerDownEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/platform.dart' show isDesktop;
import '../../../app/tablet.dart';
import '../../../core/di/core_providers.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../pdf/pdf_providers.dart';
import '../../pdf/presentation/pdf_ink_input.dart' show PdfInkInput, palmRadiusMajor;
import '../../pdf/presentation/pdf_ink_session.dart';
import '../../pdf/presentation/pdf_page_ink_layer.dart';
import '../data/page_image_picker.dart';
import '../domain/flow_layout.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_board.dart';
import '../domain/page_item_geometry.dart';
import '../domain/page_item_ops.dart';
import '../domain/page_size.dart';
import '../domain/page_template.dart';
import '../notes_providers.dart';
import 'dock_placement.dart';
import 'item_toolbar.dart';
import 'note_page_editor.dart' show NotePageEditor;
import 'note_tool_dock.dart';
import 'note_tool_settings.dart';
import 'page_items_controller.dart';
import 'page_items_layer.dart';
import 'page_template_painter.dart';
import 'tool_rail.dart';

/// Defterin SÜREKLİ DİKEY AKIŞ görünümü: sayfalar alt alta, parmakla kaydırılır, iki
/// parmakla (tüm akış birlikte) yakınlaştırılır, kalem yazdığı sayfaya çizer.
///
/// Tek bir kalem oturumu tüm defteri taşır: oturumdaki "sayfa numarası" sayfanın KALICI
/// dizinidir (kimlik -> dizin, oturum boyunca değişmez; ekleme/silme/sıra değişimi
/// önbelleği bozmaz); çizgi sahibi yine `NotePageOwner(sayfaKimliği, pageNo)`.
/// Yalnız görünen (±1) sayfalar canlı tutulur: kalem katmanı, öğeler, şablon. Uzaktakiler
/// düz kâğıt kutusudur. Sonsuz sayfa akışta tek uzun sayfadır (kendi uzar).
class NoteFlowView extends ConsumerStatefulWidget {
  const NoteFlowView({
    super.key,
    required this.notebookId,
    required this.pages,
    required this.tools,
    required this.initialPageId,
    required this.onVisiblePage,
    required this.onAddPage,
    required this.onGrow,
    required this.onTemplate,
    required this.onTemplateAll,
    required this.onBackground,
    required this.onSpacing,
    this.spacing = 1,
    this.stylusOnlyOverride,
    this.onTranscribe,
    this.onOpenPage,
  });

  final String notebookId;

  /// Gösterilen sayfalar (sıra = akış sırası).
  final List<InkNotePageRecord> pages;
  final NoteToolSettings tools;

  /// İlk açılışta kaydırılacak sayfa.
  final String? initialPageId;

  /// Kaydırmayla görünen sayfa değişti (üst çubuk göstergesi).
  final ValueChanged<String> onVisiblePage;

  /// "Yeni sayfa" kartı / öneri çipi: sona sayfa ekler (ekran ekler, akış oraya kayar).
  final VoidCallback onAddPage;
  final Future<void> Function(String pageId, double newHeight) onGrow;
  final void Function(String pageId, PageTemplate t) onTemplate;
  final ValueChanged<PageTemplate> onTemplateAll;
  final void Function(String pageId, int c) onBackground;
  final double spacing;
  final ValueChanged<double> onSpacing;
  final bool? stylusOnlyOverride;
  final VoidCallback? onTranscribe;
  final ValueChanged<String>? onOpenPage;

  @override
  ConsumerState<NoteFlowView> createState() => NoteFlowViewState();
}

/// Sayfa ekranın dışına çıktığında/eklendiğinde oturumun sayfa dizinini bulmak için.
class NoteFlowViewState extends ConsumerState<NoteFlowView>
    with SingleTickerProviderStateMixin
    implements DockDragHandler {
  late final PdfInkSession session;
  final _transform = TransformationController();
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _errorSub;
  late final AnimationController _scroll = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  final _zoom = ValueNotifier<double>(1);
  final _highRes = ValueNotifier<bool>(false);
  final _itemLock = ValueNotifier<int>(0);
  final _areaKey = GlobalKey();
  final _dockKey = GlobalKey();
  final _dockDrag = ValueNotifier<DockDrag?>(null);
  final _activeItems = ValueNotifier<PageItemsController?>(null);
  Offset _dockGrab = Offset.zero;
  Offset? _doubleTapAt;

  /// Kimlik -> oturum dizini (kalıcı) ve bilinen kayıtlar (sayfa silinse de sahip bulunur).
  final Map<String, int> _idx = {};
  final Map<int, String> _idOf = {};
  final Map<String, InkNotePageRecord> _known = {};
  final Map<String, _FlowPageState> _live = {};

  late FlowLayout _layout;
  double _areaW = 0, _areaH = 0;
  int _first = 0, _last = 0;
  String? _current;
  bool _suggest = false;
  Timer? _suggestTimer;
  Matrix4? _zoomBack;
  VoidCallback? _scrollTick;

  /// Şablon/arka plan seçimi veritabanı akışını beklemeden hemen görünür.
  final Map<String, PageTemplate> _tplLocal = {};
  final Map<String, int> _bgLocal = {};

  List<InkNotePageRecord> get pages => widget.pages;

  @override
  void initState() {
    super.initState();
    _syncPages();
    session = PdfInkSession(
      documentId: widget.notebookId,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
      attemptNo: 0,
      ownerOf: (i) {
        final r = _known[_idOf[i]];
        // Bilinmeyen dizin olmamalı; olursa ilk bilinen sayfaya yazılmaz, boş sahiple düşer.
        return NotePageOwner(r?.id ?? '', r?.pageNo ?? 0);
      },
      penKinds: true,
    );
    _transform.addListener(_transformChanged);
    session.zoomInteraction.zoomOf = () => _transform.value.getMaxScaleOnAxis();
    // Geriye dönük avuç reddi: avuç kalemden önce değip akışı oynattıysa geri al.
    session.readViewMatrix = () => _transform.value.clone();
    session.writeViewMatrix = (m) => _transform.value = (m as Matrix4).clone();
    widget.tools.apply(session);
    widget.tools.addListener(_applyTools);
    _errorSub = session.errors.listen((m) => _toast(m));
    _lifecycle = AppLifecycleListener(onInactive: flush, onHide: flush, onPause: flush);
    final want = widget.initialPageId;
    _current = pages.any((p) => p.id == want) ? want : pages.firstOrNull?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _current;
      if (c != null) scrollToPage(c, animate: false);
    });
  }

  /// Sayfa listesinden dizin/bilinen kayıtlar ve yerleşim.
  void _syncPages() {
    for (final p in pages) {
      _known[p.id] = p;
      final i = _idx.putIfAbsent(p.id, () => _idx.length);
      _idOf[i] = p.id;
    }
    _layout = FlowLayout(
      [for (final p in pages) (w: p.width, h: p.height)],
      width: _areaW > 0 ? _areaW : 1000,
    );
  }

  int indexOfPage(String id) => _idx[id] ?? -1;

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _applyTools() {
    widget.tools.apply(session);
    if (mounted) setState(() {}); // yuva konumu
    if (widget.tools.itemTool == ItemTool.none) return;
    for (final p in _live.values) {
      final c = p.items;
      if (c.editingId != null && widget.tools.itemTool != ItemTool.text) unawaited(c.stopEditing());
    }
  }

  @override
  void didUpdateWidget(NoteFlowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tools != widget.tools) {
      oldWidget.tools.removeListener(_applyTools);
      widget.tools.addListener(_applyTools);
      _applyTools();
    }
    final grew = widget.pages.length > oldWidget.pages.length;
    _syncPages();
    if (widget.pages.length != oldWidget.pages.length) _hideSuggest();
    for (final p in pages) {
      if (_tplLocal[p.id] == p.template) _tplLocal.remove(p.id);
      if (_bgLocal[p.id] == p.background) _bgLocal.remove(p.id);
    }
    if (grew) WidgetsBinding.instance.addPostFrameCallback((_) => _transformChanged());
  }

  @override
  void dispose() {
    _suggestTimer?.cancel();
    widget.tools.removeListener(_applyTools);
    _transform.removeListener(_transformChanged);
    _scroll.dispose();
    _lifecycle.dispose();
    _errorSub?.cancel();
    _transform.dispose();
    _zoom.dispose();
    _highRes.dispose();
    _itemLock.dispose();
    _dockDrag.dispose();
    _activeItems.dispose();
    unawaited(session.flush().whenComplete(session.dispose));
    super.dispose();
  }

  /// Bekleyen kayıtların bitmesini bekler (sayfa çoğaltma/silme/geçiş, kapanış).
  Future<void> flush() async {
    for (final p in _live.values.toList()) {
      await p.items.flush();
    }
    await session.flush();
  }

  // ───────────── görünüm: kaydırma, görünen sayfa, canlı aralık ─────────────

  /// Görünür içerik dikdörtgeni (içerik koordinatı).
  ui.Rect _visibleContent() {
    final m = _transform.value;
    final z = m.getMaxScaleOnAxis();
    if (z <= 0) return ui.Rect.zero;
    final t = m.getTranslation();
    return ui.Rect.fromLTWH(-t.x / z, -t.y / z, _areaW / z, _areaH / z);
  }

  void _transformChanged() {
    if (!mounted) return;
    final z = _transform.value.getMaxScaleOnAxis();
    if (_zoom.value != z) _zoom.value = z;
    final hi = z > 1.8;
    if (_highRes.value != hi) _highRes.value = hi;
    session.zoomInteraction.pulse(); // zum/kaydırma: çizgiler hafif çizilir
    if (_layout.count == 0) return;
    final v = _visibleContent();
    final r = _layout.visibleRange(v.top, v.bottom);
    // Görünen sayfa: ekranın üst üçte birindeki nokta.
    final cur = pages[_layout.indexAt(v.top + v.height * 0.33)].id;
    widget.tools.pastePage = _idx[cur] ?? 0;
    if (cur != _current) {
      _current = cur;
      widget.onVisiblePage(cur);
    }
    if (r.first != _first || r.last != _last) {
      setState(() {
        _first = r.first;
        _last = r.last;
      });
    }
  }

  /// [id] sayfasının üstüne kayar (zum korunur). Sayfa yoksa bir şey yapmaz.
  void scrollToPage(String id, {bool animate = true}) {
    final i = pages.indexWhere((p) => p.id == id);
    if (i < 0 || _areaH <= 0) return;
    final z = _transform.value.getMaxScaleOnAxis();
    final t = _transform.value.getTranslation();
    final toY = -(_layout.tops[i] - 8 / z) * z;
    Matrix4 at(double y) => Matrix4.identity()
      ..translateByDouble(t.x, y, 0, 1)
      ..scaleByDouble(z, z, z, 1);
    _scroll.stop();
    if (!animate) {
      _transform.value = at(toY);
      return;
    }
    final fromY = t.y;
    final old = _scrollTick;
    if (old != null) _scroll.removeListener(old);
    void tick() => _transform.value = at(fromY + (toY - fromY) * Curves.easeOutCubic.transform(_scroll.value));
    _scrollTick = tick;
    _scroll
      ..reset()
      ..addListener(tick)
      ..forward();
  }

  bool get _isFit => _transform.value.getMaxScaleOnAxis() == 1 && _transform.value.getTranslation().x == 0;

  /// Genişliğe sığdır: zum 1, görünen sayfanın üstüne.
  void fitToWidth() {
    if (!_isFit) _zoomBack = _transform.value.clone();
    final c = _current;
    _transform.value = Matrix4.identity();
    if (c != null) scrollToPage(c, animate: false);
  }

  void toggleFit() {
    if (_isFit) {
      final b = _zoomBack;
      if (b != null) _transform.value = b;
    } else {
      fitToWidth();
    }
  }

  // ───────────── yeni sayfa önerisi ─────────────

  void _suggestNewPage() {
    if (_suggest) return;
    setState(() => _suggest = true);
    _suggestTimer?.cancel();
    _suggestTimer = Timer(const Duration(seconds: 10), _hideSuggest);
  }

  void _hideSuggest() {
    _suggestTimer?.cancel();
    if (mounted && _suggest) setState(() => _suggest = false);
  }

  // ───────────── çift dokunuş, avuç ─────────────

  void _onDoubleTap() {
    final at = _doubleTapAt;
    if (at != null) {
      for (final p in _live.values) {
        final pt = p.toPage(at);
        if (pt == null) continue;
        final hit = hitTestItems(p.items.items, pt.dx, pt.dy);
        if (hit != null) {
          p.items.select(hit.id);
          if (hit.kind == PageItemKind.text) p.items.startEditing(hit.id);
          return;
        }
      }
    }
    toggleFit();
  }

  bool _isPalm(PointerDownEvent e) =>
      session.penActive || e.radiusMajor >= palmRadiusMajor || session.isPalmNearPen(e.position);

  // ───────────── fotoğraf (görünen sayfaya) ─────────────

  static const _maxImageBytes = 60 * 1024 * 1024;

  Future<void> addPhoto() async {
    final src = await showModalBottomSheet<PageImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('note-photo-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeri'),
              onTap: () => Navigator.pop(ctx, PageImageSource.gallery),
            ),
            ListTile(
              key: const Key('note-photo-file'),
              leading: const Icon(Icons.folder_open),
              title: const Text('Dosya'),
              onTap: () => Navigator.pop(ctx, PageImageSource.file),
            ),
            if (!isDesktop)
              ListTile(
                key: const Key('note-photo-camera'),
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Kamera'),
                onTap: () => Navigator.pop(ctx, PageImageSource.camera),
              ),
          ],
        ),
      ),
    );
    if (src == null || !mounted) return;
    await addPhotoFrom(src);
  }

  Future<void> addPhotoFrom(PageImageSource src) async {
    // Hedef sayfa, seçici açılmadan önceki görünen sayfa.
    final target = _current;
    PickedPageImage? picked;
    try {
      picked = await ref.read(pageImagePickerProvider).pick(src);
    } catch (e) {
      _toast('Görsel alınamadı: $e');
      return;
    }
    if (picked == null || !mounted) return;
    try {
      final len = await File(picked.path).length();
      if (len > _maxImageBytes) {
        _toast('Görsel çok büyük (en çok 60 MB).');
        return;
      }
      final stored = await ref.read(pageImageStoreProvider).saveFile(picked.path);
      if (!mounted) return;
      final ps = target == null ? null : _live[target];
      if (ps == null) {
        _toast('Görsel kaydedildi ama sayfa görünmüyor; yeniden dene.');
        return;
      }
      final page = ps.widget.page;
      final v = _visiblePageRect(page.id);
      final base = defaultImageRect(stored.pxW, stored.pxH, page.width, page.height);
      final rect = placeInVisible(base.w, base.h, v.left, v.top, v.width, v.height, page.width, page.height);
      await ps.items.addImage(stored.path, rect, ImageItemPayload(pxW: stored.pxW, pxH: stored.pxH));
    } on FileSystemException {
      _toast('Görsel okunamadı ya da bozuk.');
    } catch (e) {
      _toast('Görsel eklenemedi: ${e is StateError ? e.message : e}');
    } finally {
      if (picked.temp) {
        try {
          await ref.read(mediaStorageProvider).discardTemp(picked.path);
        } catch (_) {}
      }
    }
  }

  /// Görünür alanın [id] sayfasındaki dikdörtgeni (not birimi); kesişmiyorsa tüm sayfa.
  Rect _visiblePageRect(String id) {
    final i = pages.indexWhere((p) => p.id == id);
    if (i < 0) return Rect.zero;
    final p = pages[i];
    final all = Rect.fromLTWH(0, 0, p.width, p.height);
    if (_areaW <= 0) return Rect.fromLTWH(0, 0, p.width, math.min(p.height, p.width * 1.4));
    final k = p.width / _areaW;
    final v = _visibleContent().shift(Offset(0, -_layout.tops[i]));
    final r = Rect.fromLTRB(v.left * k, v.top * k, v.right * k, v.bottom * k).intersect(all);
    return r.isEmpty ? all : r;
  }

  // ───────────── yuva sürükleme (serbest konum) ─────────────

  Offset? _areaLocal(Offset global) {
    final b = _areaKey.currentContext?.findRenderObject();
    if (b is! RenderBox || !b.attached) return null;
    return b.globalToLocal(global);
  }

  @override
  void start(Offset global) {
    final dock = _dockKey.currentContext?.findRenderObject();
    final p = _areaLocal(global);
    if (dock is! RenderBox || p == null) return;
    final topLeft = _areaLocal(dock.localToGlobal(Offset.zero)) ?? p;
    _dockGrab = p - topLeft;
    _dockDrag.value = DockDrag(p, _dockGrab);
  }

  @override
  void update(Offset global) {
    final p = _areaLocal(global);
    if (p == null || _dockDrag.value == null) return;
    _dockDrag.value = DockDrag(p, _dockGrab);
  }

  @override
  void end(Offset global) {
    final dock = _dockKey.currentContext?.findRenderObject();
    final area = _areaKey.currentContext?.findRenderObject();
    final d = _dockDrag.value;
    _dockDrag.value = null;
    if (d == null || dock is! RenderBox || area is! RenderBox) return;
    final pad = MediaQuery.paddingOf(context);
    final inset = EdgeInsets.fromLTRB(10 + pad.left, 10 + pad.top, 10 + pad.right, 10 + pad.bottom);
    final t = dockTravel(area.size, dock.size, inset);
    final tl = Offset(d.topLeft.dx.clamp(t.minX, t.maxX).toDouble(), d.topLeft.dy.clamp(t.minY, t.maxY).toDouble());
    final snap = snapEdgeFor(tl & dock.size, area.size);
    if (snap != null) {
      widget.tools.setDockPosition(snap);
    } else {
      final f = freeDockFraction(tl, area.size, dock.size, inset);
      widget.tools.setDockFree(f.fx, f.fy);
    }
  }

  @override
  void cancel() => _dockDrag.value = null;

  // ───────────── yapı ─────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final focus = TabletFocus.maybeOf(context)?.value ?? false;
    final pos = widget.tools.dockPosition;
    final pad = MediaQuery.paddingOf(context);
    final cur = pages.where((p) => p.id == _current).firstOrNull ?? pages.firstOrNull;
    final template = cur == null ? PageTemplate.plain : (_tplLocal[cur.id] ?? cur.template);
    final background = cur == null ? 0xFFFFFFFF : (_bgLocal[cur.id] ?? cur.background);
    final styleControl = PageStyleControl(
                    template: template,
                    background: background,
                    spacing: widget.spacing,
                    onTemplate: (t) {
                      final id = cur?.id;
                      if (id == null) return;
                      setState(() => _tplLocal[id] = t);
                      widget.onTemplate(id, t);
                    },
                    onTemplateAll: (t) {
                      final id = cur?.id;
                      if (id != null) setState(() => _tplLocal[id] = t);
                      widget.onTemplateAll(t);
                    },
                    onBackground: (c) {
                      final id = cur?.id;
                      if (id == null) return;
                      setState(() => _bgLocal[id] = c);
                      widget.onBackground(id, c);
                    },
                    onSpacing: widget.onSpacing,
                    onTranscribe: widget.onTranscribe,
                  );
    return ColoredBox(
      color: cs.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth.isFinite ? box.maxWidth : 1000.0;
          if (w != _areaW || box.maxHeight != _areaH) {
            _areaW = w;
            _areaH = box.maxHeight.isFinite ? box.maxHeight : 800;
            _syncPages();
          }
          if (_layout.count > 0) {
            final v = _visibleContent();
            final r = _layout.visibleRange(v.top, v.bottom);
            _first = r.first;
            _last = r.last;
          }
          return Stack(
            key: _areaKey,
            children: [
              GestureDetector(
                supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.mouse},
                onDoubleTapDown: (d) => _doubleTapAt = d.globalPosition,
                onDoubleTap: _onDoubleTap,
                child: PdfInkInput(
                  session: session,
                  stylusOnlyOverride: widget.stylusOnlyOverride,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: session.viewerLocked,
                    builder: (context, locked, _) => ValueListenableBuilder<int>(
                      valueListenable: _itemLock,
                      builder: (context, itemLock, _) => InteractiveViewer(
                        transformationController: _transform,
                        panEnabled: !locked && itemLock == 0,
                        scaleEnabled: !locked && itemLock == 0,
                        constrained: false,
                        // Yatayda sayfa genişliğe oturur (zum 1'de kayma yok); dikeyde uçlarda pay.
                        boundaryMargin: const EdgeInsets.fromLTRB(0, 40, 0, 240),
                        minScale: 1,
                        maxScale: NotePageEditor.maxZoom,
                        onInteractionStart: (_) => session.zoomInteraction.begin(),
                        onInteractionEnd: (_) => session.zoomInteraction.end(),
                        child: SizedBox(
                          key: const Key('note-flow-content'),
                          width: w,
                          height: _layout.total,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // Uzaktaki sayfalar: yalnız düz kâğıt (canlı katman yok).
                              for (var i = 0; i < pages.length; i++)
                                if (i < _first || i > _last)
                                  Positioned(
                                    key: ValueKey('far-${pages[i].id}'),
                                    left: 0,
                                    top: _layout.tops[i],
                                    width: w,
                                    height: _layout.heights[i],
                                    child: ColoredBox(color: Color(_bgLocal[pages[i].id] ?? pages[i].background)),
                                  ),
                              for (var i = _first; i <= _last && i < pages.length; i++)
                                Positioned(
                                  key: ValueKey('page-${pages[i].id}'),
                                  left: 0,
                                  top: _layout.tops[i],
                                  width: w,
                                  height: _layout.heights[i],
                                  child: _FlowPage(
                                    key: ValueKey(pages[i].id),
                                    owner: this,
                                    page: pages[i],
                                    index: _idx[pages[i].id]!,
                                    top: _layout.tops[i],
                                    width: w,
                                    isLast: i == pages.length - 1,
                                  ),
                                ),
                              Positioned(
                                left: 0,
                                right: 0,
                                top: _layout.endTop,
                                height: _layout.endHeight,
                                child: Center(
                                  child: FilledButton.tonalIcon(
                                    key: const Key('note-flow-add'),
                                    onPressed: widget.onAddPage,
                                    icon: const Icon(Icons.add),
                                    label: const Text('Yeni sayfa'),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: pos == DockPosition.right ? null : 8 + pad.right,
                left: pos == DockPosition.right ? 8 + pad.left : null,
                top: pos == DockPosition.top ? null : 8,
                bottom: pos == DockPosition.top ? 8 + pad.bottom : null,
                child: Material(
                  color: cs.surface.withValues(alpha: 0.9),
                  elevation: 2,
                  borderRadius: BorderRadius.circular(20),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 12),
                      ValueListenableBuilder<Matrix4>(
                        valueListenable: _transform,
                        builder: (_, m, _) =>
                            Text(NotePageEditor.zoomLabel(m.getMaxScaleOnAxis()), key: const Key('note-zoom-label')),
                      ),
                      IconButton(
                        key: const Key('note-zoom-fit'),
                        tooltip: 'Sayfaya sığdır',
                        icon: const Icon(Icons.fit_screen),
                        onPressed: fitToWidth,
                      ),
                    ],
                  ),
                ),
              ),
              if (_suggest)
                Positioned(
                  top: 52,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ActionChip(
                      key: const Key('note-flow-suggest'),
                      avatar: const Icon(Icons.note_add_outlined, size: 18),
                      label: const Text('Yeni sayfa ekle'),
                      onPressed: () {
                        _hideSuggest();
                        widget.onAddPage();
                      },
                    ),
                  ),
                ),
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Center(
                  child: ValueListenableBuilder<PageItemsController?>(
                    valueListenable: _activeItems,
                    builder: (context, c, _) => c == null
                        ? const SizedBox.shrink()
                        : ItemToolbar(
                            controller: c,
                            onDeleted: (id) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  SnackBar(
                                    content: const Text('Silindi.'),
                                    action: SnackBarAction(
                                      key: const Key('note-item-undo-delete'),
                                      label: 'Geri al',
                                      onPressed: () => c.restore(id),
                                    ),
                                  ),
                                );
                            },
                          ),
                  ),
                ),
              ),
              if (widget.tools.rail)
                ToolRail(
                  tools: widget.tools,
                  session: session,
                  small: focus,
                  itemTools: true,
                  onPhoto: addPhoto,
                  page: styleControl,
                )
              else
              DockPlacement(
                tools: widget.tools,
                drag: _dockDrag,
                child: NoteToolDock(
                  key: _dockKey,
                  tools: widget.tools,
                  session: session,
                  small: focus,
                  dockDrag: this,
                  itemTools: true,
                  onPhoto: addPhoto,
                  page: styleControl,
                ),
              ),
              ValueListenableBuilder<DockDrag?>(
                valueListenable: _dockDrag,
                builder: (context, d, _) {
                  final dock = _dockKey.currentContext?.findRenderObject();
                  if (d == null || dock is! RenderBox || !dock.hasSize) return const SizedBox.shrink();
                  final edge = snapEdgeFor(d.topLeft & dock.size, box.biggest);
                  return edge == null ? const SizedBox.shrink() : DockSnapPreview(edge: edge);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Sayfanın ekran dönüşümüne göre kaydırılmış görünümü: şablon çizicisi sayfayı içerik
/// kökünde sanır; akışta sayfa [top] kadar aşağıdadır.
class _PageViewTransform extends ChangeNotifier implements ValueListenable<Matrix4> {
  _PageViewTransform(this.base, this.top) {
    base.addListener(notifyListeners);
  }
  final TransformationController base;
  double top;

  @override
  Matrix4 get value => base.value.clone()..translateByDouble(0, top, 0, 1);

  @override
  void dispose() {
    base.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Akıştaki canlı bir sayfa: kâğıt, öğeler, kalem katmanı, öğe katmanı.
class _FlowPage extends ConsumerStatefulWidget {
  const _FlowPage({
    super.key,
    required this.owner,
    required this.page,
    required this.index,
    required this.top,
    required this.width,
    required this.isLast,
  });
  final NoteFlowViewState owner;
  final InkNotePageRecord page;
  final int index;
  final double top;
  final double width;
  final bool isLast;

  @override
  ConsumerState<_FlowPage> createState() => _FlowPageState();
}

class _FlowPageState extends ConsumerState<_FlowPage> {
  late final PageItemsController items;
  final _pageKey = GlobalKey();
  late final _PageViewTransform _view = _PageViewTransform(widget.owner._transform, widget.top);
  PagePen? _pen;
  int _lastCount = 0;

  NoteFlowViewState get o => widget.owner;

  @override
  void initState() {
    super.initState();
    final p = widget.page;
    items = PageItemsController(
      repo: ref.read(inkPageItemRepositoryProvider),
      pageId: p.id,
      pageW: p.width,
      pageH: p.height,
      onError: o._toast,
    )..addListener(_itemsChanged);
    o._live[p.id] = this;
    ref.listenManual(pageItemsProvider(p.id), (_, n) {
      final v = n.value;
      if (v != null) items.sync(v);
    }, fireImmediately: true);
    if (widget.isLast) _watchPen();
  }

  /// Son sayfada: yeni çizgi alt %15'e girince "yeni sayfa" önerilir (sonsuz sayfada değil).
  void _watchPen() {
    final pen = o.session.penFor(widget.index);
    _pen = pen..addListener(_penChanged);
    _lastCount = pen.strokes.length;
  }

  void _penChanged() {
    final pen = _pen;
    if (pen == null || pen.isDisposed || !widget.isLast || isInfinitePage(widget.page.height)) return;
    final n = pen.strokes.length;
    final grew = n > _lastCount;
    _lastCount = n;
    if (!grew) return;
    final s = pen.strokes.last;
    // Yalnız yeni çizilen (henüz kaydı bitmemiş) çizgi: yüklemeden gelenler öneri açmaz.
    if (s.id != null || s.points.isEmpty) return;
    if (flowNearEnd(s.bounds.bottom, widget.page.height)) o._suggestNewPage();
  }

  void _itemsChanged() {
    if (items.selectedId != null) {
      o._activeItems.value = items;
    } else if (o._activeItems.value == items) {
      o._activeItems.value = null;
    }
  }

  @override
  void didUpdateWidget(_FlowPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _view.top = widget.top;
    items.pageW = widget.page.width;
    items.pageH = widget.page.height;
    if (oldWidget.isLast != widget.isLast) {
      _pen?.removeListener(_penChanged);
      _pen = null;
      if (widget.isLast) _watchPen();
    }
  }

  @override
  void dispose() {
    try {
      _pen?.removeListener(_penChanged);
    } catch (_) {}
    if (o._live[widget.page.id] == this) o._live.remove(widget.page.id);
    final active = o._activeItems;
    items.removeListener(_itemsChanged);
    if (active.value == items) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (o.mounted && active.value == items) active.value = null;
      });
    }
    _view.dispose();
    items.dispose();
    super.dispose();
  }

  /// Ekran noktasını bu sayfanın not koordinatına çevirir; sayfa dışındaysa null.
  Offset? toPage(Offset global) {
    final box = _pageKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.width <= 0) return null;
    final l = box.globalToLocal(global);
    if (!(Offset.zero & box.size).contains(l)) return null;
    final k = widget.page.width / box.size.width;
    return Offset(l.dx * k, l.dy * k);
  }

  Future<void> _tapEmpty(double x, double y) async {
    final tool = o.widget.tools.itemTool;
    if (tool == ItemTool.text) {
      final dark = Color(widget.page.background).computeLuminance() < 0.35;
      await items.createText(x, y, color: dark ? 0xFFFFFFFF : 0xFF000000);
    } else if (tool == ItemTool.child) {
      await _createChild(x, y);
    }
  }

  Future<void> _createChild(double x, double y) async {
    final page = widget.page;
    final cx = x.clamp(0.0, page.width).toDouble(), cy = y.clamp(0.0, page.height).toDouble();
    try {
      await o.flush(); // bekleyen çizgiler ebeveynde kayıtlı kalsın
      final id = await ref.read(inkBoardRepositoryProvider).createChildPage(page.id, cx, cy);
      if (!mounted) return;
      final tools = o.widget.tools;
      tools.setKind(tools.lastPenKind); // tek seferlik: kaleme dön
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Alt sayfa oluşturuldu.'),
            action: SnackBarAction(label: 'Aç', onPressed: () => o.widget.onOpenPage?.call(id)),
          ),
        );
    } catch (e) {
      o._toast('Alt sayfa oluşturulamadı: ${e is StateError ? e.message : e}');
    }
  }

  List<ChildNodeData> _nodes(List<PageLinkRecord> links, List<InkNotePageRecord> pages) {
    final byId = {for (final p in pages) p.id: p};
    return [
      for (final l in links)
        if (l.fromPageId == widget.page.id &&
            l.kind == PageLinkKind.child &&
            l.fromX != null &&
            l.fromY != null &&
            byId.containsKey(l.toPageId))
          ChildNodeData(
            linkId: l.id,
            pageId: l.toPageId,
            title: (byId[l.toPageId]!.title ?? '').trim().isEmpty ? 'Alt sayfa' : byId[l.toPageId]!.title!.trim(),
            x: l.fromX!,
            y: l.fromY!,
          ),
    ];
  }

  Future<void> _moveNode(ChildNodeData n, double x, double y) async {
    try {
      await ref.read(inkBoardRepositoryProvider).setLinkAnchor(n.linkId, x, y);
    } catch (e) {
      o._toast('Düğüm taşınamadı: ${e is StateError ? e.message : e}');
    }
  }

  Future<void> _nodeMenu(ChildNodeData n, Offset global) async {
    final size = MediaQuery.sizeOf(context);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(global.dx, global.dy, size.width - global.dx, size.height - global.dy),
      items: const [
        PopupMenuItem(value: 'open', key: Key('note-node-open'), child: Text('Aç')),
        PopupMenuItem(value: 'rename', key: Key('note-node-rename'), child: Text('Yeniden adlandır')),
        PopupMenuItem(value: 'delete', key: Key('note-node-delete'), child: Text('Sil')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'open':
        o.widget.onOpenPage?.call(n.pageId);
      case 'rename':
        await _renameNode(n);
      case 'delete':
        await _deleteNode(n);
    }
  }

  Future<void> _renameNode(ChildNodeData n) async {
    final c = TextEditingController(text: n.title == 'Alt sayfa' ? '' : n.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alt sayfanın adı'),
        content: TextField(
          key: const Key('note-node-name-field'),
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Alt sayfa'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            key: const Key('note-node-name-ok'),
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name == null || !mounted) return;
    try {
      await ref.read(inkNotebookRepositoryProvider).setPageTitle(n.pageId, name);
    } catch (e) {
      o._toast('Ad kaydedilemedi: ${e is StateError ? e.message : e}');
    }
  }

  /// Düğümü siler: bağlantı yumuşak silinir; alt sayfa yalnız kullanıcı isterse (onaylı) silinir.
  Future<void> _deleteNode(ChildNodeData n) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alt sayfa düğümü silinsin mi?'),
        content: Text(
          '"${n.title}" sayfasını da silmek ister misin? Sayfayı silmezsen yalnız bu düğüm kalkar; sayfa defterde durur.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          TextButton(
            key: const Key('note-node-delete-link'),
            onPressed: () => Navigator.pop(ctx, 'link'),
            child: const Text('Yalnız düğümü sil'),
          ),
          FilledButton(
            key: const Key('note-node-delete-page'),
            onPressed: () => Navigator.pop(ctx, 'page'),
            child: const Text('Alt sayfayı da sil'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final board = ref.read(inkBoardRepositoryProvider);
    final nb = ref.read(inkNotebookRepositoryProvider);
    try {
      await board.deleteLink(n.linkId);
      if (choice == 'page') {
        try {
          await nb.deletePage(n.pageId);
        } catch (e) {
          await board.restoreLink(n.linkId); // yarım kalmasın
          rethrow;
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(choice == 'page' ? 'Alt sayfa silindi.' : 'Düğüm silindi.'),
            action: SnackBarAction(
              label: 'Geri al',
              onPressed: () async {
                try {
                  if (choice == 'page') await nb.restorePage(n.pageId);
                  await board.restoreLink(n.linkId);
                } catch (_) {}
              },
            ),
          ),
        );
    } catch (e) {
      o._toast('Silinemedi: ${e is StateError ? e.message : e}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final w = widget.width;
    final k = w / page.width;
    final links = ref.watch(boardLinksProvider(page.notebookId)).value ?? const <PageLinkRecord>[];
    final all = ref.watch(inkNotebookPagesProvider(page.notebookId)).value ?? const <InkNotePageRecord>[];
    final nodes = _nodes(links, all);
    final tools = o.widget.tools;
    final template = o._tplLocal[page.id] ?? page.template;
    final background = o._bgLocal[page.id] ?? page.background;
    return SizedBox(
      key: _pageKey,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                key: const Key('note-page-paper'),
                painter: PageTemplatePainter(
                  template: template,
                  background: background,
                  pageWidth: page.width,
                  pageHeight: page.height,
                  spacingFactor: o.widget.spacing,
                  viewTransform: _view,
                  viewSize: Size(o._areaW, o._areaH),
                ),
              ),
            ),
            // Metin ve görseller çizgilerin ALTINDA (üstüne yazılır).
            ValueListenableBuilder<bool>(
              valueListenable: o._highRes,
              builder: (context, hi, _) => PageItemsPaintLayer(
                controller: items,
                scale: k,
                highRes: hi,
                resolve: (p) => ref.read(pageImageStoreProvider).resolve(p),
              ),
            ),
            PdfPageInkLayer(
              key: const Key('note-page-ink'),
              session: o.session,
              page: widget.index,
              pageWidth: page.width,
              pageHeight: page.height,
            ),
            ListenableBuilder(
              listenable: tools,
              builder: (context, _) => PageItemsOverlay(
                controller: items,
                scale: k,
                zoom: o._zoom,
                tool: tools.itemTool,
                viewLock: o._itemLock,
                nodes: nodes,
                isPalm: o._isPalm,
                onTapEmpty: _tapEmpty,
                onOpenNode: (n) => o.widget.onOpenPage?.call(n.pageId),
                onMoveNode: _moveNode,
                onNodeMenu: _nodeMenu,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
