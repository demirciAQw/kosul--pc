import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/pdf/domain/watermark.dart';

/// Sentetik sayfa: beyaz zemin, koyu "metin" blokları (kenarda anti-alias pikselleri),
/// üstünde açık gri diyagonal şeffaf filigran.
class _Img {
  _Img(this.w, this.h, {int r = 255, int g = 255, int b = 255})
      : px = Uint8List(w * h * 4) {
    for (var i = 0; i < w * h; i++) {
      px[i * 4] = r;
      px[i * 4 + 1] = g;
      px[i * 4 + 2] = b;
      px[i * 4 + 3] = 255;
    }
  }
  final int w, h;
  final Uint8List px;

  void set(int x, int y, int r, int g, int b) {
    final i = (y * w + x) * 4;
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
  }

  List<int> at(int x, int y) {
    final i = (y * w + x) * 4;
    return [px[i], px[i + 1], px[i + 2], px[i + 3]];
  }

  /// Koyu metin bloğu + 1 piksel anti-alias çerçeve (açık gri 200).
  void text(int x0, int y0, int x1, int y1) {
    for (var y = y0 - 1; y <= y1; y++) {
      for (var x = x0 - 1; x <= x1; x++) {
        final inside = x >= x0 && x < x1 && y >= y0 && y < y1;
        if (inside) {
          set(x, y, 10, 10, 10);
        } else {
          set(x, y, 200, 200, 200);
        }
      }
    }
  }

  /// Diyagonal 6 piksel kalınlığında bant, verilen renkte.
  void diagonal(int r, int g, int b, {int thick = 6}) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (((x - y) % 40).abs() < thick) {
          final i = (y * w + x) * 4;
          // Yalnız beyaz zeminin üstüne (metin üstüne saydam binmiş gibi koyuya dokunma).
          if (px[i] == 255 && px[i + 1] == 255 && px[i + 2] == 255) set(x, y, r, g, b);
        }
      }
    }
  }
}

_Img _page() {
  final im = _Img(200, 200);
  im.text(20, 20, 80, 30);
  im.text(20, 60, 120, 66);
  im.text(100, 140, 180, 150);
  return im;
}

/// Test görüntüleri küçük; gerçek sayfa çözünürlüğünü (yüksek) simüle eder.
Uint8List _rm(Uint8List px, int w, int h, WatermarkParams p, {PixelRect? region, PixelOrder order = PixelOrder.rgba, double pxPerUnit = 3}) =>
    removeWatermark(px, w, h, p, region: region, order: order, pxPerUnit: pxPerUnit);

int _lum(List<int> c) => (c[0] * 77 + c[1] * 150 + c[2] * 29) >> 8;

