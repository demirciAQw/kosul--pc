import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../ink/domain/ink_models.dart';
import '../../question_bank/question_bank_providers.dart';
import '../domain/pdf_engine.dart';
import '../domain/solve.dart';
import '../pdf_providers.dart';
import 'pdf_ink_input.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';
import 'pdf_reader_page.dart' show PdfInkToolbar;

/// Çözüm ekranı (`/pdf/:id/soru/:questionId`): sorunun PDF kutusu çevresiyle
/// açılır; her çözüm denemesi ayrı katmandır.
class PdfSolvePage extends ConsumerWidget {
  const PdfSolvePage({super.key, required this.documentId, required this.questionId});
  final String documentId;
  final String questionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget msg(String t) => Scaffold(appBar: AppBar(title: const Text('Soru çözümü')), body: Center(child: Text(t)));
    final card = ref.watch(questionByIdProvider(questionId));
    final info = ref.watch(pdfOpenInfoProvider(documentId));
    if (card.isLoading || info.isLoading) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final c = card.value;
    final i = info.value;
    if (c == null) return msg('Soru bulunamadı.');
    if (i == null) return msg('Bu PDF bulunamadı.');
    if (i.path == null) return msg('Bu PDF dosyası bu cihazda yok.');
    if (!c.hasPdfAnchor || c.pdfDocumentId != documentId) return msg('Bu soru bu PDF\'e bağlı değil.');
    return PdfSolveView(info: i, questionId: questionId, page: c.pdfPage!, box: c.pdfBox!);
  }
}

class PdfSolveView extends ConsumerStatefulWidget {
  const PdfSolveView({super.key, required this.info, required this.questionId, required this.page, required this.box});
  final PdfOpenInfo info;
  final String questionId;

  /// 0'dan.
  final int page;
  final PdfBox box;

  @override
  ConsumerState<PdfSolveView> createState() => _PdfSolveViewState();
}

class _PdfSolveViewState extends ConsumerState<PdfSolveView> {
  final Map<int, PdfInkSession> _sessions = {};
  final List<StreamSubscription<String>> _errorSubs = [];
  late final AppLifecycleListener _lifecycle;

  int? _current;
  bool _showOld = false;
  int? _oldPick;
  double _opacity = defaultOldOpacity;
  bool _compare = false;
  (int, int)? _cmp;

  InkTool _tool = InkTool.pen;
  int _color = 0xFF1B1B1F;
  double _width = 4;

