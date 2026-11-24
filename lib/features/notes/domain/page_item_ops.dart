import 'dart:math' as math;

import 'page_board.dart';
import 'page_item_geometry.dart';

/// Sayfa öğesi işlemleri (saf Dart): dönmüş kutuda isabet, dönmüş kutuyu yeniden
/// boyutlandırma, açı yakalama. Tüm koordinatlar not birimidir; açı radyandır ve
/// kutu merkezi çevresinde saat yönünde artar (ekran koordinatı, y aşağı).

/// Noktayı kutunun YEREL (döndürülmemiş) çerçevesine çevirir.
({double x, double y}) toItemLocal(BoardRect r, double rotation, double px, double py) {
  final dx = px - r.cx, dy = py - r.cy;
  final c = math.cos(-rotation), s = math.sin(-rotation);
  return (x: r.cx + dx * c - dy * s, y: r.cy + dx * s + dy * c);
}

/// Kutunun YEREL çerçevesindeki noktayı sayfa koordinatına çevirir.
({double x, double y}) fromItemLocal(BoardRect r, double rotation, double lx, double ly) {
  final dx = lx - r.cx, dy = ly - r.cy;
  final c = math.cos(rotation), s = math.sin(rotation);
  return (x: r.cx + dx * c - dy * s, y: r.cy + dx * s + dy * c);
}

/// [px],[py] dönmüş kutunun içinde mi ([slop]: her yandan ek pay).
bool hitRotatedRect(BoardRect r, double rotation, double px, double py, {double slop = 0}) {
  final l = toItemLocal(r, rotation, px, py);
  return l.x >= r.x - slop && l.x <= r.right + slop && l.y >= r.y - slop && l.y <= r.bottom + slop;
}

/// Noktanın altındaki en üstteki öğe (liste alttan üste sıralıdır: son eleman üstte);
/// yoksa null. Bilinmeyen türdeki öğe (`kind == null`) görmezden gelinir.
PageItemRecord? hitTestItems(List<PageItemRecord> bottomToTop, double px, double py, {double slop = 0}) {
  for (var i = bottomToTop.length - 1; i >= 0; i--) {
    final it = bottomToTop[i];
    if (it.kind == null || it.deleted) continue;
    if (hitRotatedRect(it.rect, it.rotation, px, py, slop: slop)) return it;
  }
  return null;
}

/// Tutamacın ([handle]) dünya koordinatında ([dx], [dy]) kadar sürüklenmesiyle oluşan
/// yeni kutu. Döndürülmemiş kutuda [resizeItemRect] ile aynıdır. Dönmüşte karşı köşe
/// (kenar tutamacında karşı kenarın ortası) SAYFADA yerinde kalır; sonuç merkezi sayfa
/// içinde ve boyutu sayfayı aşmayacak biçimde kırpılır.
BoardRect resizeRotatedRect(
  BoardRect r,
  double rotation,
  ResizeHandle handle,
  double dx,
  double dy, {
  bool keepAspect = false,
  double minSize = minItemSize,
  double? pageW,
  double? pageH,
}) {
  if (rotation == 0) {
    return resizeItemRect(r, handle, dx, dy, keepAspect: keepAspect, minSize: minSize, pageW: pageW, pageH: pageH);
  }
  final c = math.cos(-rotation), s = math.sin(-rotation);
  final nr = resizeItemRect(r, handle, dx * c - dy * s, dx * s + dy * c, keepAspect: keepAspect, minSize: minSize);
  final moveL = handle == ResizeHandle.topLeft || handle == ResizeHandle.left || handle == ResizeHandle.bottomLeft;
  final moveR = handle == ResizeHandle.topRight || handle == ResizeHandle.right || handle == ResizeHandle.bottomRight;
  final moveT = handle == ResizeHandle.topLeft || handle == ResizeHandle.top || handle == ResizeHandle.topRight;
  final moveB = handle == ResizeHandle.bottomLeft || handle == ResizeHandle.bottom || handle == ResizeHandle.bottomRight;
  // Sabit kalan nokta (eski ve yeni kutuda aynı mantıksal nokta).
  double fixX(BoardRect b) => moveL ? b.right : (moveR ? b.x : b.cx);
  double fixY(BoardRect b) => moveT ? b.bottom : (moveB ? b.y : b.cy);
  final p = fromItemLocal(r, rotation, fixX(r), fixY(r));
  final oc = math.cos(rotation), os = math.sin(rotation);
  final ox = fixX(nr) - nr.cx, oy = fixY(nr) - nr.cy;
  var cx = p.x - (ox * oc - oy * os);
  var cy = p.y - (ox * os + oy * oc);
  var w = nr.w, h = nr.h;
  if (pageW != null && pageH != null) {
    final k = math.min(1.0, math.min(pageW / w, pageH / h));
    if (k < 1) {
      w *= k;
      h *= k;
    }
    cx = cx.clamp(0.0, pageW).toDouble();
    cy = cy.clamp(0.0, pageH).toDouble();
  }
  return BoardRect(cx - w / 2, cy - h / 2, w, h);
}

/// Döndürme tutamacı için açı: merkezden ([px],[py]) noktasına bakış, "yukarı" 0 sayılır
/// (tutamaç kutunun üstündedir). [snap] derecenin katlarına [snapTolerance] derece içinde
/// yapışır (varsayılan 15° katları, 3° tolerans); sonuç (-pi, pi].
double rotationFromPoint(BoardRect r, double px, double py, {double snapStep = 15, double snapTolerance = 3}) {
  var a = math.atan2(py - r.cy, px - r.cx) + math.pi / 2;
  return snapAngle(a, snapStep: snapStep, snapTolerance: snapTolerance);
}

/// [a] radyanını [snapStep] derecenin en yakın katına, [snapTolerance] derece içindeyse
/// çeker; (-pi, pi] aralığına getirir.
double snapAngle(double a, {double snapStep = 15, double snapTolerance = 3}) {
  var d = a * 180 / math.pi;
  d = (d + 180) % 360;
  if (d < 0) d += 360;
  d -= 180;
  if (snapStep > 0) {
    final nearest = (d / snapStep).round() * snapStep;
    if ((d - nearest).abs() <= snapTolerance) d = nearest.toDouble();
  }
  if (d <= -180) d += 360;
  return d * math.pi / 180;
}

/// Görünür alanın (not birimi, [vx],[vy],[vw],[vh]) ortasına [w] x [h] kutu yerleştirir;
/// kutu görünür alanın [fraction]'ından büyükse oranla küçülür; sayfaya sığdırılır.
BoardRect placeInVisible(
  double w,
  double h,
  double vx,
  double vy,
  double vw,
  double vh,
  double pageW,
  double pageH, {
  double fraction = 0.6,
}) {
  var ww = w, hh = h;
  final k = math.min(1.0, math.min(vw * fraction / ww, vh * fraction / hh));
  if (k > 0 && k < 1) {
    ww *= k;
    hh *= k;
  }
  return clampItemRect(BoardRect(vx + vw / 2 - ww / 2, vy + vh / 2 - hh / 2, ww, hh), pageW, pageH);
}
