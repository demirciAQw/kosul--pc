/// Çizgi düzeyinde geri al / yinele yığını (saf Dart).
///
/// Bir eylem, bir sayfadaki çizgi kümesinin eklenmesi, silinmesi ya da (alan silgisi)
/// bir kümenin başka bir kümeyle değiştirilmesidir.
/// Geri al: eklenenleri yumuşak siler, silinenleri geri getirir. Yinele tersi.
/// Yeni eylem yinele yığınını boşaltır.
library;

import '../../ink/domain/ink_models.dart';

enum InkActionKind { added, erased, replaced, updated }

class InkAction {
  const InkAction(this.kind, this.page, this.strokeIds, {this.addedIds = const [], this.before, this.after});
  final InkActionKind kind;
  final int page;

  /// added: eklenenler; erased: silinenler; replaced: yerine konulanlar (silinen özgünler).
  final List<String> strokeIds;

  /// Yalnız replaced (alan silgisi, hareket başına TEK kayıt): özgünlerin yerine eklenen parçalar.
  final List<String> addedIds;

  /// Yalnız updated (kement taşıma/boyutlandırma): kimlik → noktalar, önce ve sonra.
  /// Geri al [before]'u, yinele [after]'ı yazar.
  final Map<String, List<InkPoint>>? before, after;

  /// [InkPoint] başına yaklaşık bellek (nesne başlığı + 5 double).
  static const bytesPerPoint = 56;

  /// Eylemin tuttuğu noktaların yaklaşık belleği (bayt); yalnız updated eylemleri nokta taşır.
  int get approxBytes {
    var n = 0;
    for (final m in [before, after]) {
      if (m == null) continue;
      for (final pts in m.values) {
        n += pts.length;
      }
    }
    return n * bytesPerPoint;
  }
}

class InkHistory {
  InkHistory({this.limit = 200, this.maxBytes = defaultMaxBytes});

  /// Nokta kopyaları (taşıma/boyutlandırma) için toplam bellek üst sınırı: 32 MB.
  static const defaultMaxBytes = 32 * 1024 * 1024;
  final int maxBytes;

  /// Yığın üst sınırı (bellek); aşılınca en eski eylem düşer (çizgiler silinmez).
  final int limit;
  final List<InkAction> _undo = [];
  final List<InkAction> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void push(InkAction a) {
    if (a.strokeIds.isEmpty && a.addedIds.isEmpty) return;
    _undo.add(a);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    _trim();
  }

  /// Bellek üst sınırı aşılınca en eski eylemler düşer (en yeni eylem her zaman kalır).
  void _trim() {
    var total = _undo.fold<int>(0, (n, a) => n + a.approxBytes);
    while (total > maxBytes && _undo.length > 1) {
      total -= _undo.removeAt(0).approxBytes;
    }
  }

  /// Yığındaki toplam yaklaşık bayt (test/teşhis).
  int get approxBytes => [..._undo, ..._redo].fold<int>(0, (n, a) => n + a.approxBytes);
  int get undoLength => _undo.length;

  /// Geri alınacak eylemi yığından çıkarıp döner (yinele yığınına koymak
  /// [commitUndo] ile, işlem başarılıysa).
  InkAction? takeUndo() => _undo.isEmpty ? null : _undo.removeLast();
  void commitUndo(InkAction a) => _redo.add(a);

  /// [takeUndo] sonrası işlem başarısız olduysa eylemi yığına geri koyar.
  void returnUndo(InkAction a) => _undo.add(a);

  /// [takeRedo] sonrası işlem başarısız olduysa eylemi yığına geri koyar.
  void returnRedo(InkAction a) => _redo.add(a);

  InkAction? takeRedo() => _redo.isEmpty ? null : _redo.removeLast();
  void commitRedo(InkAction a) => _undo.add(a);
}
