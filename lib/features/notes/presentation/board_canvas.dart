import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../../../core/text/turkish_text.dart';
import '../domain/board_view.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_board.dart';
import 'board_card.dart';
import 'board_link_painter.dart';

/// Panonun görünümünü dışarıdan yönetir (sığdır, %100, odakla) ve ölçeği duyurur.
class BoardViewController {
  final ValueNotifier<BoardViewport> viewport = ValueNotifier(const BoardViewport());
  final ValueNotifier<double> zoom = ValueNotifier(1);
  BoardCanvasState? _state;

  /// Tüm kartları görünür kılar.
  void fit() => _state?.fit();

  /// Ölçeği %100 yapar (ekran ortası sabit).
  void resetZoom() => _state?.zoomCenter(1 / viewport.value.scale);

  /// Karta odaklanır (ölçek çok küçükse okunur ölçeğe getirir).
  void focusOn(String pageId) => _state?.focusOn(pageId);

  /// Bekleyen (yazım sonucu beklenen) sürükleme değişikliklerini bırakır (yazım başarısız olunca).
  void discardPending() => _state?.discard();

  /// Kart listesi bir sonraki değişişte görünümü sığdırır (otomatik düzenleden sonra).
  void fitOnNextCards() => _state?._fitPending = true;

  /// Ekranda şu an görünen pano dikdörtgeni (henüz yerleşmediyse null).
  BoardRect? visibleRect() => _state?.visibleRect();

  void dispose() {
    viewport.dispose();
    zoom.dispose();
  }
}

enum _Mode { none, pan, card, resize, link }

/// Sonsuz pano: kendi jest katmanı (parmakla kaydır/yakınlaştır, kartı sürükle, tutamaçlar).
/// Kalem yalnız kart/bağlantı işlemleri içindir: boş alanda kaydırmaz, çizmez.
class BoardCanvas extends StatefulWidget {
  const BoardCanvas({
    super.key,
    required this.controller,
    required this.cards,
    required this.pages,
    required this.links,
    required this.linkMode,
    required this.onOpen,
    required this.onChanged,
    required this.onConnect,
    required this.onConnectEmpty,
    required this.onLinkTap,
    this.query = '',
  });

  final BoardViewController controller;
  final List<BoardCard> cards;
  final Map<String, InkNotePageRecord> pages;
  final List<PageLinkRecord> links;
  final bool linkMode;
  final String query;

  /// Karta dokunuldu (bağlantı modu kapalıyken).
  final ValueChanged<String> onOpen;

  /// Taşıma/boyutlandırma bitti: önceki ve sonraki dikdörtgenler (yalnız değişen kartlar).
  final void Function(Map<String, BoardRect> before, Map<String, BoardRect> after) onChanged;

  /// Bir karttan başka karta bağlantı kuruldu (sürükleyerek ya da bağlantı modunda iki dokunuşla).
  final void Function(String fromId, String toId) onConnect;

  /// Bağla tutamacı boş yere bırakıldı: pano konumu ile.
  final void Function(String fromId, BoardPoint at) onConnectEmpty;

  final ValueChanged<PageLinkRecord> onLinkTap;

  @override
  State<BoardCanvas> createState() => BoardCanvasState();
}

class BoardCanvasState extends State<BoardCanvas> {
  Size _size = Size.zero;
  bool _fitted = false;

  /// Kartların kalıcı (ya da yerleşmemişler için geçici) dikdörtgenleri.
  Map<String, BoardRect> _base = const {};

  /// Sürükleme sırasındaki / yazım bitene dek bekleyen dikdörtgenler.
  final Map<String, BoardRect> _over = {};

  _Mode _mode = _Mode.none;
  String? _dragId;
  Map<String, BoardRect> _before = const {};
  Offset _startFocal = Offset.zero;
  BoardViewport _startView = const BoardViewport();
  BoardPoint _startWorld = const BoardPoint(0, 0);
  BoardPoint? _linkTo;
  String? _target;
  String? _pick;

