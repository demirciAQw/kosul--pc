import 'package:flutter/services.dart';

import '../domain/health_models.dart';
import '../domain/health_source.dart';

/// Android Health Connect (Kotlin kanalı `kocum/health`; tool/health_patch.dart).
/// Salt okuma. Kanal yoksa (yama uygulanmamış) "desteklenmiyor" döner.
class HealthConnectSource implements HealthSource {
  HealthConnectSource({MethodChannel? channel}) : _ch = channel ?? const MethodChannel('kocum/health');
  final MethodChannel _ch;

  HealthStatus _status(Object? raw) {
    if (raw is! Map) return const HealthStatus(availability: HealthAvailability.unsupported);
    final availability = switch (raw['availability']) {
      'available' => HealthAvailability.available,
      'needsUpdate' => HealthAvailability.needsUpdate,
      'needsInstall' => HealthAvailability.needsInstall,
      _ => HealthAvailability.unsupported,
    };
    final granted = <HealthDataType>{
      for (final n in (raw['granted'] as List? ?? const []))
        for (final t in HealthDataType.values)
          if (t.name == n) t,
    };
    return HealthStatus(availability: availability, granted: granted);
  }

  @override
  Future<HealthStatus> status() async {
    try {
      return _status(await _ch.invokeMethod<Object?>('status'));
    } on MissingPluginException {
      return const HealthStatus(availability: HealthAvailability.unsupported);
    } on PlatformException catch (e) {
      return HealthStatus(availability: HealthAvailability.unsupported, error: e.message);
    }
  }

  @override
  Future<HealthStatus> requestPermissions() async {
    try {
      return _status(await _ch.invokeMethod<Object?>('request'));
    } on MissingPluginException {
      return const HealthStatus(availability: HealthAvailability.unsupported);
    } on PlatformException catch (e) {
      return HealthStatus(availability: HealthAvailability.unsupported, error: e.message);
    }
  }

  static int _int(Object? o) => (o as num).toInt();

  @override
  Future<List<SleepSession>> readSleep(DateTime from, DateTime to) async {
    final raw = await _ch.invokeMethod<List<Object?>>('readSleep', {
          'from': from.millisecondsSinceEpoch,
          'to': to.millisecondsSinceEpoch,
        }) ??
        const [];
    return [
      for (final r in raw)
        if (r is Map)
          SleepSession(
            start: DateTime.fromMillisecondsSinceEpoch(_int(r['s'])),
            end: DateTime.fromMillisecondsSinceEpoch(_int(r['e'])),
            source: 'health_connect',
            stages: [
              for (final st in (r['st'] as List? ?? const []))
                if (st is Map)
                  SleepStageSpan(
                    DateTime.fromMillisecondsSinceEpoch(_int(st['s'])),
                    DateTime.fromMillisecondsSinceEpoch(_int(st['e'])),
                    SleepStageKind.parse(st['t'] as String?),
                  ),
            ],
          ),
    ];
  }

  @override
  Future<List<DailyVitals>> readDailyVitals(DateTime from, DateTime to) async {
    final raw = await _ch.invokeMethod<Map<Object?, Object?>>('readDaily', {
      'from': from.millisecondsSinceEpoch,
      'to': to.millisecondsSinceEpoch,
    });
    if (raw == null) return const [];
    return groupDailyVitals(
      resting: _pairs(raw['resting']),
      hrv: _pairs(raw['hrv']),
      steps: _pairs(raw['steps']),
    );
  }

  List<(int, double)> _pairs(Object? o) => [
        for (final e in (o as List? ?? const []))
          if (e is Map) (_int(e['t']), (e['v'] as num).toDouble()),
      ];

  @override
  Future<List<OriginCount>> originSummary(int days) async {
    final raw = await _ch.invokeMethod<List<Object?>>('origins', {'days': days}) ?? const [];
    return [
      for (final e in raw)
        if (e is Map)
          OriginCount(
            type: HealthDataType.values.where((t) => t.name == e['type']).firstOrNull?.label ?? '${e['type']}',
            packageName: '${e['pkg']}',
            count: _int(e['n']),
          ),
    ]..sort((a, b) => b.count.compareTo(a.count));
  }
}

/// (zaman ms, değer) çiftlerini yerel güne göre toplar: dinlenme nabzı ve HRV ortalama, adım toplam gün değeri.
List<DailyVitals> groupDailyVitals({
  List<(int, double)> resting = const [],
  List<(int, double)> hrv = const [],
  List<(int, double)> steps = const [],
}) {
  Map<String, double> avg(List<(int, double)> l) {
    final by = <String, List<double>>{};
    for (final (t, v) in l) {
      (by[dayKey(DateTime.fromMillisecondsSinceEpoch(t))] ??= []).add(v);
    }
    return {for (final e in by.entries) e.key: e.value.reduce((a, b) => a + b) / e.value.length};
  }

  final r = avg(resting), h = avg(hrv);
  final s = <String, double>{};
  for (final (t, v) in steps) {
    final k = dayKey(DateTime.fromMillisecondsSinceEpoch(t));
    s[k] = (s[k] ?? 0) + v;
  }
  final days = {...r.keys, ...h.keys, ...s.keys}.toList()..sort();
  return [
    for (final d in days)
      DailyVitals(day: d, restingHr: r[d]?.round(), hrv: h[d], steps: s[d]?.round()),
  ];
}
