/// Kalemin hareketsiz basılı tutulduğunu bulur (şekil düzeltme için; saf Dart).
///
/// Zaman dışarıdan verilir (sahte zamanla test edilir). Hareket, çapa noktasından
/// [tolerance] uzaklığı aşarsa çapa yeni yere kayar ve süre sıfırlanır; titreme
/// (kalem ucunun doğal oynaması) süreyi sıfırlamaz.
library;

import 'dart:math' as math;

/// Varsayılan basılı tutma süresi (ms).
const shapeHoldMs = 600;

/// Varsayılan hareketsizlik eşiği (görünüm pikseli).
const shapeHoldTolerancePx = 6.0;

class HoldDetector {
  HoldDetector({this.holdMs = shapeHoldMs, this.tolerance = shapeHoldTolerancePx});

  final int holdMs;
  final double tolerance;

  double? _ax, _ay;
  double _since = 0;

  /// Çizgi başladı ya da yeni çapa. [tMs] ms cinsinden herhangi bir tek saat.
  void start(double x, double y, double tMs) {
    _ax = x;
    _ay = y;
    _since = tMs;
  }

  /// Yeni nokta. Hareket eşiği aştıysa çapa kayar ve true döner (zamanlayıcı yeniden kurulur).
  bool onPoint(double x, double y, double tMs) {
    final ax = _ax, ay = _ay;
    if (ax == null || ay == null) {
      start(x, y, tMs);
      return true;
    }
    final d = math.sqrt((x - ax) * (x - ax) + (y - ay) * (y - ay));
    if (d <= tolerance) return false;
    start(x, y, tMs);
    return true;
  }

  /// [tMs] anında kalem [holdMs] boyunca hareketsiz kaldı mı.
  bool isHeld(double tMs) => _ax != null && tMs - _since >= holdMs;

  void reset() {
    _ax = null;
    _ay = null;
  }
}
