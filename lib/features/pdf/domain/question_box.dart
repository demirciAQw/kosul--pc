/// "Soru seç" aracının saf mantığı (Flutter'a bağlı değil): kutu normalizasyonu,
/// kutu metni yeterli mi kararı, metinden ders/konu/tür önerisi, kitap haritası.
library;

import 'dart:math' as math;

import '../../../core/text/turkish_text.dart';
import '../../curriculum/domain/curriculum.dart';
import '../../library/domain/library.dart';
import '../../library/domain/progress.dart';
import '../../ocr/domain/auto_tags.dart';
import '../../ocr/domain/ocr.dart';
import '../../ocr/domain/question_text.dart';
import '../../ocr/domain/reader/page_reader.dart';
import 'pdf_engine.dart';

/// Bu kenardan (PDF birimi, 1/72 inç ≈ 8 mm) küçük kutu soru sayılmaz:
/// kalemin yanlışlıkla dokunuşu ve titremesi kayıt üretmesin.
const double minQuestionBoxSide = 24;

/// Kalemle sürüklenen iki köşeyi (sayfa birimi) kutuya çevirir: ters sürükleme
/// düzelir, kutu sayfa sınırına kırpılır, çok küçük ya da sonsuz/NaN kutu null.
PdfBox? normalizeQuestionBox(double x1, double y1, double x2, double y2, PdfPageSize page) {
  for (final v in [x1, y1, x2, y2, page.width, page.height]) {
    if (!v.isFinite) return null;
  }
  if (page.width <= 0 || page.height <= 0) return null;
  double cx(double v) => v < 0 ? 0 : (v > page.width ? page.width : v);
  double cy(double v) => v < 0 ? 0 : (v > page.height ? page.height : v);
  final box = PdfBox.fromCorners(cx(x1), cy(y1), cx(x2), cy(y2));
  if (box.width < minQuestionBoxSide || box.height < minQuestionBoxSide) return null;
  return box;
}

/// Kutudaki metnin kaynağı kararı.
enum BoxTextSource {
  /// PDF'in metin katmanı yeterli.
  textLayer,

  /// Metin yok (taranmış PDF): sayfa resmine çizilip ML Kit ile okunur.
  ocr,

  /// Metin yok ve okuma yolu da yok (ör. Linux): metinsiz kaydedilir.
  none,
}

const int minBoxTextChars = 20;
const int minBoxTextWords = 3;

/// Metin katmanı "yeterli" mi: en az [minBoxTextChars] harf/rakam ve
/// [minBoxTextWords] sözcük. Tek tük harf (sayfa numarası, süs) metin sayılmaz.
bool hasEnoughBoxText(String text) {
  final alnum = RegExp(r'[A-Za-z0-9ÇĞİÖŞÜçğıöşü]').allMatches(text).length;
  final words = text.split(RegExp(r'\s+')).where((w) => RegExp(r'[A-Za-z0-9ÇĞİÖŞÜçğıöşü]').hasMatch(w)).length;
  return alnum >= minBoxTextChars && words >= minBoxTextWords;
}

/// [text]: `textInBox` çıktısı. [ocrAvailable]: bu cihazda ML Kit var mı (yalnız Android).
BoxTextSource decideBoxTextSource(String text, {required bool ocrAvailable}) {
  if (hasEnoughBoxText(text)) return BoxTextSource.textLayer;
  return ocrAvailable ? BoxTextSource.ocr : BoxTextSource.none;
}

/// Kutu metninden öneri (kullanıcı düzeltebilir).
class BoxSuggestion {
  const BoxSuggestion({
    this.subject,
    this.topic,
    this.mebNodeId,
    this.questionNo,
    this.types = const [],
    this.text = '',
  });

  /// "TYT Matematik" gibi ders anahtarı; bilinmiyorsa null.
  final String? subject;

  /// Kesin konu ya da (kesin değilse) boş.
  final String? topic;
  final String? mebNodeId;

  /// Metnin başında okunan soru numarası ("7." gibi), yoksa null.
  final int? questionNo;
  final List<String> types;
  final String text;

  bool get isEmpty => subject == null && topic == null && types.isEmpty;
}

const _familySubject = {
  'mat': 'Matematik',
  'geo': 'Geometri',
  'fiz': 'Fizik',
  'kim': 'Kimya',
  'bio': 'Biyoloji',
  'tur': 'Türkçe',
  'edb': 'Edebiyat',
  'tar': 'Tarih',
  'cog': 'Coğrafya',
};

/// Metin satırlarını sayfa okuyucuya verilebilecek konumlu satırlara çevirir
/// (PDF metni konum vermez: satır sırası yeter).
List<OcrLine> linesFromPlainText(String text) {
  final rows = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  return [
    for (final (i, l) in rows.indexed)
      OcrLine(l, left: 0, top: i * 20.0, height: 16, width: 8.0 * l.length.clamp(1, 80)),
  ];
}

