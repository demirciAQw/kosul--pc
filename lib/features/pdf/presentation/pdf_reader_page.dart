import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart' as r; // pdfrx YALNIZ data/ ve bu dosyada

import '../../../app/routes.dart';
import '../../ink/domain/ink_models.dart';
import '../../question_bank/domain/question_card.dart';
import '../domain/pdf_engine.dart' show PdfBox, PdfPageSize;
import '../domain/question_box.dart';
import 'pdf_box_overlay.dart';
import 'pdf_question_panel.dart';
import '../../../core/di/core_providers.dart';
import '../pdf_providers.dart';
import 'pdf_ink_input.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

/// PDF okuyucu: dikey kaydırma, parmakla yakınlaştırma, küçük resim şeridi,
/// sayfa göstergesi ve her sayfanın üstünde kalem katmanı.
class PdfReaderPage extends ConsumerWidget {
  const PdfReaderPage({super.key, required this.documentId, this.initialPage, this.highlight, this.questionId});
  final String documentId;

  /// Vurgulanan kutunun soru kartı: varsa "Çöz" düğmesi görünür.
  final String? questionId;

  /// Soru kartından gelince: açılacak sayfa (0'dan) ve vurgulanacak kutu.
  final int? initialPage;
  final PdfBox? highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(pdfOpenInfoProvider(documentId));
    return info.when(
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('PDF açılamadı: $e')),
      ),
      data: (i) {
        if (i == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Bu PDF bulunamadı.')),
          );
        }
        if (i.path == null) {
          return Scaffold(
            appBar: AppBar(title: Text(i.record.title)),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Bu PDF\'in dosyası bu cihazda yok. Aynı PDF\'i "PDF ekle" ile içe aktar; çizgilerin yerinde durur.',
                ),
              ),
            ),
          );
        }
        // Bağlantıdan gelen sayfa belgede yoksa başa açılır, kutu yok sayılır.
        final page = validReaderPage(initialPage, i.record.pageCount);
        return PdfReaderView(
          info: i,
          initialPage: page,
          highlight: page == null ? null : highlight,
          questionId: page == null ? null : questionId,
        );
      },
    );
  }
}

const _colors = <int>[
  0xFF1B1B1F,
  0xFF1565C0,
  0xFFC62828,
  0xFF2E7D32,
  0xFFF9A825,
];
const _widths = <double>[2, 4, 8];

class PdfReaderView extends ConsumerStatefulWidget {
  const PdfReaderView({super.key, required this.info, this.initialPage, this.highlight, this.questionId});
  final PdfOpenInfo info;
  final String? questionId;
  final int? initialPage;
  final PdfBox? highlight;

