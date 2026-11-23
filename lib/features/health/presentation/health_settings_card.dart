import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../domain/health_models.dart';
import '../domain/health_source.dart';
import '../health_providers.dart';

/// Ayarlar: "Sağlık verisi" kartı. Masaüstünde görünmez.
class HealthSettingsCard extends ConsumerStatefulWidget {
  const HealthSettingsCard({super.key});

  @override
  ConsumerState<HealthSettingsCard> createState() => _HealthSettingsCardState();
}

class _HealthSettingsCardState extends ConsumerState<HealthSettingsCard> {
  bool _busy = false;
  bool _showOrigins = false;
  String? _msg;

  Future<void> _ask() async {
    setState(() => _busy = true);
    try {
      await ref.read(healthSourceProvider).requestPermissions();
      ref.invalidate(healthStatusProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final n = await ref.read(healthSyncServiceProvider).sync();
      _msg = n == 0 ? 'Yeni veri gelmedi.' : '$n günün verisi güncellendi.';
    } catch (e) {
      _msg = 'Okunamadı: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sağlık verisini sil'),
        content: const Text(
          'Uyku, stres ve nabız özetlerinin hepsi bu telefondan silinir (üç tablo). '
          'Health Connect\'teki verin ve Koçum\'un izni değişmez; izni Health Connect ayarlarından geri alabilirsin. '
          'Daha önce aldığın yedek ZIP\'lerde kalan kopyalar silinmez.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true) return;
    final n = await ref.read(healthRepositoryProvider).deleteAll();
    if (mounted) setState(() => _msg = '$n kayıt silindi.');
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(healthVisibleProvider)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final status = ref.watch(healthStatusProvider);
    final counts = ref.watch(healthCountsProvider).value;
    final includeReport = ref.watch(healthIncludeInReportProvider).value ?? false;
    final st = status.value;
    final text = switch (st?.availability) {
      null => 'Kontrol ediliyor…',
      HealthAvailability.unsupported => 'Health Connect bu cihazda kullanılamıyor.',
      HealthAvailability.needsInstall => 'Health Connect yok. Play Store\'dan "Health Connect"i kur.',
      HealthAvailability.needsUpdate => 'Health Connect güncellenmeli (Play Store).',
      HealthAvailability.available => st!.allGranted
          ? 'Health Connect hazır; tüm izinler verildi.'
          : st.anyGranted
              ? 'Health Connect hazır; izinler eksik (${st.granted.length}/${HealthDataType.values.length}).'
              : 'Health Connect hazır; izin verilmedi.',
    };
    return Card(
      key: const Key('health-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.monitor_heart_outlined),
              const SizedBox(width: 12),
              Expanded(child: Text('Sağlık verisi', style: theme.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 4),
            Text(
              'Saatinin uyku, nabız ve adım verisini Health Connect\'ten okur (yalnız okuma, yalnız bu telefonda). '
              'Stres için Health Connect\'te veri türü yok; stres için Huawei ZIP içe aktar ya da elle gir.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(text, key: const Key('health-status')),
            if (st?.error != null)
              Text(st!.error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              if (st?.usable == true && !(st?.allGranted ?? false))
                FilledButton(
                    key: const Key('health-grant'), onPressed: _busy ? null : _ask, child: const Text('İzin ver')),
              if (st?.usable == true && st!.anyGranted)
                OutlinedButton(
                    key: const Key('health-sync'), onPressed: _busy ? null : _sync, child: const Text('Şimdi al (14 gün)')),
              OutlinedButton(onPressed: () => ref.invalidate(healthStatusProvider), child: const Text('Yenile')),
            ]),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            if (_msg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_msg!)),
            const Divider(height: 24),
            Text('Veri hangi uygulamalardan geliyor?', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (!_showOrigins)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const Key('health-origins-btn'),
                  onPressed: st?.anyGranted == true ? () => setState(() => _showOrigins = true) : null,
                  child: const Text('Son 14 günü tara'),
                ),
              )
            else
              const _Origins(),
            const Divider(height: 24),
            OutlinedButton.icon(
              key: const Key('health-open'),
              icon: const Icon(Icons.bar_chart_rounded),
              onPressed: () => context.push(AppRoutes.health),
              label: const Text('Sağlık verisi (son 14 gün)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('health-huawei'),
              icon: const Icon(Icons.folder_zip_outlined),
              onPressed: () => context.push(AppRoutes.huaweiImport),
              label: const Text('Huawei verisi içe aktar (ZIP)'),
            ),
            SwitchListTile(
              key: const Key('health-report-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Sağlık verisini Claude raporuna dahil et'),
              subtitle: const Text('Kapalıyken rapora ve paketlere hiçbir sağlık verisi girmez.'),
              value: includeReport,
              onChanged: (v) async {
                await ref.read(healthRepositoryProvider).setIncludeInReport(v);
                ref.invalidate(healthIncludeInReportProvider);
              },
            ),
            const SizedBox(height: 4),
            Text(
              'Gizlilik: sağlık verisi bilgisayara kablosuz eşitlemeyle GİTMEZ. Ama yedek ZIP tüm veritabanını '
              'içerdiği için sağlık verisi YEDEĞE GİRER; yedeği paylaşırken dikkat et.'
              '${counts == null ? '' : '\nKayıtlı: ${counts.days} gün özeti, ${counts.sessions} uyku oturumu, ${counts.stress} stres ölçümü.'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('health-delete'),
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
              label: const Text('Sağlık verisini sil'),
            ),
            Text(
              'İzni geri almak için: Ayarlar > Uygulamalar > Health Connect > Uygulama izinleri > Koçum.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Origins extends ConsumerWidget {
  const _Origins();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final origins = ref.watch(healthOriginsProvider);
    return origins.when(
      loading: () => const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
      error: (e, _) => Text('Taranamadı: $e'),
      data: (list) {
        if (list.isEmpty) {
          return const Text(
            'Son 14 günde Health Connect\'te hiç kayıt görünmüyor (ya da izin yok). Saatin Huawei Sağlık ile '
            'eşleşiyorsa Huawei Sağlık Health Connect\'e yazmıyor olabilir: "Huawei verisi içe aktar (ZIP)" yolunu dene.',
            key: Key('health-origins-empty'),
          );
        }
        final huawei = list.any((o) => isHuaweiOrigin(o.packageName));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final o in list)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${originLabel(o.packageName)}: ${o.type}, ${o.count} kayıt'),
              ),
            const SizedBox(height: 6),
            Text(
              huawei
                  ? 'Huawei Sağlık Health Connect\'e yazıyor; uyku/nabız verisi otomatik gelir.'
                  : 'Listede Huawei Sağlık YOK: Huawei Sağlık Health Connect\'e yazmıyor olabilir. '
                      '"Huawei verisi içe aktar (ZIP)" yolunu dene.',
              key: Key(huawei ? 'health-origins-huawei' : 'health-origins-nohuawei'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}
