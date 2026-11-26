import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pdf_layer_state.dart';

/// Üst üste binmiş iki A4 kâğıdı ve sağ altta yuvarlak "+" rozeti (kendi çizim).
class LayerPagesIcon extends StatelessWidget {
  const LayerPagesIcon({super.key, this.size = 26, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _PagesPainter(color ?? IconTheme.of(context).color ?? Colors.black87, Theme.of(context).colorScheme.primary),
      );
}

class _PagesPainter extends CustomPainter {
  _PagesPainter(this.ink, this.badge);
  final Color ink;
  final Color badge;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width * 0.52, h = w * 1.414; // A4 oranı
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.07
      ..color = ink;
    final back = Rect.fromLTWH(s.width * 0.08, s.height * 0.02, w, h);
    final front = Rect.fromLTWH(s.width * 0.26, s.height * 0.16, w, h);
    canvas.drawRRect(RRect.fromRectAndRadius(back, const Radius.circular(2)), line);
    final fr = RRect.fromRectAndRadius(front, const Radius.circular(2));
    canvas.drawRRect(fr, Paint()..color = Colors.white.withValues(alpha: 0.0));
    canvas.drawRRect(fr, line);
    final c = Offset(s.width * 0.80, s.height * 0.80), r = s.width * 0.2;
    canvas.drawCircle(c, r, Paint()..color = badge);
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = s.width * 0.065
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c.translate(-r * 0.5, 0), c.translate(r * 0.5, 0), p);
    canvas.drawLine(c.translate(0, -r * 0.5), c.translate(0, r * 0.5), p);
  }

  @override
  bool shouldRepaint(_PagesPainter o) => o.ink != ink || o.badge != badge;
}

/// Soru katmanı simgesi: kesik çizgili seçim kutusu ve "+" rozeti.
class LayerRegionIcon extends StatelessWidget {
  const LayerRegionIcon({super.key, this.size = 26, this.color, this.badge = true});
  final double size;
  final Color? color;

  /// Sağ altta "+" rozeti.
  final bool badge;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _RegionPainter(color ?? IconTheme.of(context).color ?? Colors.black87, badge ? Theme.of(context).colorScheme.primary : null),
      );
}

class _RegionPainter extends CustomPainter {
  _RegionPainter(this.ink, this.badge);
  final Color ink;
  final Color? badge;

  @override
  void paint(Canvas canvas, Size s) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.07
      ..color = ink;
    final rect = badge == null
        ? Rect.fromLTWH(s.width * 0.12, s.height * 0.14, s.width * 0.76, s.height * 0.72)
        : Rect.fromLTWH(s.width * 0.06, s.height * 0.12, s.width * 0.7, s.height * 0.62);
    // kesik çizgili dikdörtgen
    final path = Path()..addRect(rect);
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + s.width * 0.13, m.length)), line);
        d += s.width * 0.22;
      }
    }
    final b = badge;
    if (b == null) return;
    final c = Offset(s.width * 0.80, s.height * 0.80), r = s.width * 0.2;
    canvas.drawCircle(c, r, Paint()..color = b);
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = s.width * 0.065
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c.translate(-r * 0.5, 0), c.translate(r * 0.5, 0), p);
    canvas.drawLine(c.translate(0, -r * 0.5), c.translate(0, r * 0.5), p);
  }

  @override
  bool shouldRepaint(_RegionPainter o) => o.ink != ink || o.badge != badge;
}

/// Tek tık + uzun basış alan üst çubuk düğmesi.
class LayerBarButton extends StatelessWidget {
  const LayerBarButton({
    super.key,
    required this.tooltip,
    required this.child,
    required this.onTap,
    required this.onLongPress,
    this.active = false,
  });
  final String tooltip;
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          onLongPress: onLongPress,
          radius: 24,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: active
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primaryContainer,
                  )
                : null,
            child: child,
          ),
        ),
      );
}

