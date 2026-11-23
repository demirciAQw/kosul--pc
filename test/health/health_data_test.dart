import 'dart:io';

import 'package:drift/drift.dart' show Value;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/database/health_tables.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/ledger/ledger_triggers.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/desktop/import/domain/import_rules.dart';
import 'package:kocum/features/health/data/health_connect_source.dart';
import 'package:kocum/features/health/data/health_repository.dart';
import 'package:kocum/features/health/data/health_sync_service.dart';
import 'package:kocum/features/health/domain/health_aggregate.dart';
import 'package:kocum/features/health/domain/health_models.dart';
import 'package:kocum/features/health/domain/health_source.dart';

Future<AppDatabase> _open() async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

SleepSession _night(DateTime wake, {int hours = 7, String source = healthSourceConnect}) {
  final end = wake;
  final start = end.subtract(Duration(hours: hours));
  return SleepSession(
    start: start,
    end: end,
    source: source,
    stages: [
      SleepStageSpan(start, start.add(const Duration(hours: 2)), SleepStageKind.deep),
      SleepStageSpan(start.add(const Duration(hours: 2)), end.subtract(const Duration(minutes: 30)), SleepStageKind.light),
      SleepStageSpan(end.subtract(const Duration(minutes: 30)), end, SleepStageKind.awake),
    ],
  );
}

