import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../domain/ink_notebook.dart';
import '../notes_providers.dart';

/// Defter kapağı renkleri (ARGB).
const notebookCoverColors = <int>[
  0xFF3F51B5,
  0xFF0B8A8A,
  0xFF188038,
  0xFFD93025,
  0xFFE8710A,
  0xFF8E24AA,
  0xFF5F6368,
];

/// Defterler listesi: yeni defter, yeniden adlandır, sırala, yumuşak sil (onaylı) ve geri al.
class NotebooksScreen extends ConsumerStatefulWidget {
  const NotebooksScreen({super.key, this.onOpen, this.embedded = false});

  /// true: başka bir çerçevenin içinde (başlık çubuğu yok).
  final bool embedded;

  /// Defteri açma (varsayılan: `/defter/:id` rotası). Rotasız testlerde verilir.
  final void Function(BuildContext context, InkNotebookRecord notebook)? onOpen;

  @override
  ConsumerState<NotebooksScreen> createState() => _NotebooksScreenState();
}

class _NotebooksScreenState extends ConsumerState<NotebooksScreen> {
  bool _showDeleted = false;

  void _open(InkNotebookRecord n) {
    final f = widget.onOpen;
    if (f != null) {
      f(context, n);
    } else {
      context.push(AppRoutes.inkNotebook(n.id));
    }
  }

  Future<void> _create() async {
    final res = await showDialog<({String title, int color})>(
      context: context,
      builder: (_) => const _NotebookDialog(),
    );
    if (res == null || !mounted) return;
    final repo = ref.read(inkNotebookRepositoryProvider);
    final id = await repo.createNotebook(title: res.title, coverColor: res.color);
    final n = await repo.findNotebook(id);
    if (n != null && mounted) _open(n);
  }

  Future<void> _rename(InkNotebookRecord n) async {
    final res = await showDialog<({String title, int color})>(
      context: context,
      builder: (_) => _NotebookDialog(initial: n),
    );
    if (res == null) return;
    final repo = ref.read(inkNotebookRepositoryProvider);
    await repo.renameNotebook(n.id, res.title);
    if (res.color != n.coverColor) await repo.setCoverColor(n.id, res.color);
  }

  Future<void> _delete(InkNotebookRecord n) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Defter silinsin mi?'),
        content: Text('"${_name(n)}" listeden kalkar. Çizgileri silinmez; Silinenler\'den geri getirebilirsin.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(
            key: const Key('notebook-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(inkNotebookRepositoryProvider);
    await repo.deleteNotebook(n.id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('"${_name(n)}" silindi.'),
          action: SnackBarAction(label: 'Geri al', onPressed: () => repo.restoreNotebook(n.id)),
        ),
      );
  }

  Future<void> _reorder(List<InkNotebookRecord> alive, int from, int to) async {
    final ids = [for (final n in alive) n.id];
    ids.insert(to, ids.removeAt(from));
    await ref.read(inkNotebookRepositoryProvider).reorderNotebooks(ids);
  }

  static String _name(InkNotebookRecord n) => n.title.isEmpty ? 'Adsız defter' : n.title;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(inkNotebooksProvider);
    final body = all.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Defterler okunamadı: $e')),
      data: (list) {
        final alive = [for (final n in list) if (!n.deleted) n];
        final deleted = [for (final n in list) if (n.deleted) n];
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
          children: [
            if (widget.embedded)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('notebook-new'),
                  onPressed: _create,
                  icon: const Icon(Icons.add),
                  label: const Text('Yeni defter'),
                ),
              ),
            if (alive.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Henüz defter yok. "Yeni defter" ile başla.')),
              ),
            ReorderableListView.builder(
              key: const Key('notebook-list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: alive.length,
              onReorderItem: (a, b) => _reorder(alive, a, b),
              itemBuilder: (context, i) {
                final n = alive[i];
                return Card(
                  key: ValueKey(n.id),
                  child: ListTile(
                    key: Key('notebook-${n.id}'),
                    leading: _Cover(n.coverColor),
                    title: Text(_name(n)),
                    subtitle: Text('${n.pageCount} sayfa'),
                    onTap: () => _open(n),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('notebook-rename-${n.id}'),
                          tooltip: 'Yeniden adlandır',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _rename(n),
                        ),
                        IconButton(
                          key: Key('notebook-del-${n.id}'),
                          tooltip: 'Sil',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(n),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_showDeleted) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                child: Text('Silinenler', style: Theme.of(context).textTheme.titleSmall),
              ),
              if (deleted.isEmpty) const ListTile(title: Text('Silinen defter yok.')),
              for (final n in deleted)
                Card(
                  key: ValueKey('del-${n.id}'),
                  child: ListTile(
                    leading: Opacity(opacity: 0.5, child: _Cover(n.coverColor)),
                    title: Text(_name(n)),
                    subtitle: Text('${n.pageCount} sayfa'),
                    trailing: TextButton(
                      key: Key('notebook-restore-${n.id}'),
                      onPressed: () => ref.read(inkNotebookRepositoryProvider).restoreNotebook(n.id),
                      child: const Text('Geri getir'),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
    final deletedToggle = IconButton(
      key: const Key('notebook-show-deleted'),
      tooltip: _showDeleted ? 'Silinenleri gizle' : 'Silinenleri göster',
      isSelected: _showDeleted,
      icon: const Icon(Icons.restore_from_trash_outlined),
      onPressed: () => setState(() => _showDeleted = !_showDeleted),
    );
    if (widget.embedded) {
      return Stack(children: [body, Positioned(right: 8, top: 0, child: deletedToggle)]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Defterler'), actions: [deletedToggle]),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('notebook-new'),
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Yeni defter'),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover(this.color);
  final int color;

  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 48,
    decoration: BoxDecoration(color: Color(color), borderRadius: BorderRadius.circular(4)),
    child: const Icon(Icons.menu_book, color: Colors.white70, size: 20),
  );
}

/// Yeni defter / yeniden adlandırma: başlık ve kapak rengi.
class _NotebookDialog extends StatefulWidget {
  const _NotebookDialog({this.initial});
  final InkNotebookRecord? initial;

  @override
  State<_NotebookDialog> createState() => _NotebookDialogState();
}

class _NotebookDialogState extends State<_NotebookDialog> {
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late int _color = widget.initial?.coverColor ?? notebookCoverColors.first;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Yeni defter' : 'Defteri düzenle'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('notebook-title-field'),
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Defter adı'),
            onSubmitted: (_) => Navigator.pop(context, (title: _title.text.trim(), color: _color)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final c in notebookCoverColors)
                InkWell(
                  key: Key('notebook-color-${c.toRadixString(16)}'),
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: Color(c),
                    child: _color == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
        FilledButton(
          key: const Key('notebook-dialog-ok'),
          onPressed: () => Navigator.pop(context, (title: _title.text.trim(), color: _color)),
          child: const Text('Tamam'),
        ),
      ],
    );
  }
}
