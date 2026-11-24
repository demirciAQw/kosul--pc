import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../domain/page_board.dart';
import '../domain/page_item_geometry.dart';
import '../domain/page_item_ops.dart';
import 'image_item_widget.dart';
import 'note_tool_settings.dart' show ItemTool;
import 'page_items_controller.dart';
import 'text_item_widget.dart';

/// Alt sayfa düğümü kartının boyutu (not birimi); çapa kartın MERKEZİDİR.
const childNodeW = 220.0;
const childNodeH = 64.0;

/// Sayfadaki bir alt sayfa düğümü (`child` bağlantısı + hedef sayfa).
class ChildNodeData {
  const ChildNodeData({
    required this.linkId,
    required this.pageId,
    required this.title,
    required this.x,
    required this.y,
  });
  final String linkId;
  final String pageId;
  final String title;
  final double x;
  final double y;

  BoardRect get rect => BoardRect(x - childNodeW / 2, y - childNodeH / 2, childNodeW, childNodeH);
}

/// Öğelerin salt görünümü: kalem çizgilerinin ALTINDA durur (çizgiler fotoğraf ve yazı
/// üstüne yazılır). Dokunuş almaz; düzenlenen metin kutusu burada çizilmez (üst katmanda).
class PageItemsPaintLayer extends StatelessWidget {
  const PageItemsPaintLayer({
    super.key,
    required this.controller,
    required this.scale,
    required this.resolve,
    this.highRes = false,
  });
  final PageItemsController controller;

  /// Not biriminden yerel piksele.
  final double scale;
  final File Function(String path) resolve;
  final bool highRes;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final editing = controller.editingId;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final it in controller.items)
              if (it.id != editing)
                Positioned(
                  key: ValueKey('item-${it.id}'),
                  left: it.x * scale,
                  top: it.y * scale,
                  width: it.w * scale,
                  height: it.h * scale,
                  child: Transform.rotate(
                    angle: it.rotation,
                    child: RepaintBoundary(
                      child: it.kind == PageItemKind.text
                          ? TextItemView(key: Key('note-text-${it.id}'), payload: it.text, scale: scale)
                          : ImageItemView(
                              key: Key('note-image-${it.id}'),
                              file: resolve(it.mediaPath ?? ''),
                              payload: it.image,
                              highRes: highRes,
                            ),
                    ),
                  ),
                ),
          ],
        );
      },
    ),
  );
}

enum _Op { none, move, resize, rotate, node }

/// Kalemin ÜSTÜNDEKİ katman: seçili öğenin çerçevesi ve tutamaçları, düzenlenen metin
/// kutusu, alt sayfa düğümleri ve ham işaretçi işleme (oluşturma, seçme, taşıma,
/// boyutlandırma, döndürme). Ham `Listener` kullanır (hareket arenasına girmez); bir
/// işlem başlayınca [viewLock] artar ve görünüm kaymaz/yakınlaşmaz.
///
/// Kalem ([ItemTool.none] iken) YALNIZ çizer; öğelere parmak/fare dokunur. Metin ve Alt
/// sayfa araçları açıkken kalem de parmak gibi dokunur (o zaman çizim girişi kapalıdır).
class PageItemsOverlay extends StatefulWidget {
  const PageItemsOverlay({
    super.key,
    required this.controller,
    required this.scale,
    required this.zoom,
    required this.tool,
    required this.viewLock,
    required this.nodes,
    required this.onTapEmpty,
    required this.onOpenNode,
    required this.onMoveNode,
    required this.onNodeMenu,
    this.isPalm,
  });

  final PageItemsController controller;
  final double scale;

  /// Görünüm yakınlaştırması (yerel piksel -> ekran pikseli).
  final ValueListenable<double> zoom;
  final ItemTool tool;
  final ValueNotifier<int> viewLock;
  final List<ChildNodeData> nodes;

  /// Araç (Metin/Alt sayfa) açıkken boşluğa dokunuldu (not birimi).
  final void Function(double x, double y) onTapEmpty;
  final void Function(ChildNodeData node) onOpenNode;
  final void Function(ChildNodeData node, double x, double y) onMoveNode;
  final void Function(ChildNodeData node, Offset global) onNodeMenu;

  /// Avuç mu (kalem çizerken/yakınında dokunuş): öğe işlemi başlatmaz.
  final bool Function(PointerDownEvent e)? isPalm;

  @override
  State<PageItemsOverlay> createState() => _PageItemsOverlayState();
}

