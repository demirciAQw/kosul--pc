import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import '../../domain/tag_tree.dart';
import 'pickers.dart';

/// Etiket çubuğu: seçili etiketler (silinebilir) ve + düğmesi.
/// Otomatik etiketlerin yanında küçük bir "oto" imi olur.
class TagBar extends ConsumerWidget {
  const TagBar({super.key, required this.selected, required this.onChanged, this.autoIds = const {}});

  final Set<String> selected;
  final Set<String> autoIds;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final id in selected)
          if (tags.any((t) => t.id == id))
            InputChip(
              key: ValueKey('etiket:$id'),
              avatar: Icon(autoIds.contains(id) ? Icons.auto_awesome : Icons.sell_outlined, size: 16),
              label: Text(tagPathLabel(tags, id)),
              onDeleted: () => onChanged({...selected}..remove(id)),
            ),
        ActionChip(
          key: const ValueKey('etiket-ekle'),
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('Etiket'),
          onPressed: () async {
            final id = await showTagPicker(context, ref, exclude: selected);
            if (id != null) onChanged({...selected, id});
          },
        ),
      ],
    );
  }
}

/// Kişi çubuğu: seçili kişiler ve + düğmesi.
class PersonBar extends ConsumerWidget {
  const PersonBar({super.key, required this.selected, required this.onChanged});

  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final id in selected)
          for (final p in people.where((p) => p.id == id))
            InputChip(
              key: ValueKey('kisi:$id'),
              avatar: const Icon(Icons.person_outline, size: 16),
              label: Text(p.name),
              onDeleted: () => onChanged({...selected}..remove(id)),
            ),
        ActionChip(
          key: const ValueKey('kisi-ekle'),
          avatar: const Icon(Icons.person_add_alt_1_outlined, size: 18),
          label: const Text('Kişi'),
          onPressed: () async {
            final id = await showPersonPicker(context, ref, exclude: selected);
            if (id != null) onChanged({...selected, id});
          },
        ),
      ],
    );
  }
}
