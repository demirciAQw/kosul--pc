import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/tablet.dart' show TabletFocus;
import '../../ink/domain/pen_profiles.dart';
import '../../ink/domain/shape_recognizer.dart';
import '../../pdf/presentation/pdf_ink_session.dart';
import '../domain/page_template.dart';
import 'note_tool_settings.dart';
import 'page_template_painter.dart';

/// Yuvadaki araçlar (ayar penceresi olanlar).
enum DockTool { pen, highlighter, eraser, shape }

const _kindInfo = {
  PenKind.ballpoint: (Icons.edit_outlined, 'Tükenmez'),
  PenKind.fountain: (Icons.brush_outlined, 'Dolma'),
  PenKind.pencil: (Icons.create_outlined, 'Kurşun'),
  PenKind.highlighter: (Icons.border_color_outlined, 'Fosforlu'),
};

const _shapeIcons = {
  ShapeTool.line: Icons.horizontal_rule,
  ShapeTool.arrow: Icons.arrow_right_alt,
  ShapeTool.circle: Icons.circle_outlined,
  ShapeTool.ellipse: Icons.panorama_fish_eye,
  ShapeTool.rectangle: Icons.crop_square,
  ShapeTool.triangle: Icons.change_history,
};

const _positionInfo = {
  DockPosition.top: (Icons.align_vertical_top, 'Üst'),
  DockPosition.bottom: (Icons.align_vertical_bottom, 'Alt'),
  DockPosition.left: (Icons.align_horizontal_left, 'Sol'),
  DockPosition.right: (Icons.align_horizontal_right, 'Sağ'),
};

/// Yuvayı sayfanın üstünde, [NoteToolSettings.dockPosition] kenarına yerleştirir
/// (üst/alt: yatay yuva; sol/sağ: dikey yuva). YALNIZCA `Stack` içinde kullanılır
/// (`Positioned.fill` döner). Alt kenarda sistem çubuğu payı hesaba katılır.
class FloatingToolDock extends StatelessWidget {
  const FloatingToolDock({
    super.key,
    required this.tools,
    required this.session,
    this.page,
    this.selecting = false,
    this.onSelect,
  });

  final NoteToolSettings tools;
  final PdfInkSession? session;
  final PageStyleControl? page;
  final bool selecting;
  final VoidCallback? onSelect;

  /// Odak modu (tablet çerçevesi) yuvayı küçültür.
  static final _noFocus = ValueNotifier<bool>(false);

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ListenableBuilder(
      listenable: Listenable.merge([
        tools,
        TabletFocus.maybeOf(context) ?? _noFocus,
      ]),
      builder: (context, _) {
        final small = (TabletFocus.maybeOf(context) ?? _noFocus).value;
        final pos = tools.dockPosition;
        final pad = MediaQuery.paddingOf(context);
        final alignment = switch (pos) {
          DockPosition.top => Alignment.topCenter,
          DockPosition.bottom => Alignment.bottomCenter,
          DockPosition.left => Alignment.centerLeft,
          DockPosition.right => Alignment.centerRight,
        };
        return Align(
          alignment: alignment,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              10,
              10,
              10,
              10 + (pos == DockPosition.bottom ? pad.bottom : 0),
            ),
            child: NoteToolDock(
              tools: tools,
              session: session,
              page: page,
              small: small,
              selecting: selecting,
              onSelect: onSelect,
            ),
          ),
        );
      },
    ),
  );
}

/// Ekranda yüzen araç yuvası: kalem, fosforlu, silgi, kement, şekil; geri al /
/// yinele (her zaman görünür); "Sayfa" (şablon; [page] null ise yok), "Soru seç"
/// ([onSelect] varsa) ve "Konum" (üst/alt/sol/sağ; basılı tutup sürükleyerek de
/// taşınır). Seçili araca yeniden dokununca o aracın ayar penceresi açılır.
///
/// Yuva sayfanın ÜSTÜNDE yüzer (sayfa alanı küçülmez). [axis] verilmezse konumdan
/// türer: sol/sağ dikey sütun (ayar pencereleri yana açılır, sığmazsa kayar), üst/alt
/// yatay. Telefonda (<600 dp) düğmeler küçülür; odak modunda ([small]) düğmeler biraz küçülür, "Konum" sabit (kaydırma
/// dışı) kalır; yuva yerinde kalır.
class NoteToolDock extends StatelessWidget {
  const NoteToolDock({
    super.key,
    required this.tools,
    required this.session,
    this.page,
    this.small = false,
    this.axis,
    this.selecting = false,
    this.onSelect,
  });