class _PageItemsOverlayState extends State<PageItemsOverlay> {
  int? _pointer;
  _Op _op = _Op.none;
  Offset _startLocal = Offset.zero;
  bool _moved = false;
  bool _locked = false;
  bool _tapEmpty = false;
  bool _longPressed = false;
  String? _itemId;
  BoardRect _startRect = const BoardRect(0, 0, 1, 1);
  double _startRot = 0;
  ResizeHandle? _handle;
  ChildNodeData? _node;
  Offset? _nodePos; // sürüklenen düğümün anlık merkezi (not birimi)
  Offset _nodeStart = Offset.zero;
  Timer? _lp;
  Offset _lastGlobal = Offset.zero;

  PageItemsController get _c => widget.controller;
  double get _k => widget.scale;
  double get _zoom => widget.zoom.value <= 0 ? 1 : widget.zoom.value;
  bool get _itemMode => widget.tool != ItemTool.none;

  /// Ekran pikselini not birimine çevirir.
  double _units(double screenPx) => screenPx / (_k * _zoom);

  @override
  void dispose() {
    _lp?.cancel();
    _release();
    super.dispose();
  }

  void _lock() {
    if (_locked) return;
    _locked = true;
    widget.viewLock.value++;
  }

  void _release() {
    if (!_locked) return;
    _locked = false;
    widget.viewLock.value--;
  }

  static const _textHandles = {
    ResizeHandle.left,
    ResizeHandle.right,
    ResizeHandle.topLeft,
    ResizeHandle.topRight,
    ResizeHandle.bottomLeft,
    ResizeHandle.bottomRight,
  };
  static const _imageHandles = {
    ResizeHandle.topLeft,
    ResizeHandle.topRight,
    ResizeHandle.bottomLeft,
    ResizeHandle.bottomRight,
  };

  static Offset _handleLocal(BoardRect r, ResizeHandle h) => switch (h) {
    ResizeHandle.topLeft => Offset(r.x, r.y),
    ResizeHandle.top => Offset(r.cx, r.y),
    ResizeHandle.topRight => Offset(r.right, r.y),
    ResizeHandle.right => Offset(r.right, r.cy),
    ResizeHandle.bottomRight => Offset(r.right, r.bottom),
    ResizeHandle.bottom => Offset(r.cx, r.bottom),
    ResizeHandle.bottomLeft => Offset(r.x, r.bottom),
    ResizeHandle.left => Offset(r.x, r.cy),
  };

  Offset _world(PageItemRecord it, Offset local) {
    final w = fromItemLocal(it.rect, it.rotation, local.dx, local.dy);
    return Offset(w.x, w.y);
  }

  /// Seçili öğede [p] (not birimi) bir tutamaca denk geliyor mu: ya döndürme ya yeniden boyut.
  ({bool rotate, ResizeHandle? handle})? _handleAt(PageItemRecord it, Offset p) {
    final r = it.rect;
    final tol = _units(24);
    final rot = _world(it, Offset(r.cx, r.y - _units(38)));
    if ((rot - p).distance <= tol) return (rotate: true, handle: null);
    final set = it.kind == PageItemKind.text ? _textHandles : _imageHandles;
    ResizeHandle? best;
    var bestD = tol;
    for (final h in set) {
      final d = (_world(it, _handleLocal(r, h)) - p).distance;
      if (d <= bestD) {
        bestD = d;
        best = h;
      }
    }
    return best == null ? null : (rotate: false, handle: best);
  }

  ChildNodeData? _nodeAt(Offset p) {
    for (final n in widget.nodes.reversed) {
      final c = _nodePos != null && _node?.linkId == n.linkId ? _nodePos! : Offset(n.x, n.y);
      if ((p.dx - c.dx).abs() <= childNodeW / 2 && (p.dy - c.dy).abs() <= childNodeH / 2) return n;
    }
    return null;
  }

