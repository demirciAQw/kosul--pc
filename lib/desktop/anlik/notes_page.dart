import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/anlik/anlik_providers.dart';
import '../../features/anlik/domain/anlik.dart';
import '../../features/anlik/domain/anlik_search.dart';
import '../../features/anlik/presentation/widgets/anlik_editor.dart';
import '../../features/anlik/presentation/widgets/anlik_tile.dart';
import '../../features/anlik/presentation/widgets/filter_sheet.dart';
import '../widgets/desktop_page.dart';
import 'anlik_desktop_providers.dart';

/// Notlar: solda liste ve süzgeç, sağda düzenlenebilir not.
/// Ctrl+N yeni not, Ctrl+S kaydet, Ctrl+F ara, Esc paneli kapatır.
/// Pencere darsa (&lt; 820 px) liste ve not sırayla gösterilir.
class DesktopNotesPage extends ConsumerStatefulWidget {
  const DesktopNotesPage({super.key});

  @override
  ConsumerState<DesktopNotesPage> createState() => _DesktopNotesPageState();
}

class _DesktopNotesPageState extends ConsumerState<DesktopNotesPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'not-ara');
  final _editorKey = GlobalKey<AnlikEditorState>();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
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

  void _select(String? id) => ref.read(desktopAnlikSelectionProvider.notifier).select(id);

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(desktopAnlikSelectionProvider);
    final filter = ref.watch(anlikFilterProvider);
    final async = ref.watch(filteredAnlikProvider);
    final all = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
    final subjects = {for (final n in all) if (n.subject != null) n.subject!};

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _select(kNewAnlik),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _editorKey.currentState?.save(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchFocus.hasFocus && _search.text.isNotEmpty) {
            _search.clear();
            _setQuery('');
          } else {
            _select(null);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: DesktopPage(
          title: 'Notlar',
          subtitle: 'Ctrl+N yeni · Ctrl+S kaydet · Ctrl+F ara',
          actions: [
            FilledButton.icon(
              key: const ValueKey('not-yeni'),
              onPressed: () => _select(kNewAnlik),
              icon: const Icon(Icons.add),
              label: const Text('Yeni not'),
            ),
          ],
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 820;
              final list = _ListPane(
                search: _search,
                searchFocus: _searchFocus,
                onQuery: _setQuery,
                filtered: filter,
                subjects: subjects,
                async: async,
                selected: selected,
                onSelect: _select,
              );
              final editor = _EditorPane(editorKey: _editorKey, selected: selected, all: all, onSelect: _select, showBack: !wide);
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: (box.maxWidth * 0.4).clamp(320, 460).toDouble(), child: list),
                    const VerticalDivider(width: 1),
                    Expanded(child: editor),
                  ],
                );
              }
              return selected == null ? list : editor;
            },
          ),
        ),
      ),
    );
  }
}

class _ListPane extends ConsumerWidget {
  const _ListPane({
    required this.search,
    required this.searchFocus,
    required this.onQuery,
    required this.filtered,
    required this.subjects,
    required this.async,
    required this.selected,
    required this.onSelect,
  });

  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onQuery;
  final AnlikFilter filtered;
  final Set<String> subjects;
  final AsyncValue<List<AnlikNote>> async;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('anlik-ara'),
                  controller: search,
                  focusNode: searchFocus,
                  onChanged: onQuery,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Notlarda ara',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: const ValueKey('anlik-suzgec'),
                tooltip: 'Süzgeç: etiket, kişi, ders, tarih',
                onPressed: () => showAnlikFilterSheet(context, subjects: subjects),
                icon: Badge(
                  isLabelVisible: filtered.tagId != null || filtered.personId != null || filtered.from != null || filtered.subject != null,
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
            data: (list) => list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(filtered.isEmpty ? 'Henüz not yok. Ctrl+N ile yaz.' : 'Bu süzgece uyan not yok.'),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) => AnlikTile(
                      note: list[i],
                      selected: list[i].id == selected,
                      onTap: () => onSelect(list[i].id),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _EditorPane extends ConsumerWidget {
  const _EditorPane({
    required this.editorKey,
    required this.selected,
    required this.all,
    required this.onSelect,
    required this.showBack,
  });

  final GlobalKey<AnlikEditorState> editorKey;
  final String? selected;
  final List<AnlikNote> all;
  final ValueChanged<String?> onSelect;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (selected == null) {
      return Center(
        child: Text('Soldan bir not seç ya da Ctrl+N ile yeni yaz.',
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final existing = selected == kNewAnlik ? null : all.where((n) => n.id == selected).firstOrNull;
    if (selected != kNewAnlik && existing == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => onSelect(null), icon: const Icon(Icons.arrow_back), label: const Text('Liste')),
          ),
        Expanded(
          child: AnlikEditor(
            key: editorKey,
            existing: existing,
            // Aynı not açıkken yeniden kurulmasın; farklı not/yeni not temiz açılsın.
            focusNode: null,
            autofocus: true,
            onCancel: () => onSelect(null),
            onSaved: (saved, undo) {
              final messenger = ScaffoldMessenger.of(context);
              onSelect(saved.id);
              messenger
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: const Text('Kaydedildi'),
                  action: SnackBarAction(
                    label: 'Geri al',
                    onPressed: () async {
                      await undo();
                      if (existing == null) onSelect(null);
                    },
                  ),
                ));
            },
          ),
        ),
      ],
    );
  }
}
