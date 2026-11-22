/// Çizgi düzeyinde geri al / yinele yığını (saf Dart).
///
/// Bir eylem, bir sayfadaki çizgi kümesinin eklenmesi ya da silinmesidir.
/// Geri al: eklenenleri yumuşak siler, silinenleri geri getirir. Yinele tersi.
/// Yeni eylem yinele yığınını boşaltır.
library;

enum InkActionKind { added, erased }

class InkAction {
  const InkAction(this.kind, this.page, this.strokeIds);
  final InkActionKind kind;
  final int page;
  final List<String> strokeIds;
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
    if (a.strokeIds.isEmpty) return;
    _undo.add(a);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// Geri alınacak eylemi yığından çıkarıp döner (yinele yığınına koymak
  /// [commitUndo] ile, işlem başarılıysa).
  InkAction? takeUndo() => _undo.isEmpty ? null : _undo.removeLast();
  void commitUndo(InkAction a) => _redo.add(a);

  InkAction? takeRedo() => _redo.isEmpty ? null : _redo.removeLast();
  void commitRedo(InkAction a) => _undo.add(a);
}
