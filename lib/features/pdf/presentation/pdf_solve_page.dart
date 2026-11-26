import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../notes/data/note_tool_prefs_store.dart';
import '../../notes/presentation/note_tool_dock.dart';
import '../../notes/presentation/note_tool_settings.dart';
import '../../question_bank/question_bank_providers.dart';
import '../domain/pdf_engine.dart';
import '../domain/solve.dart';
import '../pdf_providers.dart';
import 'pdf_ink_input.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';
import 'solve_background.dart';

/// Çözüm ekranı (`/pdf/:id/soru/:questionId`): sorunun PDF kutusu çevresiyle
/// açılır; her çözüm denemesi ayrı katmandır. PDF bu cihazda yoksa kartın
/// önizlemesiyle açılır ([QuestionSolvePage]).
class PdfSolvePage extends ConsumerWidget {
  const PdfSolvePage({
    super.key,
    required this.documentId,
    required this.questionId,
  });
  final String documentId;
  final String questionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget msg(String t) => Scaffold(
      appBar: AppBar(title: const Text('Soru çözümü')),
      body: Center(child: Text(t)),
    );
    final card = ref.watch(questionByIdProvider(questionId));
    final info = ref.watch(pdfOpenInfoProvider(documentId));
    if (card.isLoading || info.isLoading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final c = card.value;
    final i = info.value;
    if (c == null) return msg('Soru bulunamadı.');
    if (!c.hasPdfAnchor || c.pdfDocumentId != documentId)
      return msg('Bu soru bu PDF\'e bağlı değil.');
    if (i == null || i.path == null)
      return QuestionSolvePage(questionId: questionId);
    return PdfSolveView(
      info: i,
      questionId: questionId,
      page: c.pdfPage!,
      box: c.pdfBox!,
    );
  }
}

/// Soru kartı kimliğiyle çözüm ekranı (`/soru/:questionId/coz`): karttan türetir.
/// PDF'li kart + PDF bu cihazda: PDF sayfası (PDF birimi). PDF'li kart, PDF yok:
/// önizleme resmi kutunun yerinde (yine PDF birimi). Fotoğraflı kart: soru
/// fotoğrafı (`photoUnitWidth` uzayı, `QuestionImageOwner`). Resim de yoksa ileti.
class QuestionSolvePage extends ConsumerWidget {
  const QuestionSolvePage({super.key, required this.questionId});
  final String questionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget msg(String t) => Scaffold(
      appBar: AppBar(title: const Text('Soru çözümü')),
      body: Center(child: Text(t)),
    );
    final card = ref.watch(questionByIdProvider(questionId));
    final c = card.value;
    if (card.isLoading)
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    if (c == null) return msg('Soru bulunamadı.');
    if (c.hasPdfAnchor) {
      final info = ref.watch(pdfOpenInfoProvider(c.pdfDocumentId!));
      if (info.isLoading)
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()),
        );
      final i = info.value;
      if (i != null && i.path != null) {
        return PdfSolveView(
          info: i,
          questionId: questionId,
          page: c.pdfPage!,
          box: c.pdfBox!,
        );
      }
    }
    final image = c.questionImage;
    switch (solveSpaceOf(
      hasPdfAnchor: c.hasPdfAnchor,
      hasImage: image != null,
    )) {
      case SolveSpace.none:
        return msg('Bu sorunun görüntüsü yok; çizim için önce fotoğraf ekle.');
      case SolveSpace.pdf:
        return SolveView(
          questionId: questionId,
          loadBackground: (ref) => loadPreviewBackground(
            ref,
            image: image!,
            documentId: c.pdfDocumentId!,
            page: c.pdfPage!,
            box: c.pdfBox!,
          ),
        );
      case SolveSpace.photo:
        return SolveView(
          questionId: questionId,
          loadBackground: (ref) => loadPhotoBackground(ref, questionId, image!),
        );
    }
  }
}

