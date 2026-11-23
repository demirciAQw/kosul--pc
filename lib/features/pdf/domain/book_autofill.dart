/// PDF'ten kitap ekleme formunu otomatik doldurma (saf Dart).
///
/// Dolduramadığı alan `null` kalır; arayüz o alanı vurgular ve kullanıcıya
/// doldurtur. Hiçbir tahmin sessizce kaydedilmez: kullanıcı hepsini değiştirebilir.
library;

import '../../../core/text/turkish_text.dart';
import '../../curriculum/domain/yks.dart';
import '../../ocr/domain/auto_tags.dart';
import 'pdf_import_rules.dart';

/// Bilinen yayınevleri (kanonik ad). Dosya adı, PDF yazarı ve ilk sayfa
/// metninde tam sözcük olarak aranır.
const knownPublishers = <String>[
  'Bilgi Sarmal',
  'Tonguç',
  'Orijinal',
  'Aydın',
  'Palme',
  'Karekök',
  'Apotemi',
  'Hız ve Renk',
  'Yayın Denizi',
  'Fenomen',
  'Endemik',
  'Kafa Dengi',
  'Nitelik',
  'Zafer',
  'Antrenman',
  'Pegem',
  'Üç Dört Beş',
  'Paraf',
  'Benim Hocam',
  'Bilfen',
  'MEB',
];

/// Dosya adının sonundan atılacak gürültü sözcükleri.
final _noiseWord = RegExp(
  r'(\s+(v|ver|surum|sürüm)\s*\d+([.,]\d+)*|\s+\(\d+\)|\s+(final|son|yeni|kopya|copy|indir|compressed|sikistirilmis|sıkıştırılmış|min|pdf|ocr|scan)|\s+-\s*(kopya|copy))$',
  caseSensitive: false,
);

/// Dosya adından kitap başlığı: uzantı, alt çizgi/tire/nokta, sürüm ve kopya ekleri,
/// site adları atılır. "Tonguç_TYT-Matematik_v2 (1).pdf" → "Tonguç TYT Matematik".
String cleanBookTitle(String fileName) {
  var name = fileName.replaceAll('\\', '/').split('/').last;
  name = name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
  name = name.replaceAll(RegExp(r'(www\.)?[A-Za-z0-9-]+\.(com|net|org|info|tr)(\.tr)?\b', caseSensitive: false), ' ');
  name = name.replaceAll('_', ' ');
  name = name.replaceAll(RegExp(r'\s*[-–—]\s*'), ' ');
  // Harfler arasındaki noktalar ("Tyt.Matematik.final"); sayı noktaları durur.
  name = name.replaceAllMapped(RegExp(r'(?<=\p{L})\.(?=\p{L})', unicode: true), (_) => ' ');
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  for (var i = 0; i < 6; i++) {
    final next = name.replaceFirst(_noiseWord, '').trim();
    if (next == name) break;
    name = next;
  }
  if (name.isEmpty) return titleFromFileName(fileName);
  final hasUpper = name.runes.any((r) => String.fromCharCode(r) != String.fromCharCode(r).toLowerCase() || r == 0x130);
  if (!hasUpper) {
    name = titleCaseTr(name).replaceAllMapped(RegExp(r'\b(Tyt|Ayt|Ydt|Yks)\b'), (m) => m[0]!.toUpperCase());
  }
  return name;
}

/// Sıradan sözcük olarak da geçen yayınevi adları: yalnız hemen ardından
/// "yayın..." (Yayınları, Yayıncılık, Yayınevi) gelirse eşleşir
/// ("Orijinal soru", "Zafer Bayramı", "Antrenman programı" yayınevi sayılmaz).
const _ambiguousPublishers = {'Orijinal', 'Aydın', 'Nitelik', 'Zafer', 'Antrenman', 'Paraf', 'Fenomen'};

/// Metinde (katlanmış, tam sözcük) geçen ilk bilinen yayınevi; yoksa null.
String? findPublisher(String text) {
  final t = ' ${normalizeTr(text)} ';
  for (final p in knownPublishers) {
    final n = normalizeTr(p);
    if (_ambiguousPublishers.contains(p)) {
      if (RegExp('(^| )${RegExp.escape(n)} yayin').hasMatch(t)) return p;
    } else if (t.contains(' $n ')) {
      return p;
    }
  }
  return null;
}

/// TYT / AYT / YDT: önce başlıkta, yoksa metinde baskın olanı; belirsizse null.
String? guessExamType(String title, String text) {
  String? of(String s) {
    final t = ' ${normalizeTr(s)} ';
    final hits = [for (final e in const ['TYT', 'AYT', 'YDT']) if (t.contains(' ${e.toLowerCase()} ')) e];
    return hits.length == 1 ? hits.single : null;
  }

  final fromTitle = of(title);
  if (fromTitle != null) return fromTitle;
  final t = ' ${normalizeTr(text)} ';
  final c = {for (final e in const ['TYT', 'AYT', 'YDT']) e: ' ${e.toLowerCase()} '.allMatches(t).length};
  // Aynı sayfada hem TYT hem AYT geçebilir; açık fark (en az 2 kat) iste.
  final sorted = c.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  if (sorted.first.value >= 1 && sorted.first.value >= 2 * sorted[1].value) return sorted.first.key;
  return null;
}