  void _down(PointerDownEvent e) {
    if (_pointer != null) {
      // İkinci temas (yakınlaştırma): süren öğe işlemi biter, görünüm serbest kalır.
      _finishOp(commit: true);
      return;
    }
    final fingerLike = e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.mouse;
    if (!fingerLike && !_itemMode) return; // kalem çizer
    if (e.kind == PointerDeviceKind.touch && (widget.isPalm?.call(e) ?? false)) return;
    final p = Offset(e.localPosition.dx / _k, e.localPosition.dy / _k);
    _startLocal = e.localPosition;
    _lastGlobal = e.position;
    _moved = false;
    _longPressed = false;
    _tapEmpty = false;
    _op = _Op.none;
    _itemId = null;
    _node = null;

    final sel = _c.selected;
    if (sel != null && _c.editingId == null) {
      final h = _handleAt(sel, p);
      if (h != null) {
        _begin(e, h.rotate ? _Op.rotate : _Op.resize, sel);
        _handle = h.handle;
        return;
      }
    }
    final node = _nodeAt(p);
    if (node != null) {
      _pointer = e.pointer;
      _op = _Op.node;
      _node = node;
      _nodeStart = Offset(node.x, node.y);
      _nodePos = null;
      _lock();
      _lp?.cancel();
      _lp = Timer(const Duration(milliseconds: 550), () {
        if (_pointer == null || _moved || _node == null) return;
        _longPressed = true;
        widget.onNodeMenu(_node!, _lastGlobal);
        _finishOp(commit: false);
      });
      return;
    }
    final hit = hitTestItems(_c.items, p.dx, p.dy);
    if (hit != null) {
      if (_c.editingId == hit.id) return; // yazı alanı kendi işler
      if (_itemMode || hit.id == _c.selectedId) {
        if (_c.selectedId != hit.id) _c.select(hit.id);
        _begin(e, _Op.move, hit);
        return;
      }
    }
    // Boşluk (ya da seçili olmayan öğe, öğe aracı yokken): dokunuşla oluştur/seçimi kaldır.
    if (_itemMode || _c.selectedId != null) {
      _pointer = e.pointer;
      _tapEmpty = true;
    }
  }

  void _begin(PointerDownEvent e, _Op op, PageItemRecord it) {
    _pointer = e.pointer;
    _op = op;
    _itemId = it.id;
    _startRect = it.rect;
    _startRot = it.rotation;
    _handle = null;
    _lock();
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _lastGlobal = e.position;
    final slop = 10 / _zoom;
    if (!_moved && (e.localPosition - _startLocal).distance > slop) {
      _moved = true;
      _lp?.cancel();
    }
    if (!_moved) return;
    final d = (e.localPosition - _startLocal) / _k;
    final p = Offset(e.localPosition.dx / _k, e.localPosition.dy / _k);
    switch (_op) {
      case _Op.move:
        final id = _itemId;
        if (id == null) return;
        final r = clampItemRect(BoardRect(_startRect.x + d.dx, _startRect.y + d.dy, _startRect.w, _startRect.h), _c.pageW, _c.pageH);
        _c.preview(id, rect: r);
      case _Op.resize:
        final id = _itemId, h = _handle;
        final it = id == null ? null : _c.byId(id);
        if (id == null || h == null || it == null) return;
        final r = resizeRotatedRect(
          _startRect,
          _startRot,
          h,
          d.dx,
          d.dy,
          keepAspect: it.kind == PageItemKind.image,
          pageW: _c.pageW,
          pageH: _c.pageH,
        );
        _c.preview(id, rect: r);
      case _Op.rotate:
        final id = _itemId;
        if (id == null) return;
        _c.preview(id, rotation: rotationFromPoint(_startRect, p.dx, p.dy));
      case _Op.node:
        final n = _node;
        if (n == null) return;
        setState(() {
          _nodePos = Offset(
            (_nodeStart.dx + d.dx).clamp(0.0, _c.pageW).toDouble(),
            (_nodeStart.dy + d.dy).clamp(0.0, _c.pageH).toDouble(),
          );
        });
      case _Op.none:
        break;
    }
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _finishOp(commit: true, up: e);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _finishOp(commit: false);
  }

