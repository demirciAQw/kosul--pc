import '../../../core/database/health_tables.dart';
import '../domain/health_aggregate.dart';
import '../domain/health_models.dart';
import '../domain/health_source.dart';
import 'health_repository.dart';

/// Health Connect'ten son [days] günü okuyup veritabanına (tekilleştirerek) yazar.
class HealthSyncService {
  HealthSyncService(this._source, this._repo, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final HealthSource _source;
  final HealthRepository _repo;
  final DateTime Function() _clock;

  /// Yazılan gün sayısı döner; izin/erişim yoksa 0.
  Future<int> sync({int days = 14}) async {
    final st = await _source.status();
    if (!st.usable || !st.anyGranted) return 0;
    final to = _clock();
    final from = DateTime(to.year, to.month, to.day).subtract(Duration(days: days - 1));
    final sleep = st.granted.contains(HealthDataType.sleep) ? await _source.readSleep(from, to) : const <SleepSession>[];
    final vitals = await _source.readDailyVitals(from, to);
    final byDay = buildHealthDays(source: healthSourceConnect, sessions: sleep, vitals: vitals);
    await _repo.upsertSessions(sleep);
    return _repo.upsertDays(byDay);
  }
}