/// Ders taban adları: başlıkta aranan sözcük → taban ad.
const _titleSubjects = <String, String>{
  'matematik': 'Matematik',
  'geometri': 'Matematik',
  'fizik': 'Fizik',
  'kimya': 'Kimya',
  'biyoloji': 'Biyoloji',
  'turkce': 'Türkçe',
  'edebiyat': 'Edebiyat',
  'tarih': 'Tarih',
  'cografya': 'Coğrafya',
  'felsefe': 'Felsefe',
  'din kulturu': 'Din Kültürü',
  'ingilizce': 'Yabancı Dil',
  'yabanci dil': 'Yabancı Dil',
};

/// Sözlük ailesi → taban ders.
const _familySubject = <String, String>{
  'mat': 'Matematik',
  'geo': 'Matematik',
  'fiz': 'Fizik',
  'kim': 'Kimya',
  'bio': 'Biyoloji',
  'tur': 'Türkçe',
  'edb': 'Edebiyat',
  'tar': 'Tarih',
  'cog': 'Coğrafya',
};

/// Sınava ait ders adları ([exam] null ise hepsi, tekrarsız).
List<String> subjectsFor(String? exam) {
  final out = <String>[];
  for (final s in [...Yks.tyt, ...Yks.ayt, ...Yks.ydt]) {
    if ((exam == null || s.examType == exam) && !out.contains(s.name)) out.add(s.name);
  }
  return out;
}

/// "Matematik" ya da "Tarih" gibi taban adı o sınavın ders adına çevirir
/// ("Tarih" + AYT → "Tarih-1"). Sınav null ise TYT, sonra AYT, sonra YDT. Bulamazsa null.
String? resolveSubject(String? subject, String? exam) {
  if (subject == null) return null;
  final base = normalizeTr(subject);
  final exams = exam == null ? const ['TYT', 'AYT', 'YDT'] : [exam];
  for (final e in exams) {
    for (final name in subjectsFor(e)) {
      final n = normalizeTr(name);
      if (n == base || n.startsWith('$base ')) return name;
    }
  }
  return null;
}

/// Ders tahmini: önce başlıkta ders adı; yoksa ilk sayfaların metninden konu
/// sözlüğüyle (yeterince güvenliyse). Güven yoksa null.
String? guessSubject(String title, String text, TopicLexicon? lexicon) {
  final t = ' ${normalizeTr(title)} ';
  String? best;
  var bestAt = 1 << 30;
  for (final e in _titleSubjects.entries) {
    final at = t.indexOf(' ${e.key}');
    if (at >= 0 && at < bestAt) {
      best = e.value;
      bestAt = at;
    }
  }
  if (best != null) return best;
  if (lexicon == null || text.trim().isEmpty) return null;
  final folded = foldForTags(text);
  final scores = <String, int>{};
  for (final fam in lexicon.families.entries) {
    final subject = _familySubject[fam.key];
    if (subject == null) continue;
    var s = 0;
    for (final topic in fam.value.values) {
      for (final k in topic) {
        final c = lexicon.patternOf(k).allMatches(folded).length;
        s += (c > 3 ? 3 : c) * (k.contains(' ') ? 2 : 1);
      }
    }
    if (s > 0) scores[subject] = (scores[subject] ?? 0) + s;
  }
  if (scores.isEmpty) return null;
  final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final top = ranked.first.value;
  final second = ranked.length > 1 ? ranked[1].value : 0;
  return top >= 8 && top >= 2 * second ? ranked.first.key : null;
}

/// Kitabın 1. sayfası PDF'te [firstPdfPage]. (1'den) sayfadaysa sayfa ofseti.
/// Kayıt kuralı: kitap sayfası = pdf sayfası (0'dan) + 1 + ofset.
int offsetFromFirstPage(int firstPdfPage) => 1 - firstPdfPage;

/// [offsetFromFirstPage]'in tersi.
int firstPageFromOffset(int offset) => 1 - offset;

/// Formun açılış değerleri. `null` = otomatik doldurulamadı (kullanıcı doldurur).
class BookAutofill {
  const BookAutofill({
    required this.title,
    required this.pageCount,
    this.publisher,
    this.exam,
    this.subject,
    this.firstPdfPage = 1,
  });

  final String title;
  final int pageCount;
  final String? publisher;
  final String? exam;
  final String? subject;

  /// Kitabın 1. sayfası PDF'te kaçıncı sayfa (varsayılan 1).
  final int firstPdfPage;

  /// Kullanıcı doldurmadan kaydedilemeyen alanlardan eksik olan var mı.
  bool get missingRequired => exam == null || subject == null || title.trim().isEmpty || pageCount < 1;
}

/// Tüm ipuçlarından form açılış değerleri. [metaTitle]/[metaAuthor] PDF
/// üst verisidir (varsa); [text] ilk birkaç sayfanın metin katmanıdır.
BookAutofill buildBookAutofill({
  required String fileName,
  required int pageCount,
  String? metaTitle,
  String? metaAuthor,
  String text = '',
  TopicLexicon? lexicon,
}) {
  final meta = (metaTitle ?? '').trim();
  final title = meta.length >= 3 ? normalizePdfTitle(meta) : cleanBookTitle(fileName);
  final exam = guessExamType(title, text);
  final base = guessSubject(title, text, lexicon);
  final publisher = findPublisher(metaAuthor ?? '') ??
      findPublisher(title) ??
      findPublisher(fileName) ??
      findPublisher(text.length > 2000 ? text.substring(0, 2000) : text);
  return BookAutofill(
    title: title,
    pageCount: pageCount,
    publisher: publisher,
    exam: exam,
    subject: resolveSubject(base, exam),
  );
}
