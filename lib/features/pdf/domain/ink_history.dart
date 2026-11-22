/// Çizgi düzeyinde geri al / yinele yığını (saf Dart).
///
/// Bir eylem, bir sayfadaki çizgi kümesinin eklenmesi, silinmesi ya da (alan silgisi)
/// bir kümenin başka bir kümeyle değiştirilmesidir.
/// Geri al: eklenenleri yumuşak siler, silinenleri geri getirir. Yinele tersi.
/// Yeni eylem yinele yığınını boşaltır.
library;

enum InkActionKind { added, erased, replaced }

class InkAction {
  const InkAction(this.kind, this.page, this.strokeIds, {this.addedIds = const []});
  final InkActionKind kind;
  final int page;

  /// added: eklenenler; erased: silinenler; replaced: yerine konulanlar (silinen özgünler).
  final List<String> strokeIds;

  /// Yalnız replaced (alan silgisi, hareket başına TEK kayıt): özgünlerin yerine eklenen parçalar.
  final List<String> addedIds;
}

class InkHistory {
  InkHistory({this.limit = 200});

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
  }

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
