/// Çizgi nesneleri kümesi üzerinde geri al / yinele (saf Dart, arayüzden bağımsız).
library;

import 'ink_object.dart';

enum InkCommandKind { add, remove, transform, split }

class _Entry {
  _Entry(this.kind, this.before, this.after);
  final InkCommandKind kind;
  final List<InkObject> before;
  final List<InkObject> after;
}

/// Her komut öncesi/sonrası listeyi (değişmez nesne başvuruları) tutar;
/// z-sırası geri alınınca da korunur.
class InkCommandStack {
  InkCommandStack({
    List<InkObject> initial = const [],
    this.maxDepth = 100,
  }) : _objects = List.of(initial);

  final int maxDepth;
  List<InkObject> _objects;
  final List<_Entry> _undo = [];
  final List<_Entry> _redo = [];

  List<InkObject> get objects => List.unmodifiable(_objects);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _commit(InkCommandKind kind, List<InkObject> next) {
    _undo.add(_Entry(kind, _objects, next));
    if (_undo.length > maxDepth) _undo.removeAt(0);
    _redo.clear();
    _objects = next;
  }

  void add(Iterable<InkObject> items) {
    final list = items.toList();
    if (list.isEmpty) return;
    _commit(InkCommandKind.add, [..._objects, ...list]);
  }

  /// Kimliği verilenleri siler. Silinen yoksa komut eklenmez; döner: silinen sayısı.
  int remove(Iterable<String> ids) {
    final set = ids.toSet();
    final next = [
      for (final o in _objects)
        if (!set.contains(o.id)) o,
    ];
    final n = _objects.length - next.length;
    if (n > 0) _commit(InkCommandKind.remove, next);
    return n;
  }

  /// Verilen kimlikli nesneleri [fn] ile dönüştürür (taşı, ölçekle, döndür).
  void transform(Iterable<String> ids, InkObject Function(InkObject) fn) {
    final set = ids.toSet();
    var any = false;
    final next = [
      for (final o in _objects)
        if (set.contains(o.id)) (() { any = true; return fn(o); })() else o,
    ];
    if (any) _commit(InkCommandKind.transform, next);
  }

  /// [id] nesnesini [pieces] ile değiştirir (alan silgisi); boşsa nesne silinir.
  /// Parçalar eski nesnenin z-sırasında durur.
  void split(String id, List<InkObject> pieces) {
    final i = _objects.indexWhere((o) => o.id == id);
    if (i < 0) return;
    final next = [..._objects]..replaceRange(i, i + 1, pieces);
    _commit(InkCommandKind.split, next);
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    final e = _undo.removeLast();
    _redo.add(e);
    _objects = e.before;
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final e = _redo.removeLast();
    _undo.add(e);
    _objects = e.after;
    return true;
  }
}
