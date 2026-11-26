import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'note_tool_settings.dart';

/// Yuva kenara bu kadar (mantıksal piksel) yaklaşınca bırakılırsa kenara yapışır.
const dockSnapDistance = 56.0;

/// Yuvanın ekranda gidebileceği dikdörtgen ([area] içinde, güvenli alan ve kenar
/// boşluğu çıkarılmış) ve yuva boyutu [dock] için sol-üst köşe sınırları.
({double minX, double maxX, double minY, double maxY}) dockTravel(
  Size area,
  Size dock,
  EdgeInsets inset,
) {
  final minX = inset.left, minY = inset.top;
  final maxX = math.max(minX, area.width - inset.right - dock.width);
  final maxY = math.max(minY, area.height - inset.bottom - dock.height);
  return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

/// Serbest yuvanın sol-üst köşesi: oranlar gidebileceği alana uygulanır, bu yüzden
/// ekran boyutu değişse de yuva her zaman ekranın içinde kalır.
Offset freeDockTopLeft(
  double fx,
  double fy,
  Size area,
  Size dock,
  EdgeInsets inset,
) {
  final t = dockTravel(area, dock, inset);
  return Offset(
    t.minX + fx.clamp(0.0, 1.0) * (t.maxX - t.minX),
    t.minY + fy.clamp(0.0, 1.0) * (t.maxY - t.minY),
  );
}

/// [freeDockTopLeft]'in tersi: sol-üst köşeden oran (sınırlara kırpılır).
({double fx, double fy}) freeDockFraction(
  Offset topLeft,
  Size area,
  Size dock,
  EdgeInsets inset,
) {
  final t = dockTravel(area, dock, inset);
  final dx = t.maxX - t.minX, dy = t.maxY - t.minY;
  return (
    fx: dx <= 0 ? 0.5 : ((topLeft.dx - t.minX) / dx).clamp(0.0, 1.0),
    fy: dy <= 0 ? 0.5 : ((topLeft.dy - t.minY) / dy).clamp(0.0, 1.0),
  );
}

/// Yuvanın dikdörtgeni [dockRect] ekranın bir kenarına [distance]'tan yakınsa o kenar
/// (yapışma önizlemesi); değilse null. Birden çok kenar yakınsa en yakını.
DockPosition? snapEdgeFor(
  Rect dockRect,
  Size area, {
  double distance = dockSnapDistance,
}) {
  final d = {
    DockPosition.top: dockRect.top,
    DockPosition.bottom: area.height - dockRect.bottom,
    DockPosition.left: dockRect.left,
    DockPosition.right: area.width - dockRect.right,
  };
  DockPosition? best;
  for (final e in d.entries) {
    if (e.value > distance) continue;
    if (best == null || e.value < d[best]!) best = e.key;
  }
  return best;
}

/// Basılı tutup sürükleme sırasındaki yuva durumu: işaretçi (yerel) ve yuvanın
/// tutulduğu nokta (yuvanın sol-üstüne göre).
class DockDrag {
  const DockDrag(this.pointer, this.grab);
  final Offset pointer;
  final Offset grab;
  Offset get topLeft => pointer - grab;
}

/// Yuvanın konum düğmesine bağlanan sürükleme işleyicisi (yuvayı yerleştiren
/// sahip uygular).
abstract interface class DockDragHandler {
  void start(Offset global);
  void update(Offset global);
  void end(Offset global);
  void cancel();
}

/// Yuvayı yerleştirir: kenarda (üst/alt/sol/sağ) ya da serbest; sürükleme
/// sırasında işaretçiyi izler. HEP aynı ağaç yapısını kullanır, bu yüzden kenardan
/// serbeste geçerken yuva yeniden kurulmaz ve süren basılı tutma kopmaz.
/// YALNIZCA bir `Stack` içinde kullanılır (`Positioned.fill` döner).
class DockPlacement extends StatelessWidget {
  const DockPlacement({
    super.key,
    required this.tools,
    required this.drag,
    required this.child,
  });

  final NoteToolSettings tools;
  final ValueListenable<DockDrag?> drag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Positioned.fill(
      child: ListenableBuilder(
        listenable: Listenable.merge([tools, drag]),
        builder: (context, _) => CustomSingleChildLayout(
          delegate: _DockLayout(
            pos: tools.dockPosition,
            free: tools.dockFree,
            fx: tools.dockFx,
            fy: tools.dockFy,
            pad: pad,
            drag: drag.value,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Kenar yerleşimi eski `Align + Padding` ile aynıdır (sistem çubuğu payı dahil).
class _DockLayout extends SingleChildLayoutDelegate {
  _DockLayout({
    required this.pos,
    required this.free,
    required this.fx,
    required this.fy,
    required this.pad,
    required this.drag,
  });

  final DockPosition pos;
  final bool free;
  final double fx;
  final double fy;
  final EdgeInsets pad;
  final DockDrag? drag;

  /// Serbest/sürükleme alanı: güvenli alan + 10 dp boşluk.
  EdgeInsets get _freeInset => EdgeInsets.fromLTRB(
    10 + pad.left,
    10 + pad.top,
    10 + pad.right,
    10 + pad.bottom,
  );

  EdgeInsets get _edgeInset => EdgeInsets.fromLTRB(
    10 + (pos == DockPosition.right ? 0 : pad.left),
    10,
    10 + (pos == DockPosition.left ? 0 : pad.right),
    10 + (pos == DockPosition.top ? 0 : pad.bottom),
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final i = free || drag != null ? _freeInset : _edgeInset;
    return BoxConstraints.loose(
      Size(
        math.max(0, c.maxWidth - i.horizontal),
        math.max(0, c.maxHeight - i.vertical),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final d = drag;
    if (d != null) {
      final t = dockTravel(size, child, _freeInset);
      return Offset(
        d.topLeft.dx.clamp(t.minX, t.maxX).toDouble(),
        d.topLeft.dy.clamp(t.minY, t.maxY).toDouble(),
      );
    }
    if (free) return freeDockTopLeft(fx, fy, size, child, _freeInset);
    final i = _edgeInset;
    final a = switch (pos) {
      DockPosition.top => Alignment.topCenter,
      DockPosition.bottom => Alignment.bottomCenter,
      DockPosition.left => Alignment.centerLeft,
      DockPosition.right => Alignment.centerRight,
    };
    final availW = size.width - i.horizontal, availH = size.height - i.vertical;
    return Offset(
      i.left + (a.x + 1) / 2 * (availW - child.width),
      i.top + (a.y + 1) / 2 * (availH - child.height),
    );
  }

  @override
  bool shouldRelayout(_DockLayout o) =>
      o.pos != pos ||
      o.free != free ||
      o.fx != fx ||
      o.fy != fy ||
      o.pad != pad ||
      o.drag?.pointer != drag?.pointer ||
      (o.drag == null) != (drag == null);
}

/// Yuvayı sürüklerken kenara yapışma önizlemesi: yaklaşılan kenarda ince bant.
class DockSnapPreview extends StatelessWidget {
  const DockSnapPreview({super.key, required this.edge});
  final DockPosition edge;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    final band = Container(
      key: Key('note-dock-snap-${edge.name}'),
      color: c.withValues(alpha: 0.35),
    );
    const t = 10.0;
    return Positioned.fill(
      child: IgnorePointer(
        child: switch (edge) {
          DockPosition.top => Align(
            alignment: Alignment.topCenter,
            child: SizedBox(height: t, width: double.infinity, child: band),
          ),
          DockPosition.bottom => Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(height: t, width: double.infinity, child: band),
          ),
          DockPosition.left => Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: t, height: double.infinity, child: band),
          ),
          DockPosition.right => Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: t, height: double.infinity, child: band),
          ),
        },
      ),
    );
  }
}
