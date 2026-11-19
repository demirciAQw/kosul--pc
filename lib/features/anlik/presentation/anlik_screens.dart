import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../anlik_providers.dart';
import '../domain/anlik.dart';
import '../domain/anlik_search.dart';
import 'widgets/anlik_editor.dart';
import 'widgets/anlik_tile.dart';
import 'widgets/filter_sheet.dart';
import 'widgets/people_tags_manage.dart';

/// Kayıttan sonra kısa onay ve "Geri al".
void showSavedSnack(ScaffoldMessengerState messenger, String text, Future<void> Function() undo) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      action: SnackBarAction(label: 'Geri al', onPressed: undo),
    ));
}

/// Alt gezinmedeki "Anlık" sekmesi: arama, süzgeç, liste. Yazma düğmesi tam
/// ekran editörü açar; klavye hemen gelir.
class AnlikScreen extends ConsumerStatefulWidget {
  const AnlikScreen({super.key});

  @override
  ConsumerState<AnlikScreen> createState() => _AnlikScreenState();
}

class _AnlikScreenState extends ConsumerState<AnlikScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(String q) {
    final f = ref.read(anlikFilterProvider);
    ref.read(anlikFilterProvider.notifier).set(AnlikFilter(
          query: q,
          tagId: f.tagId,
          personId: f.personId,
          from: f.from,
          to: f.to,
          subject: f.subject,
          kind: f.kind,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(anlikFilterProvider);
    final async = ref.watch(filteredAnlikProvider);
    final all = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
    final subjects = {for (final n in all) if (n.subject != null) n.subject!};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Anlık'),
        actions: [
          IconButton(
            tooltip: 'Kişiler',
            onPressed: () => context.push(AppRoutes.people),
            icon: const Icon(Icons.people_outline),
          ),
          IconButton(
            tooltip: 'Etiketler',
            onPressed: () => context.push(AppRoutes.tags),
            icon: const Icon(Icons.sell_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('anlik-yaz'),
        onPressed: () => context.push(AppRoutes.newAnlik),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Yaz'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('anlik-ara'),
                    controller: _search,
                    onChanged: _setQuery,
                    decoration: InputDecoration(
                      hintText: 'Notlarda ara',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _search.clear();
                                _setQuery('');
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const ValueKey('anlik-suzgec'),
                  tooltip: 'Süzgeç',
                  onPressed: () => showAnlikFilterSheet(context, subjects: subjects),
                  icon: Badge(
                    isLabelVisible: filter.tagId != null || filter.personId != null || filter.from != null || filter.subject != null,
                    child: const Icon(Icons.filter_list),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Notlar okunamadı: $e')),
              data: (list) {
                if (list.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        filter.isEmpty ? 'Aklından geçeni yaz. Etiket için ((etiket)), kişi için @ad.' : 'Bu süzgece uyan not yok.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  itemBuilder: (_, i) => AnlikTile(
                    note: list[i],
                    onTap: () => context.push(AppRoutes.anlik(list[i].id)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Yeni not ya da düzenleme (tam ekran). Yazma alanı hemen odaklanır.
class AnlikEditorScreen extends ConsumerWidget {
  const AnlikEditorScreen({super.key, this.noteId});
  final String? noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(anlikNotesProvider);
    AnlikNote? existing;
    if (noteId != null) {
      if (notes.isLoading) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
      existing = notes.value?.where((n) => n.id == noteId).firstOrNull;
      if (existing == null) {
        return Scaffold(appBar: AppBar(title: const Text('Not')), body: const Center(child: Text('Bu not bulunamadı.')));
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Yeni not' : 'Notu düzenle'),
        actions: [
          if (existing != null)
            IconButton(
              tooltip: 'Sil',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, ref, existing!),
            ),
        ],
      ),
      body: AnlikEditor(
        existing: existing,
        onSaved: (saved, undo) {
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          showSavedSnack(messenger, 'Kaydedildi', undo);
        },
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, AnlikNote n) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Not silinsin mi?'),
        content: const Text('Silince “Geri al” ile geri getirebilirsin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (sure != true) return;
    final repo = ref.read(anlikRepositoryProvider);
    await repo.deleteNote(n.id);
    nav.pop();
    showSavedSnack(messenger, 'Not silindi', () => repo.commit(note: n));
  }
}

/// Kişiler sayfası.
class PeopleScreen extends ConsumerWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('Kişiler')),
        floatingActionButton: FloatingActionButton(
          key: const ValueKey('kisi-yeni'),
          tooltip: 'Yeni kişi',
          onPressed: () => showPersonDialog(context, ref),
          child: const Icon(Icons.person_add_alt_1),
        ),
        body: PeopleList(onOpen: (p) => context.push(AppRoutes.person(p.id))),
      );
}

/// Bir kişiyle ilgili tüm notlar, tarih sırasıyla (eskiden yeniye).
class PersonNotesScreen extends ConsumerWidget {
  const PersonNotesScreen({super.key, required this.personId});
  final String personId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final person = people.where((p) => p.id == personId).firstOrNull;
    final notes = ref.watch(anlikNotesProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(person == null ? 'Kişi' : '${person.name} hakkında'),
        actions: [
          if (person != null)
            IconButton(
              tooltip: 'Düzenle',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showPersonDialog(context, ref, person: person),
            ),
        ],
      ),
      body: notes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Notlar okunamadı: $e')),
        data: (all) {
          final list = filterAnlik(all, AnlikFilter(personId: personId)).reversed.toList();
          if (list.isEmpty) return const Center(child: Text('Bu kişiyle ilgili not yok.'));
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => AnlikTile(note: list[i], onTap: () => context.push(AppRoutes.anlik(list[i].id))),
          );
        },
      ),
    );
  }
}

/// Etiket ağacı (yeniden adlandır, üst etiket, birleştir).
class TagsScreen extends StatelessWidget {
  const TagsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Etiketler')),
        body: const TagsManager(),
      );
}
