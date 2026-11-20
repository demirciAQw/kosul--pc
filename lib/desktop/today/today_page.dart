import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/palette.dart';
import '../../core/di/core_providers.dart';
import '../../features/curriculum/curriculum_providers.dart';
import '../../features/curriculum/domain/curriculum.dart';
import '../../features/question_bank/domain/question_bank.dart';
import '../../features/question_bank/question_bank_providers.dart';
import '../desktop_providers.dart';
import '../notebook/notebook_providers.dart';
import '../widgets/desktop_page.dart';
import 'domain/today_groups.dart';

const _months = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
const _weekdays = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];

/// Bugün: telefondaki ana ekranın "tekrar" kısmı. Tekrarı gelen sorular, ders
/// ve konuya göre. Soruya basınca Defter'de açılır. Veri `dueReviewsProvider`
/// (telefonla aynı aralıklı tekrar); eşitlemeyle yeni vade gelince tazelenir.
class DesktopTodayPage extends ConsumerWidget {
  const DesktopTodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tekrar sayısı değişince (eşitleme, düzenleme) liste yeniden okunur.
    ref.listen(dueCountProvider, (_, _) => ref.invalidate(dueReviewsProvider));
    final now = ref.watch(clockProvider)();
    final due = ref.watch(dueReviewsProvider);
    final curriculum = ref.watch(curriculumProvider).value ?? const <CurriculumNode>[];
    final titles = {for (final n in curriculum) n.id: n.title};
    final theme = Theme.of(context);

    return DesktopPage(
      title: 'Bugün',
      subtitle: '${now.day} ${_months[now.month - 1]} ${_weekdays[now.weekday - 1]}',
      actions: [
        IconButton(
          key: const ValueKey('bugun-yenile'),
          tooltip: 'Yenile',
          onPressed: () => ref.invalidate(dueReviewsProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: due.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Tekrarlar okunamadı: $e')),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 48, color: KocumColors.green),
                  const SizedBox(height: 12),
                  Text('Bugün tekrar edecek soru yok.', style: theme.textTheme.titleMedium),
                ],
              ),
            );
          }
          final groups = groupDueReviews(
            list,
            (r) => titles[r.card.mebNodeId] ?? r.card.topicText,
          );
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${list.length} soru tekrar bekliyor · ${groups.length} ders',
                key: const ValueKey('bugun-ozet'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              for (final g in groups) _SubjectCard(group: g, now: now),
            ],
          );
        },
      ),
    );
  }
}

class _SubjectCard extends ConsumerWidget {
  const _SubjectCard({required this.group, required this.now});
  final SubjectGroup group;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('bugun-ders:${group.subject}'),
        initiallyExpanded: true,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(group.subject, style: theme.textTheme.titleSmall),
        trailing: Text('${group.count} soru', style: theme.textTheme.labelLarge),
        children: [
          for (final t in group.topics) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Row(
                children: [
                  Expanded(child: Text(t.title, style: theme.textTheme.labelLarge)),
                  Text('${t.count}', style: theme.textTheme.labelMedium),
                ],
              ),
            ),
            for (final r in t.reviews) _QuestionTile(review: r, now: now),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _QuestionTile extends ConsumerWidget {
  const _QuestionTile({required this.review, required this.now});
  final DueReview review;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = review.card;
    final late = overdueDays(review.state.dueAt, now);
    final parts = [
      card.sourceName,
      if (card.reason != null) card.reasonText,
      late == 0 ? 'bugün' : '$late gün gecikti',
    ];
    return ListTile(
      key: ValueKey('bugun-soru:${card.id}'),
      dense: true,
      title: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () {
        ref.read(notebookSelectionProvider.notifier).select(card.id);
        ref.read(desktopSectionProvider.notifier).select(DesktopSection.notebook);
      },
    );
  }
}
