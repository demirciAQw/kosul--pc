import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../domain/health_aggregate.dart';
import '../health_providers.dart';

/// Uyku kartının altında: "Dün gece (saatten): 7s 12dk, derin 1s 30dk".
/// Elle kayıtla çakışma varsa kullanıcıya hangisini kullanacağı sorulur;
/// hiçbir kayıt otomatik üzerine yazılmaz ya da silinmez.
class SleepWatchRow extends ConsumerWidget {
  const SleepWatchRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(healthVisibleProvider)) return const SizedBox.shrink();
    final st = ref.watch(lastNightProvider).value;
    if (st == null || st.day == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final c = st.conflict;
    Future<void> choose(String v) async {
      await ref.read(healthRepositoryProvider).setSleepChoice(st.day!.day, v);
      ref.invalidate(sleepChoiceProvider(st.day!.day));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (st.showWatch)
          Text(lastNightSummary(st.day)!, key: const Key('uyku-saat-ozet'), style: theme.textTheme.bodyMedium)
        else
          Text('Saatteki uyku verisi gizlendi (elle kaydını seçtin).', style: theme.textTheme.bodySmall),
        if (st.needsChoice && c != null) ...[
          const SizedBox(height: 4),
          Text(
            'Elle kaydın (${formatShortDate(c.manualBed)} - ${formatShortDate(c.manualWake)}) ile saatin '
            '(${formatShortDate(c.healthStart)} - ${formatShortDate(c.healthEnd)}) farklı. Hangisini kullanayım?',
            key: const Key('uyku-cakisma'),
            style: theme.textTheme.bodySmall,
          ),
          Wrap(spacing: 8, children: [
            TextButton(key: const Key('uyku-saat'), onPressed: () => choose('saat'), child: const Text('Saati kullan')),
            TextButton(key: const Key('uyku-elle'), onPressed: () => choose('elle'), child: const Text('Elle kaydı kullan')),
          ]),
        ],
      ]),
    );
  }
}
