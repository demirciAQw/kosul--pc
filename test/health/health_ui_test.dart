import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/database/health_tables.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/export/zip_writer.dart';
import 'package:kocum/features/anlik/domain/anlik.dart';
import 'package:kocum/features/anlik/presentation/sleep_card.dart';
import 'package:kocum/features/health/data/health_repository.dart';
import 'package:kocum/features/health/data/huawei_import_service.dart';
import 'package:kocum/features/health/domain/health_models.dart';
import 'package:kocum/features/health/domain/health_source.dart';
import 'package:kocum/features/health/domain/huawei_zip_parser.dart';
import 'package:kocum/features/health/health_providers.dart';
import 'package:kocum/features/health/presentation/health_screen.dart';
import 'package:kocum/features/health/presentation/health_settings_card.dart';
import 'package:kocum/features/health/presentation/stress_card.dart';

final _now = DateTime(2026, 11, 23, 9);

Future<(AppDatabase, ProviderContainer, FakeHealthSource)> _setup(WidgetTester tester, {FakeHealthSource? src}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final fake = src ?? FakeHealthSource();
  final c = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    clockProvider.overrideWithValue(() => _now),
    healthSourceProvider.overrideWithValue(fake),
    healthVisibleProvider.overrideWithValue(true),
  ]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.runAsync(db.close);
  });
  return (db, c, fake);
}

Widget _app(ProviderContainer c, Widget w) =>
    UncontrolledProviderScope(container: c, child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: w))));

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump();
  }
}