  final NoteToolSettings tools;

  /// Yuvanın yönü; null ise `tools.dockPosition` (sol/sağ dikey, üst/alt yatay).
  final Axis? axis;

  /// Sayfa değişirken null olabilir (geri al/yinele kapalı).
  final PdfInkSession? session;

  /// "Sayfa" penceresinin eylemleri ve durumu; null ise "Sayfa" düğmesi yok (PDF).
  final PageStyleControl? page;

  /// Odak modu: küçük yuva.
  final bool small;

  /// "Soru seç" aracı (PDF okuyucu): [onSelect] null ise düğme yok. [selecting]
  /// iken kalem/silgi/... seçili görünmez; birine dokununca [onSelect] ile kapanır.
  final bool selecting;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    final size = phone ? 40.0 : (small ? 44.0 : 52.0);
    return ListenableBuilder(
      listenable: tools,
      builder: (context, _) {
        final t = tools;
        final pos = t.dockPosition;
        final vertical =
            (axis ??
                (pos == DockPosition.left || pos == DockPosition.right
                    ? Axis.vertical
                    : Axis.horizontal)) ==
            Axis.vertical;
        final actions = t.lasso && session != null
            ? _LassoActions(
                tools: t,
                session: session!,
                size: size,
                vertical: vertical,
              )
            : null;
        final dock = _DockBar(
          tools: t,
          session: session,
          page: page,
          size: size,
          phone: phone,
          small: small,
          vertical: vertical,
          selecting: selecting,
          onSelect: onSelect,
        );
        if (vertical) {
          final inner =
              pos == DockPosition.right; // eylem çubuğu yuvanın iç yanında
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (actions != null && inner) ...[
                actions,
                const SizedBox(width: 6),
              ],
              dock,
              if (actions != null && !inner) ...[
                const SizedBox(width: 6),
                actions,
              ],
            ],
          );
        }
        final top = pos == DockPosition.top;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actions != null && !top) ...[
              actions,
              const SizedBox(height: 6),
            ],
            dock,
            if (actions != null && top) ...[const SizedBox(height: 6), actions],
          ],
        );
      },
    );
  }
}

class _DockBar extends StatelessWidget {
  const _DockBar({
    required this.tools,
    required this.session,
    required this.page,
    required this.size,
    required this.phone,
    required this.small,
    required this.vertical,
    required this.selecting,
    required this.onSelect,
  });
  final NoteToolSettings tools;
  final PdfInkSession? session;
  final PageStyleControl? page;
  final double size;
  final bool phone;
  final bool small;
  final bool vertical;
  final bool selecting;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final t = tools;
    final cs = Theme.of(context).colorScheme;
    final free = !selecting && !t.eraser && !t.lasso && t.shapeTool == null;
    final penActive = free && t.kind != PenKind.highlighter;
    final hlActive = free && t.kind == PenKind.highlighter;
    final kind = t.lastPenKind;

    void pop(DockTool tool, Rect anchor) => showToolPopover(
      context,
      anchor,
      side: vertical,
      builder: (_) => NoteToolPanel(tools: t, tool: tool),
    );

    // "Soru seç" açıkken bir araca dokunmak önce seçimi kapatır.
    void pick(VoidCallback act) {
      if (selecting) onSelect?.call();
      act();
    }

    final s = session;
    final big = size + 6;
    Widget history(
      Key key,
      String tip,
      IconData icon,
      bool Function(PdfInkSession) enabled,
      void Function(PdfInkSession) run,
    ) => _HistoryButton(
      key: key,
      icon: icon,
      tooltip: tip,
      size: big,
      session: s,
      enabled: enabled,
      run: run,
    );

    final gap = vertical
        ? SizedBox(height: 4, width: big)
        : const SizedBox(width: 4);
    Widget divider() => vertical
        ? SizedBox(width: size * 0.6, child: const Divider(height: 12))
        : SizedBox(height: size * 0.6, child: const VerticalDivider(width: 12));