/// Üst çubuğun tam sayfa katman düğmesi: tek tık ekler (tür tercihine göre; soru türü
/// bölge seçimini başlatır), uzun basış ayarları açar.
class PdfLayerBarButtons extends StatelessWidget {
  const PdfLayerBarButtons({super.key, required this.state, required this.onAddFull, required this.onSettings});
  final PdfLayerState state;
  final VoidCallback onAddFull;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => LayerBarButton(
        key: const Key('pdf-layer-full'),
        tooltip: 'Yeni katman ekle (uzun bas: ayarlar)',
        onTap: onAddFull,
        onLongPress: onSettings,
        child: const LayerPagesIcon(),
      );
}

/// Katmanı yumuşak siler ve "Katman silindi · Geri al" iletisini gösterir.
Future<void> deleteLayerWithUndo(BuildContext context, PdfLayerState state, int number) async {
  final messenger = ScaffoldMessenger.of(context);
  final l = await state.deleteLayer(number);
  if (l == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const Key('layer-deleted-snack'),
        content: const Text('Katman silindi'),
        action: SnackBarAction(label: 'Geri al', onPressed: () => state.restoreLayer(l.id)),
      ),
    );
}

/// PDF görünümünün SOL ÜSTÜNDE sabit hap: `[◀] [N] [▶]`. ◀ önceki, ▶ sonraki katman; sondayken
/// ▶ yerine "+" (yeni katman). Yalnız AKTİF katman görünür. N'ye uzun basış: sil / öne / arkaya.
/// Katman yokken yalnız "+" görünür.
class LayerNavPill extends StatelessWidget {
  const LayerNavPill({super.key, required this.state});
  final PdfLayerState state;

  Future<void> _menu(BuildContext context) async {
    final n = state.active;
    if (n < 1) return;
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'sil', child: Text('Katmanı sil')),
        PopupMenuItem(value: 'one', enabled: n > 1, child: const Text('Öne taşı')),
        PopupMenuItem(value: 'arkaya', enabled: n < state.layers.length, child: const Text('Arkaya taşı')),
      ],
    );
    if (!context.mounted) return;
    switch (v) {
      case 'sil':
        await deleteLayerWithUndo(context, state, n);
      case 'one':
        await state.moveLayer(n, -1);
      case 'arkaya':
        await state.moveLayer(n, 1);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final a = state.active;
          final last = state.layers.isEmpty || a >= state.layers.length;
          final Widget label = state.showNumber
              ? Text(
                  a == 0 ? 'A' : '$a',
                  key: const Key('pdf-layer-nav-label'),
                  style: TextStyle(color: cs.onPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                )
              : Icon(Icons.layers, key: const Key('pdf-layer-nav-label'), color: cs.onPrimary, size: 20);
          Widget btn(Key key, IconData icon, String tip, VoidCallback? onTap) => IconButton(
                key: key,
                tooltip: tip,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                padding: EdgeInsets.zero,
                color: cs.onPrimary,
                disabledColor: cs.onPrimary.withValues(alpha: 0.35),
                icon: Icon(icon, size: 22),
                onPressed: onTap,
              );
          return Material(
            key: const Key('pdf-layer-nav'),
            color: cs.primary.withValues(alpha: 0.92),
            elevation: 4,
            shape: const StadiumBorder(),
            child: state.layers.isEmpty
                ? btn(const Key('pdf-layer-nav-add'), Icons.add, 'Yeni katman', () => state.next())
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      btn(const Key('pdf-layer-nav-prev'), Icons.chevron_left, 'Önceki katman', a > 0 ? state.prev : null),
                      Builder(
                        builder: (ctx) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: a > 0 ? () => _menu(ctx) : null,
                          child: Container(constraints: const BoxConstraints(minWidth: 28), alignment: Alignment.center, child: label),
                        ),
                      ),
                      last
                          ? btn(const Key('pdf-layer-nav-add'), Icons.add, 'Yeni katman', () => state.next())
                          : btn(const Key('pdf-layer-nav-next'), Icons.chevron_right, 'Sonraki katman', () => state.next()),
                    ],
                  ),
          );
        },
      );
}

const double _regionBtn = 52;

/// PDF görünümünde YÜZEN yuvarlak bölge seçme düğmesi. Dokununca bölge seçimi başlar (tekrar
/// dokununca iptal). UZUN BASINCA düzenleme modu: sürüklenip taşınır (konum kalıcı, serbest
/// alanın oranı) ve yanında "Sil" (×) çıkar (silinince gizlenir; geri getirmek Ayarlar'da).
/// Düzenlemeden çıkmak için boşluğa dokun. Üst öğenin tüm alanını kaplar (Positioned.fill).
class RegionPickButton extends StatefulWidget {
  const RegionPickButton({super.key, required this.state});
  final PdfLayerState state;

