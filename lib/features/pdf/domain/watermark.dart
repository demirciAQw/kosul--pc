/// Şeffaf, açık renkli filigranı render edilmiş piksellerden kaldırır (saf Dart).
///
/// PDF dosyası değişmez: bu işlem yalnızca GÖRÜNTÜLEME içindir. Tipik durum:
/// beyaz zemin + koyu metin + üstünde açık gri (ya da açık renkli) saydam yazı/logo.
///
/// Kurallar:
/// - Koyu piksellere (parlaklık < alt sınır - yumuşaklık) ve onlara KOMŞU
///   piksellere (anti-alias kenarı) dokunulmaz; metin pikselleri aynen kalır.
/// - Filigran ağırlığı `w` pikselin parlaklığına (ton ± aralık) ve renk tonuna
///   (gri filigranda düşük doygunluk, renkli filigranda hue aralığı) göre yumuşak
///   eşikle hesaplanır; `out = lerp(piksel, beyaz, güç * w)`.
/// - Zemin rengi beyaz kabul edilir (PDF beyaz zeminde çizilir).
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Piksel dizisinde kanal sırası (PDFium BGRA verir).
enum PixelOrder { rgba, bgra }

/// Piksel dikdörtgeni (sağ/alt dışarıda).
class PixelRect {
  const PixelRect(this.left, this.top, this.right, this.bottom);
  final int left, top, right, bottom;
  int get width => right - left;
  int get height => bottom - top;
}

/// Filigran temizleme ayarı. JSON'a yazılır (`pdf_page_layers.params`).
class WatermarkParams {
  const WatermarkParams({
    this.tone = 215,
    this.toneRange = 30,
    this.strength = 1.0,
    this.hue,
    this.hueRange = 30,
  });

  /// Filigranın parlaklık merkezi (0..255).
  final double tone;

  /// Ton aralığı: merkezin iki yanındaki yarı genişlik (parlaklık birimi).
  final double toneRange;

  /// 0..1; 0 = hiçbir şey değişmez.
  final double strength;

  /// Renkli filigranda renk tonu (derece 0..360); null = gri/renksiz.
  final double? hue;
  final double hueRange;

  /// Parlaklığı bunun altındaki pikseller (yumuşaklık payıyla) metin sayılır.
  static const minTone = 120.0;

  WatermarkParams copyWith({double? tone, double? toneRange, double? strength, double? hue, bool clearHue = false, double? hueRange}) =>
      WatermarkParams(
        tone: tone ?? this.tone,
        toneRange: toneRange ?? this.toneRange,
        strength: strength ?? this.strength,
        hue: clearHue ? null : (hue ?? this.hue),
        hueRange: hueRange ?? this.hueRange,
      );

  Map<String, Object?> toJson() => {
        'tone': tone,
        'toneRange': toneRange,
        'strength': strength,
        if (hue != null) 'hue': hue,
        'hueRange': hueRange,
      };

