import 'package:flutter/material.dart';

import '../../ink/domain/pen_profiles.dart';
import '../domain/page_board.dart';
import 'page_items_controller.dart';

/// Seçili metin kutusu/görsel için küçük araç çubuğu (editörün üstünde yüzer).
/// Metin: yazı boyutu (A−/A+/sürgü), renk, kalın, italik, hizalama; ortak: öne/arkaya,
/// kopyala, sil. Silme yumuşaktır; [onDeleted] çağrılınca "Geri al" gösterilebilir.
class ItemToolbar extends StatelessWidget {
  const ItemToolbar({super.key, required this.controller, required this.onDeleted});
  final PageItemsController controller;

  /// Öğe silindi (kimlik): çağıran "Geri al" iletisi gösterir.
  final void Function(String id) onDeleted;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final it = controller.selected;
      if (it == null || it.kind == null) return const SizedBox.shrink();
      final cs = Theme.of(context).colorScheme;
      final w = MediaQuery.sizeOf(context).width;
      final children = <Widget>[
        if (it.kind == PageItemKind.text) ..._textTools(context, it) else ..._imageTools(context, it),
        const VerticalDivider(width: 12),
        _btn('note-item-front', Icons.flip_to_front, 'Öne getir', () => controller.bringToFront(it.id)),
        _btn('note-item-back', Icons.flip_to_back, 'Arkaya al', () => controller.sendToBack(it.id)),
        _btn('note-item-copy', Icons.copy_outlined, 'Kopyala', () => controller.duplicate(it.id)),
        _btn('note-item-delete', Icons.delete_outline, 'Sil', () async {
          final id = it.id;
          if (await controller.delete(id)) onDeleted(id);
        }),
      ];
      return Material(
        key: const Key('note-item-toolbar'),
        color: cs.surface.withValues(alpha: 0.96),
        elevation: 4,
        borderRadius: BorderRadius.circular(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w - 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SizedBox(
              height: 48,
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      );
    },
  );

  Widget _btn(String key, IconData icon, String tip, VoidCallback onTap, {bool selected = false}) => IconButton(
    key: Key(key),
    tooltip: tip,
    isSelected: selected,
    visualDensity: VisualDensity.compact,
    icon: Icon(icon),
    onPressed: onTap,
  );

  List<Widget> _textTools(BuildContext context, PageItemRecord it) {
    final p = it.text;
    void set(TextItemPayload n) => controller.setTextNow(it.id, n);
    final align = switch (p.align) {
      'center' => (Icons.format_align_center, 'right'),
      'right' => (Icons.format_align_right, 'left'),
      _ => (Icons.format_align_left, 'center'),
    };
    return [
      _btn('note-text-smaller', Icons.text_decrease, 'Yazıyı küçült', () => set(p.copyWith(fontSize: clampFont(p.fontSize - 2)))),
      SizedBox(
        width: 120,
        child: Slider(
          key: const Key('note-text-size'),
          min: minItemFont,
          max: maxItemFont,
          value: p.fontSize.clamp(minItemFont, maxItemFont),
          onChanged: (v) => controller.setText(it.id, p.copyWith(fontSize: v.roundToDouble())),
          onChangeEnd: (v) => set(p.copyWith(fontSize: v.roundToDouble())),
        ),
      ),
      _btn('note-text-bigger', Icons.text_increase, 'Yazıyı büyüt', () => set(p.copyWith(fontSize: clampFont(p.fontSize + 2)))),
      const VerticalDivider(width: 12),
      for (final c in penPalette.take(8))
        InkWell(
          key: Key('note-text-color-${c.toRadixString(16)}'),
          customBorder: const CircleBorder(),
          onTap: () => set(p.copyWith(color: c)),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: CircleAvatar(
              radius: 11,
              backgroundColor: Color(c),
              child: p.color == c ? const Icon(Icons.check, size: 14, color: Colors.grey) : null,
            ),
          ),
        ),
      const VerticalDivider(width: 12),
      _btn('note-text-bold', Icons.format_bold, 'Kalın', () => set(p.copyWith(bold: !p.bold)), selected: p.bold),
      _btn('note-text-italic', Icons.format_italic, 'İtalik', () => set(p.copyWith(italic: !p.italic)), selected: p.italic),
      _btn('note-text-align', align.$1, 'Hizalama', () => set(p.copyWith(align: align.$2))),
    ];
  }

  List<Widget> _imageTools(BuildContext context, PageItemRecord it) {
    final a = it.image.alpha;
    return [
      const Icon(Icons.opacity, size: 18),
      SizedBox(
        width: 140,
        child: Slider(
          key: const Key('note-image-alpha'),
          min: 0.1,
          max: 1,
          value: a.clamp(0.1, 1.0),
          onChanged: (v) => controller.setImageAlpha(it.id, v, persist: false),
          onChangeEnd: (v) => controller.setImageAlpha(it.id, v),
        ),
      ),
    ];
  }
}