  @override
  State<RegionPickButton> createState() => _RegionPickButtonState();
}

class _RegionPickButtonState extends State<RegionPickButton> {
  bool _edit = false;
  Offset? _drag; // sürüklenirken piksel konumu
  Offset _dragStart = Offset.zero;

  static const _default = Offset(8, 64);

  Offset _clamp(Offset o, Size free) => Offset(o.dx.clamp(0.0, free.width), o.dy.clamp(0.0, free.height));

  Offset _stored(Size free) {
    final r = widget.state.regionButtonAt;
    return _clamp(r == null ? _default : Offset(r.dx * free.width, r.dy * free.height), free);
  }

  void _commit(Size free) {
    final d = _drag;
    setState(() => _drag = null);
    if (d == null) return;
    widget.state.setRegionAt(Offset(free.width > 0 ? d.dx / free.width : 0, free.height > 0 ? d.dy / free.height : 0));
  }

  void _exitEdit() {
    if (_edit && mounted) setState(() => _edit = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          if (!widget.state.regionButtonVisible) return const SizedBox.shrink();
          final cs = Theme.of(context).colorScheme;
          final selecting = widget.state.selecting;
          return LayoutBuilder(builder: (context, c) {
            final free = Size(
              (c.maxWidth.isFinite ? c.maxWidth - _regionBtn : 0.0).clamp(0.0, double.infinity).toDouble(),
              (c.maxHeight.isFinite ? c.maxHeight - _regionBtn : 0.0).clamp(0.0, double.infinity).toDouble(),
            );
            final pos = _drag ?? _stored(free);
            final delLeft = pos.dx + _regionBtn + 36 <= free.width + _regionBtn ? pos.dx + _regionBtn + 4 : pos.dx - 36;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: pos.dx,
                  top: pos.dy,
                  width: _regionBtn,
                  height: _regionBtn,
                  child: TapRegion(
                    groupId: this,
                    onTapOutside: (_) => _exitEdit(),
                    child: GestureDetector(
                      key: const Key('pdf-region-button'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _edit ? null : () => widget.state.setSelecting(!selecting),
                      onLongPressStart: (_) {
                        setState(() {
                          _edit = true;
                          _dragStart = pos;
                        });
                      },
                      onLongPressMoveUpdate: (d) => setState(() => _drag = _clamp(_dragStart + d.offsetFromOrigin, free)),
                      onLongPressEnd: (_) => _commit(free),
                      onPanStart: _edit ? (_) => setState(() => _drag = pos) : null,
                      onPanUpdate: _edit ? (d) => setState(() => _drag = _clamp((_drag ?? pos) + d.delta, free)) : null,
                      onPanEnd: _edit ? (_) => _commit(free) : null,
                      child: Material(
                        color: selecting ? cs.primary : cs.primaryContainer,
                        elevation: _edit ? 8 : 4,
                        shape: CircleBorder(side: _edit ? BorderSide(color: cs.primary, width: 2) : BorderSide.none),
                        child: Center(
                          child: LayerRegionIcon(
                            badge: false,
                            size: 28,
                            color: selecting ? cs.onPrimary : cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_edit)
                  Positioned(
                    left: delLeft,
                    top: pos.dy + (_regionBtn - 32) / 2,
                    width: 32,
                    height: 32,
                    child: TapRegion(
                      groupId: this,
                      onTapOutside: (_) => _exitEdit(),
                      child: Material(
                        color: cs.errorContainer,
                        elevation: 4,
                        shape: const CircleBorder(),
                        child: InkResponse(
                          key: const Key('pdf-region-delete'),
                          customBorder: const CircleBorder(),
                          onTap: () {
                            setState(() => _edit = false);
                            widget.state.setRegionVisible(false);
                          },
                          child: Tooltip(message: 'Sil', child: Icon(Icons.close, size: 18, color: cs.onErrorContainer)),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          });
        },
      );
}
