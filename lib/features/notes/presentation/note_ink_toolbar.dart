import 'package:flutter/material.dart';

import '../../../app/tablet.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../ink/domain/shape_recognizer.dart';
import '../../pdf/presentation/pdf_ink_session.dart';
import '../domain/page_template.dart';
import 'note_tool_settings.dart';
import 'page_template_painter.dart';

/// Tek satır araç çubuğu: kalem türü, silgi, renk, kalınlık, sertlik, geri al/yinele, şablon.
class NoteInkToolbar extends StatelessWidget {
  const NoteInkToolbar({
    super.key,
    required this.tools,
    required this.session,
    required this.template,
    required this.onTemplate,
    required this.onTemplateAll,
  });

  final NoteToolSettings tools;

  /// Sayfa değişirken null olabilir (geri al/yinele kapalı).
  final PdfInkSession? session;
  final PageTemplate template;
  final ValueChanged<PageTemplate> onTemplate;
  final ValueChanged<PageTemplate> onTemplateAll;

  /// Seçili aracın görünen adı.
  static String _toolName(NoteToolSettings t) {
    if (t.lasso) return 'Kement';
    if (t.eraser) return 'Silgi';
    if (t.shapeTool != null) return shapeToolLabel(t.shapeTool!);
    return _kindIcons[t.kind]!.$2;
  }

