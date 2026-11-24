import 'dart:async';
import 'dart:math' as math;

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerDownEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/platform.dart' show isDesktop;
import '../../../app/routes.dart';
import '../../../core/di/core_providers.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../pdf/pdf_providers.dart';
import '../../pdf/presentation/pdf_ink_input.dart' show PdfInkInput, palmRadiusMajor;
import '../../pdf/presentation/pdf_ink_session.dart';
import '../../pdf/presentation/pdf_page_ink_layer.dart';
import '../data/page_image_picker.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_board.dart';
import '../domain/page_item_geometry.dart';
import '../domain/page_item_ops.dart';
import '../domain/page_size.dart';
import '../domain/page_template.dart';
import '../../../app/tablet.dart';
import '../notes_providers.dart';
import 'dock_placement.dart';
import 'item_toolbar.dart';
import 'note_tool_dock.dart';
import 'note_tool_settings.dart';
import 'page_items_controller.dart';
import 'page_items_layer.dart';
import 'page_template_painter.dart';

/// Defter sayfası düzenleyicisi: sabit boyutlu sayfa (not koordinatı), parmakla
/// kaydır/yakınlaştır, kalem çizer. PDF okuyucunun kalem girişi ve oturumu aynen
/// kullanılır (avuç süzgeci, kalem havada iken görünüm kilidi, kayıt yeniden denemesi).
///
/// Her sayfa kendi oturumunu taşır ([key] sayfa kimliği olmalı): sayfa değişince
/// bekleyen kayıtlar bitirilip oturum kapanır.
class NotePageEditor extends ConsumerStatefulWidget {
  const NotePageEditor({
    super.key,
    required this.page,
    required this.tools,
    required this.onTemplate,
    required this.onTemplateAll,
    required this.onBackground,
    this.spacing = 1,
    required this.onSpacing,
    this.stylusOnlyOverride,
    this.onGrow,
    this.onTranscribe,
    this.onOpenPage,
  });

  /// Alt sayfa düğümüne dokunuldu: sayfa açılır (ekran sayfayı değiştirir).
  final ValueChanged<String>? onOpenPage;

  /// "Sayfayı metne çevir" (araç yuvasının Sayfa penceresinde düğme olur); null = yok.
  final VoidCallback? onTranscribe;

  /// Sonsuz sayfa alt kenara yaklaşınca yeni yükseklikle çağrılır (depo
  /// `setPageSize`). Yalnız kalem havadayken (görünüm kilidi açıkken) çağrılır:
  /// çizgi yarıda kalmaz. Hata atarsa bir sonraki denemede yeniden istenir.
  final Future<void> Function(double newHeight)? onGrow;

  /// Zum aralığı (1 = sayfa genişliğe sığmış): 0.1 sayfayı küçük görmek, 60 (%6000)
  /// en küçük ayrıntı için.
  static const minZoom = 0.1;
  static const maxZoom = 60.0;

  /// Zum bu değerin altına inince "Panoya geç" çipi çıkar (yüzde 12).
  static const boardChipZoom = 0.12;

  final ValueChanged<PageTemplate> onTemplate;
  final ValueChanged<PageTemplate> onTemplateAll;
  final ValueChanged<int> onBackground;

  /// Çizgi aralığı çarpanı (yalnızca oturumda; sayfa kaydına yazılmaz).
  final double spacing;
  final ValueChanged<double> onSpacing;

  final InkNotePageRecord page;
  final NoteToolSettings tools;

  /// Testte: parmak/fare davranışını sabitlemek için.
  final bool? stylusOnlyOverride;

  @override
  ConsumerState<NotePageEditor> createState() => NotePageEditorState();
}

class NotePageEditorState extends ConsumerState<NotePageEditor> implements DockDragHandler {
  late final PdfInkSession session;
  final _transform = TransformationController();
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _errorSub;

  /// Sayfa öğeleri (metin kutusu, görsel) ve görünüm durumu.
  late final PageItemsController items;
  final _zoom = ValueNotifier<double>(1);
  final _highRes = ValueNotifier<bool>(false);

  /// Öğe sürüklenirken görünüm kaymasın/yakınlaşmasın (artırımlı kilit).
  final _itemLock = ValueNotifier<int>(0);
  final _pageKey = GlobalKey();
  final _areaKey = GlobalKey();
  final _dockKey = GlobalKey();
  final _dockDrag = ValueNotifier<DockDrag?>(null);
  Offset _dockGrab = Offset.zero;
  Offset? _doubleTapAt;

  /// Şablon/arka plan seçimi veritabanı akışını beklemeden hemen görünür.
  PageTemplate? _tplLocal;
  int? _bgLocal;