    final items = <Widget>[
      history(
        const Key('note-undo'),
        'Geri al',
        Icons.undo_rounded,
        (s) => s.canUndo && !s.erasing,
        (s) => s.undo(),
      ),
      if (vertical) gap,
      if (vertical)
        history(
          const Key('note-redo'),
          'Yinele',
          Icons.redo_rounded,
          (s) => s.canRedo && !s.erasing,
          (s) => s.redo(),
        ),
      if (vertical) divider() else gap,
      _DockButton(
        key: const Key('note-pen'),
        icon: _kindInfo[kind]!.$1,
        tooltip: _kindInfo[kind]!.$2,
        selected: penActive,
        dot: Color(t.colorFor(kind)),
        size: size,
        onTap: (r) =>
            penActive ? pop(DockTool.pen, r) : pick(() => t.setKind(kind)),
      ),
      _DockButton(
        key: const Key('note-pen-highlighter'),
        icon: _kindInfo[PenKind.highlighter]!.$1,
        tooltip: 'Fosforlu',
        selected: hlActive,
        dot: Color(t.colorFor(PenKind.highlighter)),
        size: size,
        onTap: (r) => hlActive
            ? pop(DockTool.highlighter, r)
            : pick(() => t.setKind(PenKind.highlighter)),
      ),
      _DockButton(
        key: const Key('note-eraser'),
        icon: Icons.auto_fix_normal_outlined,
        tooltip: 'Silgi',
        selected: !selecting && t.eraser,
        size: size,
        onTap: (r) => !selecting && t.eraser
            ? pop(DockTool.eraser, r)
            : pick(() => t.setEraser(true)),
      ),
      _DockButton(
        key: const Key('note-lasso'),
        icon: Icons.gesture,
        tooltip: 'Kement (seç, taşı, boyutlandır)',
        selected: !selecting && t.lasso,
        size: size,
        // Seçiliyken yeniden dokunmak kalemi geri getirir.
        onTap: (_) => !selecting && t.lasso
            ? t.setKind(kind)
            : pick(() => t.setLasso(true)),
      ),
      _DockButton(
        key: const Key('note-shape'),
        icon: t.shapeTool == null
            ? Icons.category_outlined
            : _shapeIcons[t.shapeTool]!,
        tooltip: 'Şekil: çiz ve düzelt',
        selected: !selecting && t.shapeTool != null,
        size: size,
        onTap: (r) {
          if (selecting) onSelect?.call();
          pop(DockTool.shape, r);
        },
      ),
      if (onSelect != null)
        _DockButton(
          key: const Key('pdf-tool-select'),
          icon: Icons.crop_free,
          tooltip: 'Soru seç',
          selected: selecting,
          size: size,
          onTap: (_) => onSelect!(),
        ),
      if (!vertical) gap,
      if (!vertical)
        history(
          const Key('note-redo'),
          'Yinele',
          Icons.redo_rounded,
          (s) => s.canRedo && !s.erasing,
          (s) => s.redo(),
        ),
      divider(),
      if (page != null)
        _DockButton(
          key: const Key('note-template'),
          icon: templateIcon(page!.template),
          tooltip: 'Sayfa: şablon, arka plan, çizgi aralığı',
          label: phone || vertical ? null : 'Sayfa',
          size: size,
          onTap: (r) => showToolPopover(
            context,
            r,
            side: vertical,
            builder: (_) => PageStylePanel(control: page!),
          ),
        ),
      // Odak modunda ([small]) Konum düğmesi kaydırılan listenin DIŞINDA sabit
      // durur: yuva küçülse de taşıma her zaman erişilebilir.
      if (!small) _PositionButton(tools: t, size: size, vertical: vertical),
    ];
    final pinned = small ? _PositionButton(tools: t, size: size, vertical: vertical) : null;

