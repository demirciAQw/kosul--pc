/// Giriş → kare gecikmesi hesabı (saf Dart, mikrosaniye).
///
/// Girişler zaman damgasıyla beklemeye alınır; bir kare ölçümü geldiğinde,
/// o karenin yapımı başlamadan önce gelmiş girişler o karede görünmüş sayılır
/// ve gecikme = karenin raster bitişi - giriş zamanı.
class InkLatencyTracker {
  InkLatencyTracker({this.maxPending = 256});

  final int maxPending;
  final List<int> _pendingUs = [];

  int get pendingCount => _pendingUs.length;

  void onInput(int timestampUs) {
    _pendingUs.add(timestampUs);
    if (_pendingUs.length > maxPending) _pendingUs.removeAt(0);
  }

  /// Bu karede görünen girişlerin gecikmeleri (ms). Girişler en eski sırada.
  /// Yalnız raster bitişine kadar (B'nin "giris->raster" ölçümü).
  List<double> onFrame({
    required int buildStartUs,
    required int rasterFinishUs,
  }) => onFrameDetailed(
    buildStartUs: buildStartUs,
    rasterFinishUs: rasterFinishUs,
    vsyncUs: rasterFinishUs,
  ).raster;

  /// Hem raster bitişine (giris->raster) hem karenin vsync'ine (giris->vsync)
  /// kadar gecikmeler. Yerel A tarafı yalnız vsync'e kadar ölçer; adil
  /// karşılaştırma için B'de "giris->vsync" bakılır. Giriş vsync'ten sonra
  /// ama yapım başlamadan önce geldiyse vsync gecikmesi 0 sayılır.
  ({List<double> raster, List<double> vsync}) onFrameDetailed({
    required int buildStartUs,
    required int rasterFinishUs,
    required int vsyncUs,
  }) {
    final raster = <double>[];
    final vsync = <double>[];
    _pendingUs.removeWhere((t) {
      if (t > buildStartUs) return false;
      raster.add((rasterFinishUs - t) / 1000);
      final v = (vsyncUs - t) / 1000;
      vsync.add(v < 0 ? 0 : v);
      return true;
    });
    return (raster: raster, vsync: vsync);
  }
}
