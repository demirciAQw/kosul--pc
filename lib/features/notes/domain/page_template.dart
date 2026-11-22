/// Defter sayfası şablonları ve çizgi konumları (saf Dart, T6).
///
/// Koordinatlar not koordinatındadır (sayfa genişliği/yüksekliği ile aynı birim).
enum PageTemplate {
  plain('plain'),
  ruled('ruled'),
  grid('grid');

  const PageTemplate(this.key);
  final String key;

  /// Bilinmeyen anahtar (yeni sürümden gelen) düz sayfa sayılır.
  static PageTemplate fromKey(String? key) =>
      PageTemplate.values.where((t) => t.key == key).firstOrNull ?? PageTemplate.plain;
}

/// Şablonun yatay (y değerleri) ve dikey (x değerleri) çizgileri.
class TemplateLines {
  const TemplateLines({this.horizontal = const [], this.vertical = const []});
  final List<double> horizontal;
  final List<double> vertical;

  bool get isEmpty => horizontal.isEmpty && vertical.isEmpty;
}

/// Sayfa genişliğine göre varsayılan aralık: genişliğin 1/25'i (1404 için ~56).
double defaultTemplateSpacing(double pageWidth) => pageWidth / 25;

/// [template] için çizgi konumları.
/// - düz: çizgi yok.
/// - çizgili: ilk çizgi iki aralık aşağıda (üst boşluk), sonuncusu alttan en az
///   bir aralık yukarıda; yalnızca yatay.
/// - kareli: sayfa her iki yönde ortalanır (kenar boşlukları eşit), kenarlara
///   çizgi çizilmez; hem yatay hem dikey.
/// [spacing] verilmezse [defaultTemplateSpacing]. Genişlik, yükseklik ya da
/// aralık pozitif değilse [ArgumentError].
TemplateLines templateLines(PageTemplate template, double width, double height, {double? spacing}) {
  if (!(width > 0) || !(height > 0)) throw ArgumentError('Sayfa boyutu pozitif olmalı: $width x $height');
  final step = spacing ?? defaultTemplateSpacing(width);
  if (!(step > 0)) throw ArgumentError.value(spacing, 'spacing', 'Aralık pozitif olmalı');
  switch (template) {
    case PageTemplate.plain:
      return const TemplateLines();
    case PageTemplate.ruled:
      final ys = <double>[];
      for (var y = step * 2; y <= height - step + 1e-9; y += step) {
        ys.add(y);
      }
      return TemplateLines(horizontal: ys);
    case PageTemplate.grid:
      return TemplateLines(horizontal: _centered(height, step), vertical: _centered(width, step));
  }
}

/// [length] içinde [step] aralıklı, uçlardaki boşluklar eşit, kenarlara değmeyen konumlar.
List<double> _centered(double length, double step) {
  final n = (length / step).floor();
  if (n < 1) return const [];
  final offset = (length - n * step) / 2;
  final out = <double>[];
  for (var i = 0; i <= n; i++) {
    final v = offset + i * step;
    if (v > 1e-9 && v < length - 1e-9) out.add(v);
  }
  return out;
}