    Widget content;
    final screen = MediaQuery.sizeOf(context);
    if (vertical) {
      final pad = MediaQuery.paddingOf(context);
      final maxH = math.max(120.0, screen.height - pad.vertical - 28);
      content = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH - (pinned == null ? 0 : size)),
        child: SingleChildScrollView(
          key: const Key('note-dock-scroll'),
          child: Column(mainAxisSize: MainAxisSize.min, children: items),
        ),
      );
      if (pinned != null) {
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [Flexible(child: content), pinned],
        );
      }
    } else {
      content = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: screen.width - 16 - (pinned == null ? 0 : size + 8)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: items),
        ),
      );
      if (pinned != null) {
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [Flexible(child: content), pinned],
        );
      }
    }
    return Material(
      key: const Key('note-dock'),
      color: cs.surface.withValues(alpha: 0.96),
      elevation: 6,
      borderRadius: BorderRadius.circular(size / 2 + 6),
      child: Padding(
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 6)
            : const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: content,
      ),
    );
  }
}

/// Geri al / yinele: büyük, devre dışıyken soluk; basılı tutunca hızla yineler.
class _HistoryButton extends StatefulWidget {
  const _HistoryButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.session,
    required this.enabled,
    required this.run,
  });
  final IconData icon;
  final String tooltip;
  final double size;
  final PdfInkSession? session;
  final bool Function(PdfInkSession) enabled;
  final void Function(PdfInkSession) run;

  @override
  State<_HistoryButton> createState() => _HistoryButtonState();
}

class _HistoryButtonState extends State<_HistoryButton> {
  Timer? _delay;
  Timer? _repeat;

  bool get _on {
    final s = widget.session;
    return s != null && widget.enabled(s);
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = _repeat = null;
  }

