import 'package:flutter/material.dart';

import '../../domain/mentions.dart';

/// Yazma alanı: `((` ve `@` yazılınca altında öneri çipleri çıkar. Telefonda
/// ve bilgisayarda aynı. [tagNames] / [personNames]: öneri havuzu.
class MentionTextField extends StatefulWidget {
  const MentionTextField({
    super.key,
    required this.controller,
    required this.tagNames,
    required this.personNames,
    this.focusNode,
    this.autofocus = false,
    this.minLines = 3,
    this.maxLines = 12,
    this.hint = 'Aklından geçeni yaz…  ((etiket))  @kişi',
  });

  final TextEditingController controller;
  final Iterable<String> tagNames;
  final Iterable<String> personNames;
  final FocusNode? focusNode;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final String hint;

  @override
  State<MentionTextField> createState() => _MentionTextFieldState();
}

class _MentionTextFieldState extends State<MentionTextField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(MentionTextField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final cursor = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    final ctx = mentionAt(value.text, cursor);
    final names = ctx == null ? const <String>[] : suggestNames(ctx.prefix, ctx.isTag ? widget.tagNames : widget.personNames);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ctx != null)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final n in names)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      key: ValueKey('oneri:$n'),
                      avatar: Icon(ctx.isTag ? Icons.sell_outlined : Icons.person_outline, size: 16),
                      label: Text(n),
                      onPressed: () {
                        final r = applyMention(value.text, cursor, ctx, n);
                        widget.controller.value = TextEditingValue(
                          text: r.text,
                          selection: TextSelection.collapsed(offset: r.cursor),
                        );
                      },
                    ),
                  ),
                if (names.isEmpty && ctx.prefix.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                    child: Text(
                      ctx.isTag ? 'Yeni etiket: kaydedince adı onaylarsın' : 'Yeni kişi: kaydedince eklenir mi diye sorarım',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        TextField(
          key: const ValueKey('anlik-yazi'),
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: widget.hint, border: const OutlineInputBorder()),
        ),
      ],
    );
  }
}
