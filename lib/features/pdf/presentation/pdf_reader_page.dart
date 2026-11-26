import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart' as r; // pdfrx YALNIZ data/ ve bu dosyada

import '../../../app/routes.dart';
import '../../../app/tablet.dart';
import '../../notes/data/note_tool_prefs_store.dart';
import '../../notes/presentation/note_tool_dock.dart';
import '../../notes/presentation/note_tool_settings.dart';
import '../../question_bank/domain/question_card.dart';
import '../domain/pdf_engine.dart' show PdfBox, PdfPageSize;
import '../domain/question_box.dart';
import '../domain/book_analysis.dart';
import 'analysis_overlay.dart';
import '../../ink/presentation/ink_mask.dart';
import '../../notes/presentation/tool_rail.dart';
import '../data/pdf_last_page_store.dart';
import 'pdf_analysis_panel.dart';
import 'pdf_box_overlay.dart';
import 'pdf_question_panel.dart';
import '../../../core/di/core_providers.dart';
import '../pdf_providers.dart';
import 'pdf_ink_input.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';
import '../pdf_layers_providers.dart';
import 'layer_buttons.dart';
import 'layer_page_overlay.dart';
import 'layer_settings_sheet.dart';
import 'pdf_layer_state.dart';

/// PDF okuyucu: dikey kaydırma, parmakla yakınlaştırma, küçük resim şeridi,
/// sayfa göstergesi ve her sayfanın üstünde kalem katmanı.
class PdfReaderPage extends ConsumerWidget {
  const PdfReaderPage({
    super.key,
    required this.documentId,
    this.initialPage,
    this.highlight,
    this.questionId,
    this.analysis = false,
  });
  final String documentId;

  /// Analiz modu açık başlar (`?analiz=1`); yalnız kitaba bağlı PDF'te anlamlı.
  final bool analysis;

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
        final linked = validReaderPage(initialPage, i.record.pageCount);
        // Bağlantı yoksa kapatıldığı son sayfadan açılır.
        final page = startPage(linked: linked, saved: i.lastPage, pageCount: i.record.pageCount);
        return PdfReaderView(
          info: i,
          initialPage: page,
          highlight: linked == null ? null : highlight,
          questionId: linked == null ? null : questionId,
          analysis: analysis,
        );
      },
    );
  }
}

class PdfReaderView extends ConsumerStatefulWidget {
  const PdfReaderView({
    super.key,
    required this.info,
    this.initialPage,
    this.highlight,
    this.questionId,
    this.analysis = false,
  });
  final PdfOpenInfo info;
  final bool analysis;
  final String? questionId;
  final int? initialPage;
  final PdfBox? highlight;