  void _down() {
    if (!_on) return;
    widget.run(widget.session!);
    _stop();
    _delay = Timer(const Duration(milliseconds: 450), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 140), (_) {
        if (!mounted || !_on) return _stop();
        widget.run(widget.session!);
      });
    });
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.session;
    return ListenableBuilder(
      listenable: s ?? const _NoListenable(),
      builder: (context, _) {
        final on = _on;
        return Tooltip(
          message: widget.tooltip,
          child: Semantics(
            button: true,
            enabled: on,
            label: widget.tooltip,
            onTap: on ? () => widget.run(s!) : null,
            child: Listener(
              onPointerDown: (_) => _down(),
              onPointerUp: (_) => _stop(),
              onPointerCancel: (_) => _stop(),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on
                      ? cs.secondaryContainer
                      : cs.onSurface.withValues(alpha: 0.05),
                ),
                child: Icon(
                  widget.icon,
                  size: widget.size * 0.55,
                  color: on
                      ? cs.onSecondaryContainer
                      : cs.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NoListenable implements Listenable {
  const _NoListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// "Konum": dokununca dört yönlü küçük menü; basılı tutup sürükleyince bırakılan
/// noktaya en yakın kenara taşınır.
class _PositionButton extends StatelessWidget {
  const _PositionButton({
    required this.tools,
    required this.size,
    required this.vertical,
  });
  final NoteToolSettings tools;
  final double size;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return _DockButton(
      key: const Key('note-dock-move'),
      icon: Icons.open_with,
      tooltip: 'Yuva konumu (dokun: seç, basılı tut ve sürükle: taşı)',
      size: size,
      // Düğmenin kendi uzun basışı (ipucununkini yener): bırakılan noktaya en yakın kenar.
      onLongPressEnd: (p) => tools.setDockPosition(
        nearestDockPosition(p, MediaQuery.sizeOf(context)),
      ),
      onTap: (r) => showToolPopover(
        context,
        r,
        side: vertical,
        builder: (_) => _PositionPanel(tools: tools),
      ),
    );
  }
}

class _PositionPanel extends StatelessWidget {
  const _PositionPanel({required this.tools});
  final NoteToolSettings tools;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tools,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Yuva konumu', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in DockPosition.values)
              ChoiceChip(
                key: Key('note-dock-pos-${p.name}'),
                avatar: Icon(_positionInfo[p]!.$1, size: 18),
                label: Text(_positionInfo[p]!.$2),
                selected: tools.dockPosition == p,
                onSelected: (_) {
                  tools.setDockPosition(p);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Konum düğmesini basılı tutup kenara sürükleyebilirsin.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

/// Dock düğmesi: [size] kare, seçiliyken dolgu; isteğe bağlı renk noktası ve yazı.
class _DockButton extends StatelessWidget {
  const _DockButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onTap,
    this.selected = false,
    this.dot,
    this.label,
    this.onLongPressEnd,
  });
  final void Function(Offset global)? onLongPressEnd;
  final IconData icon;
  final String tooltip;
  final double size;
  final void Function(Rect anchor)? onTap;
  final bool selected;
  final Color? dot;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final fg = !enabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : (selected ? cs.onPrimaryContainer : cs.onSurfaceVariant);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        label: tooltip,
        child: Material(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(size / 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(size / 2),
            onTap: onTap == null
                ? null
                : () {
                    final box = context.findRenderObject() as RenderBox;
                    onTap!(box.localToGlobal(Offset.zero) & box.size);
                  },
            child: GestureDetector(
              onLongPressEnd: onLongPressEnd == null
                  ? null
                  : (d) => onLongPressEnd!(d.globalPosition),
              child: SizedBox(
                height: size,
                width: label == null ? size : null,
                child: Padding(
                  padding: label == null
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (label == null)
                        Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            Icon(icon, color: fg, size: size * 0.5),
                            if (dot != null)
                              Positioned(
                                bottom: -size * 0.2,
                                child: Container(
                                  width: size * 0.3,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: dot,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                          ],
                        )
                      else ...[
                        Icon(icon, color: fg, size: size * 0.5),
                        const SizedBox(width: 6),
                        Text(label!, style: TextStyle(color: fg)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Kement seçimi eylemleri (sil, kopyala, yapıştır); yuvanın yanında küçük çubuk.
class _LassoActions extends StatelessWidget {
  const _LassoActions({
    required this.tools,
    required this.session,
    required this.size,
    this.vertical = false,
  });
  final NoteToolSettings tools;
  final PdfInkSession session;
  final double size;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface.withValues(alpha: 0.96),
      elevation: 4,
      borderRadius: BorderRadius.circular(size / 2),
      child: ListenableBuilder(
        listenable: session,
        builder: (_, _) {
          final children = [
            IconButton(
              key: const Key('note-sel-delete'),
              tooltip: 'Seçimi sil',
              icon: const Icon(Icons.delete_outline),
              onPressed: session.hasSelection ? session.deleteSelection : null,
            ),
            IconButton(
              key: const Key('note-sel-copy'),
              tooltip: 'Kopyala',
              icon: const Icon(Icons.copy_outlined),
              onPressed: session.hasSelection && !session.selectionBusy
                  ? () {
                      final c = session.copySelection();
                      if (c.isNotEmpty) tools.clipboard = c;
                    }
                  : null,
            ),
            IconButton(
              key: const Key('note-sel-paste'),
              tooltip: 'Yapıştır',
              icon: const Icon(Icons.paste_outlined),
              onPressed: () => session.pasteObjects(0, tools.clipboard),
            ),
          ];
          return vertical
              ? Column(mainAxisSize: MainAxisSize.min, children: children)
              : Row(mainAxisSize: MainAxisSize.min, children: children);
        },
      ),
    );
  }
}

/// Düğmenin yanında açılan ayar penceresi: düğmenin üstünde ya da altında (hangisinde
/// daha çok yer varsa); [side] iken (dikey yuva) düğmenin YANINDA, ekran dışına
/// taşmadan. Dışına dokununca kapanır; sayfaya dokunuş geçmez.
Future<void> showToolPopover(
  BuildContext context,
  Rect anchor, {
  required WidgetBuilder builder,
  bool side = false,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Kapat',
  barrierColor: Colors.transparent,
  transitionDuration: const Duration(milliseconds: 120),
  pageBuilder: (ctx, _, _) {
    final screen = MediaQuery.sizeOf(ctx);
    Widget card() => Material(
      key: const Key('note-popover'),
      elevation: 10,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(ctx).colorScheme.surface,
      child: SingleChildScrollView(
        child: Padding(padding: const EdgeInsets.all(12), child: builder(ctx)),
      ),
    );
    if (side) {
      return CustomSingleChildLayout(
        delegate: _SidePopoverLayout(anchor),
        child: card(),
      );
    }
    final above = anchor.top > screen.height - anchor.bottom;
    final w = math.min(380.0, screen.width - 16);
    final left = (anchor.center.dx - w / 2)
        .clamp(8.0, math.max(8.0, screen.width - w - 8))
        .toDouble();
    final maxH = math.max(
      120.0,
      above ? anchor.top - 16 : screen.height - anchor.bottom - 16,
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          width: w,
          top: above ? null : anchor.bottom + 8,
          bottom: above ? screen.height - anchor.top + 8 : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: card(),
          ),
        ),
      ],
    );
  },
);

/// Dikey yuvanın penceresi: düğmenin boş olan yanına (sol yarıdaysa sağına, değilse
/// soluna), düğmenin hizasında; ekran içinde tutulur.
class _SidePopoverLayout extends SingleChildLayoutDelegate {
  _SidePopoverLayout(this.anchor);
  final Rect anchor;

  bool _right(Size s) => anchor.center.dx < s.width / 2;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final s = c.biggest;
    final room = _right(s) ? s.width - anchor.right - 16 : anchor.left - 16;
    final w = math.min(380.0, math.max(math.min(220.0, s.width - 16), room));
    return BoxConstraints(
      maxWidth: w,
      maxHeight: math.max(120.0, s.height - 16),
    );
  }

  @override
  Offset getPositionForChild(Size s, Size child) {
    final x = _right(s) ? anchor.right + 8 : anchor.left - 8 - child.width;
    final y = anchor.top;
    return Offset(
      x.clamp(8.0, math.max(8.0, s.width - child.width - 8)).toDouble(),
      y.clamp(8.0, math.max(8.0, s.height - child.height - 8)).toDouble(),
    );
  }

  @override
  bool shouldRelayout(_SidePopoverLayout old) => old.anchor != anchor;
}

/// Araca göre ayar paneli: kalem türü, boyut + önizleme, renk, sertlik; silgi için
/// boyut ve çizgi/alan modu; şekil için şekil seçici + otomatik düzelt.
class NoteToolPanel extends StatelessWidget {
  const NoteToolPanel({super.key, required this.tools, required this.tool});
  final NoteToolSettings tools;
  final DockTool tool;

  String _name(NoteToolSettings t) => switch (tool) {
    DockTool.pen =>
      _kindInfo[t.kind == PenKind.highlighter ? t.lastPenKind : t.kind]!.$2,
    DockTool.highlighter => 'Fosforlu',
    DockTool.eraser => 'Silgi',
    DockTool.shape =>
      t.shapeTool == null ? 'Şekil' : shapeToolLabel(t.shapeTool!),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tools,
    builder: (context, _) {
      final t = tools;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _name(t),
            key: const Key('note-tool-name'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (tool == DockTool.pen) ...[
            Wrap(
              spacing: 8,
              children: [
                for (final k in const [
                  PenKind.ballpoint,
                  PenKind.fountain,
                  PenKind.pencil,
                ])
                  ChoiceChip(
                    key: Key('note-pen-kind-${k.name}'),
                    avatar: Icon(_kindInfo[k]!.$1, size: 18),
                    label: Text(_kindInfo[k]!.$2),
                    selected: t.kind == k,
                    onSelected: (_) => t.setKind(k),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (tool == DockTool.shape) ...[
            SwitchListTile(
              key: const Key('note-shape-snap'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Çizip basılı tut: otomatik düzelt'),
              value: t.shapeSnap,
              onChanged: t.setShapeSnap,
            ),
            const Text('Şekil çiz (sürükle, bırakınca düzgün olur)'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in ShapeTool.values)
                  ChoiceChip(
                    key: Key('note-shape-${s.name}'),
                    avatar: Icon(_shapeIcons[s], size: 18),
                    label: Text(shapeToolLabel(s)),
                    selected: t.shapeTool == s,
                    onSelected: (_) {
                      t.setShapeTool(s);
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (tool == DockTool.eraser) ...[
            _EraseModeCard(
              key: const Key('note-erase-mode-area'),
              selected: t.eraseMode == EraseMode.area,
              icon: Icons.blur_circular_outlined,
              title: 'Kısmi silgi (kalınlık)',
              subtitle:
                  'Yalnız silginin değdiği yeri siler; çizginin kalanı durur.',
              onTap: () => t.setEraseMode(EraseMode.area),
            ),
            const SizedBox(height: 6),
            _EraseModeCard(
              key: const Key('note-erase-mode-stroke'),
              selected: t.eraseMode == EraseMode.stroke,
              icon: Icons.timeline,
              title: 'Çizgi silgisi (tamamını sil)',
              subtitle: 'Değdiği çizgiyi baştan sona siler.',
              onTap: () => t.setEraseMode(EraseMode.stroke),
            ),
            const SizedBox(height: 8),
          ],
          _SizeSection(tools: t),
          if (tool != DockTool.eraser) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final c in t.palette)
                  InkWell(
                    key: Key('note-color-${c.toRadixString(16)}'),
                    customBorder: const CircleBorder(),
                    onTap: () => t.setColor(c),
                    child: Padding(
                      padding: const EdgeInsets.all(5), // 40 dp dokunma alanı
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: Color(c),
                        child: t.color == c
                            ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            if (penProfiles[t.kind]!.pressureSensitive)
              Row(
                children: [
                  const Text('Sertlik'),
                  Expanded(
                    child: Slider(
                      key: const Key('note-hardness'),
                      value: t.hardness,
                      onChanged: t.setHardness,
                    ),
                  ),
                ],
              ),
          ],
        ],
      );
    },
  );
}

/// Silgi modu kartı: seçili olan dolgulu, başlık + tek satır açıklama.
class _EraseModeCard extends StatelessWidget {
  const _EraseModeCard({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      child: Material(
        color: selected
            ? cs.primaryContainer
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_circle, color: cs.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SizeSection extends StatelessWidget {
  const _SizeSection({required this.tools});
  final NoteToolSettings tools;

  @override
  Widget build(BuildContext context) {
    final t = tools;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: t.eraser ? 128 : 64,
          width: double.infinity,
          child: CustomPaint(
            key: const Key('note-size-preview'),
            painter: _SizePreviewPainter(
              eraser: t.eraser,
              area: t.eraseMode == EraseMode.area,
              size: t.size,
              color: Color(t.eraser ? 0xFF455A64 : t.color),
              highlighter: !t.eraser && t.kind == PenKind.highlighter,
            ),
          ),
        ),
        Row(
          children: [
            const Text('Kalınlık'),
            Expanded(
              child: Slider(
                key: const Key('note-size-slider'),
                min: t.sizeMin,
                max: t.sizeMax,
                value: t.size.clamp(t.sizeMin, t.sizeMax),
                onChanged: t.setSize,
              ),
            ),
            Text('${t.size.round()}'),
          ],
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final v in t.sizeLevels)
              ChoiceChip(
                key: Key('note-size-chip-${v.toInt()}'),
                label: Text('${v.toInt()}'),
                selected: (t.size - v).abs() < 0.5,
                onSelected: (_) => t.setSize(v),
              ),
          ],
        ),
      ],
    );
  }
}

/// Canlı önizleme: silgide yarıçap dairesi, kalemde örnek çizgi (fosforluda saydam bant).
class _SizePreviewPainter extends CustomPainter {
  _SizePreviewPainter({
    required this.eraser,
    this.area = true,
    required this.size,
    required this.color,
    required this.highlighter,
  });
  final bool eraser;
  final bool area;
  final double size;
  final Color color;
  final bool highlighter;

  @override
  void paint(Canvas canvas, Size box) {
    final c = box.center(Offset.zero);
    if (eraser) {
      canvas.save();
      canvas.clipRect(Offset.zero & box);
      // Örnek çizgi: kısmi silgide yalnız dairenin değdiği yer kopar, çizgi silgisinde bütün kalkar.
      final line = Paint()
        ..color = const Color(0xFF9E9E9E)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      if (area) {
        canvas.drawLine(
          Offset(12, c.dy),
          Offset(math.max(12, c.dx - size), c.dy),
          line,
        );
        canvas.drawLine(
          Offset(math.min(box.width - 12, c.dx + size), c.dy),
          Offset(box.width - 12, c.dy),
          line,
        );
      } else {
        canvas.drawLine(
          Offset(12, c.dy),
          Offset(box.width - 12, c.dy),
          line..color = const Color(0x449E9E9E),
        );
      }
      canvas.drawCircle(c, size, Paint()..color = const Color(0x22000000));
      canvas.drawCircle(
        c,
        size,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.restore();
      return;
    }
    final paint = Paint()
      ..color = highlighter ? color.withValues(alpha: 0.35) : color
      ..strokeWidth = size
      ..strokeCap = highlighter ? StrokeCap.butt : StrokeCap.round;
    canvas.drawLine(Offset(12, c.dy), Offset(box.width - 12, c.dy), paint);
  }

  @override
  bool shouldRepaint(_SizePreviewPainter old) =>
      old.eraser != eraser ||
      old.area != area ||
      old.size != size ||
      old.color != color ||
      old.highlighter != highlighter;
}

/// "Sayfa" penceresinin durumu ve eylemleri (dock ve sayfa menüsü aynısını kullanır).
class PageStyleControl {
  const PageStyleControl({
    required this.template,
    required this.background,
    required this.spacing,
    required this.onTemplate,
    required this.onTemplateAll,
    required this.onBackground,
    required this.onSpacing,
    this.onTranscribe,
  });

  /// "Sayfayı metne çevir" (el yazısı tanıma); null ise düğme gösterilmez.
  final VoidCallback? onTranscribe;

  final PageTemplate template;
  final int background;

  /// Çizgi aralığı çarpanı (yalnızca oturumda tutulur).
  final double spacing;
  final ValueChanged<PageTemplate> onTemplate;
  final ValueChanged<PageTemplate> onTemplateAll;
  final ValueChanged<int> onBackground;
  final ValueChanged<double> onSpacing;
}

/// Sayfa şablonu (tek dokunuşla), arka plan rengi ve çizgi aralığı.
/// Seçimler hemen uygulanır; pencere açıkken seçili görünüm yerelde güncellenir.
class PageStylePanel extends StatefulWidget {
  const PageStylePanel({super.key, required this.control});
  final PageStyleControl control;

  @override
  State<PageStylePanel> createState() => _PageStylePanelState();
}

class _PageStylePanelState extends State<PageStylePanel> {
  late PageTemplate _template = widget.control.template;
  late int _background = widget.control.background;
  late double _spacing = widget.control.spacing;

  @override
  Widget build(BuildContext context) {
    final c = widget.control;
    final label = Theme.of(context).textTheme.labelLarge;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sayfa', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('Şablon (bu sayfa)', style: label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in PageTemplate.values)
              ChoiceChip(
                key: Key('note-template-${p.key}'),
                avatar: Icon(templateIcon(p), size: 18),
                label: Text(templateLabel(p)),
                selected: p == _template,
                onSelected: (_) {
                  setState(() => _template = p);
                  c.onTemplate(p);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Tüm sayfalara uygula', style: label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in PageTemplate.values)
              ActionChip(
                key: Key('note-template-all-${p.key}'),
                avatar: Icon(templateIcon(p), size: 18),
                label: Text(templateLabel(p)),
                onPressed: () {
                  setState(() => _template = p);
                  c.onTemplateAll(p);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Arka plan', style: label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final b in pageBackgrounds)
              ChoiceChip(
                key: Key('note-bg-${b.$1}'),
                avatar: CircleAvatar(
                  radius: 8,
                  backgroundColor: Color(b.$3),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black26),
                    ),
                  ),
                ),
                label: Text(b.$2),
                selected: _background == b.$3,
                onSelected: (_) {
                  setState(() => _background = b.$3);
                  c.onBackground(b.$3);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Çizgi aralığı (bu oturumda)', style: label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final s in pageSpacings)
              ChoiceChip(
                key: Key('note-spacing-${s.$1}'),
                label: Text(s.$2),
                selected: (_spacing - s.$3).abs() < 1e-6,
                onSelected: (_) {
                  setState(() => _spacing = s.$3);
                  c.onSpacing(s.$3);
                },
              ),
          ],
        ),
        if (c.onTranscribe != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('note-transcribe-dock'),
            onPressed: c.onTranscribe,
            icon: const Icon(Icons.text_fields_rounded),
            label: const Text('Sayfayı metne çevir'),
          ),
        ],
      ],
    );
  }
}
