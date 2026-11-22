/// Çözüm katmanlarının saf mantığı (T5, Flutter'a bağlı değil): deneme listesi,
/// sonraki deneme numarası, çizim bölgesi, hangi katman hangi saydamlıkla
/// çizilir ve çizgi zamanlarından çözüm süresi.
library;

import 'dart:math' as math;

import '../../ink/domain/ink_stroke_record.dart' show StrokeTime;
import 'pdf_engine.dart';

/// Bir sorunun tek çözüm denemesi (1, 2, …).
class SolveAttempt {
  const SolveAttempt(this.no, this.strokeCount, this.duration);
  final int no;
  final int strokeCount;
  final Duration duration;
}

/// Çizgi zamanlarını denemelere böler (küçükten büyüğe). Deneme numarası 1'den
/// küçük olanlar (not çizgisi, bozuk veri) atlanır.
List<SolveAttempt> solveAttempts(Iterable<StrokeTime> strokes, {Duration maxGap = defaultMaxGap}) {
  final by = <int, List<StrokeTime>>{};
  for (final s in strokes) {
    if (s.attemptNo < 1) continue;
    by.putIfAbsent(s.attemptNo, () => []).add(s);
  }
  final nos = by.keys.toList()..sort();
  return [for (final n in nos) SolveAttempt(n, by[n]!.length, solveDuration(by[n]!, maxGap: maxGap))];
}

/// "Yeniden çöz": mevcut en büyük numaranın bir fazlası (hiç yoksa 1).
int nextAttemptNo(Iterable<int> existing) {
  var m = 0;
  for (final n in existing) {
    if (n > m) m = n;
  }
  return m + 1;
}

/// Ekranın açıldığında çalışılacak deneme: sonuncusu, hiç yoksa 1.
int currentAttemptNo(Iterable<int> existing) {
  var m = 1;
  for (final n in existing) {
    if (n > m) m = n;
  }
  return m;
}

const Duration defaultMaxGap = Duration(seconds: 30);

/// Tek çizginin sayılacak üst süresi: bozuk (çok uzun) kayıt süreyi şişirmesin.
const Duration defaultMaxStroke = Duration(minutes: 5);

/// Aktif çözüm süresi. Çizgi aralıkları [başlangıç, başlangıç+süre] birleştirilir
/// (çakışma iki kez sayılmaz). Çizgiler arası boşluk [maxGap]'ten KISAYSA tam
/// sayılır (düşünme payı); daha uzunsa duraklama (mola) sayılır ve hiç eklenmez.
/// Negatif süre 0, [maxStroke]'tan uzun süre [maxStroke] olur; başlangıcı
/// geçersiz (<= 0) çizgi atlanır. Boş liste: sıfır.
Duration solveDuration(
  Iterable<StrokeTime> strokes, {
  Duration maxGap = defaultMaxGap,
  Duration maxStroke = defaultMaxStroke,
}) {
  final spans = <(int, int)>[];
  for (final s in strokes) {
    if (s.startedAtMs <= 0) continue;
    final d = s.durationMs < 0 ? 0 : math.min<int>(s.durationMs, maxStroke.inMilliseconds);
    spans.add((s.startedAtMs, s.startedAtMs + d));
  }
  if (spans.isEmpty) return Duration.zero;
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  final gapLimit = maxGap.inMilliseconds;
  var total = 0;
  var curStart = spans.first.$1, curEnd = spans.first.$2;
  for (final s in spans.skip(1)) {
    if (s.$1 <= curEnd) {
      curEnd = math.max<int>(curEnd, s.$2);
      continue;
    }
    total += curEnd - curStart;
    final gap = s.$1 - curEnd;
    if (gap <= gapLimit) total += gap;
    curStart = s.$1;
    curEnd = s.$2;
  }
  total += curEnd - curStart;
  return Duration(milliseconds: total);
}

/// "2 dk 10 sn", "45 sn", "0 sn".
String formatSolveDuration(Duration d) {
  final sec = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = sec ~/ 60, s = sec % 60;
  if (m == 0) return '$s sn';
  return s == 0 ? '$m dk' : '$m dk $s sn';
}

