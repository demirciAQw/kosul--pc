/// El yazısı metni: satır kaydı, JSON, sayfa/defter metni birleştirme ve
/// çizgi özeti (saf Dart). Metin TÜREV veridir; çizgiler asla değişmez.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;

class TranscriptLine {
  const TranscriptLine({
    required this.text,
    required this.strokeIds,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.isShape = false,
    this.failed = false,
  });

  /// Tanınan metin ("[şekil]" işaretli satırda "[şekil]").
  final String text;
  final List<String> strokeIds;
  final double left, top, right, bottom;
  final bool isShape;

  /// Tanıma bu satırda başarısız oldu (metin boş).
  final bool failed;

  double get height => bottom - top;

  Map<String, Object?> toJson() => {
        'text': text,
        'ids': strokeIds,
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        if (isShape) 'shape': true,
        if (failed) 'failed': true,
      };

  static TranscriptLine? fromJson(Object? v) {
    if (v is! Map) return null;
    double n(Object? x) => x is num ? x.toDouble() : 0;
    final ids = v['ids'];
    return TranscriptLine(
      text: v['text'] is String ? v['text'] as String : '',
      strokeIds: ids is List ? [for (final i in ids) if (i is String) i] : const [],
      left: n(v['left']),
      top: n(v['top']),
      right: n(v['right']),
      bottom: n(v['bottom']),
      isShape: v['shape'] == true,
      failed: v['failed'] == true,
    );
  }

  static String encodeAll(List<TranscriptLine> lines) => jsonEncode([for (final l in lines) l.toJson()]);

  /// Bozuk JSON'da boş liste (okuma hiçbir zaman fırlatmaz).
  static List<TranscriptLine> decodeAll(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final v = jsonDecode(json);
      if (v is! List) return const [];
      return [
        for (final e in v)
          if (fromJson(e) case final l?) l,
      ];
    } on FormatException {
      return const [];
    }
  }
}

/// Metni boşluklardan arındırır: satır başı/sonu kırpılır, ardışık boşluklar tek olur.
String cleanLineText(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Satırlardan sayfa metni: üst üste sırayla; satırlar arası boşluk bir satır
/// yüksekliğinden büyükse paragraf boşluğu (boş satır) konur. Boş satırlar atlanır.
String assemblePageText(List<TranscriptLine> lines, {double paragraphGapFactor = 1.0}) {
  final used = [for (final l in lines) if (l.text.trim().isNotEmpty) l];
  if (used.isEmpty) return '';
  final heights = [for (final l in used) if (l.height > 0) l.height]..sort();
  final med = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];
  final b = StringBuffer(used.first.text.trim());
  for (var i = 1; i < used.length; i++) {
    final gap = used[i].top - used[i - 1].bottom;
    b.write(med > 0 && gap > med * paragraphGapFactor ? '\n\n' : '\n');
    b.write(used[i].text.trim());
  }
  return b.toString();
}

/// Sayfadaki görünür çizgilerin özeti: çizgi eklenir/silinir/taşınırsa değişir.
/// Boş sayfada ''. Sıra önemsizdir.
String strokeSignature(Iterable<({String id, int updatedAtMs})> strokes) {
  final list = strokes.toList()..sort((a, b) => a.id.compareTo(b.id));
  if (list.isEmpty) return '';
  final s = [for (final e in list) '${e.id}@${e.updatedAtMs}'].join('|');
  return sha1.convert(utf8.encode(s)).toString().substring(0, 20);
}

/// Kayıtlı metin güncel mi? Metin yoksa "eski" sayılmaz (null).
bool isTextStale({required String? storedSig, required String currentSig}) =>
    storedSig != null && storedSig != currentSig;

/// Defter metni için tek sayfa.
class PageTextEntry {
  const PageTextEntry({required this.pageNumber, required this.text, this.stale = false});

  /// Defterdeki sıra (1'den).
  final int pageNumber;
  final String text;
  final bool stale;
}

/// Tüm sayfaların metni sırayla, "Sayfa N" başlıklarıyla. Boş sayfalar
/// [includeEmpty] false iken atlanır.
String assembleNotebookText(List<PageTextEntry> pages, {String? title, bool includeEmpty = false}) {
  final b = StringBuffer();
  if (title != null && title.trim().isNotEmpty) b.writeln(title.trim());
  for (final p in pages) {
    final t = p.text.trim();
    if (t.isEmpty && !includeEmpty) continue;
    if (b.isNotEmpty) b.writeln();
    b.writeln('— Sayfa ${p.pageNumber} —');
    if (t.isNotEmpty) b.writeln(t);
  }
  return b.toString().trimRight();
}
