/// Not sayfasındaki tek çizgi nesnesi (saf Dart; silgi, kement, geri al bunu kullanır).
library;

import 'ink_models.dart';

class InkObject {
  const InkObject({
    required this.id,
    required this.points,
    this.brush = const InkBrush(),
  });

  final String id;
  final List<InkPoint> points;
  final InkBrush brush;

  double get halfWidth => brush.width / 2;

  InkObject copyWith({String? id, List<InkPoint>? points, InkBrush? brush}) =>
      InkObject(
        id: id ?? this.id,
        points: points ?? this.points,
        brush: brush ?? this.brush,
      );
}

/// Eksenlere paralel dikdörtgen.
class InkRect {
  const InkRect(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  InkRect union(InkRect o) => InkRect(
    left < o.left ? left : o.left,
    top < o.top ? top : o.top,
    right > o.right ? right : o.right,
    bottom > o.bottom ? bottom : o.bottom,
  );

  @override
  bool operator ==(Object other) =>
      other is InkRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'InkRect($left, $top, $right, $bottom)';
}
