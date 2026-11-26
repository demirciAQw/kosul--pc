import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/anlik/anlik_providers.dart';
import '../../features/anlik/domain/anlik.dart';
import '../../features/anlik/domain/anlik_search.dart';
import '../../features/anlik/presentation/widgets/anlik_tile.dart';
import '../../features/anlik/presentation/widgets/people_tags_manage.dart';
import '../desktop_providers.dart';
import '../widgets/desktop_page.dart';
import 'anlik_desktop_providers.dart';

/// Kişiler: ekle, düzenle, takma ad ekle; kişiye tıklayınca notları.
class DesktopPeoplePage extends ConsumerWidget {
  const DesktopPeoplePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(desktopPersonSelectionProvider);
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final person = people.where((p) => p.id == selectedId).firstOrNull;
    final theme = Theme.of(context);
    return DesktopPage(
      title: 'Kişiler',
      actions: [
        FilledButton.icon(
          key: const ValueKey('kisi-yeni'),
          onPressed: () => showPersonDialog(context, ref),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Yeni kişi'),
        ),
      ],
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 720;
        final list = PeopleList(
          selectedId: selectedId,
          onOpen: (p) => ref.read(desktopPersonSelectionProvider.notifier).select(p.id),
        );
        final detail = person == null
            ? Center(
                child: Text('Soldan bir kişi seç.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)))
            : _PersonDetail(person: person, showBack: !wide);
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 340, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: detail),
            ],
          );
        }
        return person == null ? list : detail;
      }),
    );
  }
}

class _PersonDetail extends ConsumerWidget {
  const _PersonDetail({required this.person, required this.showBack});
  final Person person;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notes = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
    final list = filterAnlik(notes, AnlikFilter(personId: person.id)).reversed.toList(); // eskiden yeniye
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref.read(desktopPersonSelectionProvider.notifier).select(null),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Liste'),
            ),
          ),
        Row(
          children: [
            Expanded(child: Text('${person.name} hakkında', style: theme.textTheme.titleLarge)),
            OutlinedButton.icon(
              key: const ValueKey('kisi-duzenle'),
              onPressed: () => showPersonDialog(context, ref, person: person),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Düzenle'),
            ),
          ],
        ),
        if (person.about.isNotEmpty) Text(person.about),
        if (person.aliases.isNotEmpty) Text('Diğer adları: ${person.aliases.join(', ')}'),
        const SizedBox(height: 12),
        if (list.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Bu kişiyle ilgili not yok.')),
        for (final n in list)
          AnlikTile(
            note: n,
            onTap: () {
              ref.read(desktopAnlikSelectionProvider.notifier).select(n.id);
              ref.read(desktopSectionProvider.notifier).select(DesktopSection.notes);
            },
          ),
      ],
    );
  }
}

/// Etiketler: ağaç, yeniden adlandır, üst etiket değiştir, birleştir.
class DesktopTagsPage extends ConsumerWidget {
  const DesktopTagsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const DesktopPage(
        title: 'Etiketler',
        subtitle: 'Satırın sağındaki ⋮ ile yeniden adlandır, üst etiketi değiştir ya da birleştir',
        child: TagsManager(),
      );
}
