import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ink/domain/pen_profiles.dart';
import '../../ink/presentation/ink_mask.dart';
import '../../pdf/presentation/pdf_ink_session.dart';
import 'note_tool_dock.dart';
import 'note_tool_settings.dart';

/// Rengi seçici penceresinde gösterilen en çok renk sayısı ("+" hariç).
const railMaxColors = 8;

/// Sol dikey araç çubuğu (Google PDF Okuyucu tarzı): kalem, fosforlu, silgi | geri al, yinele |
/// çizimleri gizle (göz) | kement, şekil, (soru seç, metin, foto, alt sayfa) | "...".
/// Seçili araç dolgu daireyle vurgulanır; seçiliyken yeniden dokunmak yanında ayar penceresi açar.
/// Çubuk yerel Ink katmanında maskelenir ([InkMask]): kalem üstüne yazmaz.
/// YALNIZCA `Stack` içinde kullanılır (`Positioned.fill` döner); dikeyde ortalanır.
class ToolRail extends StatelessWidget {
  const ToolRail({
    super.key,
    required this.tools,
    required this.session,
    this.page,
    this.selecting = false,
    this.onSelect,
    this.itemTools = false,
    this.onPhoto,
    this.small = false,
    this.topInset = 64,
  });

  final NoteToolSettings tools;
  final PdfInkSession? session;
  final PageStyleControl? page;
  final bool selecting;
  final VoidCallback? onSelect;
  final bool itemTools;
  final VoidCallback? onPhoto;
  final bool small;

