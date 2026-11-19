import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/di/core_providers.dart';
import '../../../core/ledger/ledger_service.dart';
import '../../../core/utils/formatters.dart';
import '../domain/change_view.dart';

final claudeChangesProvider =
    StreamProvider<List<LedgerChange>>((ref) => ref.watch(ledgerServiceProvider).watchHistory(source: 'claude'));
final undoneChangesProvider = StreamProvider<Set<String>>((ref) => ref.watch(ledgerServiceProvider).watchUndone());
final conflictsProvider = StreamProvider<List<CakismaRow>>((ref) => ref.watch(ledgerServiceProvider).watchConflicts());

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _undoText(Map<UndoResult, int> r) {
  final done = r[UndoResult.done] ?? 0;
  final conflict = r[UndoResult.conflict] ?? 0;
  return [
    if (done > 0) '$done değişiklik geri alındı',
    if (conflict > 0) '$conflict tanesi sonradan değiştiği için üstüne yazılmadı (Çakışmalar)',
    if (done == 0 && conflict == 0) 'Geri alınacak bir şey yok',
  ].join('; ');
}

/// "Claude'un değişiklikleri": oturum oturum gruplu; madde ve oturum başına Geri al.
class ClaudeChangesView extends ConsumerWidget {
  const ClaudeChangesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(claudeChangesProvider);
    final undone = ref.watch(undoneChangesProvider).value ?? const <String>{};
    final theme = Theme.of(context);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Değişiklikler okunamadı: $e')),
      data: (all) {
        final groups = groupBySession(all);
        if (groups.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Claude henüz bir şey değiştirmedi. Değiştirince burada görünür ve geri alınabilir.',
                  textAlign: TextAlign.center),
            ),
          );
        }
        return ListView(
          children: [
            for (final g in groups)
              ExpansionTile(
                key: ValueKey('oturum:${g.session}'),
                initiallyExpanded: groups.first == g,
                title: Text(g.session == null ? 'Oturumsuz değişiklikler' : 'Oturum ${_shortId(g.session!)}'),
                subtitle: Text('${formatShortDate(g.at)} · ${g.changes.length} değişiklik'),
                trailing: TextButton(
                  key: ValueKey('oturumu-geri-al:${g.session}'),
                  onPressed: g.session == null || g.changes.every((c) => undone.contains(c.id))
                      ? null
                      : () async {
                          final ledger = ref.read(ledgerServiceProvider);
                          final r = await ledger.undoSession(g.session!);
                          if (context.mounted) _say(context, _undoText(r));
                        },
                  child: const Text('Oturumu geri al'),
                ),
                children: [
                  for (final c in g.changes)
                    ListTile(
                      key: ValueKey('degisiklik:${c.id}'),
                      dense: true,
                      title: Text(describeChange(c).title,
                          style: undone.contains(c.id) ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
                      subtitle: Text(describeChange(c).detail),
                      trailing: undone.contains(c.id)
                          ? Text('geri alındı', style: theme.textTheme.labelSmall)
                          : TextButton(
                              onPressed: () async {
                                final r = await ref.read(ledgerServiceProvider).undoChange(c.id);
                                if (context.mounted) {
                                  _say(context, switch (r) {
                                    UndoResult.done => 'Geri alındı',
                                    UndoResult.conflict => 'Satır sonradan değişmiş; üstüne yazılmadı (Çakışmalar listesinde)',
                                    UndoResult.already => 'Zaten geri alınmış',
                                    UndoResult.notFound => 'Değişiklik bulunamadı',
                                  });
                                }
                              },
                              child: const Text('Geri al'),
                            ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  static String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);
}

/// Çakışmalar: iki tarafta da değişen satırın kaybeden sürümü.
class ConflictsView extends ConsumerWidget {
  const ConflictsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(conflictsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Çakışmalar okunamadı: $e')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Çakışma yok. Telefon ve bilgisayar aynı satırı farklı değiştirirse burada görünür; '
                  'kaybeden sürüm silinmez.', textAlign: TextAlign.center),
            ),
          );
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) {
            final c = list[i];
            final why = switch (c.taraf) {
              'uzak' => 'Karşı cihazın sürümü yeni olduğu için kazandı.',
              'yerel' => 'Bu cihazın sürümü yeni olduğu için kazandı.',
              _ => 'Geri alma yapılamadı: satır sonradan değişmişti.',
            };
            return Card(
              key: ValueKey('cakisma:${c.id}'),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${tableTitle(c.tablo)} · ${formatShortDate(c.createdAt)}', style: Theme.of(context).textTheme.titleSmall),
                    Text(why),
                    const SizedBox(height: 6),
                    Text('Kazanan: ${_preview(c.kazanan)}'),
                    Text('Kaybeden: ${_preview(c.kaybeden)}'),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            key: ValueKey('cakisma-gec:${c.id}'),
                            onPressed: () => ref.read(ledgerServiceProvider).resolveConflict(c.id),
                            child: const Text('Kazanan kalsın'),
                          ),
                          FilledButton.tonal(
                            key: ValueKey('cakisma-geri:${c.id}'),
                            onPressed: () => ref.read(ledgerServiceProvider).restoreLoser(c.id),
                            child: const Text('Kaybedeni geri getir'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static String _preview(String? json) {
    if (json == null) return '(satır silinmiş)';
    final t = describeChange(LedgerChange(
      id: '',
      device: '',
      source: '',
      table: '',
      rowId: '',
      op: 'ekle',
      clock: '0000000000000-0000-x',
      neu: json,
    ));
    return t.detail.isEmpty ? json : t.detail;
  }
}
