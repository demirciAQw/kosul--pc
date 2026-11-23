import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart' show PdfBox, PdfPageSize;
import '../domain/question_box.dart';
import 'layer_overlay.dart';
import 'pdf_layer_editor.dart';
import 'pdf_layers_panel.dart';
import 'pdf_ink_session.dart';

/// Okuyucunun katman (filigran / örtü) akışı: panel, bölge seçme, düzenleyici.
/// Okuyucu dosyasına yalnız birkaç kanca satırı eklensin diye tek yerde toplandı.
class PdfLayersController {
  PdfLayersController({
    required this.hub,
    required this.session,
    required this.contextOf,
    required this.currentPage,
    this.zoom,
    this.zoomOf,
  });

  final PdfLayersHub hub;
  final PdfInkSession session;
  final BuildContext Function() contextOf;

  /// 0'dan.
  final int Function() currentPage;
  final Listenable? zoom;
  final double Function()? zoomOf;

  ({PdfLayerKind kind, bool secondLayer})? _picking;

  bool get picking => _picking != null;

  /// Sayfa üstündeki katman çizimi (kalemin altında).
  Widget overlay(int page, double pageWidth, double pageHeight) => PdfPageLayerOverlay(
        key: ValueKey('layers-$page'),
        hub: hub,
        page: page,
        pageWidth: pageWidth,
        pageHeight: pageHeight,
        zoom: zoom,
        zoomOf: zoomOf,
      );

  /// Üst çubuk düğmeleri: katman paneli ve (katman varsa) hızlı "Orijinali göster".
  List<Widget> actions() => [
        ValueListenableBuilder<List<PdfPageLayer>>(
          valueListenable: hub.layers,
          builder: (context, layers, _) => ValueListenableBuilder<bool>(
            valueListenable: hub.showOriginal,
            builder: (context, orig, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (layers.isNotEmpty)
                  IconButton(
                    key: const Key('pdf-layers-original'),
                    tooltip: orig ? 'Katmanlı görünüm' : 'Orijinali göster',
                    icon: Icon(orig ? Icons.layers_clear : Icons.layers),
                    onPressed: () => hub.showOriginal.value = !orig,
                  ),
                IconButton(
                  key: const Key('pdf-layers-button'),
                  tooltip: 'Filigran / Katmanlar',
                  icon: Badge(
                    isLabelVisible: layers.isNotEmpty,
                    label: Text('${layers.length}'),
                    child: const Icon(Icons.water_drop_outlined),
                  ),
                  onPressed: openPanel,
                ),
              ],
            ),
          ),
        ),
      ];

  Future<void> openPanel() async {
    final ctx = contextOf();
    if (!ctx.mounted) return;
    final page = currentPage();
    unawaited(hub.refresh()); // eşitlemeyle gelen değişiklikler
    final a = await showPdfLayersPanel(ctx, hub: hub, page: page);
    if (a == null) return;
    switch (a) {
      case EditLayerAction(:final layer):
        await _edit(layer.kind, page, existing: layer);
      case AddWatermarkAction(:final scope, :final secondLayer):
        if (scope == PdfLayerScope.region) {
          _startPick(PdfLayerKind.watermark, secondLayer);
        } else {
          await _edit(PdfLayerKind.watermark, page, allPages: scope == PdfLayerScope.allPages);
        }
      case AddCoverAction():
        _startPick(PdfLayerKind.cover, true);
    }
  }

  Future<void> _edit(PdfLayerKind kind, int page, {PdfBox? box, bool allPages = false, PdfPageLayer? existing}) {
    final ctx = contextOf();
    if (!ctx.mounted) return Future.value();
    return Navigator.of(ctx).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PdfLayerEditorPage(hub: hub, page: page, kind: kind, box: box, allPages: allPages, existing: existing),
    ));
  }

  void _startPick(PdfLayerKind kind, bool secondLayer) {
    final ctx = contextOf();
    _picking = (kind: kind, secondLayer: secondLayer);
    session.setSelecting(true);
    ScaffoldMessenger.of(ctx)
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(MaterialBanner(
        key: const Key('layers-pick-banner'),
        content: const Text('Bölgeyi parmak ya da kalemle sürükleyerek çiz.'),
        actions: [TextButton(key: const Key('layers-pick-cancel'), onPressed: cancelPick, child: const Text('Vazgeç'))],
      ));
  }

  void cancelPick() {
    if (_picking == null) return;
    _picking = null;
    session.setSelecting(false);
    final ctx = contextOf();
    if (ctx.mounted) ScaffoldMessenger.of(ctx).hideCurrentMaterialBanner();
  }

  /// Okuyucunun "kutu çizildi" olayı: bölge seçilirken tüketir (true), yoksa false.
  bool consumeBox(int page, double x1, double y1, double x2, double y2, double pw, double ph) {
    final p = _picking;
    if (p == null) return false;
    final box = normalizeQuestionBox(x1, y1, x2, y2, PdfPageSize(pw, ph));
    final ctx = contextOf();
    if (box == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Bölge çok küçük. Daha büyük bir dikdörtgen çiz.')));
      }
      return true;
    }
    cancelPick();
    _edit(p.kind, page, box: box);
    return true;
  }

  /// Okuyucu kapanırken.
  void dispose() {
    if (_picking != null) {
      _picking = null;
      session.setSelecting(false);
    }
  }
}