  BoardViewController get _c => widget.controller;
  BoardViewport get _v => _c.viewport.value;

  Map<String, BoardRect> get rects => {..._base, ..._over};

  @override
  void initState() {
    super.initState();
    _c._state = this;
    _rebase();
  }

  @override
  void didUpdateWidget(BoardCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _c._state = this;
    if (!identical(oldWidget.cards, widget.cards)) {
      _rebase();
      if (_mode == _Mode.none) _over.clear();
      if (_fitPending) {
        _fitPending = false;
        _scheduleFit();
      }
    }
    if (oldWidget.linkMode != widget.linkMode) _pick = null;
    if (oldWidget.query != widget.query && widget.query.trim().isNotEmpty) {
      final m = _matches();
      final first = widget.cards.where((c) => m.contains(c.pageId)).firstOrNull;
      if (first != null) focusOn(first.pageId);
    }
  }

  @override
  void dispose() {
    if (_c._state == this) _c._state = null;
    super.dispose();
  }

  void _rebase() {
    final placed = {
      for (final c in widget.cards)
        if (c.rect() case final r?) c.pageId: r,
    };
    _base = {...placed, ...placeUnplaced(widget.cards)};
    if (!_fitted && _size != Size.zero && _base.isNotEmpty) _scheduleFit();
  }

