/// Sağlık verisi modelleri (saf Dart).
library;

/// Uyku aşaması türü (Health Connect'ten ya da Huawei verisinden).
enum SleepStageKind {
  deep,
  light,
  rem,
  awake,

  /// Aşama ayrımı olmayan uyku.
  sleeping,

  /// Yatakta uyanık / yataktan çıktı gibi uyku sayılmayan ve uyanık da olmayan.
  other;

  static SleepStageKind parse(String? s) => switch (s) {
        'deep' => deep,
        'light' => light,
        'rem' => rem,
        'awake' => awake,
        'sleeping' => sleeping,
        _ => other,
      };
}

class SleepStageSpan {
  const SleepStageSpan(this.start, this.end, this.kind);
  final DateTime start;
  final DateTime end;
  final SleepStageKind kind;

  int get minutes => end.difference(start).inMinutes;

  Map<String, Object?> toJson() =>
      {'s': start.millisecondsSinceEpoch, 'e': end.millisecondsSinceEpoch, 't': kind.name};

  static SleepStageSpan? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['s'], e = j['e'];
    if (s is! num || e is! num) return null;
    return SleepStageSpan(
      DateTime.fromMillisecondsSinceEpoch(s.toInt()),
      DateTime.fromMillisecondsSinceEpoch(e.toInt()),
      SleepStageKind.parse(j['t'] as String?),
    );
  }
}

/// Bir uyku oturumu. Aşama yoksa yalnızca [totalMinutesOverride] ile toplam bilinebilir.
class SleepSession {
  const SleepSession({
    required this.start,
    required this.end,
    required this.source,
    this.stages = const [],
    this.totalMinutesOverride,
    this.deepMinutesOverride,
    this.lightMinutesOverride,
    this.remMinutesOverride,
    this.awakeMinutesOverride,
  });

  final DateTime start;
  final DateTime end;
  final String source;
  final List<SleepStageSpan> stages;

  /// Aşama aralıkları olmayan kaynaklarda (Huawei özeti) toplamlar doğrudan gelir.
  final int? totalMinutesOverride;
  final int? deepMinutesOverride;
  final int? lightMinutesOverride;
  final int? remMinutesOverride;
  final int? awakeMinutesOverride;

  int _sum(Iterable<SleepStageKind> kinds) =>
      stages.where((s) => kinds.contains(s.kind)).fold(0, (a, s) => a + s.minutes);

  bool get hasStages => stages.isNotEmpty;

  int? get deepMinutes => hasStages ? _sum([SleepStageKind.deep]) : deepMinutesOverride;
  int? get lightMinutes => hasStages ? _sum([SleepStageKind.light]) : lightMinutesOverride;
  int? get remMinutes => hasStages ? _sum([SleepStageKind.rem]) : remMinutesOverride;
  int? get awakeMinutes => hasStages ? _sum([SleepStageKind.awake]) : awakeMinutesOverride;

  /// Uyunan süre: aşama varsa uyanık dışındaki uyku aşamaları, yoksa verilen toplam,
  /// o da yoksa başlangıç-bitiş farkı (uyanık süresi biliniyorsa düşülür).
  int get totalMinutes {
    if (hasStages) {
      return _sum([SleepStageKind.deep, SleepStageKind.light, SleepStageKind.rem, SleepStageKind.sleeping]);
    }
    if (totalMinutesOverride != null) return totalMinutesOverride!;
    final span = end.difference(start).inMinutes;
    return (span - (awakeMinutesOverride ?? 0)).clamp(0, span);
  }

  /// Uyku, uyanılan günün kaydıdır.
  String get day => dayKey(end);
}

/// Yerel gün anahtarı: YYYY-MM-DD.
String dayKey(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

class StressSample {
  const StressSample({required this.time, required this.level, required this.max, required this.source});
  final DateTime time;
  final double level;

  /// Ölçeğin en büyük değeri (elle 5, Huawei 100).
  final int max;
  final String source;

  /// 0..100'e çevrilmiş değer.
  double get percent => (level / max * 100).clamp(0, 100).toDouble();
}

/// Bir günün özeti (veritabanı satırının alan düzeyi karşılığı).
class HealthDay {
  const HealthDay({
    required this.day,
    required this.source,
    this.sleepTotalMin,
    this.sleepDeepMin,
    this.sleepLightMin,
    this.sleepRemMin,
    this.sleepAwakeMin,
    this.sleepStart,
    this.sleepEnd,
    this.restingHr,
    this.hrv,
    this.steps,
    this.stressAvg,
    this.stressMax,
  });

  final String day;
  final String source;
  final int? sleepTotalMin;
  final int? sleepDeepMin;
  final int? sleepLightMin;
  final int? sleepRemMin;
  final int? sleepAwakeMin;
  final int? sleepStart;
  final int? sleepEnd;
  final int? restingHr;
  final double? hrv;
  final int? steps;
  final double? stressAvg;
  final double? stressMax;
}

/// Sağlık kaynağından gelen günlük ölçüm (dinlenme nabzı, HRV, adım).
class DailyVitals {
  const DailyVitals({required this.day, this.restingHr, this.hrv, this.steps});
  final String day;
  final int? restingHr;
  final double? hrv;
  final int? steps;
}

/// "Hangi uygulamalar veri yazıyor" tanısı: bir veri türü + bir kaynak uygulama.
class OriginCount {
  const OriginCount({required this.type, required this.packageName, required this.count});
  final String type;
  final String packageName;
  final int count;
}

/// Kaynak uygulamanın okunabilir adı (bilinenler); bilinmeyen paket adı olduğu gibi.
String originLabel(String pkg) {
  if (pkg == 'com.huawei.health' || pkg.startsWith('com.huawei.')) return 'Huawei Sağlık ($pkg)';
  return switch (pkg) {
    'com.google.android.apps.fitness' => 'Google Fit ($pkg)',
    'com.google.android.apps.healthdata' => 'Health Connect ($pkg)',
    'com.sec.android.app.shealth' => 'Samsung Health ($pkg)',
    'com.fitbit.FitbitMobile' => 'Fitbit ($pkg)',
    _ => pkg,
  };
}

bool isHuaweiOrigin(String pkg) => pkg.startsWith('com.huawei.') || pkg.startsWith('com.hihonor.');
