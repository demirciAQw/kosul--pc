import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../anlik/anlik_providers.dart';
import '../../anlik/domain/anlik.dart';
import '../../anlik/domain/mentions.dart';
import '../../anlik/presentation/widgets/chip_bars.dart';
import '../../anlik/presentation/widgets/pickers.dart';
import '../notes_providers.dart';

/// "Etiketler ve kişiler" paneli: defter ve (verilirse) açık sayfa için Anlık'ın ortak
/// etiket/kişi listesinden seçer, bağlar, kaldırır. Seçici, oluşturma ve `((etiket))` /
/// `@kişi` ayrıştırması Anlık'ınkilerdir (çiftleme yok).
Future<void> showInkTagsPanel(BuildContext context, {required String notebookId, String? pageId}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => InkTagsPanel(notebookId: notebookId, pageId: pageId),
    );

class InkTagsPanel extends ConsumerStatefulWidget {
  const InkTagsPanel({super.key, required this.notebookId, this.pageId});
  final String notebookId;
  final String? pageId;

  @override
  ConsumerState<InkTagsPanel> createState() => _InkTagsPanelState();
}

class _InkTagsPanelState extends ConsumerState<InkTagsPanel> {
  Set<String> _nbTags = {}, _nbPeople = {}, _pgTags = {}, _pgPeople = {};
  bool _loaded = false;
  final _quick = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _quick.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(inkNotebookRepositoryProvider);
    final pid = widget.pageId;
    final nt = await repo.notebookTagIds(widget.notebookId);
    final np = await repo.notebookPersonIds(widget.notebookId);
    final pt = pid == null ? <String>{} : await repo.pageTagIds(pid);
    final pp = pid == null ? <String>{} : await repo.pagePersonIds(pid);
    if (!mounted) return;
    setState(() {
      _nbTags = nt;
      _nbPeople = np;
      _pgTags = pt;
      _pgPeople = pp;
      _loaded = true;
    });
  }

  /// Çubuktaki yeni kümeyi depoya yazar: eklenenler bağlanır, çıkarılanlar kaldırılır.
  Future<void> _sync(Set<String> old, Set<String> now, Future<void> Function(String) add, Future<void> Function(String) remove) async {
    for (final id in now.difference(old)) {
      await add(id);
    }
    for (final id in old.difference(now)) {
      await remove(id);
    }
  }

  Future<void> _setNbTags(Set<String> v) async {
    final repo = ref.read(inkNotebookRepositoryProvider);
    final old = _nbTags;
    setState(() => _nbTags = v);
    await _sync(old, v, (i) => repo.addNotebookTag(widget.notebookId, i), (i) => repo.removeNotebookTag(widget.notebookId, i));
  }

  Future<void> _setNbPeople(Set<String> v) async {
    final repo = ref.read(inkNotebookRepositoryProvider);
    final old = _nbPeople;
    setState(() => _nbPeople = v);
    await _sync(old, v, (i) => repo.addNotebookPerson(widget.notebookId, i), (i) => repo.removeNotebookPerson(widget.notebookId, i));
  }

  Future<void> _setPgTags(Set<String> v) async {
    final repo = ref.read(inkNotebookRepositoryProvider), pid = widget.pageId!;
    final old = _pgTags;
    setState(() => _pgTags = v);
    await _sync(old, v, (i) => repo.addPageTag(pid, i), (i) => repo.removePageTag(pid, i));
  }

  Future<void> _setPgPeople(Set<String> v) async {
    final repo = ref.read(inkNotebookRepositoryProvider), pid = widget.pageId!;
    final old = _pgPeople;
    setState(() => _pgPeople = v);
    await _sync(old, v, (i) => repo.addPagePerson(pid, i), (i) => repo.removePagePerson(pid, i));
  }

  /// "((his > tiksinti)) @Ayşe" yazımı: Anlık'ın ayrıştırıcısı çözer; olmayan ad
  /// onay ister (Anlık notundaki gibi), onaylanırsa ortak listeye eklenir. Bağ SAYFAYA
  /// (sayfa açıksa) yoksa deftere yazılır.
  Future<void> _submitQuick() async {
    final text = _quick.text;
    final paths = parseTagMentions(text);
    final names = parsePersonMentions(text);
    if (paths.isEmpty && names.isEmpty) return;
    final repo = ref.read(anlikRepositoryProvider);
    final tags = await repo.allTags();
    final people = await repo.allPeople();
    final knownKeys = {for (final t in tags) t.name};
    final unknownTags = [
      for (final p in paths)
        if (!p.every((l) => knownKeys.contains(tagKey(l)))) p.join(' > '),
    ];
    final unknownPeople = [
      for (final n in names)
        if (matchPerson(n, people) == null) n,
    ];
    if (unknownTags.isNotEmpty || unknownPeople.isNotEmpty) {
      if (!mounted) return;
      final ok = await confirmUnknownMentions(context, UnknownMentionsException(tags: unknownTags, people: unknownPeople));
      if (!ok || !mounted) return;
    }
    final tagIds = <String>{}, personIds = <String>{};
    for (final p in paths) {
      final id = await ensureTagPath(ref, p.join(' > '));
      if (id != null) tagIds.add(id);
    }
    for (final n in names) {
      final id = await ensurePerson(ref, n);
      if (id != null) personIds.add(id);
    }
    final onPage = widget.pageId != null;
    if (tagIds.isNotEmpty) await (onPage ? _setPgTags : _setNbTags)({...(onPage ? _pgTags : _nbTags), ...tagIds});
    if (personIds.isNotEmpty) await (onPage ? _setPgPeople : _setNbPeople)({...(onPage ? _pgPeople : _nbPeople), ...personIds});
    if (mounted) _quick.clear();
  }

  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: !_loaded
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Etiketler ve kişiler', style: th.titleMedium),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('ink-tags-quick'),
                      controller: _quick,
                      decoration: InputDecoration(
                        hintText: '((etiket)) ya da @kişi yaz, Enter',
                        prefixIcon: const Icon(Icons.alternate_email),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: _submitQuick),
                      ),
                      onSubmitted: (_) => _submitQuick(),
                    ),
                    if (widget.pageId != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('Yazarak eklenenler bu sayfaya bağlanır.', style: th.bodySmall),
                      ),
                    const SizedBox(height: 12),
                    Text('Defter', style: th.titleSmall),
                    const SizedBox(height: 4),
                    KeyedSubtree(key: const Key('ink-tags-notebook'), child: TagBar(selected: _nbTags, onChanged: _setNbTags)),
                    const SizedBox(height: 4),
                    KeyedSubtree(key: const Key('ink-people-notebook'), child: PersonBar(selected: _nbPeople, onChanged: _setNbPeople)),
                    if (widget.pageId != null) ...[
                      const Divider(height: 24),
                      Text('Bu sayfa', style: th.titleSmall),
                      const SizedBox(height: 4),
                      KeyedSubtree(key: const Key('ink-tags-page'), child: TagBar(selected: _pgTags, onChanged: _setPgTags)),
                      const SizedBox(height: 4),
                      KeyedSubtree(key: const Key('ink-people-page'), child: PersonBar(selected: _pgPeople, onChanged: _setPgPeople)),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}