  static const _kindIcons = {
    PenKind.ballpoint: (Icons.edit_outlined, 'Tükenmez'),
    PenKind.fountain: (Icons.brush_outlined, 'Dolma'),
    PenKind.pencil: (Icons.create_outlined, 'Kurşun'),
    PenKind.highlighter: (Icons.border_color_outlined, 'Fosforlu'),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tools,
      builder: (context, _) {
        final t = tools;
        // Dar tablette (dikey) sertlik "…" menüsüne iner;
        // telefonda ve geniş tablette olduğu gibi.
        final compact = isTabletContext(context) && MediaQuery.sizeOf(context).width < kToolbarCompactWidth;
        return Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    for (final e in _kindIcons.entries)
                      IconButton(
                        key: Key('note-pen-${e.key.name}'),
                        tooltip: e.value.$2,
                        isSelected: !t.eraser && !t.lasso && t.kind == e.key,
                        icon: Icon(e.value.$1),
                        onPressed: () => t.setKind(e.key),
                      ),
                    IconButton(
                      key: const Key('note-eraser'),
                      tooltip: 'Silgi',
                      isSelected: t.eraser,
                      icon: const Icon(Icons.auto_fix_normal_outlined),
                      onPressed: () => t.setEraser(true),
                    ),
                    IconButton(
                      key: const Key('note-lasso'),
                      tooltip: 'Kement (seç, taşı, boyutlandır)',
                      isSelected: t.lasso,
                      icon: const Icon(Icons.gesture),
                      onPressed: () => t.setLasso(true),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        _toolName(t),
                        key: const Key('note-tool-name'),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    _ShapeButton(tools: t),
                    if (!t.lasso) _SizeButton(tools: t),
                    const SizedBox(width: 8),
                    if (t.lasso) ...[
                      if (session != null)
                        ListenableBuilder(
                          listenable: session!,
                          builder: (_, _) => Row(
                            children: [
                              IconButton(
                                key: const Key('note-sel-delete'),
                                tooltip: 'Seçimi sil',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: session!.hasSelection ? session!.deleteSelection : null,
                              ),
                              IconButton(
                                key: const Key('note-sel-copy'),
                                tooltip: 'Kopyala',
                                icon: const Icon(Icons.copy_outlined),
                                onPressed: session!.hasSelection && !session!.selectionBusy
                                    ? () {
                                        final c = session!.copySelection();
                                        if (c.isNotEmpty) t.clipboard = c;
                                      }
                                    : null,
                              ),
                              IconButton(
                                key: const Key('note-sel-paste'),
                                tooltip: 'Yapıştır',
                                icon: const Icon(Icons.paste_outlined),
                                onPressed: () => session!.pasteObjects(0, t.clipboard),
                              ),
                            ],
                          ),
                        ),
                    ] else if (t.eraser) ...[
                      SegmentedButton<EraseMode>(
                        key: const Key('note-erase-mode'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: EraseMode.stroke, label: Text('Çizgi'), icon: Icon(Icons.timeline)),
                          ButtonSegment(
                            value: EraseMode.area,
                            label: Text('Alan'),
                            icon: Icon(Icons.blur_circular_outlined),
                          ),
                        ],
                        selected: {t.eraseMode},
                        onSelectionChanged: (s) => t.setEraseMode(s.first),
                      ),
                    ] else ...[
                      for (final c in t.palette)
                        InkWell(
                          key: Key('note-color-${c.toRadixString(16)}'),
                          customBorder: const CircleBorder(),
                          onTap: () => t.setColor(c),
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: CircleAvatar(
                              radius: 11,
                              backgroundColor: Color(c),
                              child: t.color == c ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                            ),
                          ),
                        ),
                      if (!compact && penProfiles[t.kind]!.pressureSensitive)
                        Tooltip(
                          message: 'Sertlik (baskı eğrisi)',
                          child: SizedBox(
                            width: 120,
                            child: Slider(key: const Key('note-hardness'), value: t.hardness, onChanged: t.setHardness),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (session != null)
              ListenableBuilder(
                listenable: session!,
                builder: (_, _) => Row(
                  children: [
                    IconButton(
                      key: const Key('note-undo'),
                      tooltip: 'Geri al',
                      icon: const Icon(Icons.undo_rounded),
                      onPressed: session!.canUndo && !session!.erasing ? session!.undo : null,
                    ),
                    IconButton(
                      key: const Key('note-redo'),
                      tooltip: 'Yinele',
                      icon: const Icon(Icons.redo_rounded),
                      onPressed: session!.canRedo && !session!.erasing ? session!.redo : null,
                    ),
                  ],
                ),
              )
            else
              const Row(
                children: [
                  IconButton(onPressed: null, icon: Icon(Icons.undo_rounded)),
                  IconButton(onPressed: null, icon: Icon(Icons.redo_rounded)),
                ],
              ),
            if (compact)
              PopupMenuButton<String>(
                key: const Key('note-more'),
                tooltip: 'Diğer araçlar',
                icon: const Icon(Icons.more_horiz),
                itemBuilder: (_) => [
                  if (!t.eraser && !t.lasso && penProfiles[t.kind]!.pressureSensitive) _HardnessMenuEntry(tools: t),
                  const PopupMenuItem(enabled: false, height: 32, child: Text('Boyut ve şekil: araç çubuğunda')),
                ],
              ),
            PopupMenuButton<(PageTemplate, bool)>(
              key: const Key('note-template'),
              tooltip: 'Sayfa şablonu',
              icon: Icon(templateIcon(template)),
              onSelected: (v) => v.$2 ? onTemplateAll(v.$1) : onTemplate(v.$1),
              itemBuilder: (_) => [
                for (final p in PageTemplate.values)
                  PopupMenuItem(
                    key: Key('note-template-${p.key}'),
                    value: (p, false),
                    child: ListTile(
                      dense: true,
                      leading: Icon(templateIcon(p)),
                      title: Text('${templateLabel(p)} (bu sayfa)'),
                      selected: p == template,
                    ),
                  ),
                const PopupMenuDivider(),
                for (final p in PageTemplate.values)
                  PopupMenuItem(
                    key: Key('note-template-all-${p.key}'),
                    value: (p, true),
                    child: ListTile(
                      dense: true,
                      leading: Icon(templateIcon(p)),
                      title: Text('${templateLabel(p)} (tüm sayfalar)'),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        );
      },
    );
  }
}

/// "…" menüsündeki sertlik sürgüsü. `PopupMenuItem(enabled: false)` soluk ve
/// "devre dışı" görünürdü; bu girdi etkin, dokunuşta menüyü kapatmaz (InkWell
/// yok), sürgü değeri doğrudan [NoteToolSettings]'e yazar.
class _HardnessMenuEntry extends PopupMenuEntry<String> {
  const _HardnessMenuEntry({required this.tools});
  final NoteToolSettings tools;

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(String? value) => false;

  @override
  State<_HardnessMenuEntry> createState() => _HardnessMenuEntryState();
}

class _HardnessMenuEntryState extends State<_HardnessMenuEntry> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        const Text('Sertlik'),
        Expanded(
          child: Slider(
            key: const Key('note-hardness'),
            value: widget.tools.hardness,
            onChanged: (v) {
              widget.tools.setHardness(v);
              setState(() {});
            },
          ),
        ),
      ],
    ),
  );
}

