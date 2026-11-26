import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/core_providers.dart';
import '../../../../core/text/turkish_text.dart';
import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import '../../domain/mentions.dart';
import '../../domain/tag_tree.dart';

/// Etiket seç ya da yeni etiket oluştur (yazılan ad "Oluştur"a basılınca
/// açıkça onaylanmış olur). Seçilen etiketin kimliğini döndürür.
Future<String?> showTagPicker(BuildContext context, WidgetRef ref, {Set<String> exclude = const {}}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _TagPickerSheet(exclude: exclude),
  );
}

final Expando<Future<void>> _ensureTails = Expando('ensureTail');

/// Etiket/kişi oluşturmayı (aynı depo için) sırayla çalıştırır: aynı adı iki çağrı aynı anda
/// oluşturmaya kalkmaz (`tags.name` UNIQUE hatası, kişi tekrarı). İş hata verse de kuyruk tıkanmaz.
Future<T> _serialized<T>(Object repo, Future<T> Function() job) {
  final run = (_ensureTails[repo] ?? Future<void>.value()).then((_) => job());
  _ensureTails[repo] = run.then((_) {}, onError: (_) {});
  return run;
}

/// "üst > alt" yolundaki etiketleri (yoksa) oluşturur; son etiketin kimliğini döner.
/// Etiket seçici ve defter etiket paneli aynı yolu kullanır. Yarış güvenli: aynı ad ikinci
/// çağrıda mevcut etiketi döner.
Future<String?> ensureTagPath(WidgetRef ref, String raw) {
  final path = tagPath(raw);
  if (path.isEmpty) return Future.value(null);
  final repo = ref.read(anlikRepositoryProvider);
  return _serialized(repo, () async {
    final now = ref.read(clockProvider)();
    final byKey = {for (final t in await repo.allTags()) t.name: t};
    String? parent;
    String? last;
    for (final label in path) {
      var t = byKey[tagKey(label)];
      if (t == null) {
        final fresh = Tag(id: ref.read(idGeneratorProvider).next(), name: tagKey(label), label: label, parentId: parent, createdAt: now);
        try {
          await repo.saveTag(fresh);
          t = fresh;
        } catch (_) {
          // Başka yol aynı adı az önce yazmış olabilir: varsa onu kullan, yoksa hata yukarı.
          final again = {for (final x in await repo.allTags()) x.name: x};
          t = again[fresh.name];
          if (t == null) rethrow;
        }
        byKey[t.name] = t;
      }
      parent = t.id;
      last = t.id;
    }
    return last;
  });
}

/// Adı ya da takma adı eşleşen kişiyi bulur; yoksa oluşturur. Kimliğini döner (yarış güvenli).
Future<String?> ensurePerson(WidgetRef ref, String name) {
  final n = name.trim();
  if (n.isEmpty) return Future.value(null);
  final repo = ref.read(anlikRepositoryProvider);
  return _serialized(repo, () async {
    final found = matchPerson(n, await repo.allPeople());
    if (found != null) return found.id;
    final p = Person(id: ref.read(idGeneratorProvider).next(), name: n, createdAt: ref.read(clockProvider)());
    await repo.savePerson(p);
    return p.id;
  });
}

class _TagPickerSheet extends ConsumerStatefulWidget {
  const _TagPickerSheet({required this.exclude});
  final Set<String> exclude;

  @override
  ConsumerState<_TagPickerSheet> createState() => _TagPickerSheetState();
}

class _TagPickerSheetState extends ConsumerState<_TagPickerSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _create(String raw) async {
    final id = await ensureTagPath(ref, raw);
    if (id != null && mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final q = normalizeTr(_ctrl.text);
    final list = [
      for (final (t, _) in tagTreeOrder(tags))
        if (!widget.exclude.contains(t.id) && (q.isEmpty || normalizeTr(tagPathLabel(tags, t.id)).contains(q))) t,
    ];
    final exact = tags.any((t) => t.name == q);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const ValueKey('etiket-ara'),
                controller: _ctrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) => list.length == 1 && !exact ? Navigator.pop(context, list.first.id) : null,
                decoration: const InputDecoration(
                  hintText: 'Etiket ara ya da yeni yaz (üst > alt)',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (_ctrl.text.trim().isNotEmpty && !exact)
              ListTile(
                key: const ValueKey('etiket-olustur'),
                leading: const Icon(Icons.add_circle_outline),
                title: Text('“${_ctrl.text.trim()}” etiketini oluştur'),
                onTap: () => _create(_ctrl.text),
              ),
            Flexible(
              child: list.isEmpty
                  ? const Padding(padding: EdgeInsets.all(24), child: Text('Etiket yok'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (_, i) => ListTile(
                        leading: const Icon(Icons.sell_outlined),
                        title: Text(tagPathLabel(tags, list[i].id)),
                        onTap: () => Navigator.pop(context, list[i].id),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kişi seç; yoksa "Yeni kişi ekle".
Future<String?> showPersonPicker(BuildContext context, WidgetRef ref, {Set<String> exclude = const {}}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _PersonPickerSheet(exclude: exclude),
  );
}

class _PersonPickerSheet extends ConsumerStatefulWidget {
  const _PersonPickerSheet({required this.exclude});
  final Set<String> exclude;

  @override
  ConsumerState<_PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends ConsumerState<_PersonPickerSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final id = await ensurePerson(ref, _ctrl.text);
    if (id != null && mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(peopleProvider).value ?? const <Person>[];
    final q = normalizeTr(_ctrl.text);
    final list = [
      for (final p in people)
        if (!widget.exclude.contains(p.id) && (q.isEmpty || p.keys.any((k) => k.contains(q)))) p,
    ];
    final exact = matchPerson(_ctrl.text, people) != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const ValueKey('kisi-ara'),
                controller: _ctrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Kişi ara ya da yeni ad yaz',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (_ctrl.text.trim().isNotEmpty && !exact)
              ListTile(
                key: const ValueKey('kisi-olustur'),
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: Text('Yeni kişi ekle: “${_ctrl.text.trim()}”'),
                onTap: _create,
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(list[i].name),
                  subtitle: list[i].about.isEmpty ? null : Text(list[i].about),
                  onTap: () => Navigator.pop(context, list[i].id),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kaydederken metinde olmayan etiket ya da kişi çıkarsa: adları göster, onay iste.
Future<bool> confirmUnknownMentions(BuildContext context, UnknownMentionsException e) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Yeni ad var'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (e.tags.isNotEmpty) ...[
            const Text('Şu etiketler oluşturulsun mu?'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [for (final t in e.tags) Chip(avatar: const Icon(Icons.sell_outlined, size: 16), label: Text(t))]),
            const SizedBox(height: 12),
          ],
          if (e.people.isNotEmpty) ...[
            const Text('Şu kişiler eklensin mi?'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [for (final p in e.people) Chip(avatar: const Icon(Icons.person_outline, size: 16), label: Text(p))]),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        FilledButton(key: const ValueKey('yeni-onayla'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Oluştur')),
      ],
    ),
  );
  return ok ?? false;
}
