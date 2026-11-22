import 'dart:async';

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
import 'note_ink_toolbar.dart';
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
    this.stylusOnlyOverride,
  });

  final ValueChanged<PageTemplate> onTemplate;
  final ValueChanged<PageTemplate> onTemplateAll;

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
    widget.tools.addListener(_applyTools);
    _errorSub = session.errors.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    // Uygulama arka plana giderken bekleyen kayıtları bitir.
    _lifecycle = AppLifecycleListener(onInactive: flush, onHide: flush, onPause: flush);
  }

  void _applyTools() => widget.tools.apply(session);

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

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final cs = Theme.of(context).colorScheme;
    final viewer = ColoredBox(
      color: cs.surfaceContainerHighest,
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
            minScale: 1,
            maxScale: 6,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AspectRatio(
                  aspectRatio: page.width / page.height,
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
                              template: page.template,
                              background: page.background,
                              pageWidth: page.width,
                              pageHeight: page.height,
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
      ),
    );
    return Column(
      children: [
        NoteInkToolbar(
          tools: widget.tools,
          session: session,
          template: page.template,
          onTemplate: widget.onTemplate,
          onTemplateAll: widget.onTemplateAll,
        ),
        const Divider(height: 1),
        Expanded(child: viewer),
      ],
    );
  }
}
