import 'dart:math' as math;

import 'package:flutter/material.dart';

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

/// Ekranda yüzen araç yuvası: kalem, fosforlu, silgi, kement, şekil; iki yanda geri al /
/// yinele; yanında "Sayfa" (şablon) ve ⇅ (alta/üste taşı). Seçili araca yeniden
/// dokununca o aracın ayar penceresi açılır.
///
/// Yuva sayfanın ÜSTÜNDE yüzer (sayfa alanı küçülmez); yalnızca kendi alanındaki
/// dokunuşu tutar. Telefonda (<600 dp) düğmeler küçülür ve yuva yatay kayar;
/// odak modunda ("[small]") "Sayfa" ve ⇅ gizlenir, düğmeler biraz küçülür.
class NoteToolDock extends StatelessWidget {
  const NoteToolDock({
    super.key,
    required this.tools,
    required this.session,
    required this.page,
    this.small = false,
  });

  final NoteToolSettings tools;

  /// Sayfa değişirken null olabilir (geri al/yinele kapalı).
  final PdfInkSession? session;

  /// "Sayfa" penceresinin eylemleri ve durumu.
  final PageStyleControl page;

  /// Odak modu: küçük yuva.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    final size = phone ? 40.0 : (small ? 44.0 : 52.0);
    return ListenableBuilder(
      listenable: tools,
      builder: (context, _) {
        final t = tools;
        final top = t.dockAtTop;
        final actions = t.lasso && session != null ? _LassoActions(tools: t, session: session!, size: size) : null;
        final dock = _DockBar(tools: t, session: session, page: page, size: size, phone: phone, small: small);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actions != null && !top) ...[actions, const SizedBox(height: 6)],
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
  });
  final NoteToolSettings tools;
  final PdfInkSession? session;
  final PageStyleControl page;
  final double size;
  final bool phone;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = tools;
    final cs = Theme.of(context).colorScheme;
    final penActive = !t.eraser && !t.lasso && t.shapeTool == null && t.kind != PenKind.highlighter;
    final hlActive = !t.eraser && !t.lasso && t.shapeTool == null && t.kind == PenKind.highlighter;
    final kind = t.lastPenKind;

    void pop(DockTool tool, Rect anchor) => showToolPopover(
      context,
      anchor,
      builder: (_) => NoteToolPanel(tools: t, tool: tool),
    );

    final s = session;
    Widget history(Key key, String tip, IconData icon, bool Function(PdfInkSession) enabled, void Function(PdfInkSession) run) {
      if (s == null) return _DockButton(key: key, icon: icon, tooltip: tip, size: size, onTap: null);
      return ListenableBuilder(
        listenable: s,
        builder: (_, _) =>
            _DockButton(key: key, icon: icon, tooltip: tip, size: size, onTap: enabled(s) ? (_) => run(s) : null),
      );
    }

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        history(
          const Key('note-undo'),
          'Geri al',
          Icons.undo_rounded,
          (s) => s.canUndo && !s.erasing,
          (s) => s.undo(),
        ),
        const SizedBox(width: 4),
        _DockButton(
          key: const Key('note-pen'),
          icon: _kindInfo[kind]!.$1,
          tooltip: _kindInfo[kind]!.$2,
          selected: penActive,
          dot: Color(t.colorFor(kind)),
          size: size,
          onTap: (r) => penActive ? pop(DockTool.pen, r) : t.setKind(kind),
        ),
        _DockButton(
          key: const Key('note-pen-highlighter'),
          icon: _kindInfo[PenKind.highlighter]!.$1,
          tooltip: 'Fosforlu',
          selected: hlActive,
          dot: Color(t.colorFor(PenKind.highlighter)),
          size: size,
          onTap: (r) => hlActive ? pop(DockTool.highlighter, r) : t.setKind(PenKind.highlighter),
        ),
        _DockButton(
          key: const Key('note-eraser'),
          icon: Icons.auto_fix_normal_outlined,
          tooltip: 'Silgi',
          selected: t.eraser,
          size: size,
          onTap: (r) => t.eraser ? pop(DockTool.eraser, r) : t.setEraser(true),
        ),
        _DockButton(
          key: const Key('note-lasso'),
          icon: Icons.gesture,
          tooltip: 'Kement (seç, taşı, boyutlandır)',
          selected: t.lasso,
          size: size,
          // Seçiliyken yeniden dokunmak kalemi geri getirir.
          onTap: (_) => t.lasso ? t.setKind(kind) : t.setLasso(true),
        ),
        _DockButton(
          key: const Key('note-shape'),
          icon: t.shapeTool == null ? Icons.category_outlined : _shapeIcons[t.shapeTool]!,
          tooltip: 'Şekil: çiz ve düzelt',
          selected: t.shapeTool != null,
          size: size,
          onTap: (r) => pop(DockTool.shape, r),
        ),
        const SizedBox(width: 4),
        history(
          const Key('note-redo'),
          'Yinele',
          Icons.redo_rounded,
          (s) => s.canRedo && !s.erasing,
          (s) => s.redo(),
        ),
        if (!small) ...[
          SizedBox(height: size * 0.6, child: const VerticalDivider(width: 12)),
          _DockButton(
            key: const Key('note-template'),
            icon: templateIcon(page.template),
            tooltip: 'Sayfa: şablon, arka plan, çizgi aralığı',
            label: phone ? null : 'Sayfa',
            size: size,
            onTap: (r) => showToolPopover(
              context,
              r,
                      builder: (_) => PageStylePanel(control: page),
            ),
          ),
          _DockButton(
            key: const Key('note-dock-move'),
            icon: t.dockAtTop ? Icons.vertical_align_bottom : Icons.vertical_align_top,
            tooltip: t.dockAtTop ? 'Yuvayı alta al' : 'Yuvayı üste al',
            size: size,
            onTap: (_) => t.setDockAtTop(!t.dockAtTop),
          ),
        ],
      ],
    );
    return Material(
      key: const Key('note-dock'),
      color: cs.surface.withValues(alpha: 0.96),
      elevation: 6,
      borderRadius: BorderRadius.circular(size / 2 + 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width - 16),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: row),
        ),
      ),
    );
  }
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
  });
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
    final fg = !enabled ? cs.onSurface.withValues(alpha: 0.38) : (selected ? cs.onPrimaryContainer : cs.onSurfaceVariant);
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
            child: SizedBox(
              height: size,
              width: label == null ? size : null,
              child: Padding(
                padding: label == null ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12),
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
                                decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2)),
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
    );
  }
}

