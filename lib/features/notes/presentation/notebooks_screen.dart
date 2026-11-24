import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../anlik/anlik_providers.dart';
import '../../anlik/domain/anlik.dart';
import '../../../core/text/turkish_text.dart';
import '../../anlik/domain/tag_tree.dart';
import '../../handwriting/data/page_text_repository.dart' show PageTextHit;
import '../../handwriting/handwriting_providers.dart';
import '../domain/ink_folder.dart';
import '../domain/ink_notebook.dart';
import '../domain/notebook_filter.dart';
import '../domain/page_size.dart';
import '../domain/page_template.dart';
import '../notes_providers.dart';
import 'by_konu_view.dart';
import 'curriculum_notebook_dialog.dart';
import 'folder_dialogs.dart';
import 'folder_nav.dart';
import 'ink_notebook_screen.dart' show PageSizePicker;
import 'page_template_painter.dart';

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

/// Silinmiş klasörler (Silinenler bölümü için).
final inkDeletedFoldersProvider = StreamProvider.autoDispose<List<InkFolderRecord>>(
  (ref) => ref.watch(inkFolderRepositoryProvider).watchFolders(includeDeleted: true).map((l) => [for (final f in l) if (f.deleted) f]),
);

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
  bool _byKonu = false;
  String? _tagFilter;

  /// Açık klasör (null = ana düzey).
  String? _folderId;

  /// Arama: defter adı ve kayıtlı el yazısı metni ([normalizeTr]).
  String _query = '';
  final _searchCtl = TextEditingController();

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// Arama sonucu: defteri eşleşen sayfada aç (masaüstünde `onOpen` ile defter açılır).
  void _openHit(InkNotebookRecord n, PageTextHit h) {
    final f = widget.onOpen;
    if (f != null) {
      f(context, n);
    } else {
      context.push(AppRoutes.inkNotebookAt(n.id, h.pageId));
    }
  }

  void _openKonuPage(InkNotebookRecord n, InkNotePageRecord p) {
    final f = widget.onOpen;
    if (f != null) {
      f(context, n);
    } else {
      context.push(AppRoutes.inkNotebookAt(n.id, p.id));
    }
  }

  /// İyimser silme: silinen defter, akış güncellenmeden önce de listeden kalkar
  /// (akış "silindi" deyince ya da geri alınınca/hata olunca düşer).
  final Set<String> _hidden = {};

  Future<void> _restore(String id) async {
    final repo = ref.read(inkNotebookRepositoryProvider);
    setState(() => _hidden.remove(id));
    await repo.restoreNotebook(id);
  }

  void _open(InkNotebookRecord n) {
    final f = widget.onOpen;
    if (f != null) {
      f(context, n);
    } else {
      context.push(AppRoutes.inkNotebook(n.id));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  List<InkFolderRecord> get _folders => ref.read(inkFoldersProvider).value ?? const [];

  /// Gerçekten var olan açık klasör (silinmişse ana düzey).
  String? get _curFolder => _folderId != null && _folders.any((f) => f.id == _folderId) ? _folderId : null;

  void _goFolder(String? id) => setState(() => _folderId = id);

  void _up() {
    final cur = _curFolder;
    if (cur == null) return;
    final parent = _folders.firstWhere((f) => f.id == cur).parentId;
    _goFolder(parent != null && _folders.any((f) => f.id == parent) ? parent : null);
  }

  void _enterFolder(String id) {
    _searchCtl.clear();
    setState(() {
      _query = '';
      _folderId = id;
    });
  }

  Future<void> _create() async {
    final res = await showDialog<NotebookDialogResult>(
      context: context,
      builder: (_) => const _NotebookDialog(),
    );
    if (res == null || !mounted) return;
    final repo = ref.read(inkNotebookRepositoryProvider);
    final media = MediaQuery.sizeOf(context);
    final dim = pageDimensions(res.size, aspect: screenAspect(media.width, media.height));
    final id = await repo.createNotebook(
      title: res.title,
      coverColor: res.color,
      defaultTemplate: res.template,
      pageWidth: dim.width,
      pageHeight: dim.height,
    );
    final cur = _curFolder;
    if (cur != null) await repo.moveNotebookToFolder(id, cur);
    final n = await repo.findNotebook(id);
    if (n != null && mounted) _open(n);
  }

  Future<void> _createFromCurriculum() async {
    final id = await createNotebookFromCurriculumFlow(context, ref, currentFolderId: _curFolder);
    if (id == null || !mounted) return;
    final n = await ref.read(inkNotebookRepositoryProvider).findNotebook(id);
    if (n != null && mounted) _open(n);
  }

  Future<void> _newFolder() async {
    final res = await showFolderDialog(context);
    if (res == null || !mounted) return;
    await ref.read(inkFolderRepositoryProvider).createFolder(res.name, parentId: _curFolder, color: res.color);
  }

  Future<void> _editFolder(InkFolderRecord f) async {
    final res = await showFolderDialog(context, initial: f);
    if (res == null) return;
    final repo = ref.read(inkFolderRepositoryProvider);
    await repo.renameFolder(f.id, res.name);
    if (res.color != f.color) await repo.setFolderColor(f.id, res.color);
  }

  Future<void> _moveFolder(InkFolderRecord f) async {
    final r = await showFolderPicker(context, folders: _folders, currentId: f.parentId, title: 'Klasör nereye taşınsın?');
    if (r == null) return;
    try {
      await ref.read(inkFolderRepositoryProvider).moveFolder(f.id, r.id);
    } on ArgumentError {
      _toast('Klasör kendi altına taşınamaz.');
    } on StateError {
      _toast('Hedef klasör bulunamadı.');
    }
  }

  Future<void> _deleteFolder(InkFolderRecord f) async {
    final subs = _folders.where((x) => x.parentId == f.id).length;
    if (!await confirmDeleteFolder(context, f, subfolders: subs) || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final wasHere = _folderId == f.id;
    final parent = f.parentId;
    await ref.read(inkFolderRepositoryProvider).deleteFolder(f.id);
    if (wasHere && mounted) _goFolder(parent);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('"${f.name.isEmpty ? 'Adsız klasör' : f.name}" silindi.'),
          action: SnackBarAction(
            label: 'Geri al',
            onPressed: () => ref.read(inkFolderRepositoryProvider).restoreFolder(f.id),
          ),
        ),
      );
  }

  Future<void> _moveNotebook(InkNotebookRecord n) async {
    final r = await showFolderPicker(context, folders: _folders, currentId: n.folderId);
    if (r == null) return;
    try {
      await ref.read(inkNotebookRepositoryProvider).moveNotebookToFolder(n.id, r.id);
    } on StateError {
      _toast('Hedef klasör bulunamadı.');
    }
  }

  Future<void> _folderSheet(InkFolderRecord f) => _actionSheet(
    title: f.name.isEmpty ? 'Adsız klasör' : f.name,
    actions: [
      ('folder-act-rename', Icons.edit_outlined, 'Yeniden adlandır / renk', () => _editFolder(f)),
      ('folder-act-move', Icons.drive_file_move_outlined, 'Taşı…', () => _moveFolder(f)),
      ('folder-act-delete', Icons.delete_outline, 'Sil', () => _deleteFolder(f)),
    ],
  );

  Future<void> _notebookSheet(InkNotebookRecord n) => _actionSheet(
    title: _name(n),
    actions: [
      ('nb-act-rename', Icons.edit_outlined, 'Yeniden adlandır', () => _rename(n)),
      ('nb-act-move', Icons.drive_file_move_outlined, 'Taşı…', () => _moveNotebook(n)),
      ('nb-act-delete', Icons.delete_outline, 'Sil', () => _delete(n)),
    ],
  );

  Future<void> _actionSheet({
    required String title,
    required List<(String, IconData, String, Future<void> Function())> actions,
  }) async {
    final run = await showModalBottomSheet<Future<void> Function()>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final a in actions)
              ListTile(
                key: Key(a.$1),
                leading: Icon(a.$2),
                title: Text(a.$3),
                onTap: () => Navigator.pop(ctx, a.$4),
              ),
          ],
        ),
      ),
    );
    if (run != null && mounted) await run();
  }

  Future<void> _rename(InkNotebookRecord n) async {
    final res = await showDialog<NotebookDialogResult>(
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
        content: Text(
          '"${_name(n)}" listeden kalkar. Çizgileri silinmez; Silinenler\'den geri getirebilirsin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç'),
          ),
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
    setState(() => _hidden.add(n.id));
    try {
      await repo.deleteNotebook(n.id);
    } catch (_) {
      if (mounted) setState(() => _hidden.remove(n.id));
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Defter silinemedi.')));
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('"${_name(n)}" silindi.'),
          action: SnackBarAction(
            label: 'Geri al',
            onPressed: () => _restore(n.id),
          ),
        ),
      );
  }

  /// İyimser yerel sıra (tüm silinmemiş defterler); akış aynı sırayı getirince ya da hata olunca düşer.
  List<String>? _order;

  /// [shown] süzülmüş (etiket/klasör) liste olabilir; yeni sıra TÜM silinmemiş defterlere yazılır:
  /// süzülmüş defterler kendi yerlerini, süzülmeyenler yerlerini korur.
  Future<void> _reorder(
    List<InkNotebookRecord> aliveAll,
    List<InkNotebookRecord> shown,
    int from,
    int to,
  ) async {
    if (from < 0 || from >= shown.length) return;
    final moved = [for (final n in shown) n.id];
    moved.insert(to.clamp(0, moved.length - 1), moved.removeAt(from));
    final inShown = moved.toSet();
    var k = 0;
    final ids = [
      for (final n in aliveAll) inShown.contains(n.id) ? moved[k++] : n.id,
    ];
    setState(() => _order = ids);
    try {
      await ref.read(inkNotebookRepositoryProvider).reorderNotebooks(ids);
    } on ArgumentError {
      _failOrder('Sıralama kaydedilemedi; liste yenilendi, yeniden dene.');
    } on StateError catch (e) {
      _failOrder(e.message);
    }
  }

  void _failOrder(String msg) {
    if (!mounted) return;
    setState(() => _order = null);
    _toast(msg);
  }

  Widget _subtitle(InkNotebookRecord n, Set<String> tagIds, List<Tag> allTags, {String? location}) {
    final mine = [
      for (final t in allTags)
        if (tagIds.contains(t.id)) t,
    ];
    if (mine.isEmpty && location == null) return Text('${n.pageCount} sayfa');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${n.pageCount} sayfa'),
        if (location != null)
          Text(location, key: Key('notebook-loc-${n.id}'), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (mine.isNotEmpty)
          Wrap(
            key: Key('notebook-tags-${n.id}'),
            spacing: 4,
            children: [
              for (final t in mine)
                Chip(
                  key: Key('notebook-chip-${n.id}-${t.id}'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    tagPathLabel(allTags, t.id),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  static String _name(InkNotebookRecord n) =>
      n.title.isEmpty ? 'Adsız defter' : n.title;

  Widget _crumbs(List<InkFolderRecord> path) {
    final theme = Theme.of(context);
    Widget crumb(Key k, String text, VoidCallback? onTap) => TextButton(
      key: k,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: onTap == null ? theme.textTheme.titleSmall : null,
      ),
      onPressed: onTap,
      child: Text(text),
    );
    return SingleChildScrollView(
      key: const Key('folder-crumbs'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          crumb(const Key('crumb-root'), 'Defterler', path.isEmpty ? null : () => _goFolder(null)),
          for (var i = 0; i < path.length; i++) ...[
            const Icon(Icons.chevron_right, size: 18),
            crumb(
              Key('crumb-${path[i].id}'),
              path[i].name.isEmpty ? 'Adsız klasör' : path[i].name,
              i == path.length - 1 ? null : () => _goFolder(path[i].id),
            ),
          ],
        ],
      ),
    );
  }

  Widget _folderCard(InkFolderRecord f, List<InkFolderRecord> all) {
    final subs = all.where((x) => x.parentId == f.id).length;
    return Card(
      key: ValueKey('foldercard-${f.id}'),
      child: ListTile(
        key: Key('folder-${f.id}'),
        leading: Icon(Icons.folder, size: 40, color: Color(f.color)),
        title: Text(f.name.isEmpty ? 'Adsız klasör' : f.name),
        subtitle: Text('${f.notebookCount} defter${subs > 0 ? ' · $subs klasör' : ''}'),
        onTap: () => _enterFolder(f.id),
        onLongPress: () => _folderSheet(f),
        trailing: IconButton(
          key: Key('folder-more-${f.id}'),
          tooltip: 'Klasör işlemleri',
          icon: const Icon(Icons.more_vert),
          onPressed: () => _folderSheet(f),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(inkNotebooksProvider);
    final folders = ref.watch(inkFoldersProvider).value ?? const <InkFolderRecord>[];
    final cur = _folderId != null && folders.any((f) => f.id == _folderId) ? _folderId : null;
    final folderIds = {for (final f in folders) f.id};
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final body = all.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Defterler okunamadı: $e')),
      data: (list) {
        final tagsOf =
            ref.watch(inkNotebookTagMapProvider).value ??
            const <String, Set<String>>{};
        final allTags = ref.watch(tagsProvider).value ?? const <Tag>[];
        var aliveAll = [
          for (final n in list)
            if (!n.deleted && !_hidden.contains(n.id)) n,
        ];
        // Akış silmeyi doğruladıysa iyimser gizleme gereksiz.
        _hidden.removeWhere((id) => list.any((n) => n.id == id && n.deleted));
        final order = _order;
        if (order != null) {
          final byId = {for (final n in aliveAll) n.id: n};
          final sameSet =
              order.length == aliveAll.length && order.every(byId.containsKey);
          if (!sameSet ||
              [for (final n in aliveAll) n.id].join('|') == order.join('|')) {
            _order = null;
          } else {
            aliveAll = [for (final id in order) byId[id]!];
          }
        }
        final usedTagIds = {
          for (final n in aliveAll) ...(tagsOf[n.id] ?? const <String>{}),
        };
        final filtering =
            _tagFilter != null && allTags.any((t) => t.id == _tagFilter);
        final byTag = filterNotebooksByTag(
          aliveAll,
          tagsOf,
          allTags,
          filtering ? _tagFilter : null,
        );
        final q = normalizeTr(_query);
        final hits = q.isEmpty
            ? const <PageTextHit>[]
            : [
                for (final h in ref.watch(pageTextSearchProvider(_query)).value ?? const <PageTextHit>[])
                  if (byTag.any((n) => n.id == h.notebookId)) h,
              ];
        final matching = q.isEmpty
            ? byTag
            : [for (final n in byTag) if (normalizeTr(_name(n)).contains(q)) n];
        // Arama ya da etiket süzgeci klasörler boyunca (düz); aksi halde yalnız açık klasör.
        final flat = q.isNotEmpty || filtering;
        String? effFolder(InkNotebookRecord n) => n.folderId != null && folderIds.contains(n.folderId) ? n.folderId : null;
        final alive = flat ? matching : [for (final n in matching) if (effFolder(n) == cur) n];
        final shownFolders = q.isNotEmpty
            ? [for (final f in folders) if (normalizeTr(f.name).contains(q)) f]
            : filtering
            ? const <InkFolderRecord>[]
            : childFolders(folders, cur);
        final deleted = [
          for (final n in list)
            if (n.deleted || _hidden.contains(n.id)) n,
        ];
        final deletedFolders = ref.watch(inkDeletedFoldersProvider).value ?? const <InkFolderRecord>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
          children: [
            _crumbs(folderCrumbs(cur, folders)),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (widget.embedded)
                  FilledButton.icon(
                    key: const Key('notebook-new'),
                    onPressed: _create,
                    icon: const Icon(Icons.add),
                    label: const Text('Yeni defter'),
                  ),
                OutlinedButton.icon(
                  key: const Key('folder-new'),
                  onPressed: _newFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Yeni klasör'),
                ),
                OutlinedButton.icon(
                  key: const Key('curriculum-notebook-new'),
                  onPressed: _createFromCurriculum,
                  icon: const Icon(Icons.account_tree_outlined),
                  label: const Text('Konu ağacından defter oluştur'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: TextField(
                key: const Key('notebook-search'),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Defter adı ya da el yazısı metninde ara',
                  border: const OutlineInputBorder(),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('notebook-search-clear'),
                          tooltip: 'Aramayı temizle',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _searchCtl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                controller: _searchCtl,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (usedTagIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(
                  key: const Key('notebook-tag-filter'),
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in allTags.where(
                      (t) => usedTagIds.contains(t.id),
                    ))
                      FilterChip(
                        key: Key('notebook-filter-${t.id}'),
                        avatar: const Icon(Icons.sell_outlined, size: 16),
                        label: Text(tagPathLabel(allTags, t.id)),
                        selected: _tagFilter == t.id,
                        onSelected: (on) =>
                            setState(() => _tagFilter = on ? t.id : null),
                      ),
                  ],
                ),
              ),
            if (alive.isEmpty && hits.isEmpty && shownFolders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    q.isNotEmpty
                        ? 'Aramayla eşleşen defter ya da metin yok.'
                        : filtering
                        ? 'Bu etikette defter yok.'
                        : cur != null
                        ? 'Bu klasör boş.'
                        : 'Henüz defter yok. "Yeni defter" ile başla.',
                  ),
                ),
              ),
            for (final f in shownFolders) _folderCard(f, folders),
            ReorderableListView.builder(
              key: const Key('notebook-list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: alive.length,
              onReorderItem: (a, b) => _reorder(aliveAll, alive, a, b),
              itemBuilder: (context, i) {
                final n = alive[i];
                final loc = flat && effFolder(n) != null ? folderPathLabel(effFolder(n), folders) : null;
                return Card(
                  key: ValueKey(n.id),
                  child: ListTile(
                    key: Key('notebook-${n.id}'),
                    leading: _Cover(n.coverColor),
                    title: Text(_name(n)),
                    subtitle: _subtitle(n, tagsOf[n.id] ?? const {}, allTags, location: loc),
                    onTap: () => _open(n),
                    onLongPress: () => _notebookSheet(n),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (narrow)
                          IconButton(
                            key: Key('notebook-more-${n.id}'),
                            tooltip: 'Defter işlemleri',
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => _notebookSheet(n),
                          )
                        else ...[
                          IconButton(
                            key: Key('notebook-rename-${n.id}'),
                            tooltip: 'Yeniden adlandır',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _rename(n),
                          ),
                          IconButton(
                            key: Key('notebook-move-${n.id}'),
                            tooltip: 'Taşı…',
                            icon: const Icon(Icons.drive_file_move_outlined),
                            onPressed: () => _moveNotebook(n),
                          ),
                          IconButton(
                            key: Key('notebook-del-${n.id}'),
                            tooltip: 'Sil',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(n),
                          ),
                        ],
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (hits.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                child: Text(
                  'El yazısı metninde',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final h in hits)
                Card(
                  key: Key('notebook-hit-${h.pageId}'),
                  child: ListTile(
                    leading: const Icon(Icons.text_fields_rounded),
                    title: Text(_name(byTag.firstWhere((n) => n.id == h.notebookId))),
                    subtitle: Text('Sayfa ${h.pageNumber} · ${h.snippet}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _openHit(byTag.firstWhere((n) => n.id == h.notebookId), h),
                  ),
                ),
            ],
            if (_showDeleted) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                child: Text(
                  'Silinenler',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (deleted.isEmpty && deletedFolders.isEmpty)
                const ListTile(title: Text('Silinen defter ya da klasör yok.')),
              for (final f in deletedFolders)
                Card(
                  key: ValueKey('delfolder-${f.id}'),
                  child: ListTile(
                    leading: Opacity(opacity: 0.5, child: Icon(Icons.folder, size: 40, color: Color(f.color))),
                    title: Text(f.name.isEmpty ? 'Adsız klasör' : f.name),
                    subtitle: const Text('Klasör'),
                    trailing: TextButton(
                      key: Key('folder-restore-${f.id}'),
                      onPressed: () => ref.read(inkFolderRepositoryProvider).restoreFolder(f.id),
                      child: const Text('Geri getir'),
                    ),
                  ),
                ),
              for (final n in deleted)
                Card(
                  key: ValueKey('del-${n.id}'),
                  child: ListTile(
                    leading: Opacity(opacity: 0.5, child: _Cover(n.coverColor)),
                    title: Text(_name(n)),
                    subtitle: Text('${n.pageCount} sayfa'),
                    trailing: TextButton(
                      key: Key('notebook-restore-${n.id}'),
                      onPressed: () => _restore(n.id),
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
    final tabs = Padding(
      padding: EdgeInsets.fromLTRB(12, 8, widget.embedded ? 56 : 12, 0),
      child: SegmentedButton<bool>(
        key: const Key('notebooks-view-toggle'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, icon: Icon(Icons.folder_outlined), label: Text('Defterler')),
          ButtonSegment(value: true, icon: Icon(Icons.account_tree_outlined), label: Text('Konuya göre')),
        ],
        selected: {_byKonu},
        onSelectionChanged: (s) => setState(() => _byKonu = s.first),
      ),
    );
    final content = Column(
      children: [
        tabs,
        Expanded(
          child: _byKonu ? ByKonuView(onOpenPage: _openKonuPage) : body,
        ),
      ],
    );
    final Widget page = widget.embedded
        ? Stack(
            children: [
              content,
              Positioned(right: 8, top: 0, child: deletedToggle),
            ],
          )
        : Scaffold(
            appBar: AppBar(title: const Text('Defterler'), actions: [deletedToggle]),
            body: content,
            floatingActionButton: FloatingActionButton.extended(
              key: const Key('notebook-new'),
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Yeni defter'),
            ),
          );
    // Geri tuşu: önce bir üst klasöre.
    return PopScope(
      canPop: cur == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: page,
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
    decoration: BoxDecoration(
      color: Color(color),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Icon(Icons.menu_book, color: Colors.white70, size: 20),
  );
}

typedef NotebookDialogResult = ({String title, int color, PageTemplate template, PageSizeKind size});

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
  late PageTemplate _template = widget.initial?.defaultTemplate ?? PageTemplate.ruled;
  PageSizeKind _size = PageSizeKind.a4;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  NotebookDialogResult get _result =>
      (title: _title.text.trim(), color: _color, template: _template, size: _size);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Yeni defter' : 'Defteri düzenle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('notebook-title-field'),
              controller: _title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Defter adı'),
              onSubmitted: (_) => Navigator.pop(context, _result),
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
            if (widget.initial == null) ...[
              const SizedBox(height: 16),
              const Text('Sayfa şablonu'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in PageTemplate.values)
                    ChoiceChip(
                      key: Key('notebook-template-${t.key}'),
                      avatar: Icon(templateIcon(t), size: 18),
                      label: Text(templateLabel(t)),
                      selected: _template == t,
                      onSelected: (_) => setState(() => _template = t),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('Sayfa boyutu'),
              PageSizePicker(kind: _size, onChanged: (k) => setState(() => _size = k)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
        FilledButton(
          key: const Key('notebook-dialog-ok'),
          onPressed: () => Navigator.pop(context, _result),
          child: const Text('Tamam'),
        ),
      ],
    );
  }
}
