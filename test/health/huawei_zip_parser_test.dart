import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/health/domain/health_models.dart';
import 'package:kocum/features/health/domain/huawei_zip_parser.dart';

HuaweiFile f(String name, String text) => HuaweiFile(name, text.length, text);

// Gerçek Huawei şeması BİLİNMİYOR: hepsi SENTETİK, olası düzenler.
void main() {
  final start = DateTime(2026, 11, 20, 23, 30);
  final end = DateTime(2026, 11, 21, 7, 0);

  test('düzen 1: ms zaman damgalı oturum, dakika birimli aşamalar', () {
    final json = jsonEncode({
      'sleepRecords': [
        {
          'startTime': start.millisecondsSinceEpoch,
          'endTime': end.millisecondsSinceEpoch,
          'deepSleepMinutes': 90,
          'lightSleepMinutes': 250,
          'remMinutes': 80,
          'awakeMinutes': 30,
        }
      ]
    });
    final r = parseHuaweiFiles([f('sleep_data.json', json)]);
    expect(r.sleep, hasLength(1));
    final s = r.sleep.single;
    expect(s.start, start);
    expect(s.end, end);
    expect(s.deepMinutes, 90);
    expect(s.lightMinutes, 250);
    expect(s.remMinutes, 80);
    expect(s.awakeMinutes, 30);
    expect(s.day, '2026-11-21');
  });

  test('düzen 2: saniye zaman damgası, saniye birimli süre, iç içe ve JSON dizesi', () {
    final inner = jsonEncode([
      {
        'begin_time': start.millisecondsSinceEpoch ~/ 1000,
        'wake_up_time': end.millisecondsSinceEpoch ~/ 1000,
        'deep_sleep_sec': 5400,
        'light_sleep_sec': 15000,
      }
    ]);
    final json = jsonEncode({'data': {'sleep': inner}});
    final r = parseHuaweiFiles([f('x/uyku.json', json)]);
    expect(r.sleep, hasLength(1));
    expect(r.sleep.single.deepMinutes, 90);
    expect(r.sleep.single.lightMinutes, 250);
  });

  test('düzen 3: ISO tarih + birimsiz toplam (aralıkla uyumlu birim seçilir)', () {
    final json = jsonEncode([
      {
        'startTime': '2026-11-20T23:30:00',
        'endTime': '2026-11-21T07:00:00',
        'sleepDuration': 26400, // saniye (7s 20dk): dakika olamaz
      }
    ]);
    final r = parseHuaweiFiles([f('sleep.json', json)]);
    expect(r.sleep.single.totalMinutes, 440);
  });

  test('düzen 4: CSV, noktalı virgül, gün + toplam (saatsiz)', () {
    const csv = 'date;totalSleepMinutes;deepSleepMinutes;lightSleepMinutes;remMinutes\n'
        '20261120;430;80;270;80\n'
        '20261121;400;70;250;80\n';
    final r = parseHuaweiFiles([f('sleep_summary.csv', csv)]);
    expect(r.sleep, isEmpty);
    expect(r.days, hasLength(2));
    expect(r.days.first.day, '2026-11-20');
    expect(r.days.first.sleepTotalMin, 430);
    expect(r.days.first.sleepDeepMin, 80);
  });

  test('stres: zaman + değer (0..100), diziden', () {
    final t = DateTime(2026, 11, 21, 10).millisecondsSinceEpoch;
    final json = jsonEncode({
      'stressData': [
        {'timestamp': t, 'stress': 35},
        {'timestamp': t + 600000, 'stress': 62},
        {'timestamp': t + 1200000, 'stress': -1},
      ]
    });
    final r = parseHuaweiFiles([f('stress.json', json)]);
    expect(r.stress, hasLength(2));
    expect(r.stress.first.max, 100);
    expect(r.stress.last.level, 62);
    expect(r.stressDayCount, 1);
  });

  test('stres 1..5 ölçeği ve yalnız-gün kaydı öğlen 12:00 olur', () {
    const csv = 'date,stress_level\n2026-11-20,3\n2026-11-21,4\n';
    final r = parseHuaweiFiles([f('stress_daily.csv', csv)]);
    expect(r.stress, hasLength(2));
    expect(r.stress.first.max, 5);
    expect(r.stress.first.time.hour, 12);
    expect(r.notes.join(), contains('öğlen'));
  });

  test('aşama listesi (dize türlü) çözülür; aynı başlangıç iki kez gelirse tek kayıt', () {
    final rec = {
      'startTime': start.millisecondsSinceEpoch,
      'endTime': end.millisecondsSinceEpoch,
      'stages': [
        {'startTime': start.millisecondsSinceEpoch, 'endTime': start.add(const Duration(hours: 2)).millisecondsSinceEpoch, 'type': 'DEEP'},
        {'startTime': start.add(const Duration(hours: 2)).millisecondsSinceEpoch, 'endTime': end.millisecondsSinceEpoch, 'type': 'LIGHT'},
      ],
    };
    final r = parseHuaweiFiles([
      f('sleep1.json', jsonEncode([rec])),
      f('sleep2.json', jsonEncode([rec])),
    ]);
    expect(r.sleep, hasLength(1));
    expect(r.sleep.single.deepMinutes, 120);
    expect(r.sleep.single.stages.first.kind, SleepStageKind.deep);
  });

  test('JSONL desteklenir', () {
    final line = jsonEncode({'startTime': start.millisecondsSinceEpoch, 'endTime': end.millisecondsSinceEpoch});
    final r = parseHuaweiFiles([f('sleep.jsonl', '$line\n$line\n')]);
    expect(r.sleep, hasLength(1));
  });

  test('hiçbir şey bulunamazsa neden söylenir', () {
    final r = parseHuaweiFiles([f('heart.json', '{"hr":[{"t":1,"v":70}]}')]);
    expect(r.isEmpty, isTrue);
    expect(r.notes.join(), contains('Yapı raporu'));
    expect(r.preview(), contains('Yapı raporu'));
    expect(parseHuaweiFiles(const []).notes.join(), contains('dosya yok'));
    final onlyXlsx = parseHuaweiFiles([const HuaweiFile('aciklama.xlsx', 100, null)]);
    expect(onlyXlsx.notes.join(), contains('XLSX'));
  });

  test('uyku olmayan ama saat alanlı kayıt (adım) uyku sayılmaz', () {
    final json = jsonEncode([
      {'startTime': start.millisecondsSinceEpoch, 'endTime': end.millisecondsSinceEpoch, 'steps': 100}
    ]);
    expect(parseHuaweiFiles([f('steps.json', json)]).sleep, isEmpty);
  });

  test('önizleme sayıları ve tarih aralığı', () {
    final json = jsonEncode([
      {'startTime': start.millisecondsSinceEpoch, 'endTime': end.millisecondsSinceEpoch, 'deepSleepMinutes': 60},
    ]);
    final r = parseHuaweiFiles([f('sleep.json', json)]);
    expect(r.preview(), contains('Uyku: 1 kayıt'));
    expect(r.preview(), contains('2026-11-21'));
  });

  group('yapı raporu', () {
    test('anahtarlar var, DEĞERLER yok; tarih biçimli anahtarlar gizlenir', () {
      final json = jsonEncode({
        'sleepRecords': [
          {'startTime': 1763677800000, 'owner': 'GIZLI-AD-123', 'deep': 5}
        ],
        '2026-11-21': {'x': 1},
      });
      final files = describeHuaweiStructure([
        f('a/sleep.json', json),
        f('b.csv', 'tarih,deger\n1,SIR-9\n'),
        const HuaweiFile('c.xlsx', 10, null),
      ]);
      final text = structureReportText(files);
      expect(text, contains('sleepRecords[].startTime'));
      expect(text, contains('<sayı/tarih>'));
      expect(text, contains('tarih'));
      expect(text, isNot(contains('GIZLI-AD-123')));
      expect(text, isNot(contains('SIR-9')));
      expect(text, isNot(contains('1763677800000')));
      expect(text, isNot(contains('2026-11-21')));
      expect(text, contains('XLSX'));
      expect(files[1].rows, 1);
    });
  });
}