  @override
  ConsumerState<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<PdfReaderView> {
  late final PdfInkSession _session;
  final _viewer = r.PdfViewerController();
  late final PdfLayerState _layerState; // katmanlar: tek durum kaynağı
  final _page = ValueNotifier<int>(1);

  /// Son sayfa kaydı: sayfa değişince 500 ms bekleyip yazar (kaydırırken her kareye yazılmaz).
  late final PdfLastPageStore _lastPageStore;
  Timer? _lastPageTimer;
  late int _lastPageSaved; // 1'den
  late final r.PdfDocumentRef _docRef;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _errorSub;
  bool _thumbs = false;
  bool _selecting = false;
  final _tools = NoteToolSettings();
  late final NoteToolPrefsBinding _prefs;

  /// Sayfa üstündeki kutular: bekleyen seçim (mavi) ve kart vurgusu (turuncu).
  final _marks = ValueNotifier<List<PdfBoxMark>>(const []);
  ({int page, PdfBox box})? _pending;

  /// Analiz modu: kapalıyken işaretler çizilmez, veri okunmaz.
  late bool _analysisOn;
  bool _panelOpen = false;
  AnalysisFilter _filter = AnalysisFilter.wrong;
  final _analysisData = ValueNotifier<BookAnalysis?>(null);

  @override
  void initState() {
    super.initState();
    _layerState = ref.read(pdfLayerStateProvider(widget.info.record.id));
    _session = PdfInkSession(
      documentId: widget.info.record.id,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
      penKinds: true,
      allLayers: true, // tüm katmanlar yüklenir; yalnız AKTİF katman görünür ve yazar
      layer: _layerState.activeKey,
      strokeFilter: _layerState.accepts, // soru katmanında bölge dışı çizilmez
    );
    // Geriye dönük avuç reddi: avuç kalemden önce değip sayfayı oynattıysa geri al.
    _session.readViewMatrix = () => _viewer.isReady ? _viewer.value.clone() : null;
    _session.writeViewMatrix = (m) {
      if (_viewer.isReady) _viewer.value = (m as Matrix4).clone();
    };
    _tools.apply(_session);
    _tools.addListener(_applyTools);
    // Zum/kaydırma sırasında çizgiler hafif çizilir (tekerlek/eylemsizlik dahil).
    _viewer.addListener(_session.zoomInteraction.pulse);
    // Kalem boyutu ve yuva konumu defterle AYNI kalıcı ayardır.
    _prefs = NoteToolPrefsBinding(ref.read(noteToolPrefsStoreProvider), _tools);
    _session.onSelectBox = _onBox;
    _layerState.addListener(_onLayerState);
    unawaited(_layerState.load());
    _analysisOn = widget.analysis && widget.info.record.bookId != null;
    _panelOpen = _analysisOn;
    _page.value = (widget.initialPage ?? 0) + 1;
    _lastPageStore = ref.read(pdfLastPageStoreProvider);
    _lastPageSaved = _page.value;
    final hl = widget.highlight, hp = widget.initialPage;
    if (hl != null && hp != null)
      _marks.value = [PdfBoxMark(hp, hl, _highlightColor)];
    // Görünüm ve küçük resim şeridi AYNI belgeyi paylaşır (ref anahtarı aynı:
    // PDFium belgesi bir kez açılır).
    _docRef = r.PdfDocumentRefFile(
      widget.info.path!,
      // Büyük PDF'te sayfa boyutları tek tek, açılış sayfası öncelikli yüklenir (hemen açılır).
      // Küçük belgede hepsi baştan: sayfa geçişlerinde tahmini boyutla düzen kaymaz.
      useProgressiveLoading: widget.info.record.pageCount > 150,
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

  void _flush() {
    _saveLastPageNow();
    unawaited(_session.flush());
  }

  void _onPageChanged(int n) {
    _page.value = n;
    _lastPageTimer?.cancel();
    if (n == _lastPageSaved) return;
    _lastPageTimer = Timer(const Duration(milliseconds: 500), _saveLastPageNow);
  }

  void _saveLastPageNow() {
    _lastPageTimer?.cancel();
    final n = _page.value;
    if (n == _lastPageSaved) return;
    _lastPageSaved = n;
    unawaited(_lastPageStore.save(widget.info.record.id, n - 1));
  }

  @override
  void dispose() {
    _saveLastPageNow();
    _viewer.removeListener(_session.zoomInteraction.pulse);
    _tools.removeListener(_applyTools);
    _prefs.dispose();
    _tools.dispose();
    _lifecycle.dispose();
    _errorSub?.cancel();
    _page.dispose();
    _marks.dispose();
    _analysisData.dispose();
    _layerState.removeListener(_onLayerState);
    _layerState.setSelecting(false);
    _bannerMessenger?.hideCurrentMaterialBanner();
    unawaited(_layerState.flushNotes());
    // Kuyruk bitmeden oturum kapanmasın: kayıtlar tamamlanınca kapat.
    unawaited(_session.flush().whenComplete(_session.dispose));
    super.dispose();
  }

  void _applyTools() => _tools.apply(_session);

  static const _selectColor = Color(0xFF1565C0);
  static const _highlightColor = Color(0xFFEF6C00);

  void _setSelecting(bool v) {
    setState(() {
      _selecting = v;
      if (!v) _clearPending();
    });
    if (v) _layerState.setSelecting(false);
    _session.setSelecting(v);
  }

  bool _pickShown = false;
  ScaffoldMessengerState? _bannerMessenger;

  /// Katman durumu değişti: aktif katmanı oturuma ver; bölge seçim modunu aç/kapat.
  void _onLayerState() {
    if (!mounted) return;
    _session.layer = _layerState.activeKey;
    final sel = _layerState.selecting;
    if (sel == _pickShown) return;
    _pickShown = sel;
    final m = _bannerMessenger = ScaffoldMessenger.of(context);
    if (sel) {
      if (_selecting) setState(() => _selecting = false);
      _clearPending();
      _session.setSelecting(true);
      m
        ..hideCurrentMaterialBanner()
        ..showMaterialBanner(
          MaterialBanner(
            key: const Key('layers-pick-banner'),
            content: const Text('Soru katmanı için bölgeyi sürükleyerek seç.'),
            actions: [
              TextButton(
                key: const Key('layers-pick-cancel'),
                onPressed: () => _layerState.setSelecting(false),
                child: const Text('Vazgeç'),
              ),
            ],
          ),
        );
    } else {
      if (!_selecting) _session.setSelecting(false);
      m.hideCurrentMaterialBanner();
    }
  }

  void _openLayerSettings() => showPdfLayerSettings(context, _layerState, _tools);

  void _clearPending() {
    _pending = null;
    _marks.value = [
      for (final m in _marks.value)
        if (m.color != _selectColor) m,
    ];
  }

  /// Kalemle çizilen kutu bırakıldı: normalize et, çok küçükse reddet.
  void _onBox(
    int page,
    double x1,
    double y1,
    double x2,
    double y2,
    double pw,
    double ph,
  ) {
    if (!mounted) return;
    final box = normalizeQuestionBox(x1, y1, x2, y2, PdfPageSize(pw, ph));
    if (_layerState.selecting) {
      // Soru katmanı bölgesi seçiliyor (soru kaydı değil).
      if (box == null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Bölge çok küçük. Daha büyük bir dikdörtgen çiz.')));
        return;
      }
      _layerState.setSelecting(false);
      unawaited(_layerState.addQuestion(page, box));
      return;
    }
    if (box == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Kutu çok küçük. Soruyu saran daha büyük bir kutu çiz.',
            ),
          ),
        );
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
      ..showSnackBar(
        savedQuestionSnackBar(router, widget.info.record.id, card.id),
      );
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
    PdfPageLayerOverlay(
      key: ValueKey('layers-${page.pageNumber}'),
      state: _layerState,
      page: page.pageNumber - 1,
      pageWidth: page.width,
      pageHeight: page.height,
      onOpenWindow: (l) => context.push(AppRoutes.pdfLayerWindow(widget.info.record.id, l.id)),
    ),
    AnalysisPageOverlay(
      key: ValueKey('analysis-${page.pageNumber}'),
      page: page.pageNumber - 1,
      pageWidth: page.width,
      pageHeight: page.height,
      analysis: _analysisData,
      onOpenPanel: () => setState(() => _panelOpen = true),
    ),
  ];

  void _goToPage(int pdfPage) => _viewer.goToPage(pageNumber: pdfPage + 1);

  /// Sonraki/önceki yanlış sayfasına git (yoksa ileti).
  void _stepMistake(BookAnalysis a, {required bool forward}) {
    final cur = _page.value - 1;
    final to = forward ? a.nextMistakePage(cur, _filter) : a.previousMistakePage(cur, _filter);
    if (to == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(forward ? 'Sonrası yok.' : 'Öncesi yok.')));
      return;
    }
    _goToPage(to);
  }

  /// Analiz katmanı: düğmeler ve panel. Mod kapalıyken hiçbir şey çizmez.
  Widget _analysisLayer(BookAnalysis? a, Map<int, int> badges) {
    if (!_analysisOn || a == null) return const SizedBox.shrink();
    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 8,
          child: InkMask(
           child: Material(
            key: const Key('analysis-bar'),
            elevation: 3,
            borderRadius: BorderRadius.circular(20),
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('analysis-prev'),
                  tooltip: 'Önceki yanlış',
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: () => _stepMistake(a, forward: false),
                ),
                Text('${badges.values.fold<int>(0, (x, y) => x + y)} yanlış/boş'),
                IconButton(
                  key: const Key('analysis-next'),
                  tooltip: 'Sonraki yanlış',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => _stepMistake(a, forward: true),
                ),
                IconButton(
                  key: const Key('analysis-panel-toggle'),
                  tooltip: 'Yanlışlarım',
                  icon: Icon(_panelOpen ? Icons.list_alt : Icons.list_alt_outlined),
                  onPressed: () => setState(() => _panelOpen = !_panelOpen),
                ),
              ],
            ),
          ),
          ),
        ),
        if (_panelOpen)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: analysisPanelWidth(MediaQuery.sizeOf(context).width),
            child: PdfAnalysisPanel(
              analysis: a,
              filter: _filter,
              onFilter: (f) => setState(() => _filter = f),
              onGo: (i) => _goToPage(i.pdfPage!),
              onClose: () => setState(() => _panelOpen = false),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.info.record;
    // Veri yalnız mod açıkken okunur (kapalıyken kart akışı açılmaz).
    final analysis = _analysisOn ? ref.watch(bookAnalysisProvider(rec.id)).value : null;
    // Rozetler bir kez hesaplanır (kaynak listeyi her çağrıda tarar).
    final badges = analysis?.mistakeBadges ?? const <int, int>{};
    if (_analysisData.value != analysis) {
      final a = analysis;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _analysisData.value = _analysisOn ? a : null;
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(rec.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (rec.bookId != null)
            IconButton(
              key: const Key('pdf-analysis-toggle'),
              tooltip: 'Analiz modu',
              icon: Icon(_analysisOn ? Icons.fact_check : Icons.fact_check_outlined),
              onPressed: () => setState(() {
                _analysisOn = !_analysisOn;
                _panelOpen = _analysisOn;
                if (!_analysisOn) _analysisData.value = null;
              }),
            ),
          PdfLayerBarButtons(
            state: _layerState,
            onAddFull: () => _layerState.addByPreference(),
            onSettings: _openLayerSettings,
          ),
          const FocusModeButton(),
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
          Expanded(
            child: Row(
              children: [
                if (_thumbs)
                  _ThumbStrip(
                    docRef: _docRef,
                    current: _page,
                    badges: badges,
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
                              // Pratikte sınırsız zum; bellek: döşeme önbelleği 64 MB,
                              // tek geçiş çözünürlüğü 150 dpi (üstü kademeli çizilir).
                              sizeDelegateProvider: const r.PdfViewerSizeDelegateProviderLegacy(
                                maxScale: 1000,
                                onePassRenderingScaleThreshold: 150 / 72,
                              ),
                              maxImageBytesCachedOnMemory: 64 * 1024 * 1024,
                              onInteractionStart: (_) => _session.zoomInteraction.begin(),
                              onInteractionEnd: (_) => _session.zoomInteraction.end(),
                              panEnabled: !locked,
                              scaleEnabled: !locked,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              pageOverlaysBuilder: _overlays,
                              onPageChanged: (n) {
                                if (n != null) _onPageChanged(n);
                              },
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: ListenableBuilder(
                          listenable: _tools,
                          builder: (context, _) {
                            // Alttaki yuva sayfa göstergesini, "Çöz"ü ve soru panelini örtmesin.
                            final pos = _tools.dockPosition;
                            final lift = pos == DockPosition.bottom
                                ? 84.0
                                : 0.0;
                            final liftRight = pos == DockPosition.right
                                ? 84.0
                                : 0.0;
                            return Stack(
                              children: [
                                if (_pending != null)
                                  Positioned(
                                    bottom: 48 + lift,
                                    left: 12,
                                    right: 12,
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 560,
                                        ),
                                        child: InkMask(
                                          child: PdfQuestionPanel(
                                            key: ValueKey(_pending),
                                            info: widget.info,
                                            page: _pending!.page,
                                            box: _pending!.box,
                                            onSaved: _onSaved,
                                            onCancel: () =>
                                                setState(_clearPending),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (widget.questionId != null &&
                                    widget.highlight != null)
                                  Positioned(
                                    right: 16 + liftRight,
                                    bottom: 56 + lift,
                                    child: InkMask(
                                      child: FloatingActionButton.extended(
                                        key: const Key('pdf-solve-button'),
                                        heroTag: null,
                                        onPressed: () => context.push(
                                          AppRoutes.pdfSolve(
                                            widget.info.record.id,
                                            widget.questionId!,
                                          ),
                                        ),
                                        icon: const Icon(Icons.draw_outlined),
                                        label: const Text('Çöz'),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  bottom: 12 + lift,
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
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          child: Text(
                                            '$n / ${rec.pageCount}'
                                            '${(badges[n - 1] ?? 0) > 0 ? ' · ${badges[n - 1]} yanlış' : ''}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      _analysisLayer(analysis, badges),
                      // Analiz paneli açıkken yuva panelin altında kalmasın: yuvanın
                      // alanı panelin soluna daralır (yuva her zaman panelden sonra çizilir).
                      ListenableBuilder(
                        listenable: _tools,
                        builder: (context, _) => Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          right: toolDockRightInset(
                            panelOpen: _analysisOn && _panelOpen && analysis != null,
                            screenWidth: MediaQuery.sizeOf(context).width,
                            position: _tools.dockPosition,
                          ),
                          child: Stack(
                            children: [
                              if (_tools.rail)
                                ToolRail(
                                  tools: _tools,
                                  session: _session,
                                  selecting: _selecting,
                                  onSelect: () => _setSelecting(!_selecting),
                                  small: TabletFocus.maybeOf(context)?.value ?? false,
                                )
                              else
                                FloatingToolDock(
                                  tools: _tools,
                                  session: _session,
                                  selecting: _selecting,
                                  onSelect: () => _setSelecting(!_selecting),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // Sol üst: katman gezinme hapı; altında yüzen yuvarlak bölge düğmesi.
                      Positioned(top: 8, left: 8, child: InkMask(child: LayerNavPill(state: _layerState))),
                      Positioned.fill(child: RegionPickButton(state: _layerState)),
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

class _ThumbStrip extends StatelessWidget {
  const _ThumbStrip({
    required this.docRef,
    required this.current,
    required this.onTap,
    this.badges = const {},
  });

  /// PDF sayfası (0'dan) → yanlış sayısı (analiz modu rozeti).
  final Map<int, int> badges;
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${i + 1}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          if ((badges[i] ?? 0) > 0) ...[
                            const SizedBox(width: 4),
                            Container(
                              key: Key('analysis-badge-$i'),
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              decoration: BoxDecoration(
                                color: analysisColor(QuestionStatus.wrong),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${badges[i]}',
                                style: const TextStyle(color: Colors.white, fontSize: 10),
                              ),
                            ),
                          ],
                        ],
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
SnackBar savedQuestionSnackBar(
  GoRouter? router,
  String documentId,
  String cardId,
) => SnackBar(
  content: const Text('Soru kaydedildi.'),
  action: SnackBarAction(
    label: 'Çöz',
    onPressed: () => router?.push(AppRoutes.pdfSolve(documentId, cardId)),
  ),
);

/// Analiz panelinin genişliği (ekranın %80'i, en çok 320).
@visibleForTesting
double analysisPanelWidth(double screenWidth) => (screenWidth * 0.8).clamp(0.0, 320.0);

/// Analiz paneli açıkken araç yuvasının sağdan bırakacağı boşluk (panel genişliği).
/// Sağ yuva her zaman panelin soluna alınır; üst/alt yuvada, panelden kalan genişlik
/// yuva için yeterliyse (>= 520) alan daraltılır, değilse (telefon) yuva olduğu gibi kalır.
@visibleForTesting
double toolDockRightInset({required bool panelOpen, required double screenWidth, required DockPosition position}) {
  if (!panelOpen) return 0;
  final w = analysisPanelWidth(screenWidth);
  if (position == DockPosition.right) return w;
  return screenWidth - w >= 520 ? w : 0;
}
