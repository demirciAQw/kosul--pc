/// Defter akışının (sayfalar alt alta) saf yerleşimi: sayfa üst konumları, toplam
/// yükseklik, görünen aralık ve "son sayfanın dibine yaklaştı" kararı. Flutter'a bağlı değil.
class FlowLayout {
  FlowLayout(
    List<({double w, double h})> pages, {
    required double width,
    this.gap = 12,
    this.endHeight = 120,
  }) : heights = [for (final p in pages) p.w <= 0 ? 0.0 : width * p.h / p.w],
       tops = [] {
    var y = 0.0;
    for (final h in heights) {
      tops.add(y);
      y += h + gap;
    }
    total = y + endHeight;
  }

  /// Sayfalar arası boşluk (içerik pikseli).
  final double gap;

  /// Akışın sonundaki "Yeni sayfa" kartının alanı.
  final double endHeight;
  final List<double> heights;
  final List<double> tops;

  /// Tüm içerik yüksekliği (son kart dahil).
  late final double total;

  int get count => heights.length;

  /// Sonraki "Yeni sayfa" kartının üst konumu.
  double get endTop => count == 0 ? 0 : tops.last + heights.last + gap;

  /// [y] noktasının ait olduğu sayfa (boşluk üstteki sayfaya sayılır); sınırlara kırpılır, boşsa -1.
  int indexAt(double y) {
    if (count == 0) return -1;
    if (y <= 0) return 0;
    var lo = 0, hi = count - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// [top]..[bottom] (içerik koordinatı) aralığına değen sayfalar, her yandan [margin]
  /// sayfa fazla (kalem katmanları/oturumlar yalnız bunlar için canlı tutulur).
  ({int first, int last}) visibleRange(double top, double bottom, {int margin = 1}) {
    if (count == 0) return (first: 0, last: -1);
    var first = indexAt(top);
    var last = indexAt(bottom);
    // Üst sınır sayfa dışındaysa (boşluk) bile en yakın sayfa alınır; margin yine eklenir.
    first = (first - margin).clamp(0, count - 1);
    last = (last + margin).clamp(0, count - 1);
    return (first: first, last: last);
  }
}

/// Son çizginin alt kenarı [strokeBottom] sayfanın alt [fraction] kısmında mı
/// (yeni sayfa önerisi için). Sonsuz sayfa kendiliğinden uzar: çağıran onu göndermez.
bool flowNearEnd(double strokeBottom, double pageHeight, {double fraction = 0.15}) =>
    pageHeight > 0 && strokeBottom >= pageHeight * (1 - fraction);
