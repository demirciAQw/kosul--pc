/// Kalem türleri, baskı eğrisi, renk paleti ve kalınlık seviyeleri (saf Dart).
library;

import 'dart:math' as math;

enum PenKind { ballpoint, fountain, pencil, highlighter }

enum PenCap { round, square, butt }

class PenProfile {
  const PenProfile({
    required this.kind,
    required this.minFactor,
    required this.maxFactor,
    required this.opacity,
    required this.cap,
    this.multiply = false,
    this.pressureSensitive = true,
  });

  final PenKind kind;

  /// Baskı 0 iken ve 1 iken taban kalınlığın çarpanı.
  final double minFactor;
  final double maxFactor;

  /// 0..1 saydamlık (fosforlu için düşük).
  final double opacity;
  final PenCap cap;

  /// Fosforlu: yazının üstüne çarpma (multiply) karışımıyla biner.
  final bool multiply;
  final bool pressureSensitive;

  /// Baskıyı (0..1) ve sertliği (0..1) kalınlığa çevirir.
  ///
  /// Sertlik 0 = yumuşak (hafif baskı hemen kalınlaşır), 1 = sert (baskı
  /// geç etki eder). Baskı arttıkça kalınlık azalmaz (monoton).
  double widthAt(double baseWidth, double pressure, {double hardness = 0.5}) {
    final f = pressureFactor(pressure, hardness);
    return baseWidth * (minFactor + (maxFactor - minFactor) * f);
  }
}

/// 0..1 baskıdan 0..1 etkiye: p^gamma, gamma = 2^((sertlik-0.5)*2) (0.5..2).
double pressureFactor(double pressure, double hardness) {
  final p = pressure.clamp(0.0, 1.0);
  final h = hardness.clamp(0.0, 1.0);
  final gamma = math.pow(2, (h - 0.5) * 2).toDouble();
  return math.pow(p, gamma).toDouble();
}

/// [pressureFactor]'ün tersi: biçimlenmiş baskıdan ham baskıya.
double pressureUnfactor(double shaped, double hardness) {
  final s = shaped.clamp(0.0, 1.0);
  final h = hardness.clamp(0.0, 1.0);
  final gamma = math.pow(2, (h - 0.5) * 2).toDouble();
  return math.pow(s, 1 / gamma).toDouble();
}

const penProfiles = <PenKind, PenProfile>{
  PenKind.ballpoint: PenProfile(
    kind: PenKind.ballpoint,
    minFactor: 0.85,
    maxFactor: 1.15,
    opacity: 1,
    cap: PenCap.round,
  ),
  PenKind.fountain: PenProfile(kind: PenKind.fountain, minFactor: 0.4, maxFactor: 1.6, opacity: 1, cap: PenCap.round),
  PenKind.pencil: PenProfile(kind: PenKind.pencil, minFactor: 0.6, maxFactor: 1.3, opacity: 0.8, cap: PenCap.round),
  PenKind.highlighter: PenProfile(
    kind: PenKind.highlighter,
    minFactor: 1,
    maxFactor: 1,
    opacity: 0.35,
    cap: PenCap.square,
    multiply: true,
    pressureSensitive: false,
  ),
};

/// YKS için sade renk paleti (ARGB).
const penPalette = <int>[
  0xFF1B1B1F, // siyah
  0xFF5F6368, // gri
  0xFF1A56DB, // mavi
  0xFF0B8A8A, // turkuaz
  0xFF188038, // yeşil
  0xFF8E24AA, // mor
  0xFFD93025, // kırmızı
  0xFFE8710A, // turuncu
  0xFF8D6E63, // kahve
  0xFFE91E8C, // pembe
];

/// Fosforlu için sade renkler.
const highlighterPalette = <int>[
  0xFFFFEB3B, // sarı
  0xFF8BC34A, // yeşil
  0xFFFF80AB, // pembe
  0xFFFFAB40, // turuncu
  0xFF40C4FF, // mavi
];

/// Fosforlunun varsayılan kalınlığı (bant yüksekliği, mantıksal piksel).
const highlighterDefaultWidth = 18.0;

/// Fosforlu uç: dar kenar / geniş kenar oranı (kesik uç; yatay çekince bant [width] yüksekliğinde).
const highlighterTipRatio = 0.35;

/// Silgi yarıçapı sınırları ve hazır boyutları (görünüm pikseli).
const eraserRadiusMin = 8.0;
const eraserRadiusMax = 60.0;
const eraserRadiusDefault = 16.0;
const eraserRadiusLevels = <double>[8, 16, 28, 44];

/// Silgi yarıçapını sınırlar; sonlu olmayan değer varsayılana döner.
double clampEraserRadius(double r) =>
    r.isFinite ? r.clamp(eraserRadiusMin, eraserRadiusMax).toDouble() : eraserRadiusDefault;

/// Kalınlık seviyeleri (mantıksal piksel).
const penWidthLevels = <double>[1, 2, 3, 5, 8];
const highlighterWidthLevels = <double>[12, 18, 26, 36];
const penWidthMin = 1.0;
const penWidthMax = 12.0;
const highlighterWidthMin = 8.0;
const highlighterWidthMax = 40.0;

/// En yakın kalınlık seviyesinin sırası.
int nearestWidthLevel(double width, List<double> levels) {
  var best = 0;
  for (var i = 1; i < levels.length; i++) {
    if ((levels[i] - width).abs() < (levels[best] - width).abs()) best = i;
  }
  return best;
}
