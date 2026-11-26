import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Zum/kaydırma sürerken yayılan ortak bayrak: çizgi boyayıcılar [active] iken
/// hafif çizer (yalnız görünenler, ince çizgi, nokta bütçesi), bitince ([settle]
/// sonra) tam kaliteye döner.
class ZoomInteraction {
  ZoomInteraction({this.settle = const Duration(milliseconds: 150)});

  final Duration settle;

  /// Jest (ya da dönüşüm değişimi) sürüyor.
  final ValueNotifier<bool> active = ValueNotifier(false);
  final _tick = _Tick();
  Timer? _timer;
  bool _disposed = false;

  /// Etkileşim sırasında görünür dikdörtgen, KATMANIN yerel (görünüm piksel)
  /// koordinatında; null = bilinmiyor (kırpma yapılmaz).
  ui.Rect? Function()? visibleRect;

  /// Ekrandaki toplam büyütme (yerel piksel -> ekran pikseli); bilinmiyorsa 1.
  double Function()? zoomOf;

  /// Boyayıcının dinleyeceği: bayrak değişince ve etkileşim sürerken görünüm değişince.
  Listenable get repaint => Listenable.merge([active, _tick]);

  /// Jest başladı.
  void begin() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    if (!active.value) active.value = true;
  }

  /// Jest bitti: [settle] sonra tam kalite.
  void end() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(settle, () {
      if (!_disposed) active.value = false;
    });
  }

  /// Dönüşüm değişti (jest, tekerlek, eylemsizlik, programatik): etkileşimi başlatır,
  /// [settle] sonra kendiliğinden bitirir; sürerken boyayıcıyı görünümle günceller.
  void pulse() {
    if (_disposed) return;
    final wasActive = active.value;
    begin();
    end();
    if (wasActive) _tick.ping();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    active.dispose();
    _tick.dispose();
  }
}

class _Tick extends ChangeNotifier {
  void ping() => notifyListeners();
}