  @override
  ConsumerState<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<PdfReaderView> {
  late final PdfInkSession _session;
  final _viewer = r.PdfViewerController();
  final _page = ValueNotifier<int>(1);
  late final r.PdfDocumentRef _docRef;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _errorSub;
  bool _thumbs = false;
  InkTool _tool = InkTool.pen;
  bool _selecting = false;

  /// Sayfa üstündeki kutular: bekleyen seçim (mavi) ve kart vurgusu (turuncu).
  final _marks = ValueNotifier<List<PdfBoxMark>>(const []);
  ({int page, PdfBox box})? _pending;
  int _color = _colors.first;
  double _width = _widths[1];

  @override
  void initState() {
    super.initState();
    _session = PdfInkSession(
      documentId: widget.info.record.id,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
    );
    _applyBrush();
    _session.onSelectBox = _onBox;
    _page.value = (widget.initialPage ?? 0) + 1;
    final hl = widget.highlight, hp = widget.initialPage;
    if (hl != null && hp != null) _marks.value = [PdfBoxMark(hp, hl, _highlightColor)];
    // Görünüm ve küçük resim şeridi AYNI belgeyi paylaşır (ref anahtarı aynı:
    // PDFium belgesi bir kez açılır).
    _docRef = r.PdfDocumentRefFile(
      widget.info.path!,
      useProgressiveLoading: false,
    );
    _errorSub = _session.errors.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    // Uygulama arka plana giderken (süreç öldürülebilir) bekleyen kayıtları bitir.
    _lifecycle = AppLifecycleListener(
      onInactive: _flush,
      onHide: _flush,
      onPause: _flush,
    );
  }

  void _flush() => unawaited(_session.flush());

  @override
  void dispose() {
    _lifecycle.dispose();
    _errorSub?.cancel();
    _page.dispose();
    _marks.dispose();
    // Kuyruk bitmeden oturum kapanmasın: kayıtlar tamamlanınca kapat.
    unawaited(_session.flush().whenComplete(_session.dispose));
    super.dispose();
  }

  void _applyBrush() {
    final w = _tool == InkTool.highlighter ? _width * 4 : _width;
    _session.setBrush(InkBrush(tool: _tool, color: _color, width: w));
  }

  static const _selectColor = Color(0xFF1565C0);
  static const _highlightColor = Color(0xFFEF6C00);

  void _setSelecting(bool v) {
    setState(() {
      _selecting = v;
      if (!v) _clearPending();
    });
    _session.setSelecting(v);
  }

  void _clearPending() {
    _pending = null;
    _marks.value = [for (final m in _marks.value) if (m.color != _selectColor) m];
  }

  /// Kalemle çizilen kutu bırakıldı: normalize et, çok küçükse reddet.
  void _onBox(int page, double x1, double y1, double x2, double y2, double pw, double ph) {
    if (!mounted) return;
    final box = normalizeQuestionBox(x1, y1, x2, y2, PdfPageSize(pw, ph));
    if (box == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Kutu çok küçük. Soruyu saran daha büyük bir kutu çiz.')));
      return;
    }
    setState(() => _pending = (page: page, box: box));
    _marks.value = [
      for (final m in _marks.value)
        if (m.color != _selectColor) m,
      PdfBoxMark(page, box, _selectColor),
    ];
  }

  void _onSaved(QuestionCard card) {
    setState(_clearPending);
    // Yönlendirici şimdi alınır: eylem, sayfadan çıkıldıktan sonra basılırsa
    // `context` ölü olur ve GoRouter.of(context) fırlatır.
    final router = GoRouter.maybeOf(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(savedQuestionSnackBar(router, widget.info.record.id, card.id));
  }

  List<Widget> _overlays(BuildContext context, Rect rect, r.PdfPage page) => [
    PdfPageBoxOverlay(
      key: ValueKey('box-${page.pageNumber}'),
      page: page.pageNumber - 1,
      pageWidth: page.width,
      pageHeight: page.height,
      marks: _marks,
    ),
    PdfPageInkLayer(
      key: ValueKey('ink-${page.pageNumber}'),
      session: _session,
      page: page.pageNumber - 1,
      pageWidth: page.width,
      pageHeight: page.height,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final rec = widget.info.record;
    return Scaffold(
      appBar: AppBar(
        title: Text(rec.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('pdf-thumbs-toggle'),
            tooltip: 'Küçük resimler',
            icon: Icon(
              _thumbs ? Icons.view_sidebar : Icons.view_sidebar_outlined,
            ),
            onPressed: () => setState(() => _thumbs = !_thumbs),
          ),
        ],
      ),
      body: Column(
        children: [
          PdfInkToolbar(
            session: _session,
            tool: _tool,
            selecting: _selecting,
            onSelect: () => _setSelecting(!_selecting),
            color: _color,
            width: _width,
            onTool: (t) {
              if (_selecting) _setSelecting(false);
              setState(() {
                _tool = t;
                _applyBrush();
              });
            },
            onColor: (c) => setState(() {
              _color = c;
              _applyBrush();
            }),
            onWidth: (w) => setState(() {
              _width = w;
              _applyBrush();
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                if (_thumbs)
                  _ThumbStrip(
                    docRef: _docRef,
                    current: _page,
                    onTap: (n) => _viewer.goToPage(pageNumber: n),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      PdfInkInput(
                        session: _session,
                        // Kalem çizerken/havada sayfa üstündeyken görünüm kaymaz
                        // ve yakınlaşmaz (avuç kalemden önce değse bile).
                        // Yalnız değer değişince yeniden kurulur; belge yeniden
                        // açılmaz (yalnız yerleşim bayrağı).
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _session.viewerLocked,
                          builder: (context, locked, _) => r.PdfViewer(
                            _docRef,
                            controller: _viewer,
                            initialPageNumber: (widget.initialPage ?? 0) + 1,
                            params: r.PdfViewerParams(
                              panEnabled: !locked,
                              scaleEnabled: !locked,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              pageOverlaysBuilder: _overlays,
                              onPageChanged: (n) {
                                if (n != null) _page.value = n;
                              },
                            ),
                          ),
                        ),
                      ),
                      if (_pending != null)
                        Positioned(
                          bottom: 48,
                          left: 12,
                          right: 12,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: PdfQuestionPanel(
                                key: ValueKey(_pending),
                                info: widget.info,
                                page: _pending!.page,
                                box: _pending!.box,
                                onSaved: _onSaved,
                                onCancel: () => setState(_clearPending),
                              ),
                            ),
                          ),
                        ),
                      if (widget.questionId != null && widget.highlight != null)
                        Positioned(
                          right: 16,
                          bottom: 56,
                          child: FloatingActionButton.extended(
                            key: const Key('pdf-solve-button'),
                            heroTag: null,
                            onPressed: () =>
                                context.push(AppRoutes.pdfSolve(widget.info.record.id, widget.questionId!)),
                            icon: const Icon(Icons.draw_outlined),
                            label: const Text('Çöz'),
                          ),
                        ),
                      Positioned(
                        bottom: 12,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: Center(
                            child: ValueListenableBuilder<int>(
                              valueListenable: _page,
                              builder: (_, n, _) => Container(
                                key: const Key('pdf-page-indicator'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  '$n / ${rec.pageCount}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kalem araç çubuğu (okuyucu ve çözüm ekranı ortak). [onSelect] null ise
/// "Soru seç" düğmesi gösterilmez.
class PdfInkToolbar extends StatelessWidget {
  const PdfInkToolbar({
    super.key,
    required this.session,
    required this.tool,
    this.selecting = false,
    this.onSelect,
    required this.color,
    required this.width,
    required this.onTool,
    required this.onColor,
    required this.onWidth,
  });

  final PdfInkSession session;
  final InkTool tool;
  final bool selecting;
  final VoidCallback? onSelect;
  final int color;
  final double width;
  final ValueChanged<InkTool> onTool;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget toolBtn(InkTool t, IconData icon, String tip) => IconButton(
      key: Key('pdf-tool-${t.name}'),
      tooltip: tip,
      isSelected: !selecting && tool == t,
      icon: Icon(icon),
      onPressed: () => onTool(t),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const SizedBox(width: 8),
          toolBtn(InkTool.pen, Icons.edit_outlined, 'Kalem'),
          toolBtn(InkTool.highlighter, Icons.border_color_outlined, 'Fosforlu'),
          toolBtn(InkTool.eraser, Icons.auto_fix_normal_outlined, 'Silgi'),
          if (onSelect != null)
          IconButton(
            key: const Key('pdf-tool-select'),
            tooltip: 'Soru seç',
            isSelected: selecting,
            icon: const Icon(Icons.crop_free),
            onPressed: onSelect,
          ),
          const SizedBox(width: 8),
          for (final c in _colors)
            InkWell(
              key: Key('pdf-color-${c.toRadixString(16)}'),
              customBorder: const CircleBorder(),
              onTap: () => onColor(c),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: Color(c),
                  child: color == c
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
              ),
            ),
          const SizedBox(width: 8),
          for (final w in _widths)
            InkWell(
              key: Key('pdf-width-${w.toInt()}'),
              customBorder: const CircleBorder(),
              onTap: () => onWidth(w),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Container(
                  width: 8 + w * 2,
                  height: 8 + w * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: width == w ? cs.primary : cs.outline,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 8),
          ListenableBuilder(
            listenable: session,
            builder: (_, _) => Row(
              children: [
                IconButton(
                  key: const Key('pdf-undo'),
                  tooltip: 'Geri al',
                  icon: const Icon(Icons.undo_rounded),
                  onPressed: session.canUndo && !session.erasing
                      ? session.undo
                      : null,
                ),
                IconButton(
                  key: const Key('pdf-redo'),
                  tooltip: 'Yinele',
                  icon: const Icon(Icons.redo_rounded),
                  onPressed: session.canRedo && !session.erasing
                      ? session.redo
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbStrip extends StatelessWidget {
  const _ThumbStrip({
    required this.docRef,
    required this.current,
    required this.onTap,
  });
  final r.PdfDocumentRef docRef;
  final ValueNotifier<int> current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: const Key('pdf-thumb-strip'),
      width: 108,
      child: r.PdfDocumentViewBuilder(
        documentRef: docRef,
        builder: (context, doc) {
          if (doc == null) return const SizedBox.shrink();
          return ValueListenableBuilder<int>(
            valueListenable: current,
            builder: (_, cur, _) => ListView.builder(
              itemCount: doc.pages.length,
              itemBuilder: (_, i) => InkWell(
                onTap: () => onTap(i + 1),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: cur == i + 1
                                ? cs.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: AspectRatio(
                          aspectRatio: doc.pages[i].width / doc.pages[i].height,
                          child: r.PdfPageView(
                            document: doc,
                            pageNumber: i + 1,
                            maximumDpi: 60,
                          ),
                        ),
                      ),
                      Text(
                        '${i + 1}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "Soru kaydedildi" ileti çubuğu; "Çöz" eylemi önceden alınmış [router] ile
/// çalışır (sayfadan çıkılmış olsa da `context` kullanılmaz).
@visibleForTesting
SnackBar savedQuestionSnackBar(GoRouter? router, String documentId, String cardId) => SnackBar(
      content: const Text('Soru kaydedildi.'),
      action: SnackBarAction(
        label: 'Çöz',
        onPressed: () => router?.push(AppRoutes.pdfSolve(documentId, cardId)),
      ),
    );
