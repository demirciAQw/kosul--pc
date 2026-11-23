/// Kalem giriş tanı günlüğü (saf Dart, KAPALI varsayılan).
///
/// Açıkken (app_meta `tani.kalem_girisi` = 1; Araçlar > "Kalem giriş tanısı")
/// işaretçi olayları şu biçimde yazılır (`adb logcat -s flutter | grep KocumPen`):
/// `KocumPen <ZAMAN_MS> <olay> kind=.. dev=.. ptr=.. pos=x,y p=.. rMaj=.. karar=..`
/// Kapalıyken [log] ilk satırda döner: sıfır maliyet (dize kurulmaz).
library;

const penDiagMetaKey = 'tani.kalem_girisi';

/// Karar etiketleri (tek yerde).
class PenDecision {
  PenDecision._();
  static const swallowed = 'yutuldu';
  static const penTook = 'kalem-aldi';
  static const toView = 'gorunume-gitti';
  static const noLayer = 'katman-yok';
  static const cancelSaved = 'iptal-kaydedildi';
  static const palmRetro = 'avuc-geriye-donuk';
  static const viewRestored = 'donusum-geri-alindi';
}

class PenDiag {
  PenDiag._();

  static bool enabled = false;

  // ignore: avoid_print
  static void Function(String) sink = print;

  /// Her kaçıncı Move / Hover yazılır.
  static const int moveEvery = 10;
  static const int hoverEvery = 20;

  static int _moves = 0;
  static int _hovers = 0;

  static void resetCounters() {
    _moves = 0;
    _hovers = 0;
  }

  /// [event]: down|move|up|cancel|hover. Move/Hover örneklenir.
  static void log(
    String event, {
    required int tMs,
    required String kind,
    required int device,
    required int pointer,
    required double x,
    required double y,
    required double pressure,
    required double radiusMajor,
    required String decision,
  }) {
    if (!enabled) return;
    if (event == 'move' && (_moves++ % moveEvery) != 0) return;
    if (event == 'hover' && (_hovers++ % hoverEvery) != 0) return;
    sink('KocumPen $tMs $event kind=$kind dev=$device ptr=$pointer '
        'pos=${x.toStringAsFixed(1)},${y.toStringAsFixed(1)} '
        'p=${pressure.toStringAsFixed(2)} rMaj=${radiusMajor.toStringAsFixed(1)} karar=$decision');
  }

  /// Serbest not (örn. dönüşüm geri alma).
  static void note(String text, {required int tMs}) {
    if (!enabled) return;
    sink('KocumPen $tMs not $text');
  }
}
