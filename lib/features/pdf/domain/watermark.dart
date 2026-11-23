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
    this.toneRange = 20,
    this.strength = 1.0,
    this.hue,
    this.hueRange = 30,
    this.chroma,
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

  /// Renkli filigranın ortalama doygunluğu (max-min kanal); null = doygunluk sınırlanmaz.
  final double? chroma;

  /// Parlaklığı bunun altındaki pikseller (yumuşaklık payıyla) metin sayılır.
  static const minTone = 120.0;

  WatermarkParams copyWith({double? tone, double? toneRange, double? strength, double? hue, bool clearHue = false, double? hueRange, double? chroma}) =>
      WatermarkParams(
        tone: tone ?? this.tone,
        toneRange: toneRange ?? this.toneRange,
        strength: strength ?? this.strength,
        hue: clearHue ? null : (hue ?? this.hue),
        hueRange: hueRange ?? this.hueRange,
        chroma: clearHue ? null : (chroma ?? this.chroma),
      );

  Map<String, Object?> toJson() => {
        'tone': tone,
        'toneRange': toneRange,
        'strength': strength,
        if (hue != null) 'hue': hue,
        'hueRange': hueRange,
        if (chroma != null) 'chroma': chroma,
      };

  factory WatermarkParams.fromJson(Map<String, Object?> j) {
    double d(String k, double def) => (j[k] is num) ? (j[k] as num).toDouble() : def;
    return WatermarkParams(
      tone: d('tone', 215).clamp(0, 255).toDouble(),
      toneRange: d('toneRange', 20).clamp(0, 128).toDouble(),
      strength: d('strength', 1).clamp(0, 1).toDouble(),
      hue: j['hue'] is num ? (j['hue'] as num).toDouble() : null,
      hueRange: d('hueRange', 30).clamp(0, 180).toDouble(),
      chroma: j['chroma'] is num ? (j['chroma'] as num).toDouble() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WatermarkParams &&
      other.tone == tone &&
      other.toneRange == toneRange &&
      other.strength == strength &&
      other.hue == hue &&
      other.hueRange == hueRange &&
      other.chroma == chroma;

  @override
  int get hashCode => Object.hash(tone, toneRange, strength, hue, hueRange, chroma);
}

const _edgeDark = 150; // tespitte "koyu" sayılan parlaklık
const _soft = 20.0; // metin eşiğindeki yumuşak geçiş (parlaklık birimi)
const _softHi = 10.0; // bandın üst kenarındaki yumuşak geçiş
const _grayChroma = 12; // bunun altı "renksiz" (gri filigran)
const _grayChromaSoft = 14;

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
  // Bant DAR tutulur; kullanıcı Ton aralığı sürgüsüyle genişletir.
  final range = ((b - a) / 2 + 3).clamp(8, 40).toDouble();
  final tone = ((a + b) / 2).clamp(150, 245).toDouble();
  // Renk: penceredeki piksellerin çoğu renkliyse hue (dairesel ortalama).
  var chromatic = 0, inWin = 0;
  double sx = 0, sy = 0, chromaSum = 0;
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
        chromaSum += ch;
        final h = _hueOf(r, g, bl) * math.pi / 180;
        sx += math.cos(h);
        sy += math.sin(h);
      }
    }
  }
  double? hue, chroma;
  if (inWin > 0 && chromatic * 2 > inWin) {
    chroma = chromaSum / chromatic;
    var deg = math.atan2(sy, sx) * 180 / math.pi;
    if (deg < 0) deg += 360;
    hue = deg;
  }
  return WatermarkParams(tone: tone, toneRange: range, strength: 1, hue: hue, hueRange: 30, chroma: chroma);
}

/// 1B çizgi (başlangıç, adet, adım) üzerinde 1'lerin ardışık dizilerini işler.
/// [erode]: [2r+1]'den uzun dizinin iç kısmı 1; değilse dizi her yana [r] genişler.
void _line(Uint8List src, Uint8List dst, int start, int count, int stride, int r, bool erode) {
  var i = 0;
  while (i < count) {
    if (src[start + i * stride] == 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < count && src[start + j * stride] == 1) {
      j++;
    }
    // [i, j) bir dizi
    if (erode) {
      for (var k = i + r; k <= j - 1 - r; k++) {
        dst[start + k * stride] = 1;
      }
    } else {
      for (var k = math.max(0, i - r); k <= math.min(count - 1, j - 1 + r); k++) {
        dst[start + k * stride] = 1;
      }
    }
    i = j;
  }
}