  /// Üstte bırakılacak boşluk (katman gezinme hapı gibi öğelerle çakışmasın).
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final phone = screen.width < 600;
    final size = phone ? 40.0 : (small ? 44.0 : 48.0);
    final maxH = math.max(120.0, screen.height - pad.vertical - topInset - 16);
    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.fromLTRB(8 + pad.left, topInset + pad.top, 8, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: Listenable.merge([tools, if (session != null) session!]),
            builder: (context, _) => ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  InkMask(child: _RailBar(this, size: size, phone: phone, maxHeight: maxH)),
                  if (tools.lasso && session != null) ...[
                    const SizedBox(width: 6),
                    InkMask(
                      child: DockLassoActions(tools: tools, session: session!, size: size, vertical: true),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailBar extends StatelessWidget {
  const _RailBar(this.rail, {required this.size, required this.phone, required this.maxHeight});
  final ToolRail rail;
  final double size;
  final bool phone;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final t = rail.tools;
    final s = rail.session;
    final selecting = rail.selecting;
    final cs = Theme.of(context).colorScheme;
    final kind = t.lastPenKind;
    final free = !selecting && !t.eraser && !t.lasso && t.shapeTool == null && t.itemTool == ItemTool.none;
    final penActive = free && t.kind != PenKind.highlighter;
    final hlActive = free && t.kind == PenKind.highlighter;
    final hidden = s?.inkHidden ?? false;

    // Bir araç seçilince: soru seçimi kapanır, gizli çizimler geri gelir.
    void pick(VoidCallback act) {
      if (selecting) rail.onSelect?.call();
      s?.setInkHidden(false);
      act();
    }

    void pop(DockTool tool, Rect anchor) => showToolPopover(
      context,
      anchor,
      side: true,
      builder: (_) => RailToolPanel(tools: t, tool: tool),
    );

    Widget history(Key key, String tip, IconData icon, bool Function(PdfInkSession) en, void Function(PdfInkSession) run) =>
        DockHistoryButton(key: key, icon: icon, tooltip: tip, size: size, session: s, enabled: en, run: run);

    Widget divider() => SizedBox(width: size * 0.6, child: const Divider(height: 12));

    final items = <Widget>[
      DockButton(
        key: const Key('note-pen'),
        icon: dockKindInfo[kind]!.$1,
        tooltip: dockKindInfo[kind]!.$2,
        selected: penActive,
        dot: Color(t.colorFor(kind)),
        size: size,
        onTap: (r) => penActive ? pop(DockTool.pen, r) : pick(() => t.setKind(kind)),
      ),
      DockButton(
        key: const Key('note-pen-highlighter'),
        icon: dockKindInfo[PenKind.highlighter]!.$1,
        tooltip: 'Fosforlu',
        selected: hlActive,
        dot: Color(t.colorFor(PenKind.highlighter)),
        size: size,
        onTap: (r) => hlActive ? pop(DockTool.highlighter, r) : pick(() => t.setKind(PenKind.highlighter)),
      ),
      DockButton(
        key: const Key('note-eraser'),
        icon: Icons.auto_fix_normal_outlined,
        tooltip: 'Silgi',
        selected: !selecting && t.eraser,
        size: size,
        onTap: (r) => !selecting && t.eraser ? pop(DockTool.eraser, r) : pick(() => t.setEraser(true)),
      ),
      divider(),
      history(const Key('note-undo'), 'Geri al', Icons.undo_rounded, (x) => x.canUndo && !x.erasing, (x) => x.undo()),
      const SizedBox(height: 4),
      history(const Key('note-redo'), 'Yinele', Icons.redo_rounded, (x) => x.canRedo && !x.erasing, (x) => x.redo()),
      divider(),
      DockButton(
        key: const Key('note-ink-hide'),
        icon: hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        tooltip: hidden ? 'Çizimleri göster' : 'Çizimleri gizle',
        selected: hidden,
        size: size,
        onTap: s == null ? null : (_) => s.setInkHidden(!hidden),
      ),
      divider(),
      DockButton(
        key: const Key('note-lasso'),
        icon: Icons.gesture,
        tooltip: 'Kement (seç, taşı, boyutlandır)',
        selected: !selecting && t.lasso,
        size: size,
        onTap: (_) => !selecting && t.lasso ? t.setKind(kind) : pick(() => t.setLasso(true)),
      ),
      DockButton(
        key: const Key('note-shape'),
        icon: t.shapeTool == null ? Icons.category_outlined : dockShapeIcons[t.shapeTool]!,
        tooltip: 'Şekil: çiz ve düzelt',
        selected: !selecting && t.shapeTool != null,
        size: size,
        onTap: (r) {
          if (selecting) rail.onSelect?.call();
          s?.setInkHidden(false);
          pop(DockTool.shape, r);
        },
      ),
      if (rail.onSelect != null)
        DockButton(
          key: const Key('pdf-tool-select'),
          icon: Icons.crop_free,
          tooltip: 'Soru seç',
          selected: selecting,
          size: size,
          onTap: (_) => rail.onSelect!(),
        ),
      if (rail.itemTools) ...[
        DockButton(
          key: const Key('note-tool-text'),
          icon: Icons.text_fields,
          tooltip: 'Metin kutusu (sayfaya dokun, yaz)',
          selected: !selecting && t.itemTool == ItemTool.text,
          size: size,
          onTap: (_) => t.itemTool == ItemTool.text ? t.setKind(kind) : pick(() => t.setItemTool(ItemTool.text)),
        ),
        DockButton(
          key: const Key('note-tool-photo'),
          icon: Icons.add_photo_alternate_outlined,
          tooltip: 'Fotoğraf ekle',
          size: size,
          onTap: rail.onPhoto == null ? null : (_) => pick(rail.onPhoto!),
        ),
        DockButton(
          key: const Key('note-tool-child'),
          icon: Icons.subdirectory_arrow_right,
          tooltip: 'Alt sayfa (sayfada istediğin yere)',
          selected: !selecting && t.itemTool == ItemTool.child,
          size: size,
          onTap: (_) => t.itemTool == ItemTool.child ? t.setKind(kind) : pick(() => t.setItemTool(ItemTool.child)),
        ),
      ],
      divider(),
      DockButton(
        key: const Key('note-rail-more'),
        icon: Icons.more_horiz,
        tooltip: 'Diğer',
        size: size,
        onTap: (r) => showToolPopover(
          context,
          r,
          side: true,
          builder: (ctx) => _MorePanel(
            tools: t,
            page: rail.page,
            anchor: r,
            outer: context,
          ),
        ),
      ),
    ];

    return Material(
      key: const Key('note-rail'),
      color: cs.surfaceContainerHigh,
      elevation: 4,
      borderRadius: BorderRadius.circular(size / 2 + 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          key: const Key('note-rail-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: items),
        ),
      ),
    );
  }
}

/// "..." menüsü: sayfa şablonu (varsa) ve eski taşınabilir yuvaya geçiş.
class _MorePanel extends StatelessWidget {
  const _MorePanel({required this.tools, required this.page, required this.anchor, required this.outer});
  final NoteToolSettings tools;
  final PageStyleControl? page;
  final Rect anchor;
  final BuildContext outer;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (page != null)
        ListTile(
          key: const Key('note-rail-page'),
          dense: true,
          leading: const Icon(Icons.description_outlined),
          title: const Text('Sayfa: şablon, arka plan, aralık'),
          onTap: () {
            Navigator.pop(context);
            if (!outer.mounted) return;
            showToolPopover(outer, anchor, side: true, builder: (_) => PageStylePanel(control: page!));
          },
        ),
      ListTile(
        key: const Key('note-rail-old-dock'),
        dense: true,
        leading: const Icon(Icons.open_with),
        title: const Text('Taşınabilir araç yuvası'),
        onTap: () {
          Navigator.pop(context);
          tools.setRail(false);
        },
      ),
    ],
  );
}

/// Araç ayar penceresi: boyut kaydırıcısı + sayısal değer, renk daireleri + "+" (özel renk).
/// Silgide yalnız boyut ve "sürterek sil / seçerek sil".
class RailToolPanel extends StatelessWidget {
  const RailToolPanel({super.key, required this.tools, required this.tool});
  final NoteToolSettings tools;
  final DockTool tool;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tools,
    builder: (context, _) {
      final t = tools;
      final title = Theme.of(context).textTheme.titleMedium;
      if (tool == DockTool.shape) return NoteToolPanel(tools: t, tool: tool);
      final eraser = tool == DockTool.eraser;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eraser ? 'Silgi' : (tool == DockTool.highlighter ? 'Fosforlu' : dockKindInfo[t.kind == PenKind.highlighter ? t.lastPenKind : t.kind]!.$2),
            key: const Key('note-tool-name'),
            style: title,
          ),
          const SizedBox(height: 8),
          if (tool == DockTool.pen) ...[
            Wrap(
              spacing: 8,
              children: [
                for (final k in const [PenKind.ballpoint, PenKind.fountain, PenKind.pencil])
                  ChoiceChip(
                    key: Key('note-pen-kind-${k.name}'),
                    avatar: Icon(dockKindInfo[k]!.$1, size: 18),
                    label: Text(dockKindInfo[k]!.$2),
                    selected: t.kind == k,
                    onSelected: (_) => t.setKind(k),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (eraser) ...[
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('note-erase-mode-area'),
                  label: const Text('Sürterek sil'),
                  selected: t.eraseMode == EraseMode.area,
                  onSelected: (_) => t.setEraseMode(EraseMode.area),
                ),
                ChoiceChip(
                  key: const Key('note-erase-mode-stroke'),
                  label: const Text('Seçerek sil'),
                  selected: t.eraseMode == EraseMode.stroke,
                  onSelected: (_) => t.setEraseMode(EraseMode.stroke),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              Expanded(
                child: Slider(
                  key: const Key('note-size-slider'),
                  min: t.sizeMin,
                  max: t.sizeMax,
                  value: t.size.clamp(t.sizeMin, t.sizeMax),
                  onChanged: t.setSize,
                ),
              ),
              SizedBox(
                width: 32,
                child: Text('${t.size.round()}', key: const Key('note-size-value'), textAlign: TextAlign.end),
              ),
            ],
          ),
          if (!eraser) ...[
            const SizedBox(height: 4),
            RailColorRow(tools: t),
          ],
        ],
      );
    },
  );
}