  @override
  void initState() {
    super.initState();
    final p = widget.page;
    session = PdfInkSession(
      documentId: p.id,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
      attemptNo: 0,
      ownerOf: (_) => NotePageOwner(p.id, p.pageNo),
      penKinds: true,
    );
    items = PageItemsController(
      repo: ref.read(inkPageItemRepositoryProvider),
      pageId: p.id,
      pageW: p.width,
      pageH: p.height,
      onError: _toast,
    );
    ref.listenManual(pageItemsProvider(p.id), (_, n) {
      final v = n.value;
      if (v != null) items.sync(v);
    }, fireImmediately: true);
    _transform.addListener(_zoomChanged);
    // Geriye dönük avuç reddi: avuç kalemden önce değip sayfayı oynattıysa geri al.
    session.readViewMatrix = () => _transform.value.clone();
    session.writeViewMatrix = (m) => _transform.value = (m as Matrix4).clone();
    widget.tools.apply(session);
    _dockSeen = widget.tools.dockPosition;
    widget.tools.addListener(_applyTools);
    _pen = session.penFor(0)..addListener(_maybeGrow);
    session.viewerLocked.addListener(_maybeGrow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeGrow());
    _errorSub = session.errors.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    // Uygulama arka plana giderken bekleyen kayıtları bitir.
    _lifecycle = AppLifecycleListener(
      onInactive: flush,
      onHide: flush,
      onPause: flush,
    );
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  void _zoomChanged() {
    final z = _transform.value.getMaxScaleOnAxis();
    if (_zoom.value != z) _zoom.value = z;
    final hi = z > 1.8;
    if (_highRes.value != hi) _highRes.value = hi;
  }

  late DockPosition _dockSeen;
  late final PagePen _pen;

  /// Büyütme istendi ama sayfa kaydı henüz güncellenmedi (çift istek olmasın).
  double _requestedHeight = 0;
  bool _limitWarned = false;

  void _applyTools() {
    widget.tools.apply(session);
    // Yuva konumu değişince yerleşim yenilenir (diğer ayar değişimlerinde gerekmez).
    if (_dockSeen != widget.tools.dockPosition && mounted) {
      setState(() => _dockSeen = widget.tools.dockPosition);
    }
    // Öğe aracı açılınca düzenleme/seçim sürmez (Alt sayfa aracı vb.).
    if (widget.tools.itemTool == ItemTool.none) return;
    if (items.editingId != null && widget.tools.itemTool != ItemTool.text) {
      unawaited(items.stopEditing());
    }
  }

  /// Sonsuz sayfa: çizgiler alt kenara yaklaştıysa sayfayı uzatır. Kalem basılıyken
  /// ya da havada (görünüm kilidi) ASLA: çizgi koordinatı/katmanı değişmesin.
  void _maybeGrow() {
    final grow = widget.onGrow;
    final page = widget.page;
    if (grow == null || !mounted || !isInfinitePage(page.height)) return;
    if (session.viewerLocked.value) return;
    var maxY = 0.0;
    for (final s in _pen.strokes) {
      if (s.points.isEmpty) continue;
      final b = s.bounds.bottom;
      if (b > maxY) maxY = b;
    }
    final target = infiniteGrownHeight(page.height, maxY);
    if (target > page.height) {
      if (target <= _requestedHeight) return;
      _requestedHeight = target;
      grow(target).catchError((_) => _requestedHeight = 0);
    } else if (infiniteAtLimit(page.height, maxY) && !_limitWarned) {
      _limitWarned = true;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Sayfa en uzun boyuna ulaştı; yeni sayfa ekle.'),
          ),
        );
    }
  }

  /// Bekleyen kayıtların bitmesini bekler (sayfa çoğaltma, kapanış).
  Future<void> flush() async {
    await items.flush();
    await session.flush();
  }

  @override
  void didUpdateWidget(NotePageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tools != widget.tools) {
      oldWidget.tools.removeListener(_applyTools);
      widget.tools.addListener(_applyTools);
      _applyTools();
    }
    if (oldWidget.page.height != widget.page.height) {
      _requestedHeight = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeGrow());
    }
    items.pageW = widget.page.width;
    items.pageH = widget.page.height;
    // Akıştan gelen değer yerel seçimi karşıladıysa yerel kaydı bırak.
    if (_tplLocal == widget.page.template) _tplLocal = null;
    if (_bgLocal == widget.page.background) _bgLocal = null;
  }

  @override
  void dispose() {
    widget.tools.removeListener(_applyTools);
    _pen.removeListener(_maybeGrow);
    session.viewerLocked.removeListener(_maybeGrow);
    _transform.removeListener(_zoomChanged);
    _lifecycle.dispose();
    _errorSub?.cancel();
    _transform.dispose();
    items.dispose();
    _zoom.dispose();
    _highRes.dispose();
    _itemLock.dispose();
    _dockDrag.dispose();
    // Kuyruk bitmeden oturum kapanmasın.
    unawaited(session.flush().whenComplete(session.dispose));
    super.dispose();
  }

  /// Önceki zum (çift dokunuşla "sığdır"dan geri dönmek için).
  Matrix4? _zoomBack;

  /// Sayfa genişliğe sığdırılmış mı (zum 1, kaydırma 0).
  bool get _isFit => _transform.value.isIdentity();

  /// Sayfayı genişliğe sığdırır (zum 1, üstte). Önceki zum geri dönmek için saklanır.
  void fitToWidth() {
    if (!_isFit) _zoomBack = _transform.value.clone();
    _transform.value = Matrix4.identity();
  }

  /// Çift dokunuş: sığdırılmamışsa sığdır; sığdırılmışsa önceki zuma dön.
  void toggleFit() {
    if (_isFit) {
      final back = _zoomBack;
      if (back != null) _transform.value = back;
    } else {
      fitToWidth();
    }
  }

  // ───────────── sayfa koordinatı ─────────────

  /// Ekran noktasını not koordinatına çevirir (sayfa kutusu dışında da çalışır).
  Offset? _toPage(Offset global) {
    final box = _pageKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.width <= 0) {
      return null;
    }
    final l = box.globalToLocal(global);
    final k = widget.page.width / box.size.width;
    return Offset(l.dx * k, l.dy * k);
  }

  /// Görünür alanın (not birimi) dikdörtgeni; bilinmiyorsa tüm sayfa.
  Rect _visiblePageRect() {
    final page = widget.page;
    final area = _areaKey.currentContext?.findRenderObject();
    final pageBox = _pageKey.currentContext?.findRenderObject();
    if (area is! RenderBox || pageBox is! RenderBox || !area.hasSize || !pageBox.hasSize) {
      return Rect.fromLTWH(0, 0, page.width, math.min(page.height, page.width * 1.4));
    }
    final a = _toPage(area.localToGlobal(Offset.zero));
    final b = _toPage(area.localToGlobal(area.size.bottomRight(Offset.zero)));
    if (a == null || b == null) return Rect.fromLTWH(0, 0, page.width, page.height);
    final r = Rect.fromPoints(a, b).intersect(Rect.fromLTWH(0, 0, page.width, page.height));
    return r.isEmpty ? Rect.fromLTWH(0, 0, page.width, page.height) : r;
  }

  // ───────────── çift dokunuş ─────────────

  void _onDoubleTap() {
    final at = _doubleTapAt == null ? null : _toPage(_doubleTapAt!);
    if (at != null) {
      final hit = hitTestItems(items.items, at.dx, at.dy);
      if (hit != null) {
        items.select(hit.id);
        if (hit.kind == PageItemKind.text) items.startEditing(hit.id);
        return;
      }
    }
    toggleFit();
  }

  // ───────────── öğe oluşturma ─────────────

  Future<void> _tapEmpty(double x, double y) async {
    final tool = widget.tools.itemTool;
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
      await flush(); // bekleyen çizgiler ebeveynde kayıtlı kalsın
      final id = await ref.read(inkBoardRepositoryProvider).createChildPage(page.id, cx, cy);
      if (!mounted) return;
      widget.tools.setKind(widget.tools.lastPenKind); // tek seferlik: kaleme dön
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Alt sayfa oluşturuldu.'),
            action: SnackBarAction(label: 'Aç', onPressed: () => widget.onOpenPage?.call(id)),
          ),
        );
    } catch (e) {
      _toast('Alt sayfa oluşturulamadı: ${e is StateError ? e.message : e}');
    }
  }

  List<ChildNodeData> _nodes(List<PageLinkRecord> links, List<InkNotePageRecord> pages) {
    final byId = {for (final p in pages) p.id: p};
    return [
      for (final l in links)
        if (l.fromPageId == widget.page.id && l.kind == PageLinkKind.child && l.fromX != null && l.fromY != null && byId.containsKey(l.toPageId))
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
      _toast('Düğüm taşınamadı: ${e is StateError ? e.message : e}');
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
        widget.onOpenPage?.call(n.pageId);
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
      _toast('Ad kaydedilemedi: ${e is StateError ? e.message : e}');
    }
  }

  /// Düğümü siler: bağlantı yumuşak silinir; alt sayfa yalnız kullanıcı isterse (onaylı) silinir.
  Future<void> _deleteNode(ChildNodeData n) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alt sayfa düğümü silinsin mi?'),
        content: Text('"${n.title}" sayfasını da silmek ister misin? Sayfayı silmezsen yalnız bu düğüm kalkar; sayfa defterde durur.'),
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
    try {
      await board.deleteLink(n.linkId);
      if (choice == 'page') {
        try {
          await ref.read(inkNotebookRepositoryProvider).deletePage(n.pageId);
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
                  if (choice == 'page') await ref.read(inkNotebookRepositoryProvider).restorePage(n.pageId);
                  await board.restoreLink(n.linkId);
                } catch (_) {}
              },
            ),
          ),
        );
    } catch (e) {
      _toast('Silinemedi: ${e is StateError ? e.message : e}');
    }
  }

  // ───────────── fotoğraf ─────────────

  static const _maxImageBytes = 60 * 1024 * 1024;

  /// Yuvadaki "Foto": kaynak seç, kaydet (en uzun kenar 2048), görünür alanın ortasına koy.
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

  /// Seçilen kaynaktan görsel ekler (testte doğrudan çağrılır).
  Future<void> addPhotoFrom(PageImageSource src) async {
    PickedPageImage? picked;
    try {
      picked = await ref.read(pageImagePickerProvider).pick(src);
    } catch (e) {
      _toast('Görsel alınamadı: $e');
      return;
    }
    if (picked == null || !mounted) return;
    try {
      final file = File(picked.path);
      final len = await file.length();
      if (len > _maxImageBytes) {
        _toast('Görsel çok büyük (en çok 60 MB).');
        return;
      }
      final stored = await ref.read(pageImageStoreProvider).saveFile(picked.path);
      if (!mounted) return;
      final page = widget.page;
      final v = _visiblePageRect();
      final base = defaultImageRect(stored.pxW, stored.pxH, page.width, page.height);
      final rect = placeInVisible(base.w, base.h, v.left, v.top, v.width, v.height, page.width, page.height);
      await items.addImage(stored.path, rect, ImageItemPayload(pxW: stored.pxW, pxH: stored.pxH));
    } on FileSystemException {
      _toast('Görsel okunamadı ya da bozuk.');
    } catch (e) {
      _toast('Görsel eklenemedi: ${e is StateError ? e.message : e}');
    } finally {
      if (picked.temp) {
        // Yalnız kendi geçici kopyamız silinir; kullanıcının dosyasına dokunulmaz.
        try {
          await ref.read(mediaStorageProvider).discardTemp(picked.path);
        } catch (_) {}
      }
    }
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
    final tl = Offset(
      d.topLeft.dx.clamp(t.minX, t.maxX).toDouble(),
      d.topLeft.dy.clamp(t.minY, t.maxY).toDouble(),
    );
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

  bool _isPalm(PointerDownEvent e) =>
      session.penActive || e.radiusMajor >= palmRadiusMajor || session.isPalmNearPen(e.position);

  void _openBoard() {
    try {
      context.push(AppRoutes.inkBoard(widget.page.notebookId));
    } catch (_) {
      _toast('Pano şu an açılamadı.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final cs = Theme.of(context).colorScheme;
    final focus = TabletFocus.maybeOf(context)?.value ?? false;
    final pos = widget.tools.dockPosition;
    _dockSeen = pos;
    final pad = MediaQuery.paddingOf(context);
    final template = _tplLocal ?? page.template;
    final background = _bgLocal ?? page.background;
    final links = ref.watch(boardLinksProvider(page.notebookId)).value ?? const <PageLinkRecord>[];
    final notebookPages = ref.watch(inkNotebookPagesProvider(page.notebookId)).value ?? const <InkNotePageRecord>[];
    final nodes = _nodes(links, notebookPages);
    final hasRouter = GoRouter.maybeOf(context) != null;
    final viewer = ColoredBox(
      color: cs.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, box) {
          // Sayfa genişliğe TAM oturur (kenar boşluğu yok); yükseklik sayfa oranından.
          // Kaydırma/zum matrisi ekran içindir, çizgi koordinatı (not koordinatı) etkilenmez.
          final w = box.maxWidth.isFinite ? box.maxWidth : page.width;
          final h = w * page.height / page.width;
          final k = w / page.width;
          return Stack(
            key: _areaKey,
            children: [
              GestureDetector(
                // Kalemin çift dokunuşu sığdırmasın: yalnız parmak/fare.
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                },
                onDoubleTapDown: (d) => _doubleTapAt = d.globalPosition,
                onDoubleTap: _onDoubleTap,
                child: PdfInkInput(
                  session: session,
                  stylusOnlyOverride: widget.stylusOnlyOverride,
                  // Kalem çizerken / sayfa üstünde havadayken görünüm kaymaz ve yakınlaşmaz
                  // (avuç kalemden önce değse bile).
                  child: ValueListenableBuilder<bool>(
                    valueListenable: session.viewerLocked,
                    builder: (context, locked, _) => ValueListenableBuilder<int>(
                      valueListenable: _itemLock,
                      builder: (context, itemLock, _) => InteractiveViewer(
                        transformationController: _transform,
                        panEnabled: !locked && itemLock == 0,
                        scaleEnabled: !locked && itemLock == 0,
                        constrained: false,
                        // Sayfa kenarda takılmaz; kaybolursa "sığdır" geri getirir.
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        minScale: NotePageEditor.minZoom,
                        maxScale: NotePageEditor.maxZoom,
                        child: SizedBox(
                          key: _pageKey,
                          width: w,
                          height: h,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 6,
                                  offset: Offset(0, 2),
                                ),
                              ],
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
                                      spacingFactor: widget.spacing,
                                      viewTransform: _transform,
                                      viewSize: Size(box.maxWidth, box.maxHeight),
                                    ),
                                  ),
                                ),
                                // Metin ve görseller çizgilerin ALTINDA (üstüne yazılır).
                                ValueListenableBuilder<bool>(
                                  valueListenable: _highRes,
                                  builder: (context, hi, _) => PageItemsPaintLayer(
                                    controller: items,
                                    scale: k,
                                    highRes: hi,
                                    resolve: (p) => ref.read(pageImageStoreProvider).resolve(p),
                                  ),
                                ),
                                PdfPageInkLayer(
                                  key: const Key('note-page-ink'),
                                  session: session,
                                  page: 0,
                                  pageWidth: page.width,
                                  pageHeight: page.height,
                                ),
                                ListenableBuilder(
                                  listenable: widget.tools,
                                  builder: (context, _) => PageItemsOverlay(
                                    controller: items,
                                    scale: k,
                                    zoom: _zoom,
                                    tool: widget.tools.itemTool,
                                    viewLock: _itemLock,
                                    nodes: nodes,
                                    isPalm: _isPalm,
                                    onTapEmpty: _tapEmpty,
                                    onOpenNode: (n) => widget.onOpenPage?.call(n.pageId),
                                    onMoveNode: _moveNode,
                                    onNodeMenu: _nodeMenu,
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
              ),
              // Yuva sayfanın üstünde yüzer (sayfa alanı küçülmez); boş yerlerinde
              // dokunuşlar sayfaya geçer. Zum göstergesi yuvanın karşı kenarında.
              Positioned(
                // Zum göstergesi yuvanın çakışmayacağı köşede: üst yuva -> sağ alt,
                // sağ yuva -> sol üst, diğerleri -> sağ üst.
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
                        builder: (_, m, _) => Text(
                          '%${(m.getMaxScaleOnAxis() * 100).round()}',
                          key: const Key('note-zoom-label'),
                        ),
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
              // Çok uzaklaşınca (yüzde 12 altı) panoya geçiş önerilir (yalnız yönlendirici varsa).
              if (hasRouter)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _zoom,
                      builder: (context, z, _) => z < NotePageEditor.boardChipZoom
                          ? ActionChip(
                              key: const Key('note-to-board'),
                              avatar: const Icon(Icons.dashboard_outlined, size: 18),
                              label: const Text('Panoya geç'),
                              onPressed: _openBoard,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              // Seçili öğenin araç çubuğu (üst orta).
              Positioned(
                top: hasRouter ? 52 : 8,
                left: 8,
                right: 8,
                child: Center(
                  child: ItemToolbar(
                    controller: items,
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
                              onPressed: () => items.restore(id),
                            ),
                          ),
                        );
                    },
                  ),
                ),
              ),
              // Yuva: kenarda ya da serbest; sürüklerken parmağı izler.
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
                  page: PageStyleControl(
                    template: template,
                    background: background,
                    spacing: widget.spacing,
                    onTemplate: (t) {
                      setState(() => _tplLocal = t);
                      widget.onTemplate(t);
                    },
                    onTemplateAll: (t) {
                      setState(() => _tplLocal = t);
                      widget.onTemplateAll(t);
                    },
                    onBackground: (c) {
                      setState(() => _bgLocal = c);
                      widget.onBackground(c);
                    },
                    onSpacing: widget.onSpacing,
                    onTranscribe: widget.onTranscribe,
                  ),
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
    return viewer;
  }
}
