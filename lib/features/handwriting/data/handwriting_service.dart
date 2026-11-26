import '../../ink/data/ink_stroke_repository.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../notes/domain/ink_notebook.dart';
import '../domain/handwriting_recognizer.dart';
import '../domain/line_grouping.dart';
import '../domain/page_transcriber.dart';
import 'page_text_repository.dart';

/// Tanıma sonucu: metin + kayıt anındaki çizgi özeti.
class PageRecognition {
  const PageRecognition(this.transcription, this.strokeSig);
  final PageTranscription transcription;
  final String strokeSig;
}

/// Sayfayı okur, tanıyıcıya verir, sonucu depoya yazar (orijinal çizgilere dokunmaz).
class HandwritingService {
  HandwritingService(this.recognizer, this._strokes, this.texts);

  final HandwritingRecognizer recognizer;
  final InkStrokeRepository _strokes;
  final PageTextRepository texts;

  /// [onlyIds] verilirse yalnız bu çizgiler (kement seçimi). Özet, tanıma ÖNCESİ
  /// alınır: araya çizgi girerse kayıt "güncel değil" görünür (güvenli yön).
  Future<PageRecognition> recognizePage(
    InkNotePageRecord page, {
    Set<String>? onlyIds,
    GroupingOptions options = const GroupingOptions(markShapes: true),
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final sig = await texts.currentSig(page.id);
    final all = await _strokes.forPage(NotePageOwner(page.id, page.pageNo), attemptNo: 0, layer: 0, noQuestion: true);
    final use = onlyIds == null ? all : [for (final s in all) if (onlyIds.contains(s.id)) s];
    final t = await transcribeStrokes(use, recognizer, options: options, onProgress: onProgress, isCancelled: isCancelled);
    return PageRecognition(t, sig);
  }

  /// Sayfa metnini kaydeder (tanıma sonucu; [lines] tanınan satırlar).
  Future<void> savePage(String pageId, PageRecognition r, {String? editedText}) => texts.save(
        pageId: pageId,
        text: editedText ?? r.transcription.text,
        lines: r.transcription.lines,
        strokeSig: r.strokeSig,
        languageCode: recognizer.languageCode,
      );
}