/// Renk daireleri (en çok [railMaxColors]) + seçili renk paletteyse yoksa o + "+" (özel renk).
class RailColorRow extends StatelessWidget {
  const RailColorRow({super.key, required this.tools});
  final NoteToolSettings tools;

  @override
  Widget build(BuildContext context) {
    final t = tools;
    final colors = t.palette.take(railMaxColors).toList();
    if (!colors.contains(t.color)) colors.add(t.color); // özel renk seçiliyse görünür
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final c in colors)
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
        InkWell(
          key: const Key('note-color-custom'),
          customBorder: const CircleBorder(),
          onTap: () async {
            final c = await showCustomColorDialog(context, initial: Color(t.color));
            if (c != null) t.setColor(c);
          },
          child: const Padding(
            padding: EdgeInsets.all(5),
            child: CircleAvatar(radius: 15, child: Icon(Icons.add, size: 18)),
          ),
        ),
      ],
    );
  }
}

/// Özel renk seçici (renk tonu + doygunluk + parlaklık kaydırıcıları); ARGB (opak) ya da null.
Future<int?> showCustomColorDialog(BuildContext context, {required Color initial}) {
  var hsv = HSVColor.fromColor(initial);
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        key: const Key('note-color-dialog'),
        title: const Text('Özel renk'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(radius: 24, backgroundColor: hsv.withAlpha(1).toColor()),
            const SizedBox(height: 8),
            _HsvSlider(
              label: 'Ton',
              value: hsv.hue,
              max: 359.9,
              onChanged: (v) => setState(() => hsv = hsv.withHue(v)),
            ),
            _HsvSlider(
              label: 'Doygunluk',
              value: hsv.saturation,
              max: 1,
              onChanged: (v) => setState(() => hsv = hsv.withSaturation(v)),
            ),
            _HsvSlider(
              label: 'Parlaklık',
              value: hsv.value,
              max: 1,
              onChanged: (v) => setState(() => hsv = hsv.withValue(v)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            key: const Key('note-color-ok'),
            onPressed: () => Navigator.pop(ctx, hsv.withAlpha(1).toColor().toARGB32()),
            child: const Text('Tamam'),
          ),
        ],
      ),
    ),
  );
}

class _HsvSlider extends StatelessWidget {
  const _HsvSlider({required this.label, required this.value, required this.max, required this.onChanged});
  final String label;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 80, child: Text(label)),
      Expanded(
        child: Slider(min: 0, max: max, value: value.clamp(0.0, max).toDouble(), onChanged: onChanged),
      ),
    ],
  );
}