void main() {
  test('gri diyagonal filigran kalkar; metin ve kenarı AYNEN kalır', () {
    final im = _page()..diagonal(215, 215, 215);
    final p = detectWatermark(im.px, im.w, im.h)!;
    expect(p.tone, inInclusiveRange(205, 225));
    expect(p.hue, isNull);
    final out = _rm(im.px, im.w, im.h, p);
    var wmLeft = 0, wmSeen = 0;
    for (var y = 0; y < im.h; y++) {
      for (var x = 0; x < im.w; x++) {
        final a = im.at(x, y), b = [for (var k = 0; k < 4; k++) out[(y * im.w + x) * 4 + k]];
        if (_lum(a) < 120 || (a[0] == 200 && a[1] == 200 && a[2] == 200)) {
          expect(b, a, reason: 'metin/kenar ($x,$y) değişmemeli'); // koyu piksel ve anti-alias kenar
        } else if (a[0] == 215) {
          wmSeen++;
          if (b[0] < 250) wmLeft++;
        }
      }
    }
    expect(wmSeen, greaterThan(1000));
    expect(wmLeft, 0, reason: 'metne komşu olmayan filigran piksellerinin hepsi beyaz olmalı');
    expect(im.px[3], 255); // girdi bozulmadı
  });

  test('filigran metne değiyorsa komşu pikseller korunur (metin kenarı pürüzlenmez)', () {
    final im = _Img(60, 20);
    im.text(20, 5, 40, 15);
    // Metnin hemen yanında (komşu olmayan) gri filigran şeridi.
    for (var y = 0; y < 20; y++) {
      for (var x = 44; x < 56; x++) {
        im.set(x, y, 215, 215, 215);
      }
    }
    final out = _rm(im.px, im.w, im.h, const WatermarkParams());
    // x=40 sütunu: anti-alias kenar (200) aynen.
    expect(out[(10 * 60 + 40) * 4], 200);
    // x=44 (metinden 4 piksel uzak) temizlendi.
    expect(out[(10 * 60 + 44) * 4], 255);
  });

  test('renkli (açık kırmızı) filigran: ton aralığıyla kalkar; gri modda dokunulmaz', () {
    final im = _page()..diagonal(255, 200, 200);
    final grayMode = _rm(im.px, im.w, im.h, const WatermarkParams());
    // Gri ayarıyla renkli filigran kalır (yalnız renksiz tonlar silinir).
    expect(grayMode.sublist(0, 4 * im.w * 3), im.px.sublist(0, 4 * im.w * 3));
    final p = detectWatermark(im.px, im.w, im.h)!;
    expect(p.hue, isNotNull);
    expect(p.hue!, anyOf(lessThan(15), greaterThan(345)));
    final out = _rm(im.px, im.w, im.h, p);
    var left = 0;
    for (var y = 0; y < im.h; y++) {
      for (var x = 0; x < im.w; x++) {
        final a = im.at(x, y);
        if (a[0] == 255 && a[1] == 200 && out[(y * im.w + x) * 4 + 1] < 250) left++;
      }
    }
    expect(left, 0);
    // Mavi bir açık leke (başka ton) kırmızı aralığın dışında kalır.
    final blue = _page()..diagonal(200, 200, 255);
    final o2 = _rm(blue.px, blue.w, blue.h, p);
    var changed = 0;
    for (var i = 0; i < o2.length; i++) {
      if (o2[i] != blue.px[i]) changed++;
    }
    expect(changed, 0);
  });

  test('filigran yok: tespit null, görüntü DEĞİŞMEZ', () {
    final im = _page();
    expect(detectWatermark(im.px, im.w, im.h), isNull);
    for (final p in const [WatermarkParams(), WatermarkParams(tone: 200, toneRange: 50)]) {
      expect(_rm(im.px, im.w, im.h, p), im.px);
    }
  });

  test('güç 0 = değişmez; güç 0.5 = yarı yolda', () {
    final im = _page()..diagonal(215, 215, 215);
    expect(_rm(im.px, im.w, im.h, const WatermarkParams(strength: 0)), im.px);
    // (x - y) % 40 < 6 → (6, 0) bant üzerinde.
    final half = _rm(im.px, im.w, im.h, const WatermarkParams(strength: 0.5));
    final v = half[5 * 4]; // (x=5,y=0) bant üstü
    expect(v, inInclusiveRange(230, 240)); // 215 -> ~235
  });

  test('uç durumlar: tam beyaz ve tam siyah aynen kalır; alfa korunur', () {
    final white = _Img(32, 32);
    final black = _Img(32, 32, r: 0, g: 0, b: 0);
    for (final im in [white, black]) {
      expect(detectWatermark(im.px, im.w, im.h), isNull);
      expect(_rm(im.px, im.w, im.h, const WatermarkParams()), im.px);
    }
    final a = _page()..diagonal(215, 215, 215);
    a.px[3] = 77;
    final out = _rm(a.px, a.w, a.h, const WatermarkParams());
    expect(out[3], 77);
  });

  test('yumuşak eşik: parlaklık arttıkça çıktı azalmaz ve girdiden koyu olmaz', () {
    final im = _Img(156, 12); // 1 px yüksek şerit "cetvel" sayılırdı: 12 satır
    for (var y = 0; y < 12; y++) {
      for (var x = 0; x < 156; x++) {
        im.set(x, y, 100 + x, 100 + x, 100 + x);
      }
    }
    // Koyu piksellerin yanındaki korumayı aşmak için ayrı satırlar yerine uzun gradyan kullanırız:
    final out = _rm(im.px, im.w, im.h, const WatermarkParams(toneRange: 40));
    var prev = 0;
    for (var x = 0; x < 156; x++) {
      final o = out[x * 4];
      expect(o, greaterThanOrEqualTo(im.px[x * 4]));
      expect(o, greaterThanOrEqualTo(prev - 0), reason: 'x=$x');
      prev = o;
    }
    expect(out[0], 100); // koyu: aynen
  });

  test('bölge: yalnız bölge içi temizlenir', () {
    final im = _Img(100, 40)..diagonal(215, 215, 215);
    final out = _rm(im.px, im.w, im.h, const WatermarkParams(), region: const PixelRect(0, 0, 50, 40));
    var leftHalf = 0, rightChanged = 0;
    for (var y = 0; y < 40; y++) {
      for (var x = 0; x < 100; x++) {
        final i = (y * 100 + x) * 4;
        if (x < 50 && im.px[i] == 215 && out[i] != 255) leftHalf++;
        if (x >= 50 && out[i] != im.px[i]) rightChanged++;
      }
    }
    expect(leftHalf, 0);
    expect(rightChanged, 0);
    // Taşan bölge sınırlanır, tersi/boş bölge değişmez.
    expect(_rm(im.px, 100, 40, const WatermarkParams(), region: const PixelRect(60, 10, 60, 30)), im.px);
    expect(() => _rm(im.px, 100, 40, const WatermarkParams(), region: const PixelRect(-50, -50, 500, 500)), returnsNormally);
  });

  test('BGRA sırası RGBA ile aynı sonucu verir', () {
    final im = _page()..diagonal(255, 200, 200);
    final bgra = Uint8List.fromList(im.px);
    for (var i = 0; i < bgra.length; i += 4) {
      final t = bgra[i];
      bgra[i] = bgra[i + 2];
      bgra[i + 2] = t;
    }
    final p = detectWatermark(im.px, im.w, im.h)!;
    final pb = detectWatermark(bgra, im.w, im.h, order: PixelOrder.bgra)!;
    expect(pb, p);
    final o1 = _rm(im.px, im.w, im.h, p);
    final o2 = _rm(bgra, im.w, im.h, p, order: PixelOrder.bgra);
    for (var i = 0; i < o1.length; i += 4) {
      expect([o2[i + 2], o2[i + 1], o2[i]], [o1[i], o1[i + 1], o1[i + 2]]);
    }
  });

  test('parametreler JSON gidiş-dönüş; bozuk değerler güvenli sınırlanır', () {
    const p = WatermarkParams(tone: 190, toneRange: 22, strength: 0.7, hue: 120, hueRange: 40);
    expect(WatermarkParams.fromJson(p.toJson()), p);
    final bad = WatermarkParams.fromJson({'tone': 'x', 'strength': 9, 'hueRange': -4});
    expect((bad.tone, bad.strength, bad.hueRange), (215.0, 1.0, 0.0));
  });

  test('Isolate sürümü eşzamanlıyla aynı sonucu verir', () async {
    final im = _page()..diagonal(215, 215, 215);
    const p = WatermarkParams();
    expect(await removeWatermarkInIsolate(im.px, im.w, im.h, p, pxPerUnit: 3), _rm(im.px, im.w, im.h, p));
    expect(await detectWatermarkInIsolate(im.px, im.w, im.h), detectWatermark(im.px, im.w, im.h));
  });

  test('büyük görüntüde süre makul (4 Mpx)', () async {
    final im = _Img(2000, 2000);
    im.text(100, 100, 900, 130);
    im.diagonal(215, 215, 215);
    final sw = Stopwatch()..start();
    final out = await removeWatermarkInIsolate(im.px, im.w, im.h, const WatermarkParams());
    sw.stop();
    expect(out.length, im.px.length);
    expect(sw.elapsedMilliseconds, lessThan(8000));
  });

  group('korunması gereken gerçek içerik (güç 1, varsayılan ton bandı)', () {
    // 700 px genişlik = düşük çözünürlük kovası (pxPerUnit verilmez: tam sayfa sayılır).
    void rect(_Img im, int x0, int y0, int x1, int y1, int r, int g, int b) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          im.set(x, y, r, g, b);
        }
      }
    }

    int changedIn(_Img im, Uint8List out, int x0, int y0, int x1, int y1) {
      var n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = (y * im.w + x) * 4;
          if (out[i] != im.px[i] || out[i + 1] != im.px[i + 1] || out[i + 2] != im.px[i + 2]) n++;
        }
      }
      return n;
    }

    final wm = const WatermarkParams(); // 215 ± 20

    test('açık gri tablo dolgusu, krem kutu ve soluk mavi dolgu değişmez', () {
      final im = _Img(700, 400);
      rect(im, 20, 20, 220, 100, 215, 215, 215); // gri tablo dolgusu
      rect(im, 240, 20, 440, 100, 232, 232, 232); // daha açık gri
      rect(im, 460, 20, 660, 100, 250, 245, 225); // krem zemin kutusu
      rect(im, 20, 120, 220, 200, 200, 220, 250); // soluk mavi dolgu
      final out = removeWatermark(im.px, im.w, im.h, wm);
      expect(changedIn(im, out, 0, 0, 700, 400), 0);
    });

    test('1 px gri ızgara çizgileri ve ince koyu metin değişmez', () {
      final im = _Img(700, 400);
      for (var x = 0; x < 700; x++) {
        im.set(x, 150, 204, 204, 204);
        im.set(x, 250, 215, 215, 215);
      }
      for (var y = 0; y < 400; y++) {
        im.set(300, y, 210, 210, 210);
      }
      // ince koyu metin: 2 px kalınlığında kısa çizgiler
      for (var k = 0; k < 10; k++) {
        rect(im, 40 + k * 12, 300, 42 + k * 12, 330, 20, 20, 20);
      }
      final out = removeWatermark(im.px, im.w, im.h, wm);
      expect(changedIn(im, out, 0, 0, 700, 400), 0);
    });

    test('aynı sayfada filigran kalkar, tablo dolgusu ve ızgara kalır', () {
      final im = _Img(700, 400);
      rect(im, 20, 20, 220, 100, 215, 215, 215);
      for (var x = 0; x < 700; x++) {
        im.set(x, 150, 204, 204, 204);
      }
      // filigran: kalın olmayan diyagonal şerit (genişlik 8), tablo ve ızgara dışında
      var wmPx = 0;
      for (var y = 160; y < 400; y++) {
        for (var x = 0; x < 700; x++) {
          if (((x - y) % 60).abs() < 8 && im.at(x, y)[0] == 255) {
            im.set(x, y, 215, 215, 215);
            wmPx++;
          }
        }
      }
      final out = removeWatermark(im.px, im.w, im.h, wm);
      expect(changedIn(im, out, 20, 20, 220, 100), 0);
      expect(changedIn(im, out, 0, 150, 700, 151), 0);
      var left = 0;
      for (var y = 160; y < 400; y++) {
        for (var x = 0; x < 700; x++) {
          final i = (y * 700 + x) * 4;
          if (im.px[i] == 215 && out[i] < 250) left++;
        }
      }
      expect(wmPx, greaterThan(5000));
      expect(left, 0);
    });

    test('renkli filigran modu: başka renkli ve başka doygunluktaki içerik korunur', () {
      final im = _Img(700, 400);
      rect(im, 20, 20, 220, 100, 255, 205, 205); // büyük açık kırmızı dolgu (dolgu koruması)
      rect(im, 260, 20, 460, 100, 200, 220, 250); // mavi dolgu (hue)
      for (var y = 120; y < 400; y++) {
        for (var x = 0; x < 700; x++) {
          if (((x - y) % 60).abs() < 8) im.set(x, y, 255, 205, 205); // kırmızı filigran
          if (((x + y) % 97).abs() < 7 && y > 300) im.set(x, y, 205, 235, 205); // yeşil ince çizgiler
        }
      }
      final p = detectWatermark(im.px, im.w, im.h, region: const PixelRect(0, 110, 700, 400))!;
      expect(p.hue, isNotNull);
      expect(p.chroma, isNotNull);
      final out = removeWatermark(im.px, im.w, im.h, p);
      expect(changedIn(im, out, 20, 20, 220, 100), 0, reason: 'geniş dolgu');
      expect(changedIn(im, out, 260, 20, 460, 100), 0, reason: 'başka hue');
      // kırmızı filigran temizlendi
      var red = 0, redLeft = 0, greenChanged = 0;
      for (var y = 120; y < 300; y++) {
        for (var x = 0; x < 700; x++) {
          final a = im.at(x, y);
          if (a[0] == 255 && a[1] == 205 && ((x - y) % 60).abs() < 8) {
            red++;
            if (out[(y * 700 + x) * 4 + 1] < 250) redLeft++;
          }
        }
      }
      for (var y = 300; y < 400; y++) {
        for (var x = 0; x < 700; x++) {
          final a = im.at(x, y);
          if (a[1] == 235 && a[0] == 205) {
            final i = (y * 700 + x) * 4;
            if (out[i] != 205) greenChanged++;
          }
        }
      }
      expect(red, greaterThan(1000));
      expect(redLeft, 0);
      expect(greenChanged, 0);
    });

    test('düşük ve yüksek çözünürlük aynı sonucu verir (ince metin silinmez, filigran kalkar)', () {
      Uint8List page(int w) {
        final k = w / 700.0;
        final im = _Img(w, (400 * k).round());
        // ince koyu metin: 1.5 birim kalınlık, filigranla kesişen
        for (var i = 0; i < 12; i++) {
          rect(im, (40 * k + i * 14 * k).round(), (50 * k).round(), (40 * k + i * 14 * k + 1.5 * k).round(), (90 * k).round(), 30, 30, 30);
        }
        for (var y = 0; y < im.h; y++) {
          for (var x = 0; x < w; x++) {
            if (y > 120 * k && ((x - y) % (70 * k).round()).abs() < 6 * k && im.at(x, y)[0] == 255) {
              im.set(x, y, 215, 215, 215);
            }
          }
        }
        return im.px;
      }

      for (final w in [700, 1400, 2800]) {
        final px = page(w);
        final h = px.length ~/ 4 ~/ w;
        final out = removeWatermark(px, w, h, wm);
        final k = w / 700.0;
        var textTotal = 0, textKept = 0, wmTotal = 0, wmLeft = 0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            if (y < 100 * k && px[i] == 30) {
              textTotal++;
              if (out[i] == 30) textKept++;
            } else if (px[i] == 215) {
              wmTotal++;
              if (out[i] > 250) {
                // temizlendi
              } else {
                wmLeft++;
              }
            }
          }
        }
        expect(textKept, textTotal, reason: 'metin w=$w');
        expect(wmTotal, greaterThan(500));
        expect(wmLeft / wmTotal, lessThan(0.02), reason: 'filigran w=$w');
      }
    });

    test('önizleme (küçültülmüş) ince metni silmez: kutu ortalamalı küçültme', () {
      // 1400 px sayfa -> 700 px: 2x2 ortalama; 2 px'lik koyu çizgi 1 px'te 30 ile 143 arası kalır.
      final hi = _Img(1400, 400);
      for (var i = 0; i < 12; i++) {
        rect(hi, 80 + i * 28, 100, 82 + i * 28, 180, 30, 30, 30);
        rect(hi, 81 + i * 28 + 14, 100, 82 + i * 28 + 14, 180, 30, 30, 30); // 1 px'lik çizgi: yarım piksel kayık
      }
      final lo = _Img(700, 200);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 700; x++) {
          var s = 0;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              s += hi.at(x * 2 + dx, y * 2 + dy)[0];
            }
          }
          final v = s ~/ 4;
          lo.set(x, y, v, v, v);
        }
      }
      final out = removeWatermark(lo.px, 700, 200, wm);
      var lost = 0;
      for (var i = 0; i < lo.px.length; i += 4) {
        if (lo.px[i] < 200 && out[i] != lo.px[i]) lost++;
      }
      expect(lost, 0);
    });
  });
}