/// Maskenin açılması: (2r+1) kare sığan her yer (geniş dolgu alanı).
Uint8List _opening(Uint8List m, int w, int h, int r) {
  Uint8List pass(Uint8List src, bool horizontal, bool erode) {
    final dst = Uint8List(w * h);
    if (horizontal) {
      for (var y = 0; y < h; y++) {
        _line(src, dst, y * w, w, 1, r, erode);
      }
    } else {
      for (var x = 0; x < w; x++) {
        _line(src, dst, x, h, w, r, erode);
      }
    }
    return dst;
  }

  return pass(pass(pass(pass(m, true, true), false, true), true, false), false, false);
}

/// Uzun ve ince (cetvel/ızgara) çizgi pikselleri: bir yönde [longLen]'den uzun,
/// dik yönde [thin]'den ince 1'ler dizisi.
Uint8List _rulings(Uint8List m, int w, int h, int longLen, int thin) {
  // bit0: yatay uzun, bit1: yatay ince, bit2: dikey uzun, bit3: dikey ince
  final f = Uint8List(w * h);
  void scan(int start, int count, int stride, int longBit, int thinBit) {
    var i = 0;
    while (i < count) {
      if (m[start + i * stride] == 0) {
        i++;
        continue;
      }
      var j = i;
      while (j < count && m[start + j * stride] == 1) {
        j++;
      }
      final len = j - i;
      final bits = (len >= longLen ? longBit : 0) | (len <= thin ? thinBit : 0);
      if (bits != 0) {
        for (var k = i; k < j; k++) {
          f[start + k * stride] |= bits;
        }
      }
      i = j;
    }
  }

  for (var y = 0; y < h; y++) {
    scan(y * w, w, 1, 1, 2);
  }
  for (var x = 0; x < w; x++) {
    scan(x, h, w, 4, 8);
  }
  final out = Uint8List(w * h);
  for (var k = 0; k < out.length; k++) {
    final b = f[k];
    // yatay uzun + dikey ince, dikey uzun + yatay ince, ya da kesişim (iki yönde de uzun)
    if ((b & 1 != 0 && b & 8 != 0) || (b & 4 != 0 && b & 2 != 0) || (b & 1 != 0 && b & 4 != 0)) out[k] = 1;
  }
  return out;
}