void main() {
  group('Ayarlar kartı (kaynak tanısı)', () {
    testWidgets('Health Connect yok: durum açıkça yazılır, düğme çıkmaz', (t) async {
      final (_, c, _) = await _setup(t, src: FakeHealthSource(availability: HealthAvailability.needsInstall));
      await t.pumpWidget(_app(c, const HealthSettingsCard()));
      await _settle(t);
      expect(find.textContaining('Health Connect yok'), findsOneWidget);
      expect(find.byKey(const Key('health-grant')), findsNothing);
      // Yedek ve gizlilik uyarısı, silme ve rapor anahtarı var.
      expect(find.textContaining('YEDEĞE GİRER', findRichText: true), findsOneWidget);
      expect(find.byKey(const Key('health-delete')), findsOneWidget);
      expect(find.byKey(const Key('health-report-switch')), findsOneWidget);
    });

    testWidgets('İzin ver -> izinler gelir; rapor anahtarı varsayılan KAPALI ve kalıcı', (t) async {
      final (db, c, fake) = await _setup(t, src: FakeHealthSource());
      await t.pumpWidget(_app(c, const HealthSettingsCard()));
      await _settle(t);
      expect(find.textContaining('izin verilmedi'), findsOneWidget);
      expect(_switchValue(t), isFalse);
      await t.tap(find.byKey(const Key('health-grant')));
      await _settle(t);
      expect(fake.permissionRequests, 1);
      expect(find.textContaining('tüm izinler verildi'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('health-report-switch')));
      await t.tap(find.byKey(const Key('health-report-switch')));
      await _settle(t);
      expect(_switchValue(t), isTrue);
      expect(await HealthRepository(db).includeInReport(), isTrue);
    });

    testWidgets('Kaynak listesi: com.huawei.health görünürse Huawei yazıyor denir', (t) async {
      final (_, c, _) = await _setup(
        t,
        src: FakeHealthSource(granted: {HealthDataType.sleep}, origins: const [
          OriginCount(type: 'Uyku', packageName: 'com.huawei.health', count: 12),
          OriginCount(type: 'Adım', packageName: 'com.google.android.apps.fitness', count: 300),
        ]),
      );
      await t.pumpWidget(_app(c, const HealthSettingsCard()));
      await _settle(t);
      await t.ensureVisible(find.byKey(const Key('health-origins-btn')));
      await t.tap(find.byKey(const Key('health-origins-btn')));
      await _settle(t);
      expect(find.textContaining('Huawei Sağlık (com.huawei.health): Uyku, 12 kayıt'), findsOneWidget);
      expect(find.byKey(const Key('health-origins-huawei')), findsOneWidget);
    });

    testWidgets('Kaynak listesinde Huawei yoksa ZIP yolu önerilir; boşsa açıklama', (t) async {
      final (_, c, _) = await _setup(
        t,
        src: FakeHealthSource(granted: {HealthDataType.steps}, origins: const [
          OriginCount(type: 'Adım', packageName: 'com.google.android.apps.fitness', count: 5),
        ]),
      );
      await t.pumpWidget(_app(c, const HealthSettingsCard()));
      await _settle(t);
      await t.ensureVisible(find.byKey(const Key('health-origins-btn')));
      await t.tap(find.byKey(const Key('health-origins-btn')));
      await _settle(t);
      expect(find.byKey(const Key('health-origins-nohuawei')), findsOneWidget);
      expect(find.textContaining('Huawei Sağlık Health Connect\'e yazmıyor olabilir', findRichText: true), findsOneWidget);
    });

    testWidgets('"Sağlık verisini sil" onay ister ve üç tabloyu boşaltır', (t) async {
      final (db, c, _) = await _setup(t);
      final repo = HealthRepository(db);
      await t.runAsync(() async {
        await repo.addManualStress(3);
        await repo.upsertDays([const HealthDay(day: '2026-11-22', source: healthSourceManual, sleepTotalMin: 300)]);
      });
      await t.pumpWidget(_app(c, const HealthSettingsCard()));
      await _settle(t);
      await t.ensureVisible(find.byKey(const Key('health-delete')));
      await t.tap(find.byKey(const Key('health-delete')));
      await t.pumpAndSettle();
      await t.tap(find.text('Vazgeç'));
      await t.pumpAndSettle();
      expect((await t.runAsync(repo.counts))!.stress, 1);
      await t.tap(find.byKey(const Key('health-delete')));
      await t.pumpAndSettle();
      await t.tap(find.text('Sil'));
      await _settle(t);
      final n = (await t.runAsync(repo.counts))!;
      expect((n.days, n.stress, n.sessions), (0, 0, 0));
    });
  });

  testWidgets('Hızlı stres kartı: 1-5 dokunuşu manuel kayıt yazar', (t) async {
    final (db, c, _) = await _setup(t);
    await t.pumpWidget(_app(c, const StressCard()));
    await t.tap(find.byKey(const ValueKey('stres-4')));
    await _settle(t);
    final r = await t.runAsync(() => db.select(db.saglikStres).get());
    expect(r!.single.seviye, 4);
    expect(r.single.seviyeMaks, 5);
    expect(r.single.kaynak, healthSourceManual);
    expect(find.textContaining('Kaydedildi: 4/5'), findsOneWidget);
    final days = await t.runAsync(() => db.select(db.saglikGunluk).get());
    expect(days!.single.stresOrtalama, 80);
  });

  group('Bugün: uyku kartı', () {
    HealthDay day() => HealthDay(
          day: '2026-11-23',
          source: healthSourceConnect,
          sleepTotalMin: 432,
          sleepDeepMin: 90,
          sleepStart: DateTime(2026, 11, 22, 23, 48).millisecondsSinceEpoch,
          sleepEnd: DateTime(2026, 11, 23, 7, 0).millisecondsSinceEpoch,
        );

    testWidgets('veri varsa "Dün gece (saatten)" özeti; yoksa görünmez', (t) async {
      final (db, c, _) = await _setup(t);
      await t.pumpWidget(_app(c, const SleepCard()));
      await _settle(t);
      expect(find.byKey(const Key('uyku-saat-ozet')), findsNothing);
      await t.runAsync(() => HealthRepository(db).upsertDays([day()]));
      await _settle(t);
      expect(find.text('Dün gece (saatten): 7s 12dk, derin 1s 30dk'), findsOneWidget);
    });

    testWidgets('elle kayıtla çakışma: sorar, seçimi saklar, hiçbir not silinmez/değişmez', (t) async {
      final (db, c, _) = await _setup(t);
      await t.runAsync(() async {
        await HealthRepository(db).upsertDays([day()]);
        // Elle: 01:00 yattım, 07:00 kalktım (saatle 1 saat fark).
        for (final (kind, at) in [(AnlikKind.yattim, DateTime(2026, 11, 23, 1)), (AnlikKind.kalktim, DateTime(2026, 11, 23, 7))]) {
          await db.into(db.anlikNotes).insert(AnlikNotesCompanion.insert(
                id: kind.key,
                createdAt: at,
                updatedAt: at,
                body: '',
                kind: Value(kind.key),
              ));
        }
      });
      await t.pumpWidget(_app(c, const SleepCard()));
      await _settle(t);
      expect(find.byKey(const Key('uyku-cakisma')), findsOneWidget);
      await t.tap(find.byKey(const Key('uyku-elle')));
      await _settle(t);
      expect(find.byKey(const Key('uyku-cakisma')), findsNothing);
      expect(find.byKey(const Key('uyku-saat-ozet')), findsNothing); // elle seçildi
      expect(await t.runAsync(() => HealthRepository(db).sleepChoice('2026-11-23')), 'elle');
      expect(await t.runAsync(() => db.select(db.anlikNotes).get()), hasLength(2));
      expect((await t.runAsync(() => HealthRepository(db).counts()))!.days, 1); // saat verisi de silinmedi
    });
  });

  testWidgets('Sağlık ekranı: boşken açıklama; veriyle uyku, nabız, stres ve kaynak rozeti', (t) async {
    final (db, c, _) = await _setup(t);
    await t.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: HealthScreen())));
    await _settle(t);
    expect(find.byKey(const Key('health-empty')), findsOneWidget);
    await t.runAsync(() => HealthRepository(db, clock: () => _now).upsertDays([
          const HealthDay(
            day: '2026-11-22',
            source: healthSourceHuaweiZip,
            sleepTotalMin: 420,
            sleepDeepMin: 80,
            sleepLightMin: 280,
            sleepRemMin: 60,
            restingHr: 54,
            stressAvg: 37.4,
          ),
        ]));
    await _settle(t);
    expect(find.text('2026-11-22'), findsOneWidget);
    expect(find.text('Huawei ZIP'), findsOneWidget);
    expect(find.textContaining('Uyku: 7s'), findsOneWidget);
    expect(find.textContaining('Dinlenme nabzı: 54'), findsOneWidget);
    expect(find.textContaining('Stres: 37/100'), findsOneWidget);
    expect(find.byKey(const Key('sleep-bar')), findsOneWidget);
  });

  group('Huawei ZIP içe aktarma (servis)', () {
    test('ZIP okunur (JSON metin, XLSX atlanır), yapı raporu + içe aktarma idempotent', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = HealthRepository(db);
      final svc = HuaweiImportService(repo);
      final dir = await Directory.systemTemp.createTemp('hz');
      addTearDown(() => dir.delete(recursive: true));
      final json = jsonEncode({
        'sleep': [
          {
            'startTime': DateTime(2026, 11, 20, 23, 30).millisecondsSinceEpoch,
            'endTime': DateTime(2026, 11, 21, 7).millisecondsSinceEpoch,
            'deepSleepMinutes': 90,
          }
        ],
        'stress': [
          {'timestamp': DateTime(2026, 11, 21, 10).millisecondsSinceEpoch, 'stress': 45}
        ],
      });
      final zip = ZipWriter()
        ..addText('Ay_2026_11/data.json', json)
        ..add('aciklama.xlsx', [1, 2, 3, 4])
        ..add('../kacak.json', utf8.encode('{}'));
      final file = File('${dir.path}/h.zip')..writeAsBytesSync(zip.finish());
      final files = await svc.readZip(file);
      expect(files.map((f) => f.name), ['Ay_2026_11/data.json', 'aciklama.xlsx']);
      expect(files.last.text, isNull);
      final r = parseHuaweiFiles(files);
      expect(r.sleep, hasLength(1));
      expect(r.stress, hasLength(1));
      expect(structureReportText(describeHuaweiStructure(files)), contains('sleep[].startTime'));
      await svc.import(r);
      await svc.import(r);
      final c = await repo.counts();
      expect((c.days, c.sessions, c.stress), (1, 1, 1));
      final d = (await db.select(db.saglikGunluk).getSingle());
      expect(d.kaynak, healthSourceHuaweiZip);
      expect(d.gun, '2026-11-21');
      expect(d.stresOrtalama, 45);
    });

    test('klasörden okuma', () async {
      final dir = await Directory.systemTemp.createTemp('hk');
      addTearDown(() => dir.delete(recursive: true));
      Directory('${dir.path}/a').createSync();
      File('${dir.path}/a/uyku.csv').writeAsStringSync('date,sleepMinutes\n2026-11-20,420\n');
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final files = await HuaweiImportService(HealthRepository(db)).readFolder(dir);
      expect(files.single.name, 'a/uyku.csv');
      expect(parseHuaweiFiles(files).days.single.sleepTotalMin, 420);
    });
  });
}

bool _switchValue(WidgetTester t) => t.widget<SwitchListTile>(find.byKey(const Key('health-report-switch'))).value;