const _shapeIcons = {
  ShapeTool.line: Icons.horizontal_rule,
  ShapeTool.arrow: Icons.arrow_right_alt,
  ShapeTool.circle: Icons.circle_outlined,
  ShapeTool.ellipse: Icons.panorama_fish_eye,
  ShapeTool.rectangle: Icons.crop_square,
  ShapeTool.triangle: Icons.change_history,
};

/// "Şekil" düğmesi: otomatik düzeltme anahtarı ve doğrudan şekil araçları penceresi.
class _ShapeButton extends StatelessWidget {
  const _ShapeButton({required this.tools});
  final NoteToolSettings tools;

  @override
  Widget build(BuildContext context) {
    final active = tools.shapeTool != null;
    return PopupMenuButton<void>(
      key: const Key('note-shape'),
      tooltip: 'Şekil: çiz ve düzelt',
      itemBuilder: (_) => [_ShapePanelEntry(tools: tools)],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? _shapeIcons[tools.shapeTool] : Icons.category_outlined, size: 20),
            const SizedBox(width: 4),
            Text('Şekil', style: TextStyle(fontWeight: active || tools.shapeSnap ? FontWeight.bold : null)),
          ],
        ),
      ),
    );
  }
}

class _ShapePanelEntry extends PopupMenuEntry<void> {
  const _ShapePanelEntry({required this.tools});
  final NoteToolSettings tools;

  @override
  double get height => 200;

  @override
  bool represents(void value) => false;

  @override
  State<_ShapePanelEntry> createState() => _ShapePanelEntryState();
}

class _ShapePanelEntryState extends State<_ShapePanelEntry> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.tools,
    builder: (context, _) {
      final t = widget.tools;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              spacing: 4,
              runSpacing: 4,
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
          ],
        ),
      );
    },
  );
}

/// "Boyut" düğmesi: kalem seçiliyken kalınlık, silgi seçiliyken silgi yarıçapı.
class _SizeButton extends StatelessWidget {
  const _SizeButton({required this.tools});
  final NoteToolSettings tools;

  @override
  Widget build(BuildContext context) => PopupMenuButton<void>(
    key: const Key('note-size'),
    tooltip: tools.eraser ? 'Silgi boyutu' : 'Kalem boyutu',
    itemBuilder: (_) => [_SizePanelEntry(tools: tools)],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.line_weight, size: 20),
          const SizedBox(width: 4),
          Text('Boyut ${tools.size.round()}'),
        ],
      ),
    ),
  );
}

class _SizePanelEntry extends PopupMenuEntry<void> {
  const _SizePanelEntry({required this.tools});
  final NoteToolSettings tools;

  @override
  double get height => 190;

  @override
  bool represents(void value) => false;

  @override
  State<_SizePanelEntry> createState() => _SizePanelEntryState();
}

class _SizePanelEntryState extends State<_SizePanelEntry> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.tools,
    builder: (context, _) {
      final t = widget.tools;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 64,
              width: 200,
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
              ],
            ),
            Wrap(
              spacing: 4,
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
        ),
      );
    },
  );
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