  factory WatermarkParams.fromJson(Map<String, Object?> j) {
    double d(String k, double def) => (j[k] is num) ? (j[k] as num).toDouble() : def;
    return WatermarkParams(
      tone: d('tone', 215).clamp(0, 255).toDouble(),
      toneRange: d('toneRange', 30).clamp(0, 128).toDouble(),
      strength: d('strength', 1).clamp(0, 1).toDouble(),
      hue: j['hue'] is num ? (j['hue'] as num).toDouble() : null,
      hueRange: d('hueRange', 30).clamp(0, 180).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WatermarkParams &&
      other.tone == tone &&
      other.toneRange == toneRange &&
      other.strength == strength &&
      other.hue == hue &&
      other.hueRange == hueRange;

  @override
  int get hashCode => Object.hash(tone, toneRange, strength, hue, hueRange);
}

const _edgeDark = 150; // tespitte "koyu" sayılan parlaklık
const _soft = 20.0; // metin eşiğindeki yumuşak geçiş (parlaklık birimi)
const _grayChroma = 24; // bunun altı "renksiz" (gri filigran)
const _grayChromaSoft = 30;

int _lum(int r, int g, int b) => (r * 77 + g * 150 + b * 29) >> 8;

double _smooth(double t) {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  return t * t * (3 - 2 * t);
}

double _hueOf(int r, int g, int b) {
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final d = (mx - mn).toDouble();
  if (d == 0) return 0;
  double h;
  if (mx == r) {
    h = ((g - b) / d) % 6;
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  h *= 60;
  return h < 0 ? h + 360 : h;
}

double _hueDist(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

PixelRect _clampRect(PixelRect? r, int w, int h) {
  if (r == null) return PixelRect(0, 0, w, h);
  return PixelRect(
    r.left.clamp(0, w), r.top.clamp(0, h), r.right.clamp(0, w), r.bottom.clamp(0, h));
}

/// Bölgedeki filigranı otomatik bulur; belirgin bir filigran yoksa null.
/// Açık ama beyaz olmayan tonların histogramında baskın tepe = filigran tonu.
WatermarkParams? detectWatermark(
  Uint8List px,
  int width,
  int height, {
  PixelRect? region,
  PixelOrder order = PixelOrder.rgba,
}) {
  final rc = _clampRect(region, width, height);
  if (rc.width <= 0 || rc.height <= 0) return null;
  final ri = order == PixelOrder.rgba ? 0 : 2, bi = order == PixelOrder.rgba ? 2 : 0;
  final bins = List<int>.filled(256, 0);
  var counted = 0;
  // Koyu piksele komşu (anti-alias kenarı) pikseller sayılmaz: metin kenarı filigran sanılmasın.
  bool nearDark(int x, int y) {
    for (var dy = -1; dy <= 1; dy++) {
      final yy = y + dy;
      if (yy < 0 || yy >= height) continue;
      for (var dx = -1; dx <= 1; dx++) {
        final xx = x + dx;
        if (xx < 0 || xx >= width) continue;
        final j = (yy * width + xx) * 4;
        if (_lum(px[j + ri], px[j + 1], px[j + bi]) < _edgeDark) return true;
      }
    }
    return false;
  }

  for (var y = rc.top; y < rc.bottom; y++) {
    var i = (y * width + rc.left) * 4;
    for (var x = rc.left; x < rc.right; x++, i += 4) {
      if (px[i + 3] == 0) continue;
      final l = _lum(px[i + ri], px[i + 1], px[i + bi]);
      if (l < 250 && l >= 120 && nearDark(x, y)) continue;
      counted++;
      bins[l]++;
    }
  }
  if (counted == 0) return null;
  // 170..250 aralığında 9 genişlikli kayan toplam; en yüksek tepe.
  var bestC = -1, bestSum = 0;
  for (var c = 174; c <= 246; c++) {
    var s = 0;
    for (var k = -4; k <= 4; k++) {
      s += bins[c + k];
    }
    if (s > bestSum) {
      bestSum = s;
      bestC = c;
    }
  }
  // Tepe yeterince büyük (piksellerin %0,5'i) ve çevresindeki tabanın en az 3 katı olmalı.
  if (bestC < 0 || bestSum < counted * 0.005) return null;
  final lo = math.max(170, bestC - 40), hi = math.min(250, bestC + 40);
  var total = 0, n = 0;
  for (var l = lo; l <= hi; l++) {
    total += bins[l];
    n++;
  }
  final avg9 = total / n * 9;
  if (bestSum < avg9 * 2.5) return null;
  // Tepenin yarı genişliği: tepe kutusunun %25'ine düşene dek.
  var top = bestC;
  for (var l = bestC - 4; l <= bestC + 4; l++) {
    if (bins[l] > bins[top]) top = l;
  }
  final peak = bins[top];
  var a = top, b = top;
  while (a > 120 && bins[a - 1] * 4 >= peak) {
    a--;
  }
  while (b < 250 && bins[b + 1] * 4 >= peak) {
    b++;
  }
  final range = ((b - a) / 2 + 6).clamp(10, 50).toDouble();
  final tone = ((a + b) / 2).clamp(150, 245).toDouble();
  // Renk: penceredeki piksellerin çoğu renkliyse hue (dairesel ortalama).
  var chromatic = 0, inWin = 0;
  double sx = 0, sy = 0;
  for (var y = rc.top; y < rc.bottom; y++) {
    var i = (y * width + rc.left) * 4;
    for (var x = rc.left; x < rc.right; x++, i += 4) {
      final r = px[i + ri], g = px[i + 1], bl = px[i + bi];
      final l = _lum(r, g, bl);
      if ((l - tone).abs() > range || nearDark(x, y)) continue;
      inWin++;
      final ch = math.max(r, math.max(g, bl)) - math.min(r, math.min(g, bl));
      if (ch >= 20) {
        chromatic++;
        final h = _hueOf(r, g, bl) * math.pi / 180;
        sx += math.cos(h);
        sy += math.sin(h);
      }
    }
  }
  double? hue;
  if (inWin > 0 && chromatic * 2 > inWin) {
    var deg = math.atan2(sy, sx) * 180 / math.pi;
    if (deg < 0) deg += 360;
    hue = deg;
  }
  return WatermarkParams(tone: tone, toneRange: range, strength: 1, hue: hue, hueRange: 30);
}

/// Filigranı kaldırır; girdiyi değiştirmez, yeni dizi döner (alfa aynen).
/// [region] (piksel) verilirse yalnız orası işlenir.
Uint8List removeWatermark(
  Uint8List px,
  int width,
  int height,
  WatermarkParams p, {
  PixelRect? region,
  PixelOrder order = PixelOrder.rgba,
}) {
  final out = Uint8List.fromList(px);
  final rc = _clampRect(region, width, height);
  if (p.strength <= 0 || rc.width <= 0 || rc.height <= 0) return out;
  final ri = order == PixelOrder.rgba ? 0 : 2, bi = order == PixelOrder.rgba ? 2 : 0;
  final lo = math.max(p.tone - p.toneRange, WatermarkParams.minTone);
  final darkCut = lo - _soft;

  // Bölge + 1 piksel kenar için parlaklık ve "koyu" maskesi.
  final x0 = math.max(0, rc.left - 1), y0 = math.max(0, rc.top - 1);
  final x1 = math.min(width, rc.right + 1), y1 = math.min(height, rc.bottom + 1);
  final mw = x1 - x0, mh = y1 - y0;
  final dark = Uint8List(mw * mh);
  for (var y = 0; y < mh; y++) {
    var i = ((y + y0) * width + x0) * 4;
    final row = y * mw;
    for (var x = 0; x < mw; x++, i += 4) {
      if (_lum(px[i + ri], px[i + 1], px[i + bi]) < darkCut) dark[row + x] = 1;
    }
  }
  // 3x3 genişletme (ayrılabilir): metin kenarındaki anti-alias pikselleri korunur.
  final h1 = Uint8List(mw * mh);
  for (var y = 0; y < mh; y++) {
    final row = y * mw;
    for (var x = 0; x < mw; x++) {
      if (dark[row + x] == 1 || (x > 0 && dark[row + x - 1] == 1) || (x + 1 < mw && dark[row + x + 1] == 1)) {
        h1[row + x] = 1;
      }
    }
  }
  final protectedMask = Uint8List(mw * mh);
  for (var y = 0; y < mh; y++) {
    for (var x = 0; x < mw; x++) {
      final k = y * mw + x;
      if (h1[k] == 1 || (y > 0 && h1[k - mw] == 1) || (y + 1 < mh && h1[k + mw] == 1)) protectedMask[k] = 1;
    }
  }

  final hue = p.hue;
  for (var y = rc.top; y < rc.bottom; y++) {
    var i = (y * width + rc.left) * 4;
    final mrow = (y - y0) * mw - x0;
    for (var x = rc.left; x < rc.right; x++, i += 4) {
      if (protectedMask[mrow + x] == 1) continue;
      final r = px[i + ri], g = px[i + 1], b = px[i + bi];
      final l = _lum(r, g, b);
      if (l >= 255) continue;
      var w = _smooth((l - darkCut) / _soft);
      if (w == 0) continue;
      final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      if (hue == null) {
        w *= 1 - _smooth((chroma - _grayChroma) / _grayChromaSoft);
      } else {
        if (chroma < 8) {
          w = 0;
        } else {
          final d = _hueDist(_hueOf(r, g, b), hue);
          w *= 1 - _smooth((d - p.hueRange) / 20);
        }
      }
      if (w <= 0) continue;
      final t = p.strength * w;
      out[i + ri] = (r + (255 - r) * t).round();
      out[i + 1] = (g + (255 - g) * t).round();
      out[i + bi] = (b + (255 - b) * t).round();
    }
  }
  return out;
}

/// [removeWatermark] ayrı iş parçacığında (ana iş parçacığı donmasın).
/// Girdi baytları kopyalanır; sonuç yeni dizidir.
Future<Uint8List> removeWatermarkInIsolate(
  Uint8List px,
  int width,
  int height,
  WatermarkParams p, {
  PixelRect? region,
  PixelOrder order = PixelOrder.rgba,
}) =>
    Isolate.run(() => removeWatermark(px, width, height, p, region: region, order: order));

/// [detectWatermark] ayrı iş parçacığında.
Future<WatermarkParams?> detectWatermarkInIsolate(
  Uint8List px,
  int width,
  int height, {
  PixelRect? region,
  PixelOrder order = PixelOrder.rgba,
}) =>
    Isolate.run(() => detectWatermark(px, width, height, region: region, order: order));
