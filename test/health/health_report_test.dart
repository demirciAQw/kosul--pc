import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/dashboard/domain/ai_report.dart';
import 'package:kocum/features/health/domain/health_aggregate.dart';
import 'package:kocum/features/health/domain/health_models.dart';

void main() {
  AiReport build({String? health}) =>
      buildAiReport(cards: const [], curriculum: const {}, exams: const [], books: const [], now: DateTime(2026, 11, 23), healthSection: health);

  test('varsayılan: rapora hiçbir sağlık verisi girmez', () {
    expect(build().markdown, isNot(contains('Sağlık verisi')));
  });

  test('ayar açıkken küçük günlük özet bölümü eklenir', () {
    final section = healthReportSection([
      const HealthDay(day: '2026-11-22', source: 'x', sleepTotalMin: 420, restingHr: 55),
    ]);
    final md = build(health: section).markdown;
    expect(md, contains('## Sağlık verisi (öğrencinin izniyle)'));
    expect(md, contains('| 2026-11-22 | 7s | - | 55 | - |'));
  });
}