  // Sayfa resmi ve bölge.
  PdfBox? _region;
  PdfPageSize? _pageSize;
  ui.Image? _image;
  double _imageScale = 1;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: _flush, onHide: _flush, onPause: _flush);
    unawaited(_loadPage());
  }

  void _flush() {
    for (final s in _sessions.values) {
      unawaited(s.flush());
    }
  }

  PdfInkSession _sessionFor(int attempt) => _sessions.putIfAbsent(attempt, () {
    final s = PdfInkSession(
      documentId: widget.info.record.id,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
      attemptNo: attempt,
      questionId: widget.questionId,
    );
    _errorSubs.add(s.errors.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    }));
    return s;
  });

  Future<void> _loadPage() async {
    try {
      final engine = ref.read(pdfEngineProvider);
      final doc = await engine.openFile(widget.info.path!);
      try {
        final size = await doc.pageSize(widget.page);
        final region = solveRegion(widget.box, size);
        if (region == null) throw StateError('Soru kutusu geçersiz');
        // Bölge genişliği ~1600 piksel olsun (en çok 3x); belge sınırını aşma.
        var scale = math.min<double>(3, 1600 / region.width);
        while (size.width * scale * size.height * scale > maxRenderPixels * 0.9) {
          scale *= 0.8;
        }
        final w = math.max<int>(1, (size.width * scale).round());
        final h = math.max<int>(1, (size.height * scale).round());
        final img = await doc.renderPage(widget.page, width: w, height: h);
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          img.bytes,
          img.width,
          img.height,
          img.format == PdfPixelFormat.bgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888,
          c.complete,
        );
        final decoded = await c.future;
        if (!mounted) {
          decoded.dispose();
          return;
        }
        setState(() {
          _region = region;
          _pageSize = size;
          _image = decoded;
          _imageScale = img.width / size.width;
        });
      } finally {
        await doc.close();
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Sayfa açılamadı: $e');
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final s in _errorSubs) {
      s.cancel();
    }
    _image?.dispose();
    // Kuyruk bitmeden oturum kapanmasın: kayıtlar tamamlanınca kapat.
    for (final s in _sessions.values) {
      unawaited(s.flush().whenComplete(s.dispose));
    }
    super.dispose();
  }

  void _applyBrush() {
    final cur = _current;
    if (cur == null) return;
    final w = _tool == InkTool.highlighter ? _width * 4 : _width;
    _sessionFor(cur).setBrush(InkBrush(tool: _tool, color: _color, width: w));
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
    if (!waiting && _current == null) {
      _current = currentAttemptNo(nos);
      _applyBrush();
    }
    final cur = _current;
    Duration durOf(int n) => list.where((a) => a.no == n).firstOrNull?.duration ?? Duration.zero;

    return Scaffold(
      appBar: AppBar(title: Text('Soru çözümü', overflow: TextOverflow.ellipsis)),
      body: cur == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                PdfInkToolbar(
                  session: _sessionFor(cur),
                  tool: _tool,
                  color: _color,
                  width: _width,
                  onTool: (t) => setState(() {
                    _tool = t;
                    _applyBrush();
                  }),
                  onColor: (c) => setState(() {
                    _color = c;
                    _applyBrush();
                  }),
                  onWidth: (w) => setState(() {
                    _width = w;
                    _applyBrush();
                  }),
                ),
                _controls(nos, cur, durOf),
                const Divider(height: 1),
                Expanded(child: _canvas(nos, cur)),
              ],
            ),
    );
  }

  Widget _controls(List<int> nos, int cur, Duration Function(int) durOf) {
    final others = [for (final n in nos) if (n != cur) n];
    final oldSel = _oldPick != null && others.contains(_oldPick) ? _oldPick : defaultOldAttempt(nos, cur);
    final cmp = _cmp ?? (nos.length >= 2 ? (nos[nos.length - 2], nos.last) : null);
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
            onSelected: others.isEmpty || _compare ? null : (v) => setState(() => _showOld = v),
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
            _cmpPicker('solve-cmp-a', cmp.$1, nos, compareTintA, (n) => setState(() => _cmp = (n, cmp.$2))),
            _cmpPicker('solve-cmp-b', cmp.$2, nos, compareTintB, (n) => setState(() => _cmp = (cmp.$1, n))),
          ],
        ],
      ),
    );
  }

  Widget _cmpPicker(String key, int value, List<int> nos, int tint, ValueChanged<int> on) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 12, color: Color(tint)),
      const SizedBox(width: 4),
      DropdownButton<int>(
        key: Key(key),
        value: nos.contains(value) ? value : null,
        items: [for (final n in nos) DropdownMenuItem(value: n, child: Text('$n. deneme'))],
        onChanged: (n) {
          if (n != null) on(n);
        },
      ),
    ],
  );

  Widget _canvas(List<int> nos, int cur) {
    final region = _region;
    final size = _pageSize;
    if (_loadError != null) return Center(child: Text(_loadError!));
    if (region == null || size == null || _image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final specs = planSolveLayers(
      current: cur,
      existing: nos,
      showOld: _showOld,
      old: _oldPick ?? defaultOldAttempt(nos, cur),
      oldOpacity: _opacity,
      compare: _compare ? (_cmp ?? (nos.length >= 2 ? (nos[nos.length - 2], nos.last) : null)) : null,
    );
    final editSession = _sessionFor(cur);
    Widget layer(SolveLayerSpec spec) {
      Widget w = PdfPageInkLayer(
        key: ValueKey('solve-ink-${spec.attemptNo}'),
        session: _sessionFor(spec.attemptNo),
        page: widget.page,
        pageWidth: region.width,
        pageHeight: region.height,
        originX: region.left,
        originY: region.top,
      );
      if (spec.tint != null) {
        w = ColorFiltered(colorFilter: ColorFilter.mode(Color(spec.tint!), BlendMode.srcIn), child: w);
      }
      if (spec.opacity < 1) w = Opacity(opacity: spec.opacity, child: w);
      return KeyedSubtree(key: ValueKey('solve-layer-${spec.attemptNo}'), child: w);
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
            maxScale: 5,
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
                      painter: _RegionPainter(_image!, _imageScale, region, size, widget.box),
                    ),
                    for (final s in specs) layer(s),
                  ],
                ),
              ),
            ),
          ),
        );
        // Üst üste bindirme salt okunurdur: kalem girişi yok (görünüm yine kayar/yakınlaşır).
        return _compare ? viewer : PdfInkInput(session: editSession, child: viewer);
      },
    );
  }
}

/// Sayfa resminin bölgeye düşen kısmını çizer; bölge sayfanın altından taşarsa
/// taşan yer beyazdır. Soru kutusu ince bir çerçeveyle işaretlenir.
class _RegionPainter extends CustomPainter {
  _RegionPainter(this.image, this.scale, this.region, this.page, this.box);
  final ui.Image image;
  final double scale;
  final PdfBox region;
  final PdfPageSize page;
  final PdfBox box;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final sx = size.width / region.width, sy = size.height / region.height;
    final r = math.min<double>(region.right, page.width);
    final b = math.min<double>(region.bottom, page.height);
    if (r > region.left && b > region.top) {
      canvas.drawImageRect(
        image,
        Rect.fromLTRB(region.left * scale, region.top * scale, r * scale, b * scale),
        Rect.fromLTRB(0, 0, (r - region.left) * sx, (b - region.top) * sy),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    canvas.drawRect(
      Rect.fromLTRB(
        (box.left - region.left) * sx,
        (box.top - region.top) * sy,
        (box.right - region.left) * sx,
        (box.bottom - region.top) * sy,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x991565C0),
    );
  }

  @override
  bool shouldRepaint(_RegionPainter o) => o.image != image || o.region != region;
}
