import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/health_tables.dart';
import '../../../core/utils/id_generator.dart';
import '../domain/health_models.dart';

/// Sağlık verisi (saglik_* tabloları). Hassas: deftere ve eşitlemeye girmez.
/// İçe aktarmalar tekilleştirir: aynı kaynak + aynı gün/başlangıç/zaman ikinci
/// kez gelirse yeni satır eklenmez, var olan güncellenir.
class HealthRepository {
  HealthRepository(this._db, {Clock? clock, IdGenerator? ids})
      : _clock = clock ?? DateTime.now,
        _ids = ids ?? const UuidV7Generator();
  final AppDatabase _db;
  final Clock _clock;
  final IdGenerator _ids;

  /// Gün özetlerini kaydeder; null alanlar eski değeri korur. Eklenen+güncellenen sayısı döner.
  Future<int> upsertDays(List<HealthDay> days) => _db.transaction(() async {
        var n = 0;
        final now = _clock();
        for (final d in days) {
          final ex = await (_db.select(_db.saglikGunluk)
                ..where((r) => r.gun.equals(d.day) & r.kaynak.equals(d.source)))
              .getSingleOrNull();
          if (ex == null) {
            await _db.into(_db.saglikGunluk).insert(SaglikGunlukCompanion.insert(
                  id: _ids.next(),
                  gun: d.day,
                  kaynak: d.source,
                  createdAt: now,
                  updatedAt: now,
                  uykuToplamDk: Value(d.sleepTotalMin),
                  uykuDerinDk: Value(d.sleepDeepMin),
                  uykuHafifDk: Value(d.sleepLightMin),
                  uykuRemDk: Value(d.sleepRemMin),
                  uykuUyanikDk: Value(d.sleepAwakeMin),
                  uykuBaslangic: Value(d.sleepStart),
                  uykuBitis: Value(d.sleepEnd),
                  dinlenmeNabzi: Value(d.restingHr),
                  ortalamaHrv: Value(d.hrv),
                  adim: Value(d.steps),
                  stresOrtalama: Value(d.stressAvg),
                  stresMaks: Value(d.stressMax),
                ));
          } else {
            Value<T> keep<T extends Object>(T? nv) => nv == null ? const Value.absent() : Value(nv);
            await (_db.update(_db.saglikGunluk)..where((r) => r.id.equals(ex.id))).write(SaglikGunlukCompanion(
              uykuToplamDk: keep(d.sleepTotalMin),
              uykuDerinDk: keep(d.sleepDeepMin),
              uykuHafifDk: keep(d.sleepLightMin),
              uykuRemDk: keep(d.sleepRemMin),
              uykuUyanikDk: keep(d.sleepAwakeMin),
              uykuBaslangic: keep(d.sleepStart),
              uykuBitis: keep(d.sleepEnd),
              dinlenmeNabzi: keep(d.restingHr),
              ortalamaHrv: keep(d.hrv),
              adim: keep(d.steps),
              stresOrtalama: keep(d.stressAvg),
              stresMaks: keep(d.stressMax),
              updatedAt: Value(now),
            ));
          }
          n++;
        }
        return n;
      });

  Future<void> upsertSessions(List<SleepSession> sessions) => _db.transaction(() async {
        for (final s in sessions) {
          final start = s.start.millisecondsSinceEpoch;
          final json = jsonEncode([for (final st in s.stages) st.toJson()]);
          final ex = await (_db.select(_db.saglikUykuOturum)
                ..where((r) => r.baslangic.equals(start) & r.kaynak.equals(s.source)))
              .getSingleOrNull();
          if (ex == null) {
            await _db.into(_db.saglikUykuOturum).insert(SaglikUykuOturumCompanion.insert(
                  id: _ids.next(),
                  baslangic: start,
                  bitis: s.end.millisecondsSinceEpoch,
                  kaynak: s.source,
                  asamaJson: Value(json),
                ));
          } else {
            await (_db.update(_db.saglikUykuOturum)..where((r) => r.id.equals(ex.id)))
                .write(SaglikUykuOturumCompanion(bitis: Value(s.end.millisecondsSinceEpoch), asamaJson: Value(json)));
          }
        }
      });

  Future<void> upsertStress(List<StressSample> samples) => _db.transaction(() async {
        for (final s in samples) {
          final t = s.time.millisecondsSinceEpoch;
          final ex = await (_db.select(_db.saglikStres)..where((r) => r.zaman.equals(t) & r.kaynak.equals(s.source)))
              .getSingleOrNull();
          if (ex == null) {
            await _db.into(_db.saglikStres).insert(SaglikStresCompanion.insert(
                  id: _ids.next(),
                  zaman: t,
                  seviye: s.level,
                  seviyeMaks: Value(s.max),
                  kaynak: s.source,
                ));
          } else {
            await (_db.update(_db.saglikStres)..where((r) => r.id.equals(ex.id)))
                .write(SaglikStresCompanion(seviye: Value(s.level), seviyeMaks: Value(s.max)));
          }
        }
      });

  /// Elle stres (1..5) şimdiki zamanla.
  Future<void> addManualStress(int level) {
    assert(level >= 1 && level <= 5);
    return upsertStress([StressSample(time: _clock(), level: level.toDouble(), max: 5, source: healthSourceManual)]);
  }