/// Filigranı kaldırır; girdiyi değiştirmez, yeni dizi döner (alfa aynen).
/// [region] (piksel) verilirse yalnız orası işlenir.
///
/// Filigran DAR bir ton bandıdır (`tone ± toneRange`, iki yandan yumuşak eşik);
/// bandın dışındaki açık ya da koyu içerik korunur. Bandın içinde de şunlara
/// dokunulmaz:
/// - koyu piksel ve komşuları (metin); çözünürlük düştükçe "koyu" eşiği yükselir
///   (ince metin düşük çözünürlükte grileşir; önizleme ile hedef sonuç tutarlı kalsın),
/// - geniş dolgu: banda düşen piksellerin açılması (yan uzunluğu sayfa genişliğinin
///   ~%4'ü olan kare sığan yerler). Bundan kalın filigran harfleri de dolgu sayılır;
///   o durumda Ton aralığı ile bant daraltılıp bölge seçilebilir,
/// - uzun ve çok ince (~1-2 px @700 px) yatay/dikey çizgiler (ızgara, cetvel),
/// - renk: gri filigranda renkli (doygun) pikseller; renkli filigranda hue ve
///   (varsa) doygunluk uzaklığı.
///
/// [pxPerUnit]: pikselin PDF birimi karşılığı (sayfa ~595 birim); verilmezse
/// görüntü tam sayfa sayılır. Çözünürlüğe bağlı eşikler bundan türetilir.
Uint8List removeWatermark(
  Uint8List px,
  int width,
  int height,
  WatermarkParams p, {
  PixelRect? region,
  PixelOrder order = PixelOrder.rgba,
  double? pxPerUnit,
}) {
  final out = Uint8List.fromList(px);
  final rc = _clampRect(region, width, height);
  if (p.strength <= 0 || rc.width <= 0 || rc.height <= 0) return out;
  final ri = order == PixelOrder.rgba ? 0 : 2, bi = order == PixelOrder.rgba ? 2 : 0;
  // Sayfa genişliği (piksel) eşdeğeri: çözünürlüğe bağlı eşikler.
  final pw = (pxPerUnit ?? width / 595.0) * 595.0;
  final lo = math.max(p.tone - p.toneRange, WatermarkParams.minTone);
  final hi = p.tone + p.toneRange;
  final boost = ((1700 - pw) / 1000 * 15).clamp(0.0, 15.0);
  final rampCut = lo - _soft; // ağırlık yükselmeye başlar
  final darkCut = rampCut + boost; // koruma maskesi eşiği (düşük çözünürlükte yüksek)
  final hue = p.hue;

  /// Bant + renk ağırlığı (0..1); koruma maskeleri hariç.
  double weightOf(int r, int g, int b) {
    final l = _lum(r, g, b);
    if (l >= 255) return 0;
    var w = _smooth((l - rampCut) / _soft) * (1 - _smooth((l - hi) / _softHi));
    if (w == 0) return 0;
    final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    if (hue == null) {
      w *= 1 - _smooth((chroma - _grayChroma) / _grayChromaSoft);
    } else if (chroma < 8) {
      return 0;
    } else {
      w *= 1 - _smooth((_hueDist(_hueOf(r, g, b), hue) - p.hueRange) / 20);
      final c0 = p.chroma;
      if (c0 != null) {
        final tol = math.max(10.0, c0 * 0.5);
        w *= 1 - _smooth(((chroma - c0).abs() - tol) / 12);
      }
    }
    return w;
  }

  // Bölge + 1 piksel kenar için "koyu" maskesi.
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

  // Dolgu ve ince çizgi korumaları (bölge içinde; yerel indeks).
  final rw = rc.width, rh = rc.height;
  final inb = Uint8List(rw * rh);
  var any = false;
  for (var y = 0; y < rh; y++) {
    var i = ((y + rc.top) * width + rc.left) * 4;
    for (var x = 0; x < rw; x++, i += 4) {
      if (protectedMask[(y + rc.top - y0) * mw + (x + rc.left - x0)] == 1) continue;
      if (weightOf(px[i + ri], px[i + 1], px[i + bi]) >= 0.5) {
        inb[y * rw + x] = 1;
        any = true;
      }
    }
  }
  if (!any) return out;
  final r = math.max(3, (pw * 0.02).round());
  final fill = (2 * r + 1 <= math.min(rw, rh)) ? _opening(inb, rw, rh, r) : null;
  final thin = math.max(2, (2 * pw / 700).round());
  final longLen = math.max(12, (pw * 0.04).round());
  final ruling = _rulings(inb, rw, rh, longLen, thin);

  for (var y = rc.top; y < rc.bottom; y++) {
    var i = (y * width + rc.left) * 4;
    final mrow = (y - y0) * mw - x0;
    final lrow = (y - rc.top) * rw - rc.left;
    for (var x = rc.left; x < rc.right; x++, i += 4) {
      if (protectedMask[mrow + x] == 1) continue;
      if (ruling[lrow + x] == 1 || (fill != null && fill[lrow + x] == 1)) continue;
      final pr = px[i + ri], pg = px[i + 1], pb = px[i + bi];
      final w = weightOf(pr, pg, pb);
      if (w <= 0) continue;
      final t = p.strength * w;
      out[i + ri] = (pr + (255 - pr) * t).round();
      out[i + 1] = (pg + (255 - pg) * t).round();
      out[i + bi] = (pb + (255 - pb) * t).round();
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
  double? pxPerUnit,
}) =>
    Isolate.run(() => removeWatermark(px, width, height, p, region: region, order: order, pxPerUnit: pxPerUnit));

/// [detectWatermark] ayrı iş parçacığında.
Future<WatermarkParams?> detectWatermarkInIsolate(
  Uint8List px,
  int width,
  int height, {
  PixelRect? region,
  PixelOrder order = PixelOrder.rgba,
}) =>
    Isolate.run(() => detectWatermark(px, width, height, region: region, order: order));
