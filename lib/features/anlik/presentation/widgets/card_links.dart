import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../anlik_providers.dart';
import '../../domain/anlik.dart';
import 'anlik_editor.dart';
import 'anlik_tile.dart';
import 'chip_bars.dart';

/// Soru kartında: serbest etiketler (ders, konu ve neden alanları aynen kalır)
/// ve karta bağlı anlık notlar. Kişi, nota eklenir.
class CardTagsSection extends ConsumerWidget {
  const CardTagsSection({super.key, required this.cardId});
  final String cardId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repo = ref.read(anlikRepositoryProvider);
    final selected = ref.watch(cardTagsProvider).value?[cardId] ?? const <String>{};
    final notes = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
    final linked = [for (final n in notes) if (n.linkedCardIds.contains(cardId)) n];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Etiketler', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TagBar(selected: selected, onChanged: (next) => repo.setCardTags(cardId, next)),
        const SizedBox(height: 16),
        Text('Bağlı notlar', style: theme.textTheme.titleSmall),
        for (final n in linked)
          Row(
            children: [
              Expanded(child: AnlikTile(note: n)),
              IconButton(
                tooltip: 'Bağı kaldır',
                icon: const Icon(Icons.link_off),
                onPressed: () => repo.unlinkNoteFromCard(n.id, cardId),
              ),
            ],
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('soruya-not-yaz'),
              icon: const Icon(Icons.edit_note),
              label: const Text('Bu soruya not yaz'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => Dialog(
                  child: SizedBox(
                    width: 560,
                    height: 560,
                    child: AnlikEditor(
                      linkCardId: cardId,
                      onCancel: () => Navigator.pop(ctx),
                      onSaved: (_, __) => Navigator.pop(ctx),
                    ),
                  ),
                ),
              ),
            ),
            OutlinedButton.icon(
              key: const ValueKey('soruya-not-bagla'),
              icon: const Icon(Icons.link),
              label: const Text('Var olan notu bağla'),
              onPressed: () async {
                final pick = [for (final n in notes) if (!n.linkedCardIds.contains(cardId) && !n.isSleep) n].take(40).toList();
                final id = await showDialog<String>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('Hangi not?'),
                    children: [
                      if (pick.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Bağlanacak not yok.')),
                      for (final n in pick)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, n.id),
                          child: Text(n.body.split('\n').first, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
                );
                if (id != null) await repo.linkNoteToCard(id, cardId);
              },
            ),
          ],
        ),
      ],
    );
  }
}
