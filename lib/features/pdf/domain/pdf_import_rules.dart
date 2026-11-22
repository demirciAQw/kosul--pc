/// PDF içe aktarma kuralları (saf Dart): dosya adı → başlık, kitap önerisi.
library;

import '../../../core/text/turkish_text.dart';

/// "Tonguç_TYT-Matematik.final.pdf" → "Tonguç TYT Matematik.final"
String titleFromFileName(String fileName) {
  var name = fileName.replaceAll('\\', '/').split('/').last;
  if (name.toLowerCase().endsWith('.pdf')) name = name.substring(0, name.length - 4);
  name = name.replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  return name.isEmpty ? 'PDF' : name;
}

/// `<sha256>.pdf`: uygulama içindeki saklama adı.
String storedFileName(String sha256) => '$sha256.pdf';

class BookCandidate {
  const BookCandidate({required this.id, required this.title, this.publisher});
  final String id;
  final String title;
  final String? publisher;
}

class BookSuggestion {
  const BookSuggestion(this.bookId, this.title, this.score);
  final String bookId;
  final String title;

  /// 0..1
  final double score;
}

/// Başlığa en çok benzeyen kitapları önerir (en iyi önce). Otomatik bağlama
/// YAPMAZ; arayüz kullanıcıya sorar. [minScore] altı elenir.
List<BookSuggestion> suggestBooks(
  String pdfTitle,
  Iterable<BookCandidate> books, {
  double minScore = 0.45,
  int limit = 3,
}) {
  final q = normalizeTr(pdfTitle);
  if (q.isEmpty) return const [];
  final qBigrams = bigramsOf(q);
  final qWords = q.split(' ').where((w) => w.length > 1).toSet();
  final out = <BookSuggestion>[];
  for (final b in books) {
    final t = normalizeTr(b.title);
    if (t.isEmpty) continue;
    var score = diceCoefficient(qBigrams, bigramsOf(t));
    // Kitap adı tamamen PDF başlığında geçiyorsa (ya da tersi) güçlü eşleşme.
    if (t == q) {
      score = 1;
    } else if (t.length >= 4 && (q.contains(t) || t.contains(q))) {
      score = score < 0.85 ? 0.85 : score;
    } else {
      final tWords = t.split(' ').where((w) => w.length > 1).toSet();
      if (tWords.isNotEmpty && qWords.containsAll(tWords)) score = score < 0.8 ? 0.8 : score;
    }
    if (score >= minScore) out.add(BookSuggestion(b.id, b.title, score));
  }
  out.sort((a, b) => b.score.compareTo(a.score));
  return out.take(limit).toList();
}
