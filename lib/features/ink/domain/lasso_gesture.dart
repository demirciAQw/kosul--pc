/// Kement seçiminin tutamaçları ve sürükleme dönüşümü (saf Dart).
///
/// Tutamaçlar seçim sınır kutusunun 4 köşesi ve 4 kenar ortası; üstte bir döndürme
/// tutamacı. Köşe: orantılı boyutlandırma (karşı köşe sabit). Kenar: tek eksende
/// uzatma. Gövde: taşıma. Ölçek asla ters dönmez ve sıfıra inmez.
library;

import 'dart:math' as math;

import 'ink_object.dart';
import 'lasso.dart';

enum LassoHandle { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotate, body }

/// Tutamak merkezi (sayfa birimi); [body] için merkez.
({double x, double y}) handlePosition(InkRect b, LassoHandle h, {double rotateOffset = 28}) => switch (h) {
  LassoHandle.topLeft => (x: b.left, y: b.top),
  LassoHandle.top => (x: b.centerX, y: b.top),
  LassoHandle.topRight => (x: b.right, y: b.top),
  LassoHandle.right => (x: b.right, y: b.centerY),
  LassoHandle.bottomRight => (x: b.right, y: b.bottom),
  LassoHandle.bottom => (x: b.centerX, y: b.bottom),
  LassoHandle.bottomLeft => (x: b.left, y: b.bottom),
  LassoHandle.left => (x: b.left, y: b.centerY),
  LassoHandle.rotate => (x: b.centerX, y: b.top - rotateOffset),
  LassoHandle.body => (x: b.centerX, y: b.centerY),
};

/// Kenar ortası tutamacı, kutu o yönde ince ise (örn. tek satır yazı) gövdenin ortasını
/// örter ve taşımayı engeller; bu durumda kapalıdır (köşe tutamaçları açık kalır).
bool isHandleUsable(InkRect b, LassoHandle h, {required double tol}) => switch (h) {
  LassoHandle.top || LassoHandle.bottom => b.height >= 4 * tol,
  LassoHandle.left || LassoHandle.right => b.width >= 4 * tol,
  _ => true,
};

/// (x, y) noktasındaki tutamak; yoksa null. [tol] tutamak yarı boyutu (sayfa birimi).
/// Önce tutamaklar (döndürme, köşe, kenar), sonra gövde.
LassoHandle? hitLassoHandle(InkRect b, double x, double y, {required double tol, double rotateOffset = 28}) {
  const order = [
    LassoHandle.rotate,
    LassoHandle.topLeft,
    LassoHandle.topRight,
    LassoHandle.bottomRight,
    LassoHandle.bottomLeft,
    LassoHandle.top,
    LassoHandle.right,
    LassoHandle.bottom,
    LassoHandle.left,
  ];
  for (final h in order) {
    if (!isHandleUsable(b, h, tol: tol)) continue;
    final p = handlePosition(b, h, rotateOffset: rotateOffset);
    if ((x - p.x).abs() <= tol && (y - p.y).abs() <= tol) return h;
  }
  return b.contains(x, y) ? LassoHandle.body : null;
}

/// Bir sürüklemenin dönüşümü. [bounds] sürükleme başındaki sınır kutusu,
/// ([startX],[startY]) tutulan nokta. Özgün çizgiler her seferinde [apply]'a verilir
/// (ardışık uygulamada hata birikmez).
class LassoDrag {
  LassoDrag(this.handle, this.bounds, this.startX, this.startY);

  final LassoHandle handle;
  final InkRect bounds;
  final double startX, startY;

  /// Ölçek sınırı: kutu bu orandan küçülmez.
  static const minRatio = 0.02;

  List<InkObject> apply(List<InkObject> originals, double x, double y) {
    final b = bounds;
    switch (handle) {
      case LassoHandle.body:
        return [for (final s in originals) translateObject(s, x - startX, y - startY)];
      case LassoHandle.rotate:
        final a0 = math.atan2(startY - b.centerY, startX - b.centerX);
        final a1 = math.atan2(y - b.centerY, x - b.centerX);
        final d = a1 - a0;
        if (!d.isFinite) return originals;
        return [for (final s in originals) rotateObject(s, d, b.centerX, b.centerY)];
      default:
        return resizeSelection(originals, b, _targetRect(x, y), keepAspect: _isCorner);
    }
  }

  bool get _isCorner =>
      handle == LassoHandle.topLeft ||
      handle == LassoHandle.topRight ||
      handle == LassoHandle.bottomLeft ||
      handle == LassoHandle.bottomRight;

  InkRect _targetRect(double x, double y) {
    final b = bounds;
    final w = math.max(b.width, 1e-6), h = math.max(b.height, 1e-6);
    final left = handle == LassoHandle.topLeft || handle == LassoHandle.bottomLeft || handle == LassoHandle.left;
    final right = handle == LassoHandle.topRight || handle == LassoHandle.bottomRight || handle == LassoHandle.right;
    final top = handle == LassoHandle.topLeft || handle == LassoHandle.topRight || handle == LassoHandle.top;
    final bottom = handle == LassoHandle.bottomLeft || handle == LassoHandle.bottomRight || handle == LassoHandle.bottom;
    // Karşı kenar(lar) sabit; sürüklenen kenar noktaya gider (ters dönmeden).
    double nw = w, nh = h;
    if (right) nw = x - b.left;
    if (left) nw = b.right - x;
    if (bottom) nh = y - b.top;
    if (top) nh = b.bottom - y;
    var rx = nw / w, ry = nh / h;
    if (_isCorner) {
      final k = math.max(math.max(rx, ry), minRatio);
      rx = k;
      ry = k;
    } else {
      rx = math.max(rx, minRatio);
      ry = math.max(ry, minRatio);
    }
    final tw = (left || right) ? w * rx : w, th = (top || bottom) ? h * ry : h;
    final fw = _isCorner ? w * rx : tw, fh = _isCorner ? h * ry : th;
    final l = left ? b.right - fw : b.left;
    final t = top ? b.bottom - fh : b.top;
    return InkRect(l, t, l + fw, t + fh);
  }
}

/// Seçimi (kopyala/yapıştır) [dx],[dy] kadar kaydırılmış kopyalar; kimlikler değişmez.
List<InkObject> offsetObjects(List<InkObject> src, double dx, double dy) => [
  for (final s in src) translateObject(s, dx, dy),
];