  void _scheduleFit() {
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) fit();
    });
  }

  void _set(BoardViewport v) {
    _c.viewport.value = v;
    _c.zoom.value = v.scale;
  }

  bool _fitPending = false;

  void discard() => setState(_over.clear);

  BoardRect? visibleRect() => _size == Size.zero ? null : _v.visibleRect(_size.width, _size.height);

  void fit() {
    final b = boundsOf(rects.values);
    if (b == null || _size == Size.zero) return;
    setState(() => _set(BoardViewport.fit(b, _size.width, _size.height)));
  }

  void zoomCenter(double factor) => setState(() => _set(_v.zoomAt(_size.width / 2, _size.height / 2, factor)));

  void focusOn(String pageId) {
    final r = rects[pageId];
    if (r == null || _size == Size.zero) return;
    final s = _v.scale < 0.3 ? 0.5 : _v.scale;
    setState(() => _set(BoardViewport(scale: s).centeredOn(r.cx, r.cy, _size.width, _size.height)));
  }

  Set<String> _matches() {
    final q = normalizeTr(widget.query.trim());
    if (q.isEmpty) return const {};
    return {
      for (final c in widget.cards)
        if (normalizeTr(boardCardTitle(c)).contains(q) || normalizeTr(c.konuId ?? '').contains(q)) c.pageId,
    };
  }

  // ───────────── Jestler ─────────────

  BoardPoint _world(Offset p) => _v.toWorld(p.dx, p.dy);

  /// Kenar işlemleri için ekran toleransı (pano birimi).
  double get _tol => 14 / _v.scale;

  ({String id, bool resize, bool link})? _handleHit(BoardPoint w) {
    if (_v.scale < boardLowDetailScale) return null;
    final r = rects;
    final vis = visibleCardIds(r, _v.visibleRect(_size.width, _size.height));
    for (final id in vis.reversed) {
      final h = BoardHandles(r[id]!, _v.scale);
      if (BoardHandles.hit(h.resize, w.x, w.y)) return (id: id, resize: true, link: false);
      if (BoardHandles.hit(h.link, w.x, w.y)) return (id: id, resize: false, link: true);
    }
    return null;
  }

  /// İlk parmağın/kalemin bastığı yer: jest eşiği aşılınca [ScaleStartDetails] odağı çoktan
  /// kaymış olur; tutamaç ve kart isabeti basılan noktadan hesaplanır.
  Offset? _down;
  int _pointers = 0;

  void _onStart(ScaleStartDetails d) {
    final origin = d.pointerCount <= 1 ? (_down ?? d.localFocalPoint) : d.localFocalPoint;
    _startFocal = origin;
    _startView = _v;
    _startWorld = _world(origin);
    _before = const {};
    _dragId = null;
    _linkTo = null;
    _target = null;
    if (d.pointerCount > 1) {
      _mode = _Mode.pan;
      return;
    }
    final w = _startWorld;
    final h = _handleHit(w);
    if (h != null) {
      _dragId = h.id;
      _mode = h.resize ? _Mode.resize : _Mode.link;
      _before = {h.id: rects[h.id]!};
      if (h.link) _linkTo = w;
      return;
    }
    final id = cardAt(rects, w.x, w.y);
    if (id != null && !widget.linkMode) {
      _dragId = id;
      _mode = _Mode.card;
      _before = {id: rects[id]!};
      return;
    }
    // Boş alan (ya da bağlantı modunda kart): parmak kaydırır; kalem hiçbir şey yapmaz.
    final pen = d.kind == PointerDeviceKind.stylus || d.kind == PointerDeviceKind.invertedStylus;
    _mode = pen ? _Mode.none : _Mode.pan;
  }

  void _onUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount > 1 && _mode != _Mode.pan) {
      // İkinci parmak geldi: işlem iptal, görünüm yakınlaşır.
      _over.removeWhere((k, _) => _before.containsKey(k));
      _linkTo = null;
      _target = null;
      _mode = _Mode.pan;
      _startFocal = d.localFocalPoint;
      _startView = _v;
      _startWorld = _world(d.localFocalPoint);
    }
    switch (_mode) {
      case _Mode.none:
        return;
      case _Mode.pan:
        final s = BoardViewport.clampScale(_startView.scale * d.scale);
        final f = d.localFocalPoint;
        setState(() => _set(BoardViewport(scale: s, tx: f.dx - _startWorld.x * s, ty: f.dy - _startWorld.y * s)));
      case _Mode.card:
        final delta = (d.localFocalPoint - _startFocal) / _v.scale;
        final b = _before[_dragId]!;
        setState(() => _over[_dragId!] = BoardRect(b.x + delta.dx, b.y + delta.dy, b.w, b.h));
      case _Mode.resize:
        final delta = (d.localFocalPoint - _startFocal) / _v.scale;
        final b = _before[_dragId]!;
        setState(() => _over[_dragId!] = BoardRect(b.x, b.y, math.max(120.0, b.w + delta.dx), math.max(160.0, b.h + delta.dy)));
      case _Mode.link:
        final w = _world(d.localFocalPoint);
        setState(() {
          _linkTo = w;
          _target = cardAt(rects, w.x, w.y, skip: _dragId);
        });
    }
  }

  void _onEnd(ScaleEndDetails d) {
    final mode = _mode;
    _mode = _Mode.none;
    final id = _dragId;
    if (id == null) return;
    if (mode == _Mode.card || mode == _Mode.resize) {
      final now = _over[id];
      final was = _before[id];
      if (now != null && was != null && now != was) {
        widget.onChanged({id: was}, {id: now});
      } else {
        setState(() => _over.remove(id));
      }
    } else if (mode == _Mode.link) {
      final to = _target;
      final at = _linkTo;
      setState(() {
        _linkTo = null;
        _target = null;
      });
      if (to != null) {
        widget.onConnect(id, to);
      } else if (at != null && (at.x - _startWorld.x).abs() + (at.y - _startWorld.y).abs() > 40 / _v.scale) {
        widget.onConnectEmpty(id, at);
      }
    }
    _dragId = null;
  }

  void _onTap(TapUpDetails d) {
    final w = _world(d.localPosition);
    final id = cardAt(rects, w.x, w.y);
    if (id != null) {
      if (widget.linkMode) {
        final src = _pick;
        if (src == null) {
          setState(() => _pick = id);
        } else {
          setState(() => _pick = null);
          if (src != id) widget.onConnect(src, id);
        }
      } else {
        widget.onOpen(id);
      }
      return;
    }
    final lid = linkAt(_curves(), w.x, w.y, _tol);
    if (lid != null) {
      final l = widget.links.where((e) => e.id == lid).firstOrNull;
      if (l != null) widget.onLinkTap(l);
      return;
    }
    if (_pick != null) setState(() => _pick = null);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      final s = ev as PointerScrollEvent;
      // Fare tekerleği: yakınlaştır; Shift ile yatay kaydır.
      if (HardwareKeyboard.instance.isShiftPressed) {
        setState(() => _set(_v.panned(-s.scrollDelta.dy, 0)));
      } else {
        setState(() => _set(_v.zoomAt(s.localPosition.dx, s.localPosition.dy, math.exp(-s.scrollDelta.dy / 300))));
      }
    });
  }

  Map<String, BoardCurve> _curves() {
    final r = rects;
    return {
      for (final l in widget.links)
        if (r[l.fromPageId] case final a?)
          if (r[l.toPageId] case final b?) l.id: curveBetween(a, b),
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _size = box.biggest;
        if (!_fitted && _size != Size.zero && _base.isNotEmpty) _scheduleFit();
        return ValueListenableBuilder<BoardViewport>(
          valueListenable: _c.viewport,
          builder: (context, v, _) => _body(context, v),
        );
      },
    );
  }

  Widget _body(BuildContext context, BoardViewport v) {
    final cs = Theme.of(context).colorScheme;
    final r = rects;
    final view = v.visibleRect(_size.width, _size.height);
    final vis = visibleCardIds(r, view, margin: 200 / v.scale);
    final low = v.scale < boardLowDetailScale;
    final byId = {for (final c in widget.cards) c.pageId: c};
    final hasChildren = {for (final c in widget.cards) if (c.parentPageId != null) c.parentPageId!};
    final matched = _matches();
    final searching = widget.query.trim().isNotEmpty;
    final curves = _curves();
    final linkMap = {for (final l in widget.links) l.id: l};
    return Listener(
      onPointerDown: (e) {
        if (_pointers == 0) _down = e.localPosition;
        _pointers++;
      },
      onPointerUp: (e) => _pointers = math.max(0, _pointers - 1),
      onPointerCancel: (e) => _pointers = math.max(0, _pointers - 1),
      onPointerSignal: _onSignal,
      child: GestureDetector(
        key: const Key('board-canvas'),
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onStart,
        onScaleUpdate: _onUpdate,
        onScaleEnd: _onEnd,
        onTapUp: _onTap,
        child: ClipRect(
          child: ColoredBox(
            color: cs.surfaceContainerLow,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: BoardLinkPainter(viewport: v, curves: curves, links: linkMap)),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Transform(
                        transform: Matrix4.identity()
                          ..translateByDouble(v.tx, v.ty, 0, 1)
                          ..scaleByDouble(v.scale, v.scale, 1, 1),
                        child: SizedBox(
                          width: 1,
                          height: 1,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final id in vis)
                                if (byId[id] case final c?)
                                  Positioned(
                                    key: ValueKey(id),
                                    left: r[id]!.x,
                                    top: r[id]!.y,
                                    width: r[id]!.w,
                                    height: r[id]!.h,
                                    child: BoardCardView(
                                      card: c,
                                      page: widget.pages[id],
                                      lowDetail: low,
                                      dimmed: searching && !matched.contains(id),
                                      matched: searching && matched.contains(id),
                                      hasChildren: hasChildren.contains(id),
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: BoardOverlayPainter(
                        viewport: v,
                        visible: {for (final id in vis) id: r[id]!},
                        linkFrom: _mode == _Mode.link && _dragId != null ? BoardPoint(r[_dragId]!.right, r[_dragId]!.cy) : null,
                        linkTo: _mode == _Mode.link ? _linkTo : null,
                        targetId: _target,
                        sourceId: _pick,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Testler için: şu an çizilen (kırpılmış) kart kimlikleri.
  List<String> get visibleIds => visibleCardIds(rects, _v.visibleRect(_size.width, _size.height), margin: 200 / _v.scale);
}
