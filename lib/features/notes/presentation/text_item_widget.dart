import 'package:flutter/material.dart';

import '../domain/page_board.dart';
import '../domain/page_item_geometry.dart';

/// Metin kutusunun iç boşluğu (not birimi).
const textItemPad = 8.0;

TextAlign textAlignOf(String a) => switch (a) {
  'center' => TextAlign.center,
  'right' => TextAlign.right,
  _ => TextAlign.left,
};

/// Metin kutusunun yazı stili; [scale]: not biriminden ekran pikseline.
TextStyle textItemStyle(TextItemPayload p, double scale) => TextStyle(
  fontSize: p.fontSize * scale,
  color: Color(p.color),
  fontWeight: p.bold ? FontWeight.w700 : FontWeight.w400,
  fontStyle: p.italic ? FontStyle.italic : FontStyle.normal,
  height: 1.25,
);

final Map<String, double> _measureCache = {};

/// [width] genişlikteki (not birimi) metin kutusunun içeriğe göre gereken yüksekliği:
/// yazı otomatik satıra sarılır, kutu içerikle büyür (en az [minItemSize]).
double measureTextHeight(TextItemPayload p, double width) {
  final key = '${p.text}|${p.fontSize}|${p.bold}|${p.italic}|${p.align}|${width.toStringAsFixed(1)}';
  final hit = _measureCache[key];
  if (hit != null) return hit;
  final tp = TextPainter(
    text: TextSpan(text: p.text.isEmpty ? ' ' : p.text, style: textItemStyle(p, 1)),
    textAlign: textAlignOf(p.align),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: (width - 2 * textItemPad).clamp(1.0, double.infinity));
  final h = (tp.height + 2 * textItemPad).clamp(minItemSize, double.infinity).toDouble();
  tp.dispose();
  if (_measureCache.length > 400) _measureCache.clear();
  return _measureCache[key] = h;
}

/// Salt okunur metin kutusu (kalem çizgilerinin altında çizilir).
class TextItemView extends StatelessWidget {
  const TextItemView({super.key, required this.payload, required this.scale});
  final TextItemPayload payload;

  /// Not biriminden yerel piksele (sayfa genişliği / not genişliği).
  final double scale;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(textItemPad * scale),
    child: Align(
      alignment: Alignment.topLeft,
      child: Text(
        payload.text,
        style: textItemStyle(payload, scale),
        textAlign: textAlignOf(payload.align),
        textScaler: TextScaler.noScaling,
        softWrap: true,
        // Gerçek yazı genişliği kutuya uysun.
      ),
    ),
  );
}

/// Düzenlenen metin kutusu: klavye açılır, yazı sarar, değişiklik [onChanged] ile bildirilir.
class TextItemEditor extends StatefulWidget {
  const TextItemEditor({
    super.key,
    required this.payload,
    required this.scale,
    required this.onChanged,
    required this.onDone,
  });
  final TextItemPayload payload;
  final double scale;
  final ValueChanged<String> onChanged;

  /// Odak kaybı/bitti: düzenleme kapanır.
  final VoidCallback onDone;

  @override
  State<TextItemEditor> createState() => _TextItemEditorState();
}

class _TextItemEditorState extends State<TextItemEditor> {
  late final TextEditingController _c = TextEditingController(text: widget.payload.text);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onDone();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(TextItemEditor old) {
    super.didUpdateWidget(old);
    // Dışarıdan (örn. geri al) değişirse yazılan metni ezme: yalnız farklıysa güncelle.
    if (widget.payload.text != _c.text && !_focus.hasFocus) _c.text = widget.payload.text;
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(textItemPad * widget.scale),
    child: TextField(
      key: const Key('note-text-field'),
      controller: _c,
      focusNode: _focus,
      maxLines: null,
      minLines: 1,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      textAlign: textAlignOf(widget.payload.align),
      style: textItemStyle(widget.payload, widget.scale),
      cursorColor: Theme.of(context).colorScheme.primary,
      decoration: const InputDecoration.collapsed(hintText: null),
      onChanged: widget.onChanged,
      scrollPhysics: const NeverScrollableScrollPhysics(),
    ),
  );
}