/// Kutu metninden ders, konu ve soru türü önerir.
///
/// [subject]: biliniyorsa (kitaptan) sabit; yoksa metinden aile skoruyla çıkarılır
/// ve [examType] ("TYT", "AYT") ile birleştirilir. Mevcut `readPage` + `autoTag`
/// kullanılır; sonuç yalnızca önerir.
BoxSuggestion suggestFromBoxText(
  String text, {
  required TopicLexicon lexicon,
  String? subject,
  String examType = 'TYT',
  List<CurriculumNode> curriculum = const [],
}) {
  final clean = text.trim();
  if (clean.isEmpty) return const BoxSuggestion();
  final lines = withWords(linesFromPlainText(clean));
  final width = lines.fold<double>(1, (m, l) => l.left + l.width > m ? l.left + l.width : m);
  final height = lines.fold<double>(1, (m, l) => l.top + l.height > m ? l.top + l.height : m);
  final reading = readPage(lines, width, height);
  final main = reading.main;
  final record = OcrRecord(
    id: 'pdf-kutu',
    ownerType: 'question',
    ownerId: 'pdf-kutu',
    imagePath: '',
    status: 'done',
    processedAt: DateTime.fromMillisecondsSinceEpoch(0),
    fullText: clean,
    parsed: main == null ? null : ParsedQuestion(stem: main.fullStem, number: main.number, options: main.options),
    lines: lines,
    structure: {'width': width.round(), 'height': height.round(), ...reading.toJson(), 'figures': const []},
  );
  var resolvedSubject = subject;
  if (resolvedSubject == null) {
    final fam = _bestFamily(lexicon, clean);
    final name = fam == null ? null : _familySubject[fam];
    if (name != null) resolvedSubject = subjectKey(examType, name);
  }
  final titles = {
    if (resolvedSubject != null)
      for (final n in curriculum)
        if (normalizeTr(n.subjectLabel).contains(normalizeTr(resolvedSubject)) ||
            normalizeTr(resolvedSubject).contains(normalizeTr(n.subjectLabel)))
          foldForTags(n.title): n.id,
  };
  final tags = autoTag(
    lexicon: lexicon,
    subject: resolvedSubject ?? '',
    record: record,
    curriculumTitles: titles,
  );
  return BoxSuggestion(
    subject: resolvedSubject,
    topic: tags.topic,
    mebNodeId: tags.curriculumId,
    questionNo: main?.number,
    types: tags.types,
    text: clean,
  );
}

/// En yüksek puanlı ders ailesi (en az 2 puan ve ikinciden 1,5 kat önde); yoksa null.
String? _bestFamily(TopicLexicon lex, String text) {
  final t = foldForTags(text);
  final scores = <String, int>{};
  for (final f in lex.families.entries) {
    var s = 0;
    for (final topic in f.value.values) {
      for (final k in topic) {
        final c = lex.patternOf(k).allMatches(t).length;
        s += (c > 2 ? 2 : c) * (k.contains(' ') ? 2 : 1);
      }
    }
    if (s > 0) scores[f.key] = s;
  }
  if (scores.isEmpty) return null;
  final sorted = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final best = sorted.first;
  final second = sorted.length > 1 ? sorted[1].value : 0;
  return best.value >= 2 && best.value >= 1.5 * second ? best.key : null;
}

/// PDF'in bağlı olduğu kitapta, kitap sayfasına düşen test/konu (kitap haritası).
class BookPageContext {
  const BookPageContext({
    required this.bookId,
    required this.subject,
    required this.sourceName,
    this.contentNodeId,
    this.mebNodeId,
    this.testLabel,
  });
  final String bookId;
  final String subject;
  final String sourceName;
  final String? contentNodeId;
  final String? mebNodeId;
  final String? testLabel;
}

/// [bookPage] (1'den) sayfasını kapsayan en derin düğüm; yoksa yalnızca kitap bilgisi.
BookPageContext bookContextForPage(Book book, int bookPage) {
  ContentNode? best;
  for (final n in book.allNodes) {
    if (!n.hasPages) continue;
    if (bookPage < n.pageStart! || bookPage > n.pageEnd!) continue;
    // En derin = en dar aralık (eşitse sonra gelen, yani daha derin).
    if (best == null || (n.pageEnd! - n.pageStart!) <= (best.pageEnd! - best.pageStart!)) best = n;
  }
  return BookPageContext(
    bookId: book.id,
    subject: subjectKey(book.examType, book.subject),
    sourceName: book.title,
    contentNodeId: best?.id,
    mebNodeId: best == null ? null : effectiveMeb(book, best.id),
    testLabel: best == null ? null : nodeLabel(book, best.id),
  );
}

/// Kutuyu sayfadan kırpmak için çizim planı: sayfa [renderWidth] x [renderHeight]
/// piksele çizilir, sonra [cropX], [cropY], [cropWidth], [cropHeight] kesilir.
class BoxRenderPlan {
  const BoxRenderPlan({
    required this.renderWidth,
    required this.renderHeight,
    required this.cropX,
    required this.cropY,
    required this.cropWidth,
    required this.cropHeight,
  });
  final int renderWidth;
  final int renderHeight;
  final int cropX;
  final int cropY;
  final int cropWidth;
  final int cropHeight;
}

/// Kutu [targetWidth] piksel genişliğinde çıksın; sayfa çizim sınırını
/// ([maxRenderPixels]) aşıyorsa ölçek düşürülür (sessiz değil: çıktı genişliği
/// planda görünür). Kutu sayfaya kırpılmış olmalıdır.
BoxRenderPlan planBoxRender(PdfPageSize page, PdfBox box, int targetWidth) {
  var scale = targetWidth / box.width;
  final limit = (maxRenderPixels * 0.9) / (page.width * page.height);
  final maxScale = limit <= 0 ? 1.0 : math.sqrt(limit);
  if (scale > maxScale) scale = maxScale;
  final rw = (page.width * scale).round().clamp(1, 1 << 15);
  final rh = (page.height * scale).round().clamp(1, 1 << 15);
  final sx = rw / page.width, sy = rh / page.height;
  final x = (box.left * sx).floor().clamp(0, rw - 1);
  final y = (box.top * sy).floor().clamp(0, rh - 1);
  final w = ((box.right * sx).ceil() - x).clamp(1, rw - x);
  final h = ((box.bottom * sy).ceil() - y).clamp(1, rh - y);
  return BoxRenderPlan(renderWidth: rw, renderHeight: rh, cropX: x, cropY: y, cropWidth: w, cropHeight: h);
}
