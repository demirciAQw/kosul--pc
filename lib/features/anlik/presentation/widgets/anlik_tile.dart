import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/formatters.dart';
import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import '../../domain/tag_tree.dart';

/// Liste satırı: zaman, metin, etiket ve kişi çipleri.
class AnlikTile extends ConsumerWidget {
  const AnlikTile({super.key, required this.note, this.onTap, this.selected = false});

  final AnlikNote note;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final tagLabels = [for (final id in note.tagIds) if (tags.any((t) => t.id == id)) tagPathLabel(tags, id)];
    final names = [for (final p in people) if (note.personIds.contains(p.id)) p.name];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: selected ? theme.colorScheme.secondaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (note.isSleep)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(note.kind == AnlikKind.yattim ? Icons.bedtime_outlined : Icons.wb_sunny_outlined, size: 16),
                    ),
                  Text(formatShortDate(note.createdAt), style: theme.textTheme.labelMedium),
                  if (note.mood != null) ...[
                    const SizedBox(width: 8),
                    Text('☺ ${note.mood}', style: theme.textTheme.labelMedium),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(note.body, maxLines: 4, overflow: TextOverflow.ellipsis),
              if (tagLabels.isNotEmpty || names.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    for (final t in tagLabels)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.sell_outlined, size: 14),
                        label: Text(t),
                      ),
                    for (final n in names)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.person_outline, size: 14),
                        label: Text(n),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
