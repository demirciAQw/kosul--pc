import 'dart:async';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../ink/data/ink_overlay_codec.dart';
import '../../ink/data/ink_overlay_controller.dart';
import '../../ink/data/ink_overlay_host.dart';
import '../../ink/domain/ink_overlay_geometry.dart';
import '../../ink/presentation/ink_mask.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

/// Bir sayfa katmanının ekrandaki durumu (Ink katmanı için).
class OverlayLayerGeometry {
  const OverlayLayerGeometry({required this.visible, required this.origin, required this.dpr});

  /// Görünen (üst öğelerin kırpmasıyla daraltılmış) dikdörtgen, pencere mantıksal koordinatı.
  final Rect visible;

  /// Katmanın sol-üst köşesi (kaydırma/yakınlaştırma dahil), pencere mantıksal koordinatı.
  final Offset origin;
  final double dpr;
}

/// [box]'ın pencere koordinatındaki görünen dikdörtgeni: üst öğelerin kırpmaları
/// (`describeApproximatePaintClip`: kaydırıcı, ClipRect) kesiştirilir. Tamamen kırpıldıysa null.
Rect? globalVisibleRect(RenderBox box) {
  if (!box.attached || !box.hasSize) return null;
  var rect = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
  RenderObject child = box;
  RenderObject? parent = box.parent;
  while (parent != null) {
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null && parent is RenderBox) {
      rect = rect.intersect(MatrixUtils.transformRect(parent.getTransformTo(null), clip));
      if (rect.isEmpty) return null;
    }
    child = parent;
    parent = parent.parent;
  }
  return rect;
}

typedef AfterDraw = Future<void> Function();

/// Çizim karesi tamamlanana kadar bekler: kuru çizgi bir kare çizilsin, sonra ek bir kare
/// (raster) geçsin; ıslak çizgi ancak ondan sonra bırakılır (titreşimsiz el değiştirme).
Future<void> waitDrawnFrames() async {
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;
}

/// Bir [PdfInkSession]'ı yerel Ink katmanına bağlar (Android, "Yerel Ink kalemi" açıkken).
///
/// Akış: araç kalem/fosforlu iken `setMode` + `setBrush`; her kare görünür sayfa katmanlarının
/// dikdörtgenleri `setRegions` ile bildirilir (değişmediyse gönderilmez). Yerel katman kalem
/// çizgisini ıslak çizer; `strokeFinished` gelince noktalar sayfa katmanının görünümüne, oradan
/// mevcut kayıt yoluyla (`PdfInkSession.addStroke`) sayfa birimine çevrilip kaydedilir; çizim
/// karesi bittikten sonra `releaseStrokes`. Parmak, silgi, kement, soru seç, şekil araçları ve
/// yan düğme Flutter yolunda kalır; katman yoksa/kapalıysa Flutter yolu aynen çalışır.
class PdfInkOverlay {
  PdfInkOverlay(this.session, {AfterDraw? afterDraw}) : _afterDraw = afterDraw ?? afterDrawOverride ?? waitDrawnFrames {
    session.addListener(sync);
    final host = InkOverlayHost.instance;
    host.availability.addListener(sync);
    InkOverlayHost.nativeEnabled.addListener(sync);
    host.ownership.addListener(sync);
    _hookFrames();
    sync();
  }

  /// Test: çizim karesi beklemesini değiştirir.
  @visibleForTesting
  static AfterDraw? afterDrawOverride;

  final PdfInkSession session;
  final AfterDraw _afterDraw;
  StreamSubscription<InkOverlayEvent>? _sub;
  InkOverlayController? _subOn;
  bool _disposed = false;

  /// Son kare eşitlemesinden: dikdörtgenler (px) ve onlara karşılık gelen katmanlar.
  List<Rect> _regionsPx = const [];
  List<PdfPageInkLayerState> _regionLayers = const [];

  /// Bu oturumun katmanı yerel katmanın sahibi mi.
  bool get owns => InkOverlayHost.instance.isOwner(this);

