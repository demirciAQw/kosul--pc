import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/core_providers.dart';
import '../../../../core/text/turkish_text.dart';
import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import '../../domain/tag_tree.dart';

/// Kişi ekle / düzenle penceresi: ad, takma adlar (virgülle), kim olduğu.
Future<void> showPersonDialog(BuildContext context, WidgetRef ref, {Person? person}) async {
  final name = TextEditingController(text: person?.name ?? '');
  final aliases = TextEditingController(text: person?.aliases.join(', ') ?? '');
  final about = TextEditingController(text: person?.about ?? '');
  String? error;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(person == null ? 'Yeni kişi' : 'Kişiyi düzenle'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('kisi-ad'),
                controller: name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: 'Ad (takma ad olabilir)', errorText: error),
              ),
              TextField(
                key: const ValueKey('kisi-takma'),
                controller: aliases,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Diğer adları (virgülle)'),
              ),
              TextField(
                key: const ValueKey('kisi-not'),
                controller: about,
                decoration: const InputDecoration(labelText: 'Kim? (ör. sınıf arkadaşı)'),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(
            key: const ValueKey('kisi-kaydet'),
            onPressed: () {
              if (name.text.trim().isEmpty) {
                setState(() => error = 'Bir ad yaz');
              } else {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    ),
  );
  if (saved == true) {
    final al = [for (final a in aliases.text.split(',')) if (a.trim().isNotEmpty) a.trim()];
    await ref.read(anlikRepositoryProvider).savePerson(Person(
          id: person?.id ?? ref.read(idGeneratorProvider).next(),
          name: name.text.trim(),
          aliases: al,
          about: about.text.trim(),
          source: person?.source ?? Source.ben,
          createdAt: person?.createdAt ?? ref.read(clockProvider)(),
        ));
  }
  // Kontrolcüler dispose edilmez: pencere kapanış animasyonunda hâlâ kullanıyor.
}

/// Etiket ağacı: yeniden adlandır, üst etiketi değiştir, iki etiketi birleştir.
class TagsManager extends ConsumerWidget {
  const TagsManager({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tagsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Etiketler okunamadı: $e')),
      data: (tags) {
        if (tags.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Henüz etiket yok. Notta ((etiket)) yaz ya da Etiket düğmesine bas.', textAlign: TextAlign.center),
            ),
          );
        }
        final order = tagTreeOrder(tags);
        return ListView.builder(
          itemCount: order.length,
          itemBuilder: (_, i) {
            final (t, depth) = order[i];
            return ListTile(
              key: ValueKey('etiket-satir:${t.id}'),
              contentPadding: EdgeInsets.only(left: 16.0 + depth * 24, right: 8),
              leading: Icon(t.source == Source.otomatik ? Icons.auto_awesome : Icons.sell_outlined),
              title: Text(t.label),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'ad' => _rename(context, ref, t, tags),
                  'ust' => _reparent(context, ref, t, tags),
                  _ => _merge(context, ref, t, tags),
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'ad', child: Text('Yeniden adlandır')),
                  PopupMenuItem(value: 'ust', child: Text('Üst etiketi değiştir')),
                  PopupMenuItem(value: 'birlestir', child: Text('Başka etiketle birleştir')),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Tag t, List<Tag> tags) async {
    final c = TextEditingController(text: t.label);
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeniden adlandır'),
        content: TextField(key: const ValueKey('etiket-yeni-ad'), controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Kaydet')),
        ],
      ),
    );
    final next = label?.trim();
    if (next == null || next.isEmpty || next == t.label) return;
    final clash = tags.any((o) => o.id != t.id && o.name == tagKey(next));
    if (clash) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bu adda bir etiket var. İstersen ikisini birleştir.')),
        );
      }
      return;
    }
    await ref.read(anlikRepositoryProvider).saveTag(t.copyWith(label: next));
  }

  Future<void> _reparent(BuildContext context, WidgetRef ref, Tag t, List<Tag> tags) async {
    final options = [for (final (o, _) in tagTreeOrder(tags)) if (canSetParent(tags, t.id, o.id) && o.id != t.id) o];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Üst etiket'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Yok (en üst)')),
          for (final o in options)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, o.id), child: Text(tagPathLabel(tags, o.id))),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(anlikRepositoryProvider).saveTag(
          picked.isEmpty ? t.copyWith(clearParent: true) : t.copyWith(parentId: picked),
        );
  }

  Future<void> _merge(BuildContext context, WidgetRef ref, Tag t, List<Tag> tags) async {
    final into = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('“${t.label}” hangi etikete katılsın?'),
        children: [
          for (final (o, _) in tagTreeOrder(tags))
            if (o.id != t.id) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, o.id), child: Text(tagPathLabel(tags, o.id))),
        ],
      ),
    );
    if (into == null) return;
    if (!context.mounted) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Birleştirilsin mi?'),
        content: Text('“${t.label}” kalkar; notları ve soruları “${tags.firstWhere((o) => o.id == into).label}” olur.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(key: const ValueKey('birlestir-onay'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Birleştir')),
        ],
      ),
    );
    if (sure == true) await ref.read(anlikRepositoryProvider).mergeTags(t.id, into);
  }
}

/// Kişi listesi; dokununca [onOpen].
class PeopleList extends ConsumerWidget {
  const PeopleList({super.key, required this.onOpen, this.selectedId});
  final void Function(Person p) onOpen;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(peopleProvider);
    final notes = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Kişiler okunamadı: $e')),
      data: (people) {
        if (people.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Henüz kişi yok. Notta @ad yaz ya da + düğmesine bas.', textAlign: TextAlign.center),
            ),
          );
        }
        return ListView.builder(
          itemCount: people.length,
          itemBuilder: (_, i) {
            final p = people[i];
            final count = notes.where((n) => n.personIds.contains(p.id)).length;
            return ListTile(
              key: ValueKey('kisi-satir:${p.id}'),
              selected: p.id == selectedId,
              leading: CircleAvatar(child: Text(normalizeTr(p.name).isEmpty ? '?' : titleCaseTr(p.name.substring(0, 1)))),
              title: Text(p.name),
              subtitle: Text([
                if (p.about.isNotEmpty) p.about,
                if (p.aliases.isNotEmpty) 'ayrıca: ${p.aliases.join(', ')}',
              ].join(' · ')),
              trailing: Text('$count not'),
              onTap: () => onOpen(p),
            );
          },
        );
      },
    );
  }
}
