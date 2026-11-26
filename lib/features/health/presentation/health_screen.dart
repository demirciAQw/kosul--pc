import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/health_tables.dart';
import '../domain/health_aggregate.dart';
import '../domain/health_models.dart';
import '../health_providers.dart';

String sourceLabel(String s) => switch (s) {
      healthSourceConnect => 'Health Connect',
      healthSourceHuaweiZip => 'Huawei ZIP',
      healthSourceManual => 'Elle',
      _ => s,
    };

/// Son 14 günün tablosu: uyku (aşamalarla), dinlenme nabzı, stres; kaynak rozetiyle.
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(healthRecentProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Sağlık verisi')),
      body: days.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Okunamadı: $e')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Henüz sağlık verisi yok. Ayarlar > Sağlık verisi kartından izin ver ve "Şimdi al"a bas, '
                  'ya da Huawei ZIP içe aktar.',
                  key: Key('health-empty'),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final maxSleep = list.fold<int>(1, (m, d) => (d.sleepTotalMin ?? 0) > m ? d.sleepTotalMin! : m);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              for (final d in list.reversed) _DayTile(day: d, maxSleep: maxSleep),
            ],
          );
        },
      ),
    );
  }
}

class _DayTile extends StatelessWidget {
  const _DayTile({required this.day, required this.maxSleep});
  final HealthDay day;
  final int maxSleep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = day.sleepTotalMin;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(day.day, style: theme.textTheme.titleSmall)),
            Container(
              key: const Key('source-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                sourceLabel(day.source),
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
          ]),
          if (total != null) ...[
            Text('Uyku: ${formatMinutes(total)}'),
            const SizedBox(height: 4),
            _SleepBar(day: day, maxSleep: maxSleep),
            Text(
              [
                if (day.sleepDeepMin != null) 'derin ${formatMinutes(day.sleepDeepMin!)}',
                if (day.sleepLightMin != null) 'hafif ${formatMinutes(day.sleepLightMin!)}',
                if (day.sleepRemMin != null) 'REM ${formatMinutes(day.sleepRemMin!)}',
                if (day.sleepAwakeMin != null) 'uyanık ${formatMinutes(day.sleepAwakeMin!)}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          ],
          Text(
            [
              if (day.restingHr != null) 'Dinlenme nabzı: ${day.restingHr}',
              if (day.hrv != null) 'HRV: ${day.hrv!.round()} ms',
              if (day.steps != null) 'Adım: ${day.steps}',
              if (day.stressAvg != null) 'Stres: ${day.stressAvg!.round()}/100',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

/// Uyku süresi çubuğu; aşama dakikaları biliniyorsa renkli dilimler.
class _SleepBar extends StatelessWidget {
  const _SleepBar({required this.day, required this.maxSleep});
  final HealthDay day;
  final int maxSleep;

  @override
  Widget build(BuildContext context) {
    final total = day.sleepTotalMin ?? 0;
    final parts = [
      (day.sleepDeepMin ?? 0, Colors.indigo),
      (day.sleepLightMin ?? 0, Colors.blue.shade300),
      (day.sleepRemMin ?? 0, Colors.teal),
    ];
    final known = parts.fold<int>(0, (a, p) => a + p.$1);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth * (total / maxSleep).clamp(0.02, 1.0);
      return Container(
        key: const Key('sleep-bar'),
        width: w,
        height: 10,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: Colors.grey.shade400),
        child: known == 0
            ? null
            : Row(children: [
                for (final p in parts)
                  if (p.$1 > 0) Expanded(flex: p.$1, child: ColoredBox(color: p.$2, child: const SizedBox.expand())),
                if (total > known) Expanded(flex: total - known, child: const SizedBox.shrink()),
              ]),
      );
    });
  }
}