/// Çözüm ekranının gösterdiği bölge (sayfa birimi): soru kutusu + çevresi.
/// Sağda ve altta yazı payı bırakılır; alt pay sayfanın DIŞINA taşabilir
/// (soru sayfanın dibindeyse de yer olsun). Sol/üst/sağ sayfaya kırpılır.
/// Geçersiz sayı ya da boş kutu: null.
PdfBox? solveRegion(
  PdfBox box,
  PdfPageSize page, {
  double side = 0.3,
  double below = 1.0,
  double pad = 12,
  double minBelow = 160,
}) {
  for (final v in [box.left, box.top, box.right, box.bottom, page.width, page.height]) {
    if (!v.isFinite) return null;
  }
  if (box.width <= 0 || box.height <= 0 || page.width <= 0 || page.height <= 0) return null;
  final l = math.max<double>(0, box.left - pad);
  final t = math.max<double>(0, box.top - pad);
  final r = math.min<double>(page.width, box.right + pad + box.width * side);
  final b = box.bottom + pad + math.max<double>(minBelow, box.height * below);
  if (r <= l) return null;
  return PdfBox(l, t, r, b);
}

/// Ekrana çizilecek bir katman.
class SolveLayerSpec {
  const SolveLayerSpec(this.attemptNo, {required this.opacity, this.tint, this.editable = false});
  final int attemptNo;

  /// 0..1.
  final double opacity;

  /// Verilirse katmanın tüm çizgileri bu ARGB renge boyanır; yoksa kendi renkleri.
  final int? tint;

  /// Kalem yalnızca bu katmana yazar (en fazla bir tane).
  final bool editable;

  @override
  bool operator ==(Object other) =>
      other is SolveLayerSpec &&
      other.attemptNo == attemptNo &&
      other.opacity == opacity &&
      other.tint == tint &&
      other.editable == editable;
  @override
  int get hashCode => Object.hash(attemptNo, opacity, tint, editable);
  @override
  String toString() => 'Katman($attemptNo, $opacity, tint=$tint, edit=$editable)';
}

const int oldAttemptTint = 0xFF757575;
const int compareTintA = 0xFF1565C0;
const int compareTintB = 0xFFC62828;
const double defaultOldOpacity = 0.4;
const double minOldOpacity = 0.1;
const double compareOpacity = 0.65;

double clampOldOpacity(double v) => v.isNaN ? defaultOldOpacity : v.clamp(minOldOpacity, 1.0);

/// Eski çözümün varsayılan seçimi: [current]'tan önceki en son deneme (yoksa null).
int? defaultOldAttempt(Iterable<int> existing, int current) {
  int? best;
  for (final n in existing) {
    if (n < current && (best == null || n > best)) best = n;
  }
  return best;
}

/// Katman planı (alttan üste).
/// - [compare] (a, b) verilmişse: iki deneme üst üste, iki renk ve saydamlıkla,
///   yazılabilir katman YOK (salt okunur). a == b ise tek katman.
/// - Aksi halde: [showOld] ve [old] geçerliyse ([existing]'te var, [current]'tan
///   farklı) eski çözüm [oldOpacity] ile altta; üstte yazılabilir [current].
List<SolveLayerSpec> planSolveLayers({
  required int current,
  required Iterable<int> existing,
  bool showOld = false,
  int? old,
  double oldOpacity = defaultOldOpacity,
  (int, int)? compare,
}) {
  final have = existing.toSet();
  if (compare != null) {
    final (a, b) = compare;
    return [
      SolveLayerSpec(a, opacity: compareOpacity, tint: compareTintA),
      if (b != a) SolveLayerSpec(b, opacity: compareOpacity, tint: compareTintB),
    ];
  }
  return [
    if (showOld && old != null && old != current && have.contains(old))
      SolveLayerSpec(old, opacity: clampOldOpacity(oldOpacity), tint: oldAttemptTint),
    SolveLayerSpec(current, opacity: 1, editable: true),
  ];
}
