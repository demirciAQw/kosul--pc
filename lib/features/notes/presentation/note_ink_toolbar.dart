import 'package:flutter/material.dart';

import '../../ink/domain/pen_profiles.dart';
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

  static const _kindIcons = {
    PenKind.ballpoint: (Icons.edit_outlined, 'Tükenmez'),
    PenKind.fountain: (Icons.brush_outlined, 'Dolma kalem'),
    PenKind.pencil: (Icons.create_outlined, 'Kurşun kalem'),
    PenKind.highlighter: (Icons.border_color_outlined, 'Fosforlu'),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: tools,
      builder: (context, _) {
        final t = tools;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const SizedBox(width: 8),
              for (final e in _kindIcons.entries)
                IconButton(
                  key: Key('note-pen-${e.key.name}'),
                  tooltip: e.value.$2,
                  isSelected: !t.eraser && t.kind == e.key,
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
              const SizedBox(width: 8),
              if (t.eraser) ...[
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
                const SizedBox(width: 8),
                for (final w in t.widthLevels)
                  InkWell(
                    key: Key('note-width-${w.toInt()}'),
                    customBorder: const CircleBorder(),
                    onTap: () => t.setWidth(w),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        width: 6 + w.clamp(1, 16),
                        height: 6 + w.clamp(1, 16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: t.width == w ? cs.primary : cs.outline,
                        ),
                      ),
                    ),
                  ),
                if (penProfiles[t.kind]!.pressureSensitive)
                  Tooltip(
                    message: 'Sertlik (baskı eğrisi)',
                    child: SizedBox(
                      width: 120,
                      child: Slider(
                        key: const Key('note-hardness'),
                        value: t.hardness,
                        onChanged: t.setHardness,
                      ),
                    ),
                  ),
              ],
              const SizedBox(width: 8),
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
                const Row(children: [
                  IconButton(onPressed: null, icon: Icon(Icons.undo_rounded)),
                  IconButton(onPressed: null, icon: Icon(Icons.redo_rounded)),
                ]),
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
              const SizedBox(width: 8),
            ],
          ),
        );
      },
    );
  }
}
