import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../notes/data/note_tool_prefs_store.dart';
import '../../notes/presentation/note_tool_dock.dart';
import '../../notes/presentation/note_tool_settings.dart';
import '../domain/page_layer.dart';
import '../pdf_layers_providers.dart';
import '../pdf_providers.dart' show inkStrokeRepositoryProvider;
import 'pdf_ink_input.dart';
import 'pdf_ink_session.dart';
import 'pdf_page_ink_layer.dart';

/// Üç parmakla kaydırma algılayıcısı: üç eşzamanlı dokunma birlikte belirgin
/// ([threshold] px) yatay ya da dikey giderse [onSwipe] bir kez çağrılır.
class ThreeFingerSwipe extends StatefulWidget {
  const ThreeFingerSwipe({super.key, required this.onSwipe, required this.child, this.threshold = 80});
  final VoidCallback onSwipe;
  final Widget child;
  final double threshold;

  @override
  State<ThreeFingerSwipe> createState() => _ThreeFingerSwipeState();
}

class _ThreeFingerSwipeState extends State<ThreeFingerSwipe> {
  final Map<int, Offset> _start = {};
  final Map<int, Offset> _now = {};
  bool _fired = false;

  void _check() {
    if (_fired || _start.length < 3) return;
    var dx = 0.0, dy = 0.0;
    for (final e in _start.entries) {
      final d = (_now[e.key] ?? e.value) - e.value;
      dx += d.dx;
      dy += d.dy;
    }
    dx /= _start.length;
    dy /= _start.length;
    if (dx.abs() >= widget.threshold || dy.abs() >= widget.threshold) {
      _fired = true;
      widget.onSwipe();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (e.kind != PointerDeviceKind.touch) return;
          _start[e.pointer] = e.position;
          _now[e.pointer] = e.position;
        },
        onPointerMove: (e) {
          if (!_start.containsKey(e.pointer)) return;
          _now[e.pointer] = e.position;
          _check();
        },
        onPointerUp: (e) => _release(e.pointer),
        onPointerCancel: (e) => _release(e.pointer),
        child: widget.child,
      );

  void _release(int p) {
    _start.remove(p);
    _now.remove(p);
    if (_start.isEmpty) _fired = false;
  }
}

/// Soru katmanının "ayrı pencere"si: seçilen bölge boyutunda BEYAZ sayfa üzerinde çizim.
/// Çizgiler `ink_strokes`a (belge, sayfa, katman numarası, noteId='katman-pencere:<id>') OTOMATİK
/// yazılır; her açılışta kaydedilmiş hali gelir. Üç parmakla kaydırma ya da geri: ana PDF'e dön.
class PdfLayerWindowPage extends ConsumerStatefulWidget {
  const PdfLayerWindowPage({super.key, required this.documentId, required this.layerId});
  final String documentId;
  final String layerId;

  @override
  ConsumerState<PdfLayerWindowPage> createState() => _PdfLayerWindowPageState();
}

class _PdfLayerWindowPageState extends ConsumerState<PdfLayerWindowPage> {
  PdfInkSession? _session;
  final _tools = NoteToolSettings();
  late final NoteToolPrefsBinding _prefs;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _errorSub;
  PdfPageLayer? _layer;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _prefs = NoteToolPrefsBinding(ref.read(noteToolPrefsStoreProvider), _tools);
    _tools.addListener(_applyTools);
    _lifecycle = AppLifecycleListener(onInactive: _flush, onHide: _flush, onPause: _flush);
    unawaited(_init());
  }

  Future<void> _init() async {
    final st = ref.read(pdfLayerStateProvider(widget.documentId));
    if (!st.loaded) await st.load();
    final l = st.byId(widget.layerId);
    if (!mounted) return;
    if (l == null || !l.isQuestion) {
      setState(() => _missing = true);
      return;
    }
    final s = PdfInkSession(
      documentId: widget.documentId,
      repository: ref.read(inkStrokeRepositoryProvider),
      clock: ref.read(clockProvider),
      penKinds: true,
      layer: l.key,
      strokeTag: layerWindowTag(l.id),
    );
    _tools.apply(s);
    _errorSub = s.errors.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    setState(() {
      _layer = l;
      _session = s;
    });
  }

  void _applyTools() {
    final s = _session;
    if (s != null) _tools.apply(s);
  }

  void _flush() {
    final s = _session;
    if (s != null) unawaited(s.flush());
  }

  void _back() {
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _tools.removeListener(_applyTools);
    _prefs.dispose();
    _tools.dispose();
    _lifecycle.dispose();
    _errorSub?.cancel();
    final s = _session;
    if (s != null) unawaited(s.flush().whenComplete(s.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = _layer, s = _session;
    return Scaffold(
      appBar: AppBar(
        title: Text(l == null ? 'Katman' : 'Katman ${l.number} · ayrı pencere'),
        leading: BackButton(onPressed: _back),
      ),
      body: _missing
          ? const Center(child: Text('Bu katman bulunamadı.'))
          : l == null || s == null
              ? const Center(child: CircularProgressIndicator())
              : ThreeFingerSwipe(onSwipe: _back, child: _canvas(l, s)),
    );
  }

  Widget _canvas(PdfPageLayer l, PdfInkSession s) {
    final b = l.box!;
    final rw = b.width <= 0 ? 1.0 : b.width, rh = b.height <= 0 ? 1.0 : b.height;
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(builder: (context, c) {
            final aspect = rw / rh;
            var w = c.maxWidth, h = c.maxWidth / aspect;
            if (h > c.maxHeight) {
              h = c.maxHeight;
              w = h * aspect;
            }
            final viewer = ValueListenableBuilder<bool>(
              valueListenable: s.viewerLocked,
              builder: (context, locked, _) => InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                panEnabled: !locked,
                scaleEnabled: !locked,
                child: Center(
                  child: Container(
                    key: const Key('layer-window-canvas'),
                    width: w,
                    height: h,
                    color: Colors.white,
                    child: PdfPageInkLayer(
                      session: s,
                      page: l.page,
                      pageWidth: rw,
                      pageHeight: rh,
                      originX: b.left,
                      originY: b.top,
                    ),
                  ),
                ),
              ),
            );
            return PdfInkInput(session: s, child: viewer);
          }),
        ),
        FloatingToolDock(tools: _tools, session: s),
      ],
    );
  }
}