/// PDF sayfasını çizer; arka plan olarak döner.
Future<SolveBackground> loadPdfBackground(
  WidgetRef ref,
  PdfOpenInfo info,
  int pageNo,
  PdfBox box,
) async {
  final engine = ref.read(pdfEngineProvider);
  final doc = await engine.openFile(info.path!);
  try {
    final size = await doc.pageSize(pageNo);
    final region = solveRegion(box, size);
    if (region == null) throw StateError('Soru kutusu geçersiz');
    // Not: motor yalnızca tam sayfa çizer (bölge-only API yok); 3x A4 ~4,4 Mpx
    // (~17 MB) olur ve aşağıdaki döngü maxRenderPixels*0.9 sınırını korur.
    // Bölge genişliği ~1600 piksel olsun (en çok 3x); belge sınırını aşma.
    var scale = math.min<double>(3, 1600 / region.width);
    while (size.width * scale * size.height * scale > maxRenderPixels * 0.9) {
      scale *= 0.8;
    }
    final w = math.max<int>(1, (size.width * scale).round());
    final h = math.max<int>(1, (size.height * scale).round());
    final img = await doc.renderPage(pageNo, width: w, height: h);
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      img.bytes,
      img.width,
      img.height,
      img.format == PdfPixelFormat.bgra
          ? ui.PixelFormat.bgra8888
          : ui.PixelFormat.rgba8888,
      c.complete,
    );
    final decoded = await c.future;
    return PdfPageBackground(
      documentId: info.record.id,
      page: pageNo,
      region: region,
      box: box,
      pageSize: size,
      image: decoded,
      imageScale: img.width / size.width,
    );
  } finally {
    await doc.close();
  }
}

/// Fotoğraflı kart: görüntü tam genişlikte, altında yazı payı.
Future<SolveBackground> loadPhotoBackground(
  WidgetRef ref,
  String questionId,
  String mediaPath,
) async {
  final file = ref.read(mediaStorageProvider).resolve(mediaPath);
  final d = await decodeSolveImage(file);
  final bg = ImageBackground.photo(
    questionId: questionId,
    image: d.image,
    pixelWidth: d.width,
    pixelHeight: d.height,
  );
  if (bg == null) {
    d.image.dispose();
    throw StateError('Görüntü boyutu geçersiz');
  }
  return bg;
}

/// PDF'li kart, PDF bu cihazda yok: önizleme kutunun yerine oturur (PDF birimi).
Future<SolveBackground> loadPreviewBackground(
  WidgetRef ref, {
  required String image,
  required String documentId,
  required int page,
  required PdfBox box,
}) async {
  final file = ref.read(mediaStorageProvider).resolve(image);
  final d = await decodeSolveImage(file);
  final bg = ImageBackground.pdfPreview(
    documentId: documentId,
    page: page,
    box: box,
    image: d.image,
  );
  if (bg == null) {
    d.image.dispose();
    throw StateError('Soru kutusu geçersiz');
  }
  return bg;
}

/// PDF bu cihazdayken çözüm ekranı (PDF sayfası arka plan).
class PdfSolveView extends StatelessWidget {
  const PdfSolveView({
    super.key,
    required this.info,
    required this.questionId,
    required this.page,
    required this.box,
  });
  final PdfOpenInfo info;
  final String questionId;

  /// 0'dan.
  final int page;
  final PdfBox box;

  @override
  Widget build(BuildContext context) => SolveView(
    questionId: questionId,
    loadBackground: (ref) => loadPdfBackground(ref, info, page, box),
  );
}

/// Ortak çözüm ekranı: arka planı [loadBackground] verir (PDF sayfası ya da
/// görüntü); denemeler, eski çözüm, süre, kayıt hepsi için aynıdır.
class SolveView extends ConsumerStatefulWidget {
  const SolveView({
    super.key,
    required this.questionId,
    required this.loadBackground,
  });
  final String questionId;
  final Future<SolveBackground> Function(WidgetRef ref) loadBackground;

  @override
  ConsumerState<SolveView> createState() => _SolveViewState();
}

class _SolveViewState extends ConsumerState<SolveView> {
  final Map<int, PdfInkSession> _sessions = {};
  final List<StreamSubscription<String>> _errorSubs = [];
  late final AppLifecycleListener _lifecycle;

  int? _current;
  bool _showOld = false;
  int? _oldPick;
  double _opacity = defaultOldOpacity;
  bool _compare = false;
  (int, int)? _cmp;

  final _tools = NoteToolSettings();
  late final NoteToolPrefsBinding _prefs;

