import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/formatters.dart';
import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import '../../domain/anlik_search.dart';
import '../../domain/tag_tree.dart';

/// Etiket (alt etiketler dahil), kişi, ders ve tarih aralığı süzgeci.
/// [subjects]: seçilebilir dersler.
Future<void> showAnlikFilterSheet(BuildContext context, {Iterable<String> subjects = const []}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FilterSheet(subjects: subjects.toList()),
  );
}

class _FilterSheet extends ConsumerWidget {
  const _FilterSheet({required this.subjects});
  final List<String> subjects;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(anlikFilterProvider);
    final n = ref.read(anlikFilterProvider.notifier);
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    AnlikFilter copy({
      String? tagId,
      String? personId,
      String? subject,
      DateTime? from,
      DateTime? to,
      bool clearTag = false,
      bool clearPerson = false,
      bool clearSubject = false,
      bool clearDates = false,
    }) =>
        AnlikFilter(
          query: f.query,
          kind: f.kind,
          tagId: clearTag ? null : (tagId ?? f.tagId),
          personId: clearPerson ? null : (personId ?? f.personId),
          subject: clearSubject ? null : (subject ?? f.subject),
          from: clearDates ? null : (from ?? f.from),
          to: clearDates ? null : (to ?? f.to),
        );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String?>(
              key: const ValueKey('suzgec-etiket'),
              initialValue: f.tagId,
              decoration: const InputDecoration(labelText: 'Etiket (alt etiketler dahil)'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Hepsi')),
                for (final (t, _) in tagTreeOrder(tags)) DropdownMenuItem(value: t.id, child: Text(tagPathLabel(tags, t.id))),
              ],
              onChanged: (v) => n.set(copy(tagId: v, clearTag: v == null)),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              key: const ValueKey('suzgec-kisi'),
              initialValue: f.personId,
              decoration: const InputDecoration(labelText: 'Kişi'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Hepsi')),
                for (final p in people) DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (v) => n.set(copy(personId: v, clearPerson: v == null)),
            ),
            if (subjects.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                initialValue: f.subject,
                decoration: const InputDecoration(labelText: 'Ders'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Hepsi')),
                  for (final s in subjects) DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) => n.set(copy(subject: v, clearSubject: v == null)),
              ),
            ],
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.date_range),
              title: Text(f.from == null ? 'Tarih aralığı: hepsi' : '${formatDate(f.from!)} – ${formatDate(f.to ?? f.from!)}'),
              trailing: f.from == null ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => n.set(copy(clearDates: true))),
              onTap: () async {
                final r = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                  initialDateRange: f.from == null ? null : DateTimeRange(start: f.from!, end: f.to ?? f.from!),
                );
                if (r != null) n.set(copy(from: r.start, to: r.end));
              },
            ),
            Row(
              children: [
                TextButton(onPressed: n.clear, child: const Text('Temizle')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Tamam')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