void main() {
  late AppDatabase db;
  late HealthRepository repo;
  final now = DateTime(2026, 11, 23, 12);

  setUp(() async {
    db = await _open();
    repo = HealthRepository(db, clock: () => now);
  });

  test('tablolar hassas: deftere, kablosuz eşitlemeye ve bilgisayara birleştirmeye girmez', () async {
    for (final t in healthTables) {
      expect(ledgerExcludedTables, contains(t));
      expect(skippedTables, contains(t));
    }
    await repo.upsertDays([HealthDay(day: '2026-11-23', source: healthSourceManual, sleepTotalMin: 400)]);
    await repo.addManualStress(3);
    await repo.upsertSessions([_night(DateTime(2026, 11, 23, 7))]);
    expect(await LedgerService(db).history(), isEmpty);
    expect(LedgerService(db).syncTables.map((t) => t.actualTableName), isNot(contains('saglik_gunluk')));
    final trg = await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%saglik%'").get();
    expect(trg, isEmpty);
  });

  test('içe aktarma tekilleştirir: aynı veri ikinci kez çift kayıt üretmez', () async {
    final s = _night(DateTime(2026, 11, 22, 7));
    final days = buildHealthDays(source: healthSourceConnect, sessions: [s]);
    for (var i = 0; i < 2; i++) {
      await repo.upsertSessions([s]);
      await repo.upsertDays(days);
      await repo.upsertStress([StressSample(time: DateTime(2026, 11, 22, 10), level: 40, max: 100, source: healthSourceHuaweiZip)]);
    }
    final c = await repo.counts();
    expect((c.days, c.sessions, c.stress), (1, 1, 1));
    // Farklı kaynak aynı gün: ayrı satır (üzerine yazılmaz).
    await repo.upsertDays([HealthDay(day: '2026-11-22', source: healthSourceHuaweiZip, sleepTotalMin: 300)]);
    expect((await repo.counts()).days, 2);
  });

  test('gün özeti: null alan eski değeri korur; stres ortalaması eklenir', () async {
    await repo.upsertDays([HealthDay(day: '2026-11-22', source: healthSourceConnect, sleepTotalMin: 420, restingHr: 55)]);
    await repo.upsertDays([HealthDay(day: '2026-11-22', source: healthSourceConnect, steps: 8000)]);
    final d = (await repo.recent(14)).single;
    expect((d.sleepTotalMin, d.restingHr, d.steps), (420, 55, 8000));
  });

  test('elle stres 1..5 -> gün özetine 0..100 ortalama', () async {
    await repo.addManualStress(1);
    await repo.addManualStress(5);
    await repo.refreshStressDays([healthSourceManual]);
    final r = await db.select(db.saglikStres).get();
    expect(r, hasLength(1)); // aynı ms: tekil (saat sabit)
    final d = (await repo.recent(14)).single;
    expect(d.source, healthSourceManual);
    expect(d.stressAvg, 100); // son değer (5/5)
  });

  test('uyku oturumu aşamaları JSON olarak gidip gelir', () async {
    await repo.upsertSessions([_night(DateTime(2026, 11, 22, 7))]);
    final back = (await repo.sessionsSince(DateTime(2026, 11, 1))).single;
    expect(back.deepMinutes, 120);
    expect(back.awakeMinutes, 30);
    expect(back.totalMinutes, 7 * 60 - 30);
  });

  test('"Sağlık verisini sil": üç tablo ve tercihler gider, başka veri kalır', () async {
    await db.customStatement("INSERT INTO app_meta (meta_key, meta_value) VALUES ('baska', '1')");
    await repo.upsertSessions([_night(DateTime(2026, 11, 22, 7))]);
    await repo.upsertDays([HealthDay(day: '2026-11-22', source: healthSourceConnect, sleepTotalMin: 420)]);
    await repo.addManualStress(2);
    await repo.setSleepChoice('2026-11-22', 'saat');
    expect(await repo.deleteAll(), 3);
    final c = await repo.counts();
    expect((c.days, c.sessions, c.stress), (0, 0, 0));
    expect(await repo.sleepChoice('2026-11-22'), isNull);
    expect((await db.customSelect("SELECT meta_value FROM app_meta WHERE meta_key = 'baska'").get()), hasLength(1));
  });

  test('Claude raporu ayarı varsayılan kapalı; açılınca özet çıkar', () async {
    expect(await repo.includeInReport(), isFalse);
    await repo.setIncludeInReport(true);
    expect(await repo.includeInReport(), isTrue);
    final md = healthReportSection([
      const HealthDay(day: '2026-11-22', source: 'x', sleepTotalMin: 432, sleepDeepMin: 90, restingHr: 54, stressAvg: 41.6),
    ])!;
    expect(md, contains('| 2026-11-22 | 7s 12dk | 1s 30dk | 54 | 42 |'));
    expect(healthReportSection(const []), isNull);
  });

  group('HealthSyncService (FakeHealthSource)', () {
    test('izin yoksa hiçbir şey yazılmaz; izinle gün özeti yazılır; tekrar çift yapmaz', () async {
      final src = FakeHealthSource(
        sleep: [_night(DateTime(2026, 11, 22, 7))],
        vitals: const [DailyVitals(day: '2026-11-22', restingHr: 56, hrv: 41.2, steps: 9001)],
      );
      final svc = HealthSyncService(src, repo, clock: () => now);
      expect(await svc.sync(), 0);
      expect((await repo.counts()).days, 0);
      await src.requestPermissions();
      expect(src.permissionRequests, 1);
      expect(await svc.sync(), 1);
      expect(await svc.sync(), 1);
      final c = await repo.counts();
      expect((c.days, c.sessions), (1, 1));
      final d = (await repo.recent(14)).single;
      expect((d.sleepTotalMin, d.sleepDeepMin, d.restingHr, d.steps), (390, 120, 56, 9001));
      expect(d.source, healthSourceConnect);
    });

    test('Health Connect yoksa ya da masaüstünde: boş', () async {
      final svc = HealthSyncService(FakeHealthSource(availability: HealthAvailability.needsInstall), repo, clock: () => now);
      expect(await svc.sync(), 0);
      const u = UnsupportedHealthSource();
      expect((await u.status()).availability, HealthAvailability.unsupported);
      expect(await u.readSleep(now, now), isEmpty);
      expect(await u.originSummary(14), isEmpty);
    });
  });

  group('toplama', () {
    test('aynı güne düşen gece + şekerleme toplanır, saat en uzundan', () {
      final nap = _night(DateTime(2026, 11, 22, 15), hours: 1);
      final night = _night(DateTime(2026, 11, 22, 7));
      final d = buildHealthDays(source: 'x', sessions: [nap, night]).single;
      expect(d.sleepStart, night.start.millisecondsSinceEpoch);
      expect(d.sleepTotalMin, greaterThan(390));
    });

    test('günlük ölçümler: dinlenme nabzı/HRV ortalama, adım toplam', () {
      final t = DateTime(2026, 11, 22, 8).millisecondsSinceEpoch;
      final v = groupDailyVitals(resting: [(t, 50), (t + 1000, 60)], hrv: [(t, 40)], steps: [(t, 1000), (t + 5, 500)]).single;
      expect((v.restingHr, v.hrv, v.steps), (55, 40.0, 1500));
    });

    test('Bugün özeti metni ve çakışma tespiti', () {
      final d = buildHealthDays(source: 'x', sessions: [_night(DateTime(2026, 11, 23, 7), hours: 8)]).single;
      expect(lastNightSummary(d), 'Dün gece (saatten): 7s 30dk, derin 2s');
      expect(lastNightSummary(null), isNull);
      // Elle kayıt saatle aynı: çakışma yok; 2 saat farklı: çakışma.
      final same = (bed: DateTime(2026, 11, 22, 23), wake: DateTime(2026, 11, 23, 7));
      expect(findSleepConflicts(manual: [same], days: [d]), isEmpty);
      final diff = (bed: DateTime(2026, 11, 23, 1), wake: DateTime(2026, 11, 23, 7));
      expect(findSleepConflicts(manual: [diff], days: [d]), hasLength(1));
      // Ayrı bir gece: örtüşmez, çakışma sayılmaz.
      final other = (bed: DateTime(2026, 11, 21, 23), wake: DateTime(2026, 11, 22, 6));
      expect(findSleepConflicts(manual: [other], days: [d]), isEmpty);
    });
  });

  group('göç', () {
    Future<void> migrate(int from) async {
      final dir = await Directory.systemTemp.createTemp('saglik_goc');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/k.sqlite');
      var d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      await d.into(d.anlikNotes).insert(AnlikNotesCompanion.insert(
          id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));
      for (final t in healthTables) {
        await d.customStatement('DROP TABLE $t');
      }
      if (from < 21) {
        for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%ink_page_text%'").get()) {
          await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
        }
        await d.customStatement('DROP TABLE ink_page_text');
      }
      await d.customStatement('DROP INDEX IF EXISTS ix_saglik_gunluk_gun');
      await d.customStatement('PRAGMA user_version = $from');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      addTearDown(d.close);
      final names = {for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
      expect(names, containsAll([...healthTables, 'ink_page_text', 'anlik_notes']));
      expect((await d.select(d.anlikNotes).getSingle()).body, 'eski not');
      expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 23);
      expect(await d.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_saglik_gunluk_gun'").get(), hasLength(1));
      final r = HealthRepository(d);
      await r.addManualStress(4);
      expect((await r.counts()).stress, 1);
      expect(await LedgerService(d).history(), isNot(contains(predicate((c) => (c as dynamic).table == 'saglik_stres'))));
    }

    test('v14 -> v22', () => migrate(14));
    test('v20 -> v22', () => migrate(20));
    test('v21 -> v22', () => migrate(21));
  });

  test('bilgisayara birleştirmede sağlık tabloları alınmaz', () async {
    final dir = await Directory.systemTemp.createTemp('saglik_bil');
    addTearDown(() => dir.delete(recursive: true));
    final phoneFile = File('${dir.path}/tel.db');
    final phone = AppDatabase(NativeDatabase(phoneFile));
    await phone.customSelect('SELECT 1').get();
    await HealthRepository(phone, clock: () => now).addManualStress(5);
    await phone.close();
    final pc = await _open();
    final res = await SnapshotMerger(pc).merge(phoneFile);
    expect(res.any((t) => healthTables.contains(t.table)), isFalse);
    expect((await HealthRepository(pc).counts()).stress, 0);
  });
}
