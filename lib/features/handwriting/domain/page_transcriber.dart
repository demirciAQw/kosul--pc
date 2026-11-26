/// Bir sayfanın çizgilerini metne çevirir (saf Dart; tanıyıcı arayüzden gelir).
library;

import '../../ink/domain/ink_stroke_record.dart';
import 'handwriting_recognizer.dart';
import 'line_grouping.dart';
import 'transcript.dart';

const shapeMarker = '[şekil]';

class PageTranscription {
  const PageTranscription({required this.lines, required this.text, this.cancelled = false});
  final List<TranscriptLine> lines;
  final String text;

  /// Kullanıcı iptal etti: [lines] o ana kadarki kısmıdır.
  final bool cancelled;

  int get failedLines => lines.where((l) => l.failed).length;
}

/// [strokes]: sayfanın görünür çizgileri. Satır satır tanır; her satırın bağlamı
/// (en çok 20 karakter) önceki satırın sonudur. Model yoksa ya da ağ hatasında
/// [HandwritingException] fırlar; tek satırın başarısızlığı yalnız o satırı boş bırakır.
Future<PageTranscription> transcribeStrokes(
  Iterable<InkStroke> strokes,
  HandwritingRecognizer recognizer, {
  GroupingOptions options = const GroupingOptions(),
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final grouping = groupStrokesIntoLines(strokes, options: options);
  if (grouping.lines.isEmpty) return const PageTranscription(lines: [], text: '');
  final status = await recognizer.modelStatus();
  if (status == HandwritingModelStatus.unsupported) {
    throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
  }
  if (status == HandwritingModelStatus.notDownloaded) {
    throw const HandwritingException(
        HandwritingErrorKind.modelMissing, 'Türkçe el yazısı modeli indirilmemiş. Ayarlar > El yazısı tanıma.');
  }
  final out = <TranscriptLine>[];
  var prev = '';
  onProgress?.call(0, grouping.lines.length);
  for (final g in grouping.lines) {
    if (isCancelled?.call() == true) {
      return PageTranscription(lines: out, text: assemblePageText(out), cancelled: true);
    }
    String text;
    var failed = false;
    if (g.isShape) {
      text = shapeMarker;
    } else {
      final ink = toRecognizerInk(g);
      try {
        final r = await recognizer.recognizeLine(
          ink.strokes,
          preContext: prev.length > 20 ? prev.substring(prev.length - 20) : prev,
          area: ink.area,
        );
        text = cleanLineText(r ?? '');
      } on HandwritingException catch (e) {
        if (e.kind == HandwritingErrorKind.failed) {
          text = '';
          failed = true;
        } else {
          rethrow;
        }
      }
    }
    out.add(TranscriptLine(
      text: text,
      strokeIds: g.strokeIds,
      left: g.left,
      top: g.top,
      right: g.right,
      bottom: g.bottom,
      isShape: g.isShape,
      failed: failed,
    ));
    if (text.isNotEmpty && !g.isShape) prev = text;
    onProgress?.call(out.length, grouping.lines.length);
  }
  return PageTranscription(lines: out, text: assemblePageText(out));
}
