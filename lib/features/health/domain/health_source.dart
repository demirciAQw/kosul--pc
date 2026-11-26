import 'health_models.dart';

/// Sağlık kaynağı (Health Connect) durumu.
enum HealthAvailability {
  /// Bu cihazda yok (masaüstü, eski Android).
  unsupported,

  /// Health Connect uygulaması yok ya da yükseltilmeli.
  needsInstall,
  needsUpdate,
  available,
}

/// Koçum'un okuduğu veri türleri (Health Connect karşılıkları).
enum HealthDataType {
  sleep('Uyku'),
  heartRate('Nabız'),
  restingHeartRate('Dinlenme nabzı'),
  hrv('Kalp atış değişkenliği'),
  oxygen('Oksijen (SpO2)'),
  steps('Adım');

  const HealthDataType(this.label);
  final String label;
}

class HealthStatus {
  const HealthStatus({
    required this.availability,
    this.granted = const {},
    this.error,
  });
  final HealthAvailability availability;
  final Set<HealthDataType> granted;
  final String? error;

  bool get usable => availability == HealthAvailability.available;
  bool get allGranted => granted.length == HealthDataType.values.length;
  bool get anyGranted => granted.isNotEmpty;
}

/// Soyut sağlık kaynağı. Android'de Health Connect; masaüstünde desteklenmez;
/// testte [FakeHealthSource].
abstract class HealthSource {
  Future<HealthStatus> status();

  /// Sistem izin ekranını açar; sonra güncel durumu döner.
  Future<HealthStatus> requestPermissions();

  Future<List<SleepSession>> readSleep(DateTime from, DateTime to);
  Future<List<DailyVitals>> readDailyVitals(DateTime from, DateTime to);

  /// Son [days] günde hangi uygulamalardan hangi türde kaç kayıt geldi.
  Future<List<OriginCount>> originSummary(int days);
}

class UnsupportedHealthSource implements HealthSource {
  const UnsupportedHealthSource();
  @override
  Future<HealthStatus> status() async => const HealthStatus(availability: HealthAvailability.unsupported);
  @override
  Future<HealthStatus> requestPermissions() => status();
  @override
  Future<List<SleepSession>> readSleep(DateTime from, DateTime to) async => const [];
  @override
  Future<List<DailyVitals>> readDailyVitals(DateTime from, DateTime to) async => const [];
  @override
  Future<List<OriginCount>> originSummary(int days) async => const [];
}

/// Testler için.
class FakeHealthSource implements HealthSource {
  FakeHealthSource({
    this.availability = HealthAvailability.available,
    Set<HealthDataType>? granted,
    this.sleep = const [],
    this.vitals = const [],
    this.origins = const [],
  }) : granted = granted ?? {};

  HealthAvailability availability;
  Set<HealthDataType> granted;
  List<SleepSession> sleep;
  List<DailyVitals> vitals;
  List<OriginCount> origins;
  int permissionRequests = 0;

  @override
  Future<HealthStatus> status() async => HealthStatus(availability: availability, granted: {...granted});

  @override
  Future<HealthStatus> requestPermissions() async {
    permissionRequests++;
    if (availability == HealthAvailability.available) granted = {...HealthDataType.values};
    return status();
  }

  @override
  Future<List<SleepSession>> readSleep(DateTime from, DateTime to) async =>
      [for (final s in sleep) if (!s.end.isBefore(from) && !s.end.isAfter(to)) s];

  @override
  Future<List<DailyVitals>> readDailyVitals(DateTime from, DateTime to) async => vitals;

  @override
  Future<List<OriginCount>> originSummary(int days) async => origins;
}
