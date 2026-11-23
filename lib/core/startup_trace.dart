import 'package:flutter/foundation.dart';

/// Açılış aşamalarını ölçer. logcat: `adb logcat -s flutter | grep KocumStart`.
/// Yalnız debug/profile'da açıktır; release'te her çağrı hemen döner
/// (Stopwatch bile başlamaz, yazı basılmaz).
class StartupTrace {
  StartupTrace({bool? enabled, void Function(String)? sink, Stopwatch? clock})
      : enabled = enabled ?? !kReleaseMode,
        _sink = sink ?? debugPrint,
        _clock = clock ?? Stopwatch();

  /// Uygulama genelinde kullanılan tek örnek.
  static final StartupTrace instance = StartupTrace();

  final bool enabled;
  final void Function(String) _sink;
  final Stopwatch _clock;
  final Map<String, int> _marks = {};

  /// Aşamaların başlangıçtan beri ms değeri (ilk işaret kaydı sırasıyla).
  Map<String, int> get marks => Map.unmodifiable(_marks);

  /// [stage] aşamasına ulaşıldı. Aynı aşama ikinci kez yazılmaz.
  void mark(String stage) {
    if (!enabled || _marks.containsKey(stage)) return;
    if (!_clock.isRunning) _clock.start();
    final ms = _clock.elapsedMilliseconds;
    _marks[stage] = ms;
    _sink('KocumStart $stage ${ms}ms');
  }
}