/// Kement seçimi eylemleri (sil, kopyala, yapıştır); yuvanın yanında küçük çubuk.
class _LassoActions extends StatelessWidget {
  const _LassoActions({required this.tools, required this.session, required this.size});
  final NoteToolSettings tools;
  final PdfInkSession session;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface.withValues(alpha: 0.96),
      elevation: 4,
      borderRadius: BorderRadius.circular(size / 2),
      child: ListenableBuilder(
        listenable: session,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
      ),
    );
  }
}

/// Düğmenin yanında açılan ayar penceresi: düğmenin üstünde ya da altında (hangisinde
/// daha çok yer varsa). Dışına dokununca kapanır; sayfaya dokunuş geçmez.
Future<void> showToolPopover(
  BuildContext context,
  Rect anchor, {
  required WidgetBuilder builder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Kapat',
  barrierColor: Colors.transparent,
  transitionDuration: const Duration(milliseconds: 120),
  pageBuilder: (ctx, _, _) {
    final screen = MediaQuery.sizeOf(ctx);
    final above = anchor.top > screen.height - anchor.bottom;
    final w = math.min(380.0, screen.width - 16);
    final left = (anchor.center.dx - w / 2).clamp(8.0, math.max(8.0, screen.width - w - 8)).toDouble();
    final maxH = math.max(120.0, above ? anchor.top - 16 : screen.height - anchor.bottom - 16);
    return Stack(
      children: [
        Positioned(
          left: left,
          width: w,
          top: above ? null : anchor.bottom + 8,
          bottom: above ? screen.height - anchor.top + 8 : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Material(
              key: const Key('note-popover'),
              elevation: 10,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(ctx).colorScheme.surface,
              child: SingleChildScrollView(
                child: Padding(padding: const EdgeInsets.all(12), child: builder(ctx)),
              ),
            ),
          ),
        ),
      ],
    );
  },
);

/// Araca göre ayar paneli: kalem türü, boyut + önizleme, renk, sertlik; silgi için
/// boyut ve çizgi/alan modu; şekil için şekil seçici + otomatik düzelt.
class NoteToolPanel extends StatelessWidget {
  const NoteToolPanel({super.key, required this.tools, required this.tool});
  final NoteToolSettings tools;
  final DockTool tool;

  String _name(NoteToolSettings t) => switch (tool) {
    DockTool.pen => _kindInfo[t.kind == PenKind.highlighter ? t.lastPenKind : t.kind]!.$2,
    DockTool.highlighter => 'Fosforlu',
    DockTool.eraser => 'Silgi',
    DockTool.shape => t.shapeTool == null ? 'Şekil' : shapeToolLabel(t.shapeTool!),
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
          Text(_name(t), key: const Key('note-tool-name'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (tool == DockTool.pen) ...[
            Wrap(
              spacing: 8,
              children: [
                for (final k in const [PenKind.ballpoint, PenKind.fountain, PenKind.pencil])
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
            SegmentedButton<EraseMode>(
              key: const Key('note-erase-mode'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: EraseMode.stroke, label: Text('Çizgi'), icon: Icon(Icons.timeline)),
                ButtonSegment(value: EraseMode.area, label: Text('Alan'), icon: Icon(Icons.blur_circular_outlined)),
              ],
              selected: {t.eraseMode},
              onSelectionChanged: (s) => t.setEraseMode(s.first),
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
                        child: t.color == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
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
                    child: Slider(key: const Key('note-hardness'), value: t.hardness, onChanged: t.setHardness),
                  ),
                ],
              ),
          ],
        ],
      );
    },
  );
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
          height: 64,
          width: double.infinity,
          child: CustomPaint(
            key: const Key('note-size-preview'),
            painter: _SizePreviewPainter(
              eraser: t.eraser,
              size: t.size,
              color: Color(t.eraser ? 0xFF455A64 : t.color),
              highlighter: !t.eraser && t.kind == PenKind.highlighter,
            ),
          ),
        ),
        Row(
          children: [
            Text(t.eraser ? 'Yarıçap' : 'Kalınlık'),
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
  _SizePreviewPainter({required this.eraser, required this.size, required this.color, required this.highlighter});
  final bool eraser;
  final double size;
  final Color color;
  final bool highlighter;

  @override
  void paint(Canvas canvas, Size box) {
    final c = box.center(Offset.zero);
    if (eraser) {
      canvas.drawCircle(c, size, Paint()..color = const Color(0x22000000));
      canvas.drawCircle(
        c,
        size,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
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
      old.eraser != eraser || old.size != size || old.color != color || old.highlighter != highlighter;
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
  });

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
      ],
    );
  }
}
