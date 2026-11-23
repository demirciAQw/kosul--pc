import 'dart:math' as math;

import '../../sync/domain/media_rules.dart';
import 'page_board.dart';

/// Sayfa öğesi (metin kutusu/görsel) geometrisi ve görsel yolu kuralları (saf Dart, v23).
/// Döndürme yok sayılır: çerçeve döndürülmemiş kutu olarak ele alınır.

/// Öğenin en küçük kenarı (not birimi).
const minItemSize = 24.0;

/// [r]'yi sayfa sınırlarına ([pageW] x [pageH]) sığdırır: sayfadan büyükse küçültür,
/// dışarı taşıyorsa içeri kaydırır. Kenarlar en az [minSize] kalır (sayfa daha küçükse sayfa kadar).
BoardRect clampItemRect(BoardRect r, double pageW, double pageH, {double minSize = minItemSize}) {
  final w = r.w.isNaN ? minSize : r.w.clamp(math.min(minSize, pageW), pageW).toDouble();
  final h = r.h.isNaN ? minSize : r.h.clamp(math.min(minSize, pageH), pageH).toDouble();
  final x = (r.x.isNaN ? 0.0 : r.x).clamp(0.0, pageW - w).toDouble();
  final y = (r.y.isNaN ? 0.0 : r.y).clamp(0.0, pageH - h).toDouble();
  return BoardRect(x, y, w, h);
}

enum ResizeHandle { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

/// Tutamacı ([dx], [dy]) kadar sürükleyince oluşan yeni kutu. Karşı köşe/kenar sabit
/// kalır; kenarlar [minSize]'ın altına inmez (ters çevrilmez). [keepAspect]: köşe
/// tutamaçlarında oran korunur (görseller). [pageW]/[pageH] verilirse sonuç sayfaya sığar.
BoardRect resizeItemRect(
  BoardRect r,
  ResizeHandle handle,
  double dx,
  double dy, {
  double minSize = minItemSize,
  bool keepAspect = false,
  double? pageW,
  double? pageH,
}) {
  var left = r.x, top = r.y, right = r.right, bottom = r.bottom;
  final moveL = handle == ResizeHandle.topLeft || handle == ResizeHandle.left || handle == ResizeHandle.bottomLeft;
  final moveR = handle == ResizeHandle.topRight || handle == ResizeHandle.right || handle == ResizeHandle.bottomRight;
  final moveT = handle == ResizeHandle.topLeft || handle == ResizeHandle.top || handle == ResizeHandle.topRight;
  final moveB = handle == ResizeHandle.bottomLeft || handle == ResizeHandle.bottom || handle == ResizeHandle.bottomRight;
  if (moveL) left = math.min(left + dx, right - minSize);
  if (moveR) right = math.max(right + dx, left + minSize);
  if (moveT) top = math.min(top + dy, bottom - minSize);
  if (moveB) bottom = math.max(bottom + dy, top + minSize);

  final corner = (moveL || moveR) && (moveT || moveB);
  if (keepAspect && corner && r.w > 0 && r.h > 0) {
    final ratio = r.w / r.h;
    var w = right - left;
    var h = bottom - top;
    // Büyük değişimi izle: daha çok değişen eksen oranı belirler.
    if ((w - r.w).abs() / r.w >= (h - r.h).abs() / r.h) {
      h = math.max(w / ratio, minSize);
      w = h * ratio;
    } else {
      w = math.max(h * ratio, minSize);
      h = w / ratio;
    }
    if (w < minSize) {
      w = minSize;
      h = w / ratio;
    }
    if (moveL) {
      left = right - w;
    } else {
      right = left + w;
    }
    if (moveT) {
      top = bottom - h;
    } else {
      bottom = top + h;
    }
  }
  var out = BoardRect(left, top, right - left, bottom - top);
  if (pageW != null && pageH != null) {
    if (keepAspect && corner && (out.w > pageW || out.h > pageH)) {
      final k = math.min(pageW / out.w, pageH / out.h);
      final w = out.w * k, h = out.h * k;
      out = BoardRect(moveL ? out.right - w : out.x, moveT ? out.bottom - h : out.y, w, h);
    }
    out = clampItemRect(out, pageW, pageH, minSize: minSize);
  }
  return out;
}

/// Görseli en uzun kenarı [maxSide]'ı geçmeyecek biçimde oranı koruyarak küçültür
/// (büyütmez). Dönüş (genişlik, yükseklik) piksel; en az 1.
({int w, int h}) fitWithin(int w, int h, {int maxSide = 2048}) {
  if (w <= 0 || h <= 0) return (w: math.max(w, 1), h: math.max(h, 1));
  final longest = math.max(w, h);
  if (longest <= maxSide) return (w: w, h: h);
  final k = maxSide / longest;
  return (w: math.max(1, (w * k).round()), h: math.max(1, (h * k).round()));
}

/// Yeni öğenin başlangıç kutusu: görsel oranına göre, sayfanın en çok yarısı genişlikte,
/// sayfa merkezinde.
BoardRect defaultImageRect(int pxW, int pxH, double pageW, double pageH) {
  final ratio = pxW > 0 && pxH > 0 ? pxW / pxH : 1.0;
  var w = pageW / 2;
  var h = w / ratio;
  if (h > pageH / 2) {
    h = pageH / 2;
    w = h * ratio;
  }
  return BoardRect((pageW - w) / 2, (pageH - h) / 2, w, h);
}

final _fileId = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
final _ext = RegExp(r'^[a-z0-9]{1,8}$');

/// Sayfa görseli göreli yolu: `notes/yyyy/mm/<id>.<uzantı>` (kablosuz aktarım kuralına
/// uyar; yeniden icat edilmedi: `isTransferableMediaPath`). Uzantı küçük harf, noktasız;
/// geçersizse [ArgumentError].
String pageImagePath(DateTime now, String id, String ext) {
  final e = ext.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (!_fileId.hasMatch(id)) throw ArgumentError('Geçersiz dosya kimliği: $id');
  if (!_ext.hasMatch(e)) throw ArgumentError('Geçersiz uzantı: $ext');
  final path = 'notes/${now.year.toString().padLeft(4, '0')}/${now.month.toString().padLeft(2, '0')}/$id.$e';
  if (!isPageImagePath(path)) throw ArgumentError('Geçersiz görsel yolu: $path');
  return path;
}

/// Sayfa görseli yolu geçerli mi: yalnızca `notes/` kovası ve aktarım kuralı.
bool isPageImagePath(String path) => path.startsWith('notes/') && isTransferableMediaPath(path);