  static bool _framesHooked = false;
  static void _hookFrames() {
    if (_framesHooked) return;
    _framesHooked = true;
    // Kaydırma/yakınlaştırma bildirim üretmez; düzen bitince (kare sonunda) bölgeler tazelenir.
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      final o = InkOverlayHost.instance.owner;
      if (o is PdfInkOverlay) o.syncRegions();
    });
  }

  /// Katman eklendi/çıktı.
  void layersChanged() => sync();

  /// Araç/fırça/anahtar/sahiplik değişti: mod, fırça ve (sahipse) bölgeler eşitlenir.
  void sync() {
    if (_disposed) return;
    final host = InkOverlayHost.instance;
    final c = host.controller;
    final wanted = c != null && InkOverlayHost.nativeEnabled.value && session.layerStates.isNotEmpty;
    if (!wanted) {
      host.release(this);
      return;
    }
    if (!host.isOwner(this)) {
      host.claim(this);
      if (!host.isOwner(this)) return;
    }
    if (!c.available) return; // yoklama sürüyor ya da katman yok: Flutter yolu
    _listen(c);
    final dpr = _dpr();
    final brush = dpr == null ? null : desiredOverlayBrush(session, dpr);
    if (brush == null) {
      c.setMode(InkOverlayMode.off);
    } else {
      c.setBrush(family: brush.family, argb: brush.argb, sizePx: brush.sizePx);
      c.setMode(brush.mode);
    }
    syncRegions();
  }

  double? _dpr() {
    for (final l in session.layerStates) {
      final g = l.overlayGeometry();
      if (g != null) return g.dpr;
    }
    // Katmanlar henüz yerleşmediyse (ilk kare) pencerenin oranı.
    final d = WidgetsBinding.instance.platformDispatcher;
    return (d.implicitView ?? d.views.firstOrNull)?.devicePixelRatio;
  }

  /// Sayfa dikdörtgenlerini (px) yerele bildirir; yalnız sahipken.
  void syncRegions() {
    if (_disposed || !owns) return;
    final c = InkOverlayHost.instance.controller;
    if (c == null || !c.available) return;
    final rects = <Rect>[];
    final layers = <PdfPageInkLayerState>[];
    double? dpr;
    for (final l in session.layerStates) {
      final g = l.overlayGeometry();
      if (g == null) continue;
      rects.add(Rect.fromLTRB(g.visible.left * g.dpr, g.visible.top * g.dpr, g.visible.right * g.dpr, g.visible.bottom * g.dpr));
      layers.add(l);
      dpr ??= g.dpr;
    }
    // Flutter arayüzü (araç çubuğu, yüzen düğmeler) üstünde kalem çizmesin.
    if (dpr != null) c.setMask(InkMaskRegistry.rectsPx(dpr));
    _regionsPx = rects;
    _regionLayers = layers;
    c.setRegions(rects);
  }

  void _listen(InkOverlayController c) {
    if (identical(_subOn, c)) return;
    _sub?.cancel();
    _subOn = c;
    _sub = c.events.listen(_onEvent);
  }

  void _onEvent(InkOverlayEvent e) {
    if (_disposed || !owns) return;
    if (e is OverlayStrokeFinished) unawaited(handleFinished(e));
  }

  /// Biten çizgiyi kaydet, çizim karesini bekle, ıslak çizgiyi bırak. Çizgi bir sayfaya
  /// düşmediyse (katman kayboldu, süzgeç reddetti) yine bırakılır: ıslak çizgi asılı kalmasın.
  @visibleForTesting
  Future<void> handleFinished(OverlayStrokeFinished e) async {
    try {
      _store(e);
    } catch (err) {
      debugPrint('PdfInkOverlay çizgi kaydı: $err');
    }
    await _afterDraw();
    if (_disposed) return;
    InkOverlayHost.instance.controller?.releaseStrokes([e.id]);
  }

  void _store(OverlayStrokeFinished e) {
    if (e.points.isEmpty) return;
    final first = e.points.first;
    final i = pickRegionIndex(_regionsPx, Offset(first.x, first.y));
    if (i == null || i >= _regionLayers.length) return;
    final layer = _regionLayers[i];
    final g = layer.overlayGeometry();
    if (g == null) return;
    layer.acceptOverlayStroke(
      overlayPointsToView(e.points, dpr: g.dpr, layerOriginLogical: g.origin, shapePressure: session.shapePressure),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    session.removeListener(sync);
    final host = InkOverlayHost.instance;
    host.availability.removeListener(sync);
    InkOverlayHost.nativeEnabled.removeListener(sync);
    host.ownership.removeListener(sync);
    _sub?.cancel();
    host.release(this);
  }
}

/// Oturumun şimdiki aracına göre Ink fırçası; null = yerel katman çizmesin (mod `off`):
/// silgi, kement, soru seç, şekil araçları, şekil düzeltme (basılı tutma Flutter'da tanınır) ve
/// kalem girişi kapalıyken (metin/foto/alt sayfa araçları).
OverlayBrush? desiredOverlayBrush(PdfInkSession s, double dpr) {
  if (s.inkInputOff || s.lassoMode || s.selecting || s.shapeTool != null) return null;
  return overlayBrushFor(s.brush, dpr);
}