  // Arka plan (PDF sayfası ya da görüntü).
  SolveBackground? _bg;
  bool _disposed = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onInactive: _flush,
      onHide: _flush,
      onPause: _flush,
    );
    _tools.addListener(_applyBrush);
    // Kalem boyutu ve yuva konumu defter ve okuyucuyla AYNI kalıcı ayardır.
    _prefs = NoteToolPrefsBinding(ref.read(noteToolPrefsStoreProvider), _tools);
    unawaited(_loadBackground());
  }

  void _flush() {
    for (final s in _sessions.values) {
      unawaited(s.flush());
    }
  }

  PdfInkSession _sessionFor(int attempt) => _sessions.putIfAbsent(attempt, () {
    final s = PdfInkSession(
      documentId: _bg!.documentId,
      ownerOf: _bg!.ownerOf,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
      attemptNo: attempt,
      questionId: widget.questionId,
      penKinds: true,
    );
    _errorSubs.add(
      s.errors.listen((m) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(m)));
      }),
    );
    return s;
  });

  Future<void> _loadBackground() async {
    try {
      final bg = await widget.loadBackground(ref);
      if (_disposed) {
        bg.dispose();
        return;
      }
      setState(() => _bg = bg);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Soru açılamadı: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tools.removeListener(_applyBrush);
    _prefs.dispose();
    _tools.dispose();
    _lifecycle.dispose();
    for (final s in _errorSubs) {
      s.cancel();
    }
    _bg?.dispose();
    // Kuyruk bitmeden oturum kapanmasın: kayıtlar tamamlanınca kapat.
    for (final s in _sessions.values) {
      unawaited(s.flush().whenComplete(s.dispose));
    }
    super.dispose();
  }

  void _applyBrush() {
    final cur = _current;
    if (cur == null || _bg == null) return;
    final s = _sessionFor(cur);
    _tools.apply(s);
    // Fotoğraf uzayında kalınlık/silgi yarıçapı arka plana göre ölçeklenir.
    final scale = _bg?.brushScale ?? 1;
    if (scale != 1) s.setBrush(s.brush.copyWith(width: s.brush.width * scale));
  }

  Future<void> _resolve(List<int> nos) async {
    final cur = _current!;
    final s = _sessionFor(cur);
    await s.flush();
    if (!mounted) return;
    if (!nos.contains(cur) && !s.hasStrokes) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Bu deneme zaten boş.')));
      return;
    }
    final next = nextAttemptNo([...nos, if (s.hasStrokes) cur]);
    setState(() {
      _current = next;
      _compare = false;
      _oldPick = cur;
    });
    _applyBrush();
  }

  @override
  Widget build(BuildContext context) {
    final attemptsAsync = ref.watch(solveAttemptsProvider(widget.questionId));
    final list = attemptsAsync.value ?? const <SolveAttempt>[];
    final nos = [for (final a in list) a.no];
    final waiting = !attemptsAsync.hasValue && !attemptsAsync.hasError;
    if (!waiting && _current == null && _bg != null) {
      _current = currentAttemptNo(nos);
      _applyBrush();
    }
    final cur = _current;
    Duration durOf(int n) =>
        list.where((a) => a.no == n).firstOrNull?.duration ?? Duration.zero;

    return Scaffold(
      appBar: AppBar(
        title: Text('Soru çözümü', overflow: TextOverflow.ellipsis),
      ),
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_loadError!),
              ),
            )
          : cur == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _controls(nos, cur, durOf),
                const Divider(height: 1),
                Expanded(
                  child: Stack(
                    children: [
                      _canvas(nos, cur),
                      FloatingToolDock(
                        tools: _tools,
                        session: _sessionFor(cur),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _controls(List<int> nos, int cur, Duration Function(int) durOf) {
    final others = [
      for (final n in nos)
        if (n != cur) n,
    ];
    final oldSel = _oldPick != null && others.contains(_oldPick)
        ? _oldPick
        : defaultOldAttempt(nos, cur);
    final cmp =
        _cmp ?? (nos.length >= 2 ? (nos[nos.length - 2], nos.last) : null);
    String lbl(int n) => '$n. deneme · ${formatSolveDuration(durOf(n))}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            key: const Key('solve-current-chip'),
            avatar: const Icon(Icons.timer_outlined, size: 18),
            label: Text(lbl(cur)),
          ),
          OutlinedButton.icon(
            key: const Key('solve-resolve'),
            onPressed: () => unawaited(_resolve(nos)),
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Yeniden çöz'),
          ),
          FilterChip(
            key: const Key('solve-show-old'),
            label: const Text('Eski çözümü göster'),
            selected: _showOld && !_compare,
            onSelected: others.isEmpty || _compare
                ? null
                : (v) => setState(() => _showOld = v),
          ),
          if (_showOld && !_compare && others.isNotEmpty) ...[
            for (final n in others)
              ChoiceChip(
                key: Key('solve-old-$n'),
                label: Text(lbl(n)),
                selected: oldSel == n,
                onSelected: (_) => setState(() => _oldPick = n),
              ),
            SizedBox(
              width: 180,
              child: Slider(
                key: const Key('solve-opacity'),
                min: minOldOpacity,
                max: 1,
                value: clampOldOpacity(_opacity),
                onChanged: (v) => setState(() => _opacity = v),
              ),
            ),
          ],
          FilterChip(
            key: const Key('solve-compare'),
            label: const Text('İki denemeyi üst üste bindir'),
            selected: _compare,
            onSelected: nos.length < 2
                ? null
                : (v) => setState(() {
                    _compare = v;
                    _cmp ??= cmp;
                  }),
          ),
          if (_compare && cmp != null) ...[
            _cmpPicker(
              'solve-cmp-a',
              cmp.$1,
              nos,
              compareTintA,
              (n) => setState(() => _cmp = (n, cmp.$2)),
            ),
            _cmpPicker(
              'solve-cmp-b',
              cmp.$2,
              nos,
              compareTintB,
              (n) => setState(() => _cmp = (cmp.$1, n)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cmpPicker(
    String key,
    int value,
    List<int> nos,
    int tint,
    ValueChanged<int> on,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 12, color: Color(tint)),
      const SizedBox(width: 4),
      DropdownButton<int>(
        key: Key(key),
        value: nos.contains(value) ? value : null,
        items: [
          for (final n in nos)
            DropdownMenuItem(value: n, child: Text('$n. deneme')),
        ],
        onChanged: (n) {
          if (n != null) on(n);
        },
      ),
    ],
  );

  Widget _canvas(List<int> nos, int cur) {
    final bg = _bg;
    if (bg == null) return const Center(child: CircularProgressIndicator());
    final region = bg.region;
    final specs = planSolveLayers(
      current: cur,
      existing: nos,
      showOld: _showOld,
      old: _oldPick ?? defaultOldAttempt(nos, cur),
      oldOpacity: _opacity,
      compare: _compare
          ? (_cmp ?? (nos.length >= 2 ? (nos[nos.length - 2], nos.last) : null))
          : null,
    );
    final editSession = _sessionFor(cur);
    Widget layer(SolveLayerSpec spec) {
      Widget w = PdfPageInkLayer(
        key: ValueKey('solve-ink-${spec.attemptNo}'),
        session: _sessionFor(spec.attemptNo),
        page: bg.page,
        pageWidth: region.width,
        pageHeight: region.height,
        originX: region.left,
        originY: region.top,
      );
      if (spec.tint != null) {
        w = ColorFiltered(
          colorFilter: ColorFilter.mode(Color(spec.tint!), BlendMode.srcIn),
          child: w,
        );
      }
      if (spec.opacity < 1) w = Opacity(opacity: spec.opacity, child: w);
      return KeyedSubtree(
        key: ValueKey('solve-layer-${spec.attemptNo}'),
        child: w,
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final aspect = region.width / region.height;
        var w = c.maxWidth, h = c.maxWidth / aspect;
        if (h > c.maxHeight) {
          h = c.maxHeight;
          w = h * aspect;
        }
        final viewer = ValueListenableBuilder<bool>(
          valueListenable: editSession.viewerLocked,
          builder: (context, locked, _) => InteractiveViewer(
            minScale: 1,
            maxScale: 200,
            onInteractionStart: (_) => editSession.zoomInteraction.begin(),
            onInteractionEnd: (_) => editSession.zoomInteraction.end(),
            panEnabled: !locked,
            scaleEnabled: !locked,
            child: Center(
              child: SizedBox(
                key: const Key('solve-canvas'),
                width: w,
                height: h,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      key: const Key('solve-page'),
                      painter: bg.painter(),
                    ),
                    for (final s in specs) layer(s),
                  ],
                ),
              ),
            ),
          ),
        );
        // Üst üste bindirme salt okunurdur: kalem girişi yok (görünüm yine kayar/yakınlaşır).
        return _compare
            ? viewer
            : PdfInkInput(session: editSession, child: viewer);
      },
    );
  }
}