  /// Stres örneklerini günlük ortalama/en yüksek olarak 'gunluk'a yazar (kaynak başına).
  Future<void> refreshStressDays(Iterable<String> sources) async {
    final all = await (_db.select(_db.saglikStres)..where((r) => r.kaynak.isIn(sources.toList()))).get();
    final by = <(String, String), List<double>>{};
    for (final r in all) {
      final p = (r.seviye / r.seviyeMaks * 100).clamp(0, 100).toDouble();
      (by[(dayKey(DateTime.fromMillisecondsSinceEpoch(r.zaman)), r.kaynak)] ??= []).add(p);
    }
    await upsertDays([
      for (final e in by.entries)
        HealthDay(
          day: e.key.$1,
          source: e.key.$2,
          stressAvg: e.value.reduce((a, b) => a + b) / e.value.length,
          stressMax: e.value.reduce((a, b) => a > b ? a : b),
        ),
    ]);
  }

  HealthDay _toDay(SaglikGunlukRow r) => HealthDay(
        day: r.gun,
        source: r.kaynak,
        sleepTotalMin: r.uykuToplamDk,
        sleepDeepMin: r.uykuDerinDk,
        sleepLightMin: r.uykuHafifDk,
        sleepRemMin: r.uykuRemDk,
        sleepAwakeMin: r.uykuUyanikDk,
        sleepStart: r.uykuBaslangic,
        sleepEnd: r.uykuBitis,
        restingHr: r.dinlenmeNabzi,
        hrv: r.ortalamaHrv,
        steps: r.adim,
        stressAvg: r.stresOrtalama,
        stressMax: r.stresMaks,
      );

  /// Son [days] günün özetleri (eskiden yeniye). Aynı güne birden çok kaynak düşebilir.
  Stream<List<HealthDay>> watchRecent(int days) {
    final from = dayKey(_clock().subtract(Duration(days: days - 1)));
    final q = _db.select(_db.saglikGunluk)
      ..where((r) => r.gun.isBiggerOrEqualValue(from))
      ..orderBy([(r) => OrderingTerm.asc(r.gun), (r) => OrderingTerm.asc(r.kaynak)]);
    return q.watch().map((l) => [for (final r in l) _toDay(r)]);
  }

  Future<List<HealthDay>> recent(int days) => watchRecent(days).first;

  /// Satır sayıları (gunluk, stres, oturum).
  Future<({int days, int stress, int sessions})> counts() async {
    Future<int> c(String t) async => (await _db.customSelect('SELECT COUNT(*) AS n FROM $t').getSingle()).read<int>('n');
    return (days: await c('saglik_gunluk'), stress: await c('saglik_stres'), sessions: await c('saglik_uyku_oturum'));
  }

  /// Üç tabloyu da siler; silinen satır sayısı döner. İzin geri alma ayrıca kullanıcıdadır.
  Future<int> deleteAll() => _db.transaction(() async {
        var n = 0;
        n += await _db.delete(_db.saglikGunluk).go();
        n += await _db.delete(_db.saglikStres).go();
        n += await _db.delete(_db.saglikUykuOturum).go();
        // Çakışma tercihleri de sağlık verisine aittir.
        await _db.customStatement("DELETE FROM app_meta WHERE meta_key LIKE 'saglik.uyku_tercih.%'");
        return n;
      });

  /// Hangi uyku oturumları kayıtlı (görünüm için, aşamalarla).
  Future<List<SleepSession>> sessionsSince(DateTime from) async {
    final rows = await (_db.select(_db.saglikUykuOturum)
          ..where((r) => r.bitis.isBiggerOrEqualValue(from.millisecondsSinceEpoch))
          ..orderBy([(r) => OrderingTerm.asc(r.baslangic)]))
        .get();
    return [
      for (final r in rows)
        SleepSession(
          start: DateTime.fromMillisecondsSinceEpoch(r.baslangic),
          end: DateTime.fromMillisecondsSinceEpoch(r.bitis),
          source: r.kaynak,
          stages: _stages(r.asamaJson),
        ),
    ];
  }

  List<SleepStageSpan> _stages(String json) {
    try {
      final v = jsonDecode(json);
      if (v is! List) return const [];
      return [for (final e in v) SleepStageSpan.fromJson(e)].whereType<SleepStageSpan>().toList();
    } catch (_) {
      return const [];
    }
  }

  // ── Ayarlar (app_meta; cihaza özel) ──

  static const _reportKey = 'saglik.rapora_dahil';
  static const _prefPrefix = 'saglik.uyku_tercih.';

  Future<String?> _meta(String key) async =>
      (await (_db.select(_db.appMeta)..where((m) => m.metaKey.equals(key))).getSingleOrNull())?.metaValue;

  Future<void> _setMeta(String key, String value) =>
      _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: key, metaValue: value));

  Future<bool> includeInReport() async => (await _meta(_reportKey)) == '1';
  Future<void> setIncludeInReport(bool v) => _setMeta(_reportKey, v ? '1' : '0');

  /// 'saat' | 'elle' | null (sorulmadı).
  Future<String?> sleepChoice(String day) => _meta('$_prefPrefix$day');
  Future<void> setSleepChoice(String day, String choice) => _setMeta('$_prefPrefix$day', choice);
}
