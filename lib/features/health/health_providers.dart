import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../core/database/health_tables.dart';
import '../../core/di/core_providers.dart';
import '../anlik/anlik_providers.dart';
import '../anlik/domain/anlik_search.dart';
import 'data/health_connect_source.dart';
import 'data/health_repository.dart';
import 'data/health_sync_service.dart';
import 'data/huawei_import_service.dart';
import 'domain/health_aggregate.dart';
import 'domain/health_models.dart';
import 'domain/health_source.dart';

/// Android'de Health Connect; masaüstünde desteklenmez (sağlık verisi gizli).
final healthSourceProvider = Provider<HealthSource>(
  (ref) => isAndroid ? HealthConnectSource() : const UnsupportedHealthSource(),
);

/// Bu cihazda sağlık özellikleri gösterilsin mi (masaüstünde hayır).
final healthVisibleProvider = Provider<bool>((ref) => isAndroid);

final healthRepositoryProvider =
    Provider((ref) => HealthRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

final healthSyncServiceProvider = Provider((ref) =>
    HealthSyncService(ref.watch(healthSourceProvider), ref.watch(healthRepositoryProvider), clock: ref.watch(clockProvider)));

final huaweiImportServiceProvider = Provider((ref) => HuaweiImportService(ref.watch(healthRepositoryProvider)));

/// Durum (Health Connect var/yok, izin). Yenilemek için `ref.invalidate`.
final healthStatusProvider = FutureProvider.autoDispose<HealthStatus>((ref) => ref.watch(healthSourceProvider).status());

/// Son 14 günde hangi uygulamalardan veri geldi (yavaş olabilir: yalnız istenince).
final healthOriginsProvider =
    FutureProvider.autoDispose<List<OriginCount>>((ref) => ref.watch(healthSourceProvider).originSummary(14));

final healthRecentProvider =
    StreamProvider.autoDispose<List<HealthDay>>((ref) => ref.watch(healthRepositoryProvider).watchRecent(14));

final healthCountsProvider = FutureProvider.autoDispose<({int days, int stress, int sessions})>((ref) {
  ref.watch(healthRecentProvider);
  return ref.watch(healthRepositoryProvider).counts();
});

final healthIncludeInReportProvider =
    FutureProvider.autoDispose<bool>((ref) => ref.watch(healthRepositoryProvider).includeInReport());

/// Claude raporuna eklenecek küçük sağlık özeti (ayar KAPALIYSA ya da veri yoksa null).
final healthReportSectionProvider = FutureProvider.autoDispose<String?>((ref) async {
  final repo = ref.watch(healthRepositoryProvider);
  if (!await repo.includeInReport()) return null;
  return healthReportSection(await repo.recent(14));
});

/// Uyku kartı için: bugün (uyanılan gün) saatten gelen uyku özeti ve elle kayıtla çakışma.
class LastNightState {
  const LastNightState({this.day, this.conflict, this.choice});
  final HealthDay? day;
  final SleepConflict? conflict;

  /// 'saat' | 'elle' | null
  final String? choice;

  /// Özet gösterilsin mi: veri var ve kullanıcı "elle"yi seçmedi.
  bool get showWatch => day != null && choice != 'elle';
  bool get needsChoice => conflict != null && choice == null;
}

final lastNightProvider = Provider.autoDispose<AsyncValue<LastNightState>>((ref) {
  final recent = ref.watch(healthRecentProvider);
  final notes = ref.watch(anlikNotesProvider).value;
  final now = ref.watch(clockProvider)();
  return recent.whenData((days) {
    final today = dayKey(now), yesterday = dayKey(now.subtract(const Duration(days: 1)));
    final cand = [for (final d in days) if ((d.day == today || d.day == yesterday) && (d.sleepTotalMin ?? 0) > 0) d];
    if (cand.isEmpty) return const LastNightState();
    // En yeni gün; aynı günde Health Connect > Huawei ZIP.
    cand.sort((a, b) {
      final c = b.day.compareTo(a.day);
      if (c != 0) return c;
      int rank(HealthDay d) => d.source == healthSourceConnect ? 0 : 1;
      return rank(a).compareTo(rank(b));
    });
    final d = cand.first;
    final manual = [
      for (final n in sleepNights(notes ?? const []))
        if (n.wake != null) (bed: n.bed, wake: n.wake!),
    ];
    final conflicts = findSleepConflicts(manual: manual, days: [d]);
    return LastNightState(
      day: d,
      conflict: conflicts.firstOrNull,
      choice: ref.watch(sleepChoiceProvider(d.day)).value,
    );
  });
});

/// Çakışma tercihi (ayrı okunur: kullanıcı seçince yenilenir).
final sleepChoiceProvider = FutureProvider.autoDispose.family<String?, String>(
    (ref, day) => ref.watch(healthRepositoryProvider).sleepChoice(day));