  void _finishOp({required bool commit, PointerUpEvent? up}) {
    _lp?.cancel();
    final op = _op, id = _itemId, node = _node;
    final moved = _moved, tapEmpty = _tapEmpty, longPressed = _longPressed;
    final nodePos = _nodePos;
    _pointer = null;
    _op = _Op.none;
    _itemId = null;
    _node = null;
    _nodePos = null;
    _tapEmpty = false;
    _handle = null;
    _release();
    if (!commit) {
      if (id != null && moved) unawaited(_c.commitGeometry(id, rect: _startRect, rotation: _startRot));
      if (node != null && nodePos != null && mounted) setState(() {});
      return;
    }
    final k = _k;
    switch (op) {
      case _Op.move:
      case _Op.resize:
      case _Op.rotate:
        if (id == null) return;
        if (moved) {
          final it = _c.byId(id);
          if (it != null) unawaited(_c.commitGeometry(id, rect: it.rect, rotation: it.rotation));
        } else if (op == _Op.move) {
          final it = _c.byId(id);
          // Metin aracı açıkken yazıya dokunmak düzenler.
          if (it != null && it.kind == PageItemKind.text && widget.tool == ItemTool.text) _c.startEditing(id);
        }
      case _Op.node:
        if (node == null || longPressed) return;
        if (moved && nodePos != null) {
          widget.onMoveNode(node, nodePos.dx, nodePos.dy);
          if (mounted) setState(() {});
        } else if (!moved) {
          widget.onOpenNode(node);
        }
      case _Op.none:
        if (tapEmpty && !moved && up != null) {
          final p = Offset(up.localPosition.dx / k, up.localPosition.dy / k);
          if (_c.editingId != null) unawaited(_c.stopEditing());
          if (_itemMode) {
            widget.onTapEmpty(p.dx, p.dy);
          } else {
            _c.select(null);
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _k;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Listener(
            key: const Key('note-items-overlay'),
            behavior: HitTestBehavior.translucent,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _cancel,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _SelectionPainter(_c, widget.zoom, k),
            ),
          ),
        ),
        for (final n in widget.nodes) _nodeWidget(context, n),
        ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final id = _c.editingId;
            final it = id == null ? null : _c.byId(id);
            if (it == null || it.kind != PageItemKind.text) return const SizedBox.shrink();
            return Positioned(
              left: it.x * k,
              top: it.y * k,
              width: it.w * k,
              height: it.h * k,
              child: Transform.rotate(
                angle: it.rotation,
                child: TextItemEditor(
                  key: ValueKey('edit-${it.id}'),
                  payload: it.text,
                  scale: k,
                  onChanged: (t) {
                    final cur = _c.byId(it.id);
                    if (cur != null) _c.setText(it.id, cur.text.copyWith(text: t));
                  },
                  onDone: () => unawaited(_c.stopEditing()),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _nodeWidget(BuildContext context, ChildNodeData n) {
    final k = _k;
    final c = _nodePos != null && _node?.linkId == n.linkId ? _nodePos! : Offset(n.x, n.y);
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      key: ValueKey('node-${n.linkId}'),
      left: (c.dx - childNodeW / 2) * k,
      top: (c.dy - childNodeH / 2) * k,
      width: childNodeW * k,
      height: childNodeH * k,
      child: IgnorePointer(
        child: Material(
          key: Key('note-child-node-${n.linkId}'),
          color: cs.primaryContainer,
          elevation: 2,
          borderRadius: BorderRadius.circular(14 * k),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12 * k),
            child: Row(
              children: [
                Icon(Icons.subdirectory_arrow_right, size: 28 * k, color: cs.onPrimaryContainer),
                SizedBox(width: 8 * k),
                Expanded(
                  child: Text(
                    n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(fontSize: 24 * k, color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Seçili öğenin çerçevesi, tutamaçları ve döndürme tutamacı; boyutları yakınlaştırmayla
/// değişmez (ekranda sabit).
class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.c, this.zoom, this.k) : super(repaint: Listenable.merge([c, zoom]));
  final PageItemsController c;
  final ValueListenable<double> zoom;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    final it = c.selected;
    if (it == null) return;
    final z = zoom.value <= 0 ? 1.0 : zoom.value;
    final r = it.rect;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / z
      ..color = const Color(0xFF1565C0);
    canvas.save();
    canvas.translate(r.cx * k, r.cy * k);
    canvas.rotate(it.rotation);
    final box = Rect.fromCenter(center: Offset.zero, width: r.w * k, height: r.h * k);
    canvas.drawRect(box, line);
    if (c.editingId == null) {
      final fill = Paint()..color = Colors.white;
      final radius = 9 / z;
      final set = it.kind == PageItemKind.text
          ? _PageItemsOverlayState._textHandles
          : _PageItemsOverlayState._imageHandles;
      for (final h in set) {
        final lp = _PageItemsOverlayState._handleLocal(r, h);
        final o = Offset((lp.dx - r.cx) * k, (lp.dy - r.cy) * k);
        canvas.drawCircle(o, radius, fill);
        canvas.drawCircle(o, radius, line);
      }
      final top = Offset(0, -r.h * k / 2);
      final rot = Offset(0, -r.h * k / 2 - 38 / z);
      canvas.drawLine(top, rot, line);
      canvas.drawCircle(rot, radius, fill);
      canvas.drawCircle(rot, radius, line);
      // Döndürme simgesi yerine iç nokta (yön).
      canvas.drawCircle(rot, math.max(1.5 / z, radius * 0.35), Paint()..color = const Color(0xFF1565C0));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.c != c || old.zoom != zoom || old.k != k;
}
