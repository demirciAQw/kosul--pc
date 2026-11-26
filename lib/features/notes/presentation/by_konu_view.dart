import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../curriculum/curriculum_providers.dart';
import '../domain/ink_notebook.dart';
import '../notes_providers.dart';
import 'konu_picker.dart';

/// Bir konuya bağlı silinmemiş sayfalar (akış).
final pagesForKonuProvider = StreamProvider.autoDispose
    .family<List<InkNotePageRecord>, String>(
      (ref, konuId) =>
          ref.watch(inkBoardRepositoryProvider).watchPagesForKonu(konuId),
    );

/// Defterler ekranının "Konuya göre" görünümü: konu seç, eşli sayfaları listele.
class ByKonuView extends ConsumerStatefulWidget {
  const ByKonuView({super.key, required this.onOpenPage});

  /// Sayfayı aç (defter + sayfa).
  final void Function(InkNotebookRecord notebook, InkNotePageRecord page)
  onOpenPage;

  @override
  ConsumerState<ByKonuView> createState() => _ByKonuViewState();
}

class _ByKonuViewState extends ConsumerState<ByKonuView> {
  String? _konuId;

  Future<void> _pick() async {
    final r = await showKonuPicker(context, selectedId: _konuId);
    if (r != null && mounted) setState(() => _konuId = r.id);
  }

  @override
  Widget build(BuildContext context) {
    final nodes = ref.watch(curriculumProvider).value ?? const [];
    final notebooks = {
      for (final n
          in ref.watch(inkNotebooksProvider).value ??
              const <InkNotebookRecord>[])
        n.id: n,
    };
    final id = _konuId;
    final pages = id == null ? null : ref.watch(pagesForKonuProvider(id)).value;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
      children: [
        Card(
          child: ListTile(
            key: const Key('bykonu-pick'),
            leading: const Icon(Icons.account_tree_outlined),
            title: Text(
              id == null
                  ? 'Konu seç'
                  : (konuPathLabel(id, nodes) ?? 'Konu bulunamadı'),
            ),
            subtitle: id == null
                ? const Text('Konuya bağlı defter sayfalarını gösterir')
                : null,
            trailing: const Icon(Icons.expand_more),
            onTap: _pick,
          ),
        ),
        if (id != null && pages != null && pages.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Bu konuya bağlı sayfa yok.')),
          ),
        if (pages != null)
          for (final p in pages)
            if (notebooks[p.notebookId] case final nb?)
              _KonuPageTile(
                notebook: nb,
                page: p,
                onTap: () => widget.onOpenPage(nb, p),
              ),
      ],
    );
  }
}

/// Eşli sayfa satırı; sayfa numarası defterdeki sıradan bulunur.
class _KonuPageTile extends ConsumerWidget {
  const _KonuPageTile({
    required this.notebook,
    required this.page,
    required this.onTap,
  });
  final InkNotebookRecord notebook;
  final InkNotePageRecord page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref.watch(inkNotebookPagesProvider(notebook.id)).value;
    final idx = pages?.indexWhere((x) => x.id == page.id) ?? -1;
    final title = page.title;
    return Card(
      key: Key('bykonu-page-${page.id}'),
      child: ListTile(
        leading: const Icon(Icons.description_outlined),
        title: Text(notebook.title.isEmpty ? 'Adsız defter' : notebook.title),
        subtitle: Text(
          [
            if (idx >= 0) 'Sayfa ${idx + 1}',
            if (title != null && title.isNotEmpty) title,
          ].join(' · '),
        ),
        onTap: onTap,
      ),
    );
  }
}
