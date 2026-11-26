/// Kalem hareket tahmininin hıza göre sınırlanması (saf Dart).
///
/// Kotlin'deki `PredictLimiter` (tool/ink_patch.dart) bunun birebir aynısıdır;
/// sabitler tek yerden (burası) Kotlin şablonuna basılır. Birimler: mantıksal
/// piksel (dp) ve milisaniye.
///
/// Sorun: `MotionEventPredictor` her harekette ilerisini tahmin eder; kalem
/// durunca bile baskı/titreşim gürültüsü tahmin ucunu sağa sola oynatır.
/// Çözüm: son birkaç gerçek olaydan hız hesaplanır; durma hızının altında
/// tahmin HİÇ verilmez; üstünde tahmin edilen yol `hız x süre` ile ve mutlak
/// bir üst sınırla kırpılır.
library;

import 'dart:math' as math;

class PredictLimits {
  PredictLimits._();

  /// Hız penceresi: son bu kadar gerçek nokta.
  static const int window = 4;

  /// Bu hızın (dp/ms) altı "durdu" sayılır: tahmin verilmez (0,08 dp/ms = 80 dp/sn).
  static const double stillSpeed = 0.08;

  /// Art arda bu kadar harekette ...
  static const int stillCount = 3;

  /// ... her biri bu mesafeden (dp) az oynadıysa kalem durmuş sayılır.
  static const double stillMove = 1.0;

  /// Tahmin süresi (ms): izin verilen en uzun tahmin yolu = hız x bu süre x [leadScale].
  static const double horizonMs = 16.0;
  static const double leadScale = 1.0;

  /// Tahmin yolunun mutlak üst sınırı (dp).
  static const double maxLeadDp = 24.0;
}

class PredictPoint {
  const PredictPoint(this.x, this.y, this.t);
  final double x;
  final double y;
  final double t;
}

class PredictLimiter {
  final List<PredictPoint> _w = [];
  int _stillRun = 0;

  void reset() {
    _w.clear();
    _stillRun = 0;
  }

  /// Gerçek bir nokta (dp, ms) ekle.
  void record(double x, double y, double t) {
    if (_w.isNotEmpty) {
      final last = _w.last;
      final moved = math.sqrt(
        (x - last.x) * (x - last.x) + (y - last.y) * (y - last.y),
      );
      _stillRun = moved < PredictLimits.stillMove ? _stillRun + 1 : 0;
    }
    _w.add(PredictPoint(x, y, t));
    if (_w.length > PredictLimits.window) _w.removeAt(0);
  }

  /// Pencere boyunca hız (dp/ms); yetersiz veri için 0.
  double get speed {
    if (_w.length < 2) return 0;
    final a = _w.first;
    final b = _w.last;
    final dt = b.t - a.t;
    if (dt <= 0) return 0;
    final d = math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
    return d / dt;
  }

  bool get isStill =>
      _w.length < 2 ||
      _stillRun >= PredictLimits.stillCount ||
      speed < PredictLimits.stillSpeed;

  /// İzin verilen en uzun tahmin yolu (dp); durmuşsa 0.
  double get maxLead => isStill
      ? 0
      : math.min(
          speed * PredictLimits.horizonMs * PredictLimits.leadScale,
          PredictLimits.maxLeadDp,
        );

  /// Tahmin noktalarını (gerçek son noktadan başlayarak) kırpar. Boş dönerse
  /// tahmin verilmez (`prediction = null`). Aşan nokta, sınıra denk gelecek
  /// biçimde ara değerlenir.
  List<PredictPoint> clip(List<PredictPoint> predicted) {
    final limit = maxLead;
    if (limit <= 0 || predicted.isEmpty || _w.isEmpty) return const [];
    final out = <PredictPoint>[];
    var px = _w.last.x;
    var py = _w.last.y;
    var pt = _w.last.t;
    var used = 0.0;
    for (final p in predicted) {
      final seg = math.sqrt((p.x - px) * (p.x - px) + (p.y - py) * (p.y - py));
      if (used + seg <= limit) {
        out.add(p);
        used += seg;
        px = p.x;
        py = p.y;
        pt = p.t;
        continue;
      }
      if (seg > 0) {
        final f = (limit - used) / seg;
        if (f > 0) {
          out.add(
            PredictPoint(
              px + (p.x - px) * f,
              py + (p.y - py) * f,
              pt + (p.t - pt) * f,
            ),
          );
        }
      }
      break;
    }
    return out;
  }
}
