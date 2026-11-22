import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../pdf/pdf_providers.dart';
import '../../pdf/presentation/pdf_ink_input.dart';
import '../../pdf/presentation/pdf_ink_session.dart';
import '../../pdf/presentation/pdf_page_ink_layer.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_template.dart';
import '../../../app/tablet.dart';
import 'note_tool_dock.dart';
import 'note_tool_settings.dart';
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
  });

  /// Zum aralığı (1 = sayfa genişliğe sığmış): 0.1 sayfayı küçük görmek, 30 ayrıntı için.
  static const minZoom = 0.1;
  static const maxZoom = 30.0;

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

class NotePageEditorState extends ConsumerState<NotePageEditor> {
  late final PdfInkSession session;
  final _transform = TransformationController();
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _errorSub;

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
    widget.tools.apply(session);
    _dockTopSeen = widget.tools.dockAtTop;
    widget.tools.addListener(_applyTools);
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

  bool _dockTopSeen = false;

  void _applyTools() {
    widget.tools.apply(session);
    // Yuva alta/üste geçince yerleşim yenilenir (diğer ayar değişimlerinde gerekmez).
    if (_dockTopSeen != widget.tools.dockAtTop && mounted) {
      setState(() => _dockTopSeen = widget.tools.dockAtTop);
    }
  }

  /// Bekleyen kayıtların bitmesini bekler (sayfa çoğaltma, kapanış).
  Future<void> flush() => session.flush();

  @override
  void didUpdateWidget(NotePageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tools != widget.tools) {
      oldWidget.tools.removeListener(_applyTools);
      widget.tools.addListener(_applyTools);
      _applyTools();
    }
  }

  @override
  void dispose() {
    widget.tools.removeListener(_applyTools);
    _lifecycle.dispose();
    _errorSub?.cancel();
    _transform.dispose();
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

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final cs = Theme.of(context).colorScheme;
    final focus = TabletFocus.maybeOf(context)?.value ?? false;
    final dockTop = widget.tools.dockAtTop;
    _dockTopSeen = dockTop;
    final viewer = ColoredBox(
      color: cs.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, box) {
          // Sayfa genişliğe TAM oturur (kenar boşluğu yok); yükseklik sayfa oranından.
          // Kaydırma/zum matrisi ekran içindir, çizgi koordinatı (not koordinatı) etkilenmez.
          final w = box.maxWidth.isFinite ? box.maxWidth : page.width;
          final h = w * page.height / page.width;
          return Stack(
            children: [
              GestureDetector(
                // Kalemin çift dokunuşu sığdırmasın: yalnız parmak/fare.
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                },
                onDoubleTap: toggleFit,
                child: PdfInkInput(
                  session: session,
                  stylusOnlyOverride: widget.stylusOnlyOverride,
                  // Kalem çizerken / sayfa üstünde havadayken görünüm kaymaz ve yakınlaşmaz
                  // (avuç kalemden önce değse bile).
                  child: ValueListenableBuilder<bool>(
                    valueListenable: session.viewerLocked,
                    builder: (context, locked, _) => InteractiveViewer(
                      transformationController: _transform,
                      panEnabled: !locked,
                      scaleEnabled: !locked,
                      constrained: false,
                      // Sayfa kenarda takılmaz; kaybolursa "sığdır" geri getirir.
                      boundaryMargin: const EdgeInsets.all(double.infinity),
                      minScale: NotePageEditor.minZoom,
                      maxScale: NotePageEditor.maxZoom,
                      child: SizedBox(
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
                                    template: page.template,
                                    background: page.background,
                                    pageWidth: page.width,
                                    pageHeight: page.height,
                                    spacingFactor: widget.spacing,
                                  ),
                                ),
                              ),
                              PdfPageInkLayer(
                                key: const Key('note-page-ink'),
                                session: session,
                                page: 0,
                                pageWidth: page.width,
                                pageHeight: page.height,
                              ),
                            ],
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
                right: 8,
                top: dockTop ? null : 8,
                bottom: dockTop ? 8 + MediaQuery.paddingOf(context).bottom : null,
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
              Positioned.fill(
                child: Align(
                  alignment: dockTop ? Alignment.topCenter : Alignment.bottomCenter,
                  child: Padding(
                    // Telefonda (tablet çerçevesi yokken) yuva alttaki sistem
                    // çubuğunun/jest alanının altında kalmasın.
                    padding: EdgeInsets.fromLTRB(
                      10,
                      10,
                      10,
                      10 + (dockTop ? 0 : MediaQuery.paddingOf(context).bottom),
                    ),
                    child: NoteToolDock(
                      tools: widget.tools,
                      session: session,
                      small: focus,
                      page: PageStyleControl(
                        template: page.template,
                        background: page.background,
                        spacing: widget.spacing,
                        onTemplate: widget.onTemplate,
                        onTemplateAll: widget.onTemplateAll,
                        onBackground: widget.onBackground,
                        onSpacing: widget.onSpacing,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return viewer;
  }
}
