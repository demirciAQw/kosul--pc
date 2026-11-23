import 'dart:math' as math;

import 'health_models.dart';

/// Uyku oturumlarını, günlük ölçümleri ve stres örneklerini gün özetlerine
/// toplar (saf Dart). Aynı güne (uyanılan gün) düşen birden çok oturumun (gece +
/// şekerleme) süreleri toplanır; başlangıç/bitiş en uzun oturumdan alınır.
List<HealthDay> buildHealthDays({
  required String source,
  List<SleepSession> sessions = const [],
  List<DailyVitals> vitals = const [],
  List<StressSample> stress = const [],
}) {
  final byDay = <String, List<SleepSession>>{};
  for (final s in sessions) {
    (byDay[s.day] ??= []).add(s);
  }
  final vitalByDay = {for (final v in vitals) v.day: v};
  final stressByDay = <String, List<StressSample>>{};
  for (final s in stress) {
    (stressByDay[dayKey(s.time)] ??= []).add(s);
  }
  final days = {...byDay.keys, ...vitalByDay.keys, ...stressByDay.keys}.toList()..sort();
  int? sumOf(List<SleepSession> l, int? Function(SleepSession) f) {
    final vals = [for (final s in l) f(s)].whereType<int>().toList();
    return vals.isEmpty ? null : vals.fold<int>(0, (a, b) => a + b);
  }

  return [
    for (final d in days)
      () {
        final ss = byDay[d] ?? const <SleepSession>[];
        final longest = ss.isEmpty
            ? null
            : ss.reduce((a, b) => a.end.difference(a.start) >= b.end.difference(b.start) ? a : b);
        final v = vitalByDay[d];
        final st = stressByDay[d] ?? const <StressSample>[];
        final pcts = [for (final s in st) s.percent];
        return HealthDay(
          day: d,
          source: source,
          sleepTotalMin: ss.isEmpty ? null : ss.fold<int>(0, (a, s) => a + s.totalMinutes),
          sleepDeepMin: sumOf(ss, (s) => s.deepMinutes),
          sleepLightMin: sumOf(ss, (s) => s.lightMinutes),
          sleepRemMin: sumOf(ss, (s) => s.remMinutes),
          sleepAwakeMin: sumOf(ss, (s) => s.awakeMinutes),
          sleepStart: longest?.start.millisecondsSinceEpoch,
          sleepEnd: longest?.end.millisecondsSinceEpoch,
          restingHr: v?.restingHr,
          hrv: v?.hrv,
          steps: v?.steps,
          stressAvg: pcts.isEmpty ? null : pcts.reduce((a, b) => a + b) / pcts.length,
          stressMax: pcts.isEmpty ? null : pcts.reduce(math.max),
        );
      }(),
  ];
}

/// "7s 12dk" biçimi.
String formatMinutes(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '${m}dk';
  if (m == 0) return '${h}s';
  return '${h}s ${m}dk';
}

/// Bugün kartındaki özet: "Dün gece (saatten): 7s 12dk, derin 1s 30dk".
String? lastNightSummary(HealthDay? d) {
  if (d == null || d.sleepTotalMin == null || d.sleepTotalMin == 0) return null;
  final b = StringBuffer('Dün gece (saatten): ${formatMinutes(d.sleepTotalMin!)}');
  if (d.sleepDeepMin != null && d.sleepDeepMin! > 0) b.write(', derin ${formatMinutes(d.sleepDeepMin!)}');
  return b.toString();
}

/// Elle girilen bir gece ile saatten gelen oturum aynı geceyi anlatıyor ama
/// ikisi de birbirinden belirgin farklıysa çakışma sayılır.
class SleepConflict {
  const SleepConflict({
    required this.day,
    required this.manualBed,
    required this.manualWake,
    required this.healthStart,
    required this.healthEnd,
  });
  final String day;
  final DateTime manualBed;
  final DateTime manualWake;
  final DateTime healthStart;
  final DateTime healthEnd;
}

/// [toleranceMinutes]: başlangıç ve bitiş farkı bunun altındaysa aynı sayılır.
List<SleepConflict> findSleepConflicts({
  required List<({DateTime bed, DateTime wake})> manual,
  required List<HealthDay> days,
  int toleranceMinutes = 20,
}) {
  final out = <SleepConflict>[];
  for (final d in days) {
    if (d.sleepStart == null || d.sleepEnd == null) continue;
    final hs = DateTime.fromMillisecondsSinceEpoch(d.sleepStart!);
    final he = DateTime.fromMillisecondsSinceEpoch(d.sleepEnd!);
    for (final m in manual) {
      final overlaps = m.bed.isBefore(he) && m.wake.isAfter(hs);
      if (!overlaps) continue;
      final differs = m.bed.difference(hs).inMinutes.abs() > toleranceMinutes ||
          m.wake.difference(he).inMinutes.abs() > toleranceMinutes;
      if (differs) {
        out.add(SleepConflict(day: d.day, manualBed: m.bed, manualWake: m.wake, healthStart: hs, healthEnd: he));
      }
    }
  }
  return out;
}

/// Claude raporu için küçük günlük özet (yalnız ayar açıkken çağrılır). Boşsa null.
String? healthReportSection(List<HealthDay> days) {
  if (days.isEmpty) return null;
  final b = StringBuffer()
    ..writeln('## Sağlık verisi (öğrencinin izniyle)')
    ..writeln()
    ..writeln('| Gün | Uyku | Derin | Dinlenme nabzı | Stres ort. (0-100) |')
    ..writeln('|---|---|---|---|---|');
  for (final d in days) {
    b.writeln('| ${d.day} | ${d.sleepTotalMin == null ? '-' : formatMinutes(d.sleepTotalMin!)} | '
        '${d.sleepDeepMin == null ? '-' : formatMinutes(d.sleepDeepMin!)} | ${d.restingHr ?? '-'} | '
        '${d.stressAvg == null ? '-' : d.stressAvg!.round()} |');
  }
  return b.toString();
}
